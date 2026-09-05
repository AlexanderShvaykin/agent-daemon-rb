# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "yaml"

class TestConfigPachcaTrigger < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    FileUtils.mkdir_p(@project_path)
    File.write(File.join(@tmpdir, "prompt.txt"), "{{message}}")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def write_config(trigger_overrides = {}, remove: [])
    trigger = {
      "type" => "pachca",
      "token" => "tok",
      "bot_user_id" => 111,
      "chats" => [900]
    }.merge(trigger_overrides)
    remove.each { |key| trigger.delete(key) }

    data = {
      "project_path" => @project_path,
      "runners" => [{ "name" => "qa", "prompt_template" => "prompt.txt", "trigger" => trigger }],
      "messenger" => { "webhook_url" => "https://example.test/hook" }
    }
    path = File.join(@tmpdir, "config.yml")
    File.write(path, YAML.dump(data))
    path
  end

  def load(trigger_overrides = {}, remove: [])
    AgentDaemon::Config.new(write_config(trigger_overrides, remove: remove))
  end

  def error_for(trigger_overrides = {}, remove: [])
    assert_raises(AgentDaemon::ConfigError) { load(trigger_overrides, remove: remove) }.message
  end

  def test_a_minimal_pachca_trigger_loads
    trigger = load.runners.first.fetch("trigger")

    assert_equal "pachca", trigger.fetch("type")
    assert_equal [900], trigger.fetch("chats")
  end

  def test_interval_and_jitter_get_defaults
    trigger = load.runners.first.fetch("trigger")

    assert_equal AgentDaemon::Config::PACHCA_TRIGGER_DEFAULTS.fetch("interval"), trigger.fetch("interval")
    assert_equal AgentDaemon::Config::PACHCA_TRIGGER_DEFAULTS.fetch("jitter"), trigger.fetch("jitter")
  end

  # The poller acknowledges by deleting from Pachca's own history, so unlike
  # the file and mattermost triggers there are no work dirs to resolve.
  def test_no_work_dirs_are_resolved
    trigger = load.runners.first.fetch("trigger")

    assert_nil trigger["input_dir"]
    assert_nil trigger["archive_dir"]
    assert_nil trigger["failed_dir"]
  end

  def test_pachca_is_a_valid_trigger_type
    assert_includes AgentDaemon::Config::VALID_TRIGGER_TYPES, "pachca"
  end

  def test_token_is_required
    assert_match(/trigger\.token is required/, error_for(remove: %w[token]))
  end

  def test_bot_user_id_is_required_and_says_why
    message = error_for(remove: %w[bot_user_id])

    assert_match(/trigger\.bot_user_id is required/, message)
    assert_match(/re-ingests its own replies/, message)
  end

  def test_bot_user_id_must_be_a_positive_integer
    assert_match(/trigger\.bot_user_id is required/, error_for({"bot_user_id" => "111"}))
  end

  # Optional, unlike the mattermost trigger's channels: the history only ever
  # holds what the bot itself received, so its chat memberships are already the
  # scope. Requiring it would also lock out direct messages outright, since a DM
  # gets its own chat id that cannot be known in advance.
  def test_chats_may_be_omitted_entirely
    assert_nil load(remove: %w[chats]).runners.first.dig("trigger", "chats")
  end

  def test_chats_is_still_validated_when_present
    assert_match(/trigger\.chats must be a non-empty Array/, error_for({"chats" => []}))
    assert_match(/trigger\.chats must be a non-empty Array/, error_for({"chats" => %w[general]}))
  end

  def test_allowed_users_is_optional_but_validated_when_present
    assert_equal [42], load({"allowed_users" => [42]}).runners.first.dig("trigger", "allowed_users")
    assert_match(/trigger\.allowed_users must be a non-empty Array/, error_for({"allowed_users" => ["bob"]}))
    assert_match(/trigger\.allowed_users must be a non-empty Array/, error_for({"allowed_users" => []}))
  end

  def test_event_types_is_optional_but_validated_when_present
    assert_equal %w[button_click], load({"event_types" => %w[button_click]}).runners.first.dig("trigger", "event_types")
    assert_match(/trigger\.event_types must be a non-empty Array/, error_for({"event_types" => [""]}))
  end

  # Config collects every problem into one error rather than failing on the first.
  def test_all_problems_are_reported_together
    message = error_for({"chats" => [], "bot_user_id" => nil, "token" => ""})

    assert_match(/trigger\.token is required/, message)
    assert_match(/trigger\.bot_user_id is required/, message)
    assert_match(/trigger\.chats must be a non-empty Array/, message)
  end
end
