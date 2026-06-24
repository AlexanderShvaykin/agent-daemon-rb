# frozen_string_literal: true

require "test_helper"
require "json"

class TestTransportMattermost < Minitest::Test
  CONFIG = {
    "type" => "mattermost",
    "base_url" => "https://mm.example.com",
    "token" => "secret-token",
    "team" => "eng",
    "default_channel" => "ops"
  }.freeze

  def fake(body)
    FakeSuccess.new(JSON.generate(body))
  end

  # Resolves the documented endpoints to stable fake ids.
  def handler
    lambda do |req|
      case [req.method, req.path]
      when ["GET", "/api/v4/users/me"] then fake(id: "bot1")
      when ["GET", "/api/v4/teams/name/eng"] then fake(id: "team1")
      when ["GET", "/api/v4/teams/team1/channels/name/dev-alerts"] then fake(id: "chan1")
      when ["GET", "/api/v4/teams/team1/channels/name/ops"] then fake(id: "chanOps")
      when ["GET", "/api/v4/users/username/ivan.petrov"] then fake(id: "user1")
      when ["POST", "/api/v4/channels/direct"] then fake(id: "dm1")
      when ["POST", "/api/v4/posts"] then fake(id: "post1")
      else raise "unexpected request: #{req.method} #{req.path}"
      end
    end
  end

  def with_transport(http)
    transport = AgentDaemon::Transport::Mattermost.new(CONFIG)
    stub_net_http(http) { yield transport, http }
  end

  def posts(http)
    http.requests.select { |r| r.path == "/api/v4/posts" }
  end

  # Answers posts only; any name/user resolution request is an assertion failure.
  def posts_only_http
    FakeHttp.new do |req|
      req.path == "/api/v4/posts" ? fake(id: "post1") : raise("unexpected resolution request: #{req.method} #{req.path}")
    end
  end

  def test_posts_to_named_channel
    with_transport(FakeHttp.new(&handler)) do |t, http|
      t.deliver("channel" => "dev-alerts", "message" => "Build green")

      assert_equal 1, posts(http).size
      assert_equal({ "channel_id" => "chan1", "message" => "Build green" }, JSON.parse(posts(http).first.body))
      assert_equal "Bearer secret-token", posts(http).first["Authorization"]
    end
  end

  def test_direct_message_to_user
    with_transport(FakeHttp.new(&handler)) do |t, http|
      t.deliver("user" => "ivan.petrov", "message" => "hi")

      direct = http.requests.find { |r| r.path == "/api/v4/channels/direct" }
      assert_equal %w[bot1 user1], JSON.parse(direct.body)
      assert_equal({ "channel_id" => "dm1", "message" => "hi" }, JSON.parse(posts(http).first.body))
    end
  end

  def test_default_channel_fallback
    with_transport(FakeHttp.new(&handler)) do |t, http|
      t.deliver("message" => "SYSTEM:tracker boom")

      assert_equal({ "channel_id" => "chanOps", "message" => "SYSTEM:tracker boom" }, JSON.parse(posts(http).first.body))
    end
  end

  def test_both_channel_and_user_raises
    with_transport(FakeHttp.new(&handler)) do |t, http|
      err = assert_raises(RuntimeError) do
        t.deliver("channel" => "dev-alerts", "user" => "ivan.petrov", "message" => "x")
      end
      assert_includes err.message, "both"
      assert_empty posts(http)
    end
  end

  def test_channel_resolution_cached_across_deliveries
    with_transport(FakeHttp.new(&handler)) do |t, http|
      t.deliver("channel" => "dev-alerts", "message" => "one")
      t.deliver("channel" => "dev-alerts", "message" => "two")

      channel_lookups = http.requests.count { |r| r.path == "/api/v4/teams/team1/channels/name/dev-alerts" }
      team_lookups = http.requests.count { |r| r.path == "/api/v4/teams/name/eng" }
      assert_equal 1, channel_lookups
      assert_equal 1, team_lookups
      assert_equal 2, posts(http).size
    end
  end

  def test_resolution_failure_raises
    failing = FakeHttp.new do |req|
      req.path == "/api/v4/posts" ? fake(id: "post1") : FakeServerError.new
    end
    with_transport(failing) do |t, _http|
      err = assert_raises(RuntimeError) { t.deliver("channel" => "dev-alerts", "message" => "x") }
      assert_includes err.message, "503"
    end
  end

  def test_channel_id_used_verbatim_without_resolution
    with_transport(posts_only_http) do |t, http|
      t.deliver("channel_id" => "chanXYZ", "message" => "in thread")

      assert_equal [["POST", "/api/v4/posts"]], http.requests.map { |r| [r.method, r.path] }
      assert_equal({ "channel_id" => "chanXYZ", "message" => "in thread" }, JSON.parse(posts(http).first.body))
    end
  end

  def test_channel_id_takes_precedence_over_channel_name
    with_transport(posts_only_http) do |t, http|
      t.deliver("channel_id" => "chanXYZ", "channel" => "dev-alerts", "message" => "in thread")

      assert_equal [["POST", "/api/v4/posts"]], http.requests.map { |r| [r.method, r.path] }
      assert_equal({ "channel_id" => "chanXYZ", "message" => "in thread" }, JSON.parse(posts(http).first.body))
    end
  end

  def test_root_id_included_in_post_body
    with_transport(posts_only_http) do |t, http|
      t.deliver("channel_id" => "chanXYZ", "root_id" => "root123", "message" => "reply")

      assert_equal(
        { "channel_id" => "chanXYZ", "root_id" => "root123", "message" => "reply" },
        JSON.parse(posts(http).first.body)
      )
    end
  end

  def test_root_id_omitted_when_absent
    with_transport(FakeHttp.new(&handler)) do |t, http|
      t.deliver("channel" => "dev-alerts", "message" => "Build green")

      refute_includes JSON.parse(posts(http).first.body).keys, "root_id"
    end
  end
end
