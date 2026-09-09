# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "yaml"

class TestConfigGitHubTrigger < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    FileUtils.mkdir_p(@project_path)
    File.write(File.join(@tmpdir, "prompt.txt"), "{{pr_url}}")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def write_config(trigger_overrides = {}, remove: [])
    trigger = { "type" => "github", "token" => "tok" }.merge(trigger_overrides)
    remove.each { |key| trigger.delete(key) }

    data = {
      "project_path" => @project_path,
      "runners" => [{ "name" => "review", "prompt_template" => "prompt.txt", "trigger" => trigger }],
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

  def test_a_minimal_github_trigger_loads
    assert_equal "github", load.runners.first.dig("trigger", "type")
  end

  # Slower than the chat triggers on purpose: nobody waits seconds for a code
  # review, and polling the inbox spends rate limit.
  def test_interval_defaults_to_a_minute
    trigger = load.runners.first.fetch("trigger")

    assert_equal 60, trigger.fetch("interval")
    assert_equal AgentDaemon::Config::GITHUB_TRIGGER_DEFAULTS.fetch("jitter"), trigger.fetch("jitter")
  end

  # The ack is marking a notification read, so there is nothing to place on disk.
  def test_no_work_dirs_are_resolved
    trigger = load.runners.first.fetch("trigger")

    assert_nil trigger["input_dir"]
    assert_nil trigger["archive_dir"]
    assert_nil trigger["failed_dir"]
  end

  def test_github_is_a_valid_trigger_type
    assert_includes AgentDaemon::Config::VALID_TRIGGER_TYPES, "github"
  end

  def test_token_is_required
    assert_match(/trigger\.token is required/, error_for(remove: %w[token]))
  end

  # All three narrow the scope and all three are optional; without them the
  # runner acts on every pull-request mention from anyone who can comment.
  def test_the_narrowing_lists_are_optional_but_validated
    %w[repos allowed_users reasons].each do |key|
      assert_equal %w[value], load({ key => %w[value] }).runners.first.dig("trigger", key)
      assert_match(/trigger\.#{key} must be a non-empty Array/, error_for({ key => [] }))
      assert_match(/trigger\.#{key} must be a non-empty Array/, error_for({ key => [42] }))
      assert_match(/trigger\.#{key} must be a non-empty Array/, error_for({ key => "one" }))
    end
  end

  def test_all_problems_are_reported_together
    message = error_for({ "token" => "", "repos" => [], "allowed_users" => [] })

    assert_match(/trigger\.token is required/, message)
    assert_match(/trigger\.repos must be/, message)
    assert_match(/trigger\.allowed_users must be/, message)
  end
end
