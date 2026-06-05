# frozen_string_literal: true

require "test_helper"
require "json"
require "webrick"

class TestTracker < Minitest::Test
  def with_server
    captured = { body: nil, headers: nil }
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/v2/issues/_search") do |req, res|
      captured[:body] = req.body
      captured[:headers] = req.header
      res["Content-Type"] = "application/json"
      res.body = [{ "key" => "TI-1" }].to_json
    end
    thread = Thread.new { server.start }
    yield "http://127.0.0.1:#{server.config[:Port]}", captured
  ensure
    server&.shutdown
    thread&.join(2)
  end

  def test_query_passed_verbatim_with_cyrillic
    query = 'Queue: BUGS AND Status: "In Review" AND Tags: needs-review'
    with_server do |base_url, captured|
      tracker = AgentDaemon::Tracker.new(
        "token" => "tok", "org_id" => "org", "base_url" => base_url
      )
      tracker.search_issues(query)

      body = JSON.parse(captured[:body])
      assert_equal query, body["query"]
    end
  end

  def test_returns_parsed_json_array
    with_server do |base_url, _|
      tracker = AgentDaemon::Tracker.new(
        "token" => "tok", "org_id" => "org", "base_url" => base_url
      )
      result = tracker.search_issues("Queue: TI")
      assert_equal 1, result.size
      assert_equal "TI-1", result.first["key"]
    end
  end

  # Mount a handler that answers every request with the given status and
  # headers, so rate-limit and error paths can be exercised against a real
  # Net::HTTP round-trip.
  def with_status_server(status:, headers: {})
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/v2/issues/_search") do |_req, res|
      res.status = status
      headers.each { |k, v| res[k] = v }
      res.body = "throttled"
    end
    thread = Thread.new { server.start }
    yield "http://127.0.0.1:#{server.config[:Port]}"
  ensure
    server&.shutdown
    thread&.join(2)
  end

  def test_429_with_retry_after_raises_rate_limit_error
    with_status_server(status: 429, headers: { "Retry-After" => "30" }) do |base_url|
      tracker = AgentDaemon::Tracker.new(
        "token" => "tok", "org_id" => "org", "base_url" => base_url, "default_backoff" => 60
      )
      err = assert_raises(AgentDaemon::Tracker::RateLimitError) { tracker.search_issues("Queue: TI") }
      assert_equal 30, err.retry_after
    end
  end

  def test_429_without_retry_after_uses_default_backoff
    with_status_server(status: 429) do |base_url|
      tracker = AgentDaemon::Tracker.new(
        "token" => "tok", "org_id" => "org", "base_url" => base_url, "default_backoff" => 45
      )
      err = assert_raises(AgentDaemon::Tracker::RateLimitError) { tracker.search_issues("Queue: TI") }
      assert_equal 45, err.retry_after
    end
  end

  def test_429_with_unparseable_retry_after_uses_default_backoff
    with_status_server(status: 429, headers: { "Retry-After" => "Wed, 21 Oct 2026 07:28:00 GMT" }) do |base_url|
      tracker = AgentDaemon::Tracker.new(
        "token" => "tok", "org_id" => "org", "base_url" => base_url, "default_backoff" => 45
      )
      err = assert_raises(AgentDaemon::Tracker::RateLimitError) { tracker.search_issues("Queue: TI") }
      assert_equal 45, err.retry_after
    end
  end

  def test_non_429_error_raises_generic_error
    with_status_server(status: 503) do |base_url|
      tracker = AgentDaemon::Tracker.new(
        "token" => "tok", "org_id" => "org", "base_url" => base_url
      )
      err = assert_raises(RuntimeError) { tracker.search_issues("Queue: TI") }
      assert_includes err.message, "Tracker API 503"
      refute_kind_of AgentDaemon::Tracker::RateLimitError, err
    end
  end
end
