# frozen_string_literal: true

require "test_helper"
require "tmpdir"

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

  # --- uploads -------------------------------------------------------------

  SIGNATURE = {
    "Content-Disposition" => "attachment",
    "acl" => "private",
    "policy" => "eyJleHBpcmF0aW9u",
    "x-amz-credential" => "7085e6/20260907/ru-1a/s3/aws4_request",
    "x-amz-algorithm" => "AWS4-HMAC-SHA256",
    "x-amz-date" => "20260907T131043Z",
    "x-amz-signature" => "cd7cec6b",
    "key" => "attaches/files/825566/dd9698fc/${filename}",
    "direct_url" => "https://pachca-prod-uploads.s3.storage.selcloud.ru"
  }.freeze

  # The storage answers 204 with an empty body, which is why the second leg is
  # checked for Net::HTTPSuccess rather than a 201.
  class FakeNoContent < Net::HTTPSuccess
    def initialize = nil
    def code = "204"
    def body = ""
  end

  def with_file(basename, bytes = "\x89PNG\r\n\x1a\n binary".b)
    Dir.mktmpdir do |dir|
      path = File.join(dir, basename)
      File.binwrite(path, bytes)
      yield path
    end
  end

  def upload_fake
    FakeHttp.new do |req|
      req.path.start_with?("/api/") ? json(SIGNATURE) : FakeNoContent.new
    end
  end

  def test_upload_signs_then_stores_and_returns_the_message_descriptor
    fake = upload_fake

    descriptor = with_file("chart.png") { |path| stub_net_http(fake) { client.upload(path) } }

    assert_equal "POST", fake.requests.first.method
    assert_equal "/api/shared/v1/uploads", fake.requests.first.path
    assert_equal({ "key" => "attaches/files/825566/dd9698fc/chart.png", "name" => "chart.png",
                   "file_type" => "image", "size" => 15 }, descriptor)
  end

  # The signed policy fixes both the field set and their order, and S3 stops
  # reading the form at the file part — so "file" last is a protocol
  # requirement, not a style choice.
  def test_the_stored_form_carries_the_signed_fields_in_order_with_the_file_last
    fake = upload_fake

    with_file("chart.png") { |path| stub_net_http(fake) { client.upload(path) } }

    stored = fake.requests.last
    assert_equal "/", stored.path
    assert_nil stored["Authorization"]
    assert_match(%r{\Amultipart/form-data; boundary=AgentDaemon-\h{32}\z}, stored["Content-Type"])

    # "; name=" so the file part contributes "file" and not its filename too.
    names = stored.body.scan(/; name="([^"]+)"/).flatten
    assert_equal ["Content-Disposition", "acl", "policy", "x-amz-credential", "x-amz-algorithm",
                  "x-amz-date", "x-amz-signature", "key", "file"], names
    assert_includes stored.body, "attaches/files/825566/dd9698fc/chart.png"
    assert_includes stored.body, "filename=\"chart.png\""
  end

  # A PNG does not survive a transcode, so the assembled body stays binary.
  def test_the_stored_body_keeps_the_bytes_intact
    fake = upload_fake
    bytes = "\x89PNG\r\n\x1a\n\xFF\xFE".b

    with_file("shot.png", bytes) { |path| stub_net_http(fake) { client.upload(path) } }

    body = fake.requests.last.body
    assert_equal Encoding::BINARY, body.encoding
    assert_includes body, bytes
  end

  def test_upload_names_the_file_type_from_the_extension
    fake = upload_fake

    log = with_file("run.log") { |path| stub_net_http(fake) { client.upload(path) } }

    assert_equal "file", log["file_type"]
  end

  def test_an_explicit_name_and_file_type_win_over_the_inferred_ones
    fake = upload_fake

    descriptor = with_file("tmp1234.png") do |path|
      stub_net_http(fake) { client.upload(path, name: "Отчёт.png", file_type: "file") }
    end

    assert_equal "Отчёт.png", descriptor["name"]
    assert_equal "file", descriptor["file_type"]
    assert_equal "attaches/files/825566/dd9698fc/Отчёт.png", descriptor["key"]
  end

  def test_a_missing_file_raises_before_any_request_is_made
    fake = upload_fake

    error = assert_raises(RuntimeError) { stub_net_http(fake) { client.upload("/nope/missing.png") } }

    assert_match(%r{/nope/missing\.png is not a readable file}, error.message)
    assert_empty fake.requests
  end

  def test_a_storage_failure_raises_with_the_status_and_body
    fake = FakeHttp.new do |req|
      req.path.start_with?("/api/") ? json(SIGNATURE) : FakeServerError.new
    end

    error = assert_raises(RuntimeError) do
      with_file("chart.png") { |path| stub_net_http(fake) { client.upload(path) } }
    end

    assert_match(/upload to pachca-prod-uploads\.s3\.storage\.selcloud\.ru returned 503: unavailable/, error.message)
  end

  def test_create_message_carries_file_descriptors_and_omits_an_empty_list
    fake = FakeHttp.new { |_req| json("data" => { "id" => 1 }) }
    files = [{ "key" => "attaches/files/1/2/chart.png", "name" => "chart.png",
               "file_type" => "image", "size" => 17 }]

    stub_net_http(fake) do
      client.create_message(entity_type: "discussion", entity_id: 900, content: "с файлом", files: files)
      client.create_message(entity_type: "discussion", entity_id: 900, content: "без файлов", files: [])
    end

    assert_equal files, JSON.parse(fake.requests.first.body).dig("message", "files")
    refute_includes JSON.parse(fake.requests.last.body).fetch("message"), "files"
  end
end
