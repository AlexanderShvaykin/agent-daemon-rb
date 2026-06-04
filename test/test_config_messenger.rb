# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

class TestConfigMessenger < Minitest::Test
  def build_config(messenger)
    Dir.mktmpdir do |dir|
      project_path = File.join(dir, "project")
      FileUtils.mkdir_p(project_path)
      template_path = File.join(dir, "p.txt")
      File.write(template_path, "x")

      data = {
        "project_path" => project_path,
        "tracker" => { "token" => "t", "org_id" => "o" },
        "runners" => [{
          "name" => "default",
          "prompt_template" => "p.txt",
          "trigger" => { "type" => "tracker", "query" => "Queue: TI" }
        }],
        "messenger" => messenger
      }

      config_path = File.join(dir, "config.yml")
      File.write(config_path, data.to_yaml)
      yield AgentDaemon::Config.new(config_path)
    end
  end

  def mattermost_keys(overrides = {})
    {
      "type" => "mattermost",
      "base_url" => "https://mm.example.com",
      "token" => "tok",
      "team" => "eng",
      "default_channel" => "ops"
    }.merge(overrides)
  end

  def test_mattermost_with_all_keys_is_valid
    build_config(mattermost_keys) do |config|
      assert_equal "mattermost", config.messenger["type"]
    end
  end

  def test_mattermost_missing_keys_raise_listing_each
    err = assert_raises(AgentDaemon::ConfigError) do
      build_config("type" => "mattermost") { |_c| }
    end
    %w[base_url token team default_channel].each do |key|
      assert_includes err.message, "messenger.#{key}"
    end
  end

  def test_webhook_with_url_is_valid
    build_config("type" => "webhook", "webhook_url" => "https://example.com/h") do |config|
      assert_equal "webhook", config.messenger["type"]
    end
  end

  def test_webhook_without_url_stays_valid
    # Backward compatibility: an absent webhook_url leaves the messenger
    # disabled rather than failing config validation.
    build_config("type" => "webhook") do |config|
      assert_equal "webhook", config.messenger["type"]
    end
  end

  def test_default_type_is_webhook
    build_config("webhook_url" => "https://example.com/h") do |config|
      assert_equal "webhook", config.messenger["type"]
    end
  end

  def test_unknown_type_raises
    err = assert_raises(AgentDaemon::ConfigError) do
      build_config("type" => "smoke-signal") { |_c| }
    end
    assert_includes err.message, "messenger.type"
  end
end
