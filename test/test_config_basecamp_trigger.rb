# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "yaml"

class TestConfigBasecampTrigger < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, "prompt.txt"), "{{request}}")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_config(trigger)
    path = File.join(@dir, "config.yml")
    File.write(path, YAML.dump(
                       "project_path" => @dir,
                       "message_dir" => "to_message",
                       "runners" => [{
                         "name" => "tasks",
                         "prompt_template" => "prompt.txt",
                         "trigger" => { "type" => "basecamp" }.merge(trigger)
                       }],
                       "messenger" => { "type" => "webhook", "url" => "https://example.test/hook" }
                     ))
    path
  end

  def load(trigger)
    AgentDaemon::Config.new(write_config(trigger))
  end

  def trigger_of(config)
    config.runners.first["trigger"]
  end

  # Unlike every other trigger there is no token to state: Basecamp is OAuth
  # 2.1, the credential lives in the CLI's own store and is refreshed there.
  def test_a_trigger_without_a_token_loads
    config = load({})

    assert_equal "basecamp", trigger_of(config)["type"]
    assert_equal 60, trigger_of(config)["interval"]
  end

  def test_allowed_users_accept_ids_and_names
    config = load("allowed_users" => [1_001, "Jane Doe"])

    assert_equal [1_001, "Jane Doe"], trigger_of(config)["allowed_users"]
  end

  def test_an_empty_allowlist_is_refused
    error = assert_raises(AgentDaemon::ConfigError) { load("allowed_users" => []) }

    assert_match(/trigger.allowed_users must be a non-empty Array/, error.message)
  end

  def test_projects_must_be_names
    error = assert_raises(AgentDaemon::ConfigError) { load("projects" => [{ "id" => 1 }]) }

    assert_match(/trigger.projects must be a non-empty Array/, error.message)
  end

  def test_a_non_positive_interval_is_refused
    error = assert_raises(AgentDaemon::ConfigError) { load("interval" => 0) }

    assert_match(/trigger.interval must be a positive Integer/, error.message)
  end
end
