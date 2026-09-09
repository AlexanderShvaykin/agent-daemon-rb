# frozen_string_literal: true

require "test_helper"

class FakeGitHubForbidden < Net::HTTPForbidden
  def initialize(headers = {})
    @headers = headers
  end

  def code = "403"
  def body = '{"message":"API rate limit exceeded"}'
  def [](name) = @headers[name]
end

class FakeGitHubError < Net::HTTPClientError
  def initialize(code, body)
    @fake_code = code
    @fake_body = body
  end

  def code = @fake_code
  def body = @fake_body
  def [](_name) = nil
end

class TestGitHubClient < Minitest::Test
  CONFIG = { "token" => "tok" }.freeze

  def client(config = CONFIG)
    AgentDaemon::GitHub::Client.new(config)
  end

  def json(data)
    FakeSuccess.new(JSON.generate(data))
  end

  def test_notifications_come_back_oldest_first
    fake = FakeHttp.new do |_req|
      json([{ "id" => "3", "updated_at" => "2026-09-06T12:00:00Z" },
            { "id" => "1", "updated_at" => "2026-09-06T10:00:00Z" },
            { "id" => "2", "updated_at" => "2026-09-06T11:00:00Z" }])
    end

    assert_equal %w[1 2 3], stub_net_http(fake) { client.notifications }.map { |n| n["id"] }
  end

  # participating=true narrows the inbox to threads this account was mentioned
  # in or asked to review — the only kind the trigger acts on.
  def test_notifications_ask_only_for_participating_threads
    fake = FakeHttp.new { |_req| json([]) }

    stub_net_http(fake) { client.notifications }

    request = fake.requests.first
    assert_equal "/notifications?participating=true", request.path
    assert_equal "Bearer tok", request["Authorization"]
    assert_equal "2022-11-28", request["X-GitHub-Api-Version"]
  end

  def test_mark_read_patches_the_thread
    fake = FakeHttp.new { |_req| FakeSuccess.new("") }

    assert stub_net_http(fake) { client.mark_read("123") }

    request = fake.requests.first
    assert_equal "PATCH", request.method
    assert_equal "/notifications/threads/123", request.path
  end

  # An unreadable comment must not raise: the caller treats nil as "cannot
  # attribute this notification" and declines to act, which is the safe
  # outcome. A raise would instead escalate to a trigger error.
  def test_an_unreadable_comment_is_nil_rather_than_an_error
    fake = FakeHttp.new { |_req| FakeGitHubError.new("404", '{"message":"Not Found"}') }

    assert_nil stub_net_http(fake) { client.comment("https://api.github.com/x") }
  end

  def test_a_blank_comment_url_makes_no_request
    fake = FakeHttp.new { |_req| flunk("must not be called") }

    assert_nil stub_net_http(fake) { client.comment(nil) }
    assert_nil stub_net_http(fake) { client.comment("") }
  end

  # GitHub signals a primary rate limit with 403 plus a zero remaining count,
  # not with 429. Read as a plain error it would escalate to a SYSTEM message
  # instead of backing off.
  def test_a_403_with_no_remaining_quota_is_a_rate_limit
    fake = FakeHttp.new do |_req|
      FakeGitHubForbidden.new("X-RateLimit-Remaining" => "0",
                              "X-RateLimit-Reset" => (Time.now.to_i + 45).to_s)
    end

    error = assert_raises(AgentDaemon::RateLimitError) { stub_net_http(fake) { client.notifications } }
    assert_in_delta 45, error.retry_after, 2
  end

  # A 403 that is not about quota is a real refusal — permissions, a blocked
  # token — and must not be retried as pacing.
  def test_an_ordinary_403_stays_an_error
    fake = FakeHttp.new { |_req| FakeGitHubForbidden.new("X-RateLimit-Remaining" => "4999") }

    assert_raises(RuntimeError) { stub_net_http(fake) { client.notifications } }
  end

  def test_a_rate_limit_without_usable_headers_falls_back_to_the_configured_backoff
    fake = FakeHttp.new { |_req| FakeGitHubForbidden.new("X-RateLimit-Remaining" => "0") }

    error = assert_raises(AgentDaemon::RateLimitError) do
      stub_net_http(fake) { client("token" => "tok", "default_backoff" => 30).notifications }
    end
    assert_equal 30, error.retry_after
  end

  def test_error_bodies_are_summarised_from_the_message_field
    fake = FakeHttp.new { |_req| FakeGitHubError.new("422", '{"message":"Validation failed"}') }

    error = assert_raises(RuntimeError) { stub_net_http(fake) { client.notifications } }
    assert_match(/Validation failed/, error.message)
  end
end
