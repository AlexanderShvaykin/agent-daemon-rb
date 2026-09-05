# frozen_string_literal: true

require "test_helper"

class FakeNotFound < Net::HTTPNotFound
  def initialize = nil
  def code = "404"
  def body = ""
  def [](_name) = nil
end

class FakeRateLimited < Net::HTTPTooManyRequests
  def initialize(retry_after = nil, body = "")
    @retry_after = retry_after
    @fake_body = body
  end

  def code = "429"
  def body = @fake_body
  def [](name) = name.casecmp("retry-after").zero? ? @retry_after : nil
end

class FakeApiError < Net::HTTPClientError
  def initialize(code, body, content_type = "application/json")
    @fake_code = code
    @fake_body = body
    @content_type = content_type
  end

  def code = @fake_code
  def body = @fake_body
  def [](name) = name.casecmp("content-type").zero? ? @content_type : nil
end

class TestPachcaClient < Minitest::Test
  CONFIG = { "token" => "tok" }.freeze

  def client(config = CONFIG)
    AgentDaemon::Pachca::Client.new(config)
  end

  def json(data)
    FakeSuccess.new(JSON.generate(data))
  end

  def test_events_are_returned_oldest_first_by_ulid
    fake = FakeHttp.new do |_req|
      json("data" => [
        { "id" => "01C", "event_type" => "message_new" },
        { "id" => "01A", "event_type" => "message_new" },
        { "id" => "01B", "event_type" => "message_new" }
      ])
    end

    events = stub_net_http(fake) { client.events }

    assert_equal %w[01A 01B 01C], events.map { |event| event["id"] }
  end

  def test_events_hits_the_shared_v1_path_with_the_bearer_token_and_limit
    fake = FakeHttp.new { |_req| json("data" => []) }

    stub_net_http(fake) { client.events(limit: 7) }

    request = fake.requests.first
    assert_equal "/api/shared/v1/webhooks/events?limit=7", request.path
    assert_equal "Bearer tok", request["Authorization"]
  end

  def test_events_tolerates_a_missing_data_key
    fake = FakeHttp.new { |_req| json({}) }

    assert_empty stub_net_http(fake) { client.events }
  end

  # --- messages -------------------------------------------------------------

  # Newest first from the API, oldest first out of here: a transcript is read
  # forwards.
  def test_messages_come_back_oldest_first
    fake = FakeHttp.new do |_req|
      json("data" => [{ "id" => 3 }, { "id" => 2 }, { "id" => 1 }], "meta" => { "paginate" => {} })
    end

    assert_equal [1, 2, 3], stub_net_http(fake) { client.messages(chat_id: 900) }.map { |m| m["id"] }
  end

  def test_a_limit_within_one_page_makes_one_request
    fake = FakeHttp.new { |_req| json("data" => [{ "id" => 1 }], "meta" => { "paginate" => {} }) }

    stub_net_http(fake) { client.messages(chat_id: 900, limit: 10) }

    assert_equal 1, fake.requests.size
    assert_includes fake.requests.first.path, "chat_id=900&sort=id&order=desc&limit=10"
  end

  # One request returns at most 50, so a bigger limit is walked back through
  # the cursor — which is opaque base64 and has to be escaped, not pasted in.
  def test_a_larger_limit_pages_through_the_cursor
    pages = [
      { "data" => Array.new(50) { |i| { "id" => 100 - i } }, "meta" => { "paginate" => { "next_page" => "cur/sor+1=" } } },
      { "data" => Array.new(50) { |i| { "id" => 50 - i } }, "meta" => { "paginate" => { "next_page" => nil } } }
    ]
    fake = FakeHttp.new { |_req| json(pages.shift) }

    result = stub_net_http(fake) { client.messages(chat_id: 900, limit: 120) }

    assert_equal 2, fake.requests.size
    assert_includes fake.requests.first.path, "limit=50"
    refute_includes fake.requests.first.path, "cursor="
    assert_includes fake.requests.last.path, "cursor=cur%2Fsor%2B1%3D"
    assert_equal 100, result.size
    assert_equal 1, result.first["id"], "oldest first across pages"
  end

  # Asking for more than the chat holds costs one extra request, not a scan.
  def test_paging_stops_when_a_page_comes_back_empty
    pages = [
      { "data" => Array.new(50) { |i| { "id" => 50 - i } }, "meta" => { "paginate" => { "next_page" => "c2" } } },
      { "data" => [], "meta" => { "paginate" => { "next_page" => "c3" } } }
    ]
    fake = FakeHttp.new { |_req| json(pages.shift || { "data" => [] }) }

    assert_equal 50, stub_net_http(fake) { client.messages(chat_id: 900, limit: 500) }.size
    assert_equal 2, fake.requests.size
  end

  # The last page is a full one with no cursor: nothing left to ask for.
  def test_paging_stops_when_there_is_no_next_cursor
    fake = FakeHttp.new do |_req|
      json("data" => Array.new(50) { |i| { "id" => 50 - i } }, "meta" => { "paginate" => { "next_page" => nil } })
    end

    stub_net_http(fake) { client.messages(chat_id: 900, limit: 500) }

    assert_equal 1, fake.requests.size
  end

  # A server that keeps handing back the same cursor must not spin this loop
  # in front of an agent that has not started yet.
  def test_a_repeated_cursor_does_not_loop_forever
    fake = FakeHttp.new do |_req|
      json("data" => Array.new(50) { |i| { "id" => 50 - i } }, "meta" => { "paginate" => { "next_page" => "same" } })
    end

    stub_net_http(fake) { client.messages(chat_id: 900, limit: 500) }

    assert_equal 2, fake.requests.size, "the second page repeats the cursor and ends it"
  end

  # Nor must one that always offers a fresh cursor.
  def test_an_endless_cursor_is_capped_by_max_pages
    n = 0
    fake = FakeHttp.new do |_req|
      n += 1
      json("data" => Array.new(50) { |i| { "id" => (n * 100) - i } }, "meta" => { "paginate" => { "next_page" => "c#{n}" } })
    end

    stub_net_http(fake) { client.messages(chat_id: 900, limit: 100_000) }

    assert_equal AgentDaemon::Pachca::Client::MAX_PAGES, fake.requests.size
  end

  def test_a_zero_limit_asks_for_nothing
    fake = FakeHttp.new { |_req| flunk("must not be called") }

    assert_empty stub_net_http(fake) { client.messages(chat_id: 900, limit: 0) }
  end

  def test_delete_event_issues_a_delete_for_the_escaped_id
    fake = FakeHttp.new { |_req| FakeSuccess.new("") }

    assert stub_net_http(fake) { client.delete_event("01A/B") }

    request = fake.requests.first
    assert_equal "DELETE", request.method
    assert_equal "/api/shared/v1/webhooks/events/01A%2FB", request.path
  end

  # The event is gone, which is exactly the state the caller asked for.
  def test_delete_event_treats_404_as_success
    fake = FakeHttp.new { |_req| FakeNotFound.new }

    assert stub_net_http(fake) { client.delete_event("01A") }
  end

  # A read 404 is a real failure; only the delete is idempotent.
  def test_events_still_raises_on_404
    fake = FakeHttp.new { |_req| FakeNotFound.new }

    error = assert_raises(RuntimeError) { stub_net_http(fake) { client.events } }
    assert_match(/returned 404/, error.message)
  end

  def test_429_raises_a_rate_limit_error_carrying_retry_after
    fake = FakeHttp.new { |_req| FakeRateLimited.new("12") }

    error = assert_raises(AgentDaemon::RateLimitError) { stub_net_http(fake) { client.events } }
    assert_equal 12, error.retry_after
  end

  # Runner::Base rescues the shared parent, so a throttle must not escalate to
  # a SYSTEM:<runner> message the way a trigger error does.
  def test_rate_limit_error_is_the_shared_kind_runner_base_rescues
    fake = FakeHttp.new { |_req| FakeRateLimited.new("3") }

    error = assert_raises(AgentDaemon::RateLimitError) { stub_net_http(fake) { client.events } }
    assert_kind_of AgentDaemon::RateLimitError, error
  end

  def test_429_without_a_usable_retry_after_falls_back_to_the_configured_backoff
    fake = FakeHttp.new { |_req| FakeRateLimited.new("Wed, 21 Oct 2026 07:28:00 GMT") }

    error = assert_raises(AgentDaemon::RateLimitError) do
      stub_net_http(fake) { client("token" => "tok", "default_backoff" => 42).events }
    end
    assert_equal 42, error.retry_after
  end

  def test_api_error_bodies_are_summarised_from_the_errors_array
    body = JSON.generate("errors" => [{ "key" => "content", "message" => "не может быть пустым", "code" => "blank" }])
    fake = FakeHttp.new { |_req| FakeApiError.new("422", body) }

    error = assert_raises(RuntimeError) { stub_net_http(fake) { client.events } }
    assert_match(/content не может быть пустым/, error.message)
  end

  def test_oauth_error_bodies_are_summarised_from_error_and_description
    body = JSON.generate("error" => "invalid_token", "error_description" => "token expired")
    fake = FakeHttp.new { |_req| FakeApiError.new("401", body) }

    error = assert_raises(RuntimeError) { stub_net_http(fake) { client.events } }
    assert_match(/invalid_token: token expired/, error.message)
  end

  # The request-frequency limiter answers text/plain, so a body that does not
  # claim to be JSON must be passed through, never parsed.
  def test_non_json_error_bodies_are_passed_through_verbatim
    fake = FakeHttp.new { |_req| FakeApiError.new("403", "Rate limit exceeded", "text/plain") }

    error = assert_raises(RuntimeError) { stub_net_http(fake) { client.events } }
    assert_match(/Rate limit exceeded/, error.message)
  end

  def test_malformed_json_error_bodies_do_not_raise_a_parser_error
    fake = FakeHttp.new { |_req| FakeApiError.new("500", "{not json", "application/json") }

    error = assert_raises(RuntimeError) { stub_net_http(fake) { client.events } }
    assert_match(/\{not json/, error.message)
  end
end
