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
end
