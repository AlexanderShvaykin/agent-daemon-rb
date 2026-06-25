# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require "fileutils"
require "time"

class TestMattermostListener < Minitest::Test
  BOT_ID = "bot1"

  def setup
    @dir = Dir.mktmpdir("mm-listener")
    @input_dir   = ::File.join(@dir, "inbox")
    @archive_dir = ::File.join(@dir, "done")
    @failed_dir  = ::File.join(@dir, "failed")
    [@input_dir, @archive_dir, @failed_dir].each { |d| FileUtils.mkdir_p(d) }

    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(::File::NULL))
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && ::File.directory?(@dir)
    AgentDaemon::Log.instance_variable_set(:@logger, nil)
  end

  def trigger_config(overrides = {})
    {
      "base_url" => "https://mm.example.com",
      "token" => "secret-token",
      "team" => "eng",
      "channels" => ["town-square"],
      "input_dir" => @input_dir,
      "archive_dir" => @archive_dir,
      "failed_dir" => @failed_dir
    }.merge(overrides)
  end

  def build_listener(overrides = {})
    AgentDaemon::Mattermost::Listener.new(trigger_config(overrides), AgentDaemon::ShutdownFlag.new)
  end

  TEAM_ID = "team1"

  # Resolves bot id via GET /api/v4/users/me and team id via
  # GET /api/v4/teams/name/{team}, then runs the block.
  def prepared_listener(overrides = {})
    listener = build_listener(overrides)
    http = FakeHttp.new do |req|
      case [req.method, req.path]
      when ["GET", "/api/v4/users/me"] then FakeSuccess.new(JSON.generate(id: BOT_ID))
      when ["GET", "/api/v4/teams/name/eng"] then FakeSuccess.new(JSON.generate(id: TEAM_ID))
      else raise "unexpected request: #{req.method} #{req.path}"
      end
    end
    stub_net_http(http) { listener.prepare }
    yield listener, http if block_given?
    listener
  end

  # Builds a `posted` event frame matching the Mattermost wire format: data.post
  # and data.mentions are themselves JSON-encoded strings.
  def posted_frame(post: {}, mentions: [BOT_ID], channel_name: "town-square", sender_name: "@alice", team_id: "team1", include_mentions: true)
    post_obj = {
      "id" => "POSTID",
      "user_id" => "UID",
      "channel_id" => "CID",
      "message" => "@bot hi",
      "root_id" => "",
      "create_at" => 1_700_000_000_000
    }.merge(post)

    data = {
      "channel_name" => channel_name,
      "channel_display_name" => "Town Square",
      "channel_type" => "O",
      "sender_name" => sender_name,
      "team_id" => team_id,
      "post" => JSON.generate(post_obj)
    }
    data["mentions"] = JSON.generate(mentions) if include_mentions

    JSON.generate("event" => "posted", "seq" => 7, "data" => data, "broadcast" => {})
  end

  def item_path(post_id)
    ::File.join(@input_dir, "#{post_id}.yml")
  end

  def written_item(post_id)
    YAML.safe_load(::File.read(item_path(post_id)))
  end

  def test_qualifying_mention_writes_work_item
    listener = prepared_listener
    listener.on_message(posted_frame(post: { "id" => "p100" }))

    assert ::File.exist?(item_path("p100")), "expected p100.yml to be written"
    item = written_item("p100")
    assert_equal "@bot hi", item["message"]
    assert_equal "CID", item["channel_id"]
    assert_equal "@alice", item["sender"]
    assert_equal "town-square", item["channel_name"]
    assert_equal "p100", item["post_id"]
    assert item.key?("created_at")
    assert Time.iso8601(item["created_at"]), "created_at must be parseable ISO-8601"
  end

  def test_threaded_mention_keeps_existing_root
    listener = prepared_listener
    listener.on_message(posted_frame(post: { "id" => "p200", "root_id" => "ROOT9" }))

    assert_equal "ROOT9", written_item("p200")["root_id"]
  end

  def test_unthreaded_mention_opens_thread_on_itself
    listener = prepared_listener
    listener.on_message(posted_frame(post: { "id" => "p300", "root_id" => "" }))

    assert_equal "p300", written_item("p300")["root_id"]
  end

  def test_self_authored_post_ignored
    listener = prepared_listener
    listener.on_message(posted_frame(post: { "id" => "p400", "user_id" => BOT_ID }))

    refute ::File.exist?(item_path("p400")), "self-authored post must not write a work-item"
  end

  def test_non_allowlisted_channel_ignored
    listener = prepared_listener
    listener.on_message(posted_frame(post: { "id" => "p500" }, channel_name: "random"))

    refute ::File.exist?(item_path("p500")), "non-allowlisted channel must be ignored"
  end

  def test_allowlisted_channel_in_other_team_ignored
    listener = prepared_listener
    # Same channel name, different team — the allowlist is scoped to the
    # configured team, so a like-named channel elsewhere must not trigger.
    listener.on_message(posted_frame(post: { "id" => "p550" }, team_id: "other-team"))

    refute ::File.exist?(item_path("p550")), "mention in a same-named channel of another team must be ignored"
  end

  def test_bot_not_mentioned_ignored
    listener = prepared_listener
    listener.on_message(posted_frame(post: { "id" => "p600" }, mentions: ["someone-else"]))

    refute ::File.exist?(item_path("p600")), "must not write when bot not mentioned"
  end

  def test_absent_mentions_ignored
    listener = prepared_listener
    listener.on_message(posted_frame(post: { "id" => "p650" }, include_mentions: false))

    refute ::File.exist?(item_path("p650")), "absent mentions key means no mention"
  end

  def test_dedup_against_inbox
    listener = prepared_listener
    ::File.write(item_path("p700"), "existing: true\n")

    listener.on_message(posted_frame(post: { "id" => "p700" }))

    assert_equal "existing: true\n", ::File.read(item_path("p700")), "must not overwrite inbox item"
  end

  def test_dedup_against_archive
    listener = prepared_listener
    ::File.write(::File.join(@archive_dir, "p800.yml"), "done\n")

    listener.on_message(posted_frame(post: { "id" => "p800" }))

    refute ::File.exist?(item_path("p800")), "must not re-enqueue an already-archived mention"
  end

  def test_dedup_against_failed
    listener = prepared_listener
    ::File.write(::File.join(@failed_dir, "p900.yml"), "failed\n")

    listener.on_message(posted_frame(post: { "id" => "p900" }))

    refute ::File.exist?(item_path("p900")), "must not re-enqueue a failed mention"
  end

  def test_on_message_routes_non_posted_event_ignored
    listener = prepared_listener
    frame = JSON.generate("event" => "post_edited", "seq" => 8, "data" => {})

    listener.on_message(frame)

    assert_empty Dir.glob(::File.join(@input_dir, "*.yml")), "non-posted events write nothing"
  end

  def test_hello_event_resets_backoff_without_writing
    listener = prepared_listener
    # Simulate a grown reconnect backoff after prior failures (white-box).
    listener.instance_variable_set(:@backoff, 16)

    listener.on_message(JSON.generate("event" => "hello", "seq" => 1, "data" => { "server_version" => "9.0.0" }))

    assert_equal AgentDaemon::Mattermost::Listener::INITIAL_BACKOFF, listener.backoff,
                 "hello must reset the reconnect backoff to the initial value"
    assert_empty Dir.glob(::File.join(@input_dir, "*.yml")), "hello must not write a work-item"
  end

  def test_malformed_frame_ignored
    listener = prepared_listener

    # Must not raise.
    listener.on_message("this is not json {")
    listener.on_message("")

    assert_empty Dir.glob(::File.join(@input_dir, "*.yml")), "malformed frames write nothing"
  end

  def test_handle_event_directly_callable
    listener = prepared_listener
    event = JSON.parse(posted_frame(post: { "id" => "p1000" }))

    listener.handle_event(event)

    assert ::File.exist?(item_path("p1000")), "handle_event should write a qualifying work-item"
  end

  def test_prepare_resolves_bot_id_and_team_id
    http = FakeHttp.new do |req|
      case [req.method, req.path]
      when ["GET", "/api/v4/users/me"] then FakeSuccess.new(JSON.generate(id: BOT_ID))
      when ["GET", "/api/v4/teams/name/eng"] then FakeSuccess.new(JSON.generate(id: TEAM_ID))
      else raise "unexpected request: #{req.method} #{req.path}"
      end
    end
    listener = build_listener
    stub_net_http(http) { listener.prepare }

    assert_equal BOT_ID, listener.bot_id
    assert_equal TEAM_ID, listener.team_id
    assert_equal(
      [["GET", "/api/v4/users/me", "Bearer secret-token"],
       ["GET", "/api/v4/teams/name/eng", "Bearer secret-token"]],
      http.requests.map { |req| [req.method, req.path, req["Authorization"]] }
    )
  end

  def test_write_creates_missing_input_dir
    listener = prepared_listener
    FileUtils.remove_entry(@input_dir)

    listener.on_message(posted_frame(post: { "id" => "p1100" }))

    assert ::File.exist?(item_path("p1100")), "listener must create the inbox dir before writing"
  end
end
