# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

class TestConfigDefaults < Minitest::Test
  def with_config(extra_runner: {})
    Dir.mktmpdir do |dir|
      project_path = File.join(dir, "project")
      FileUtils.mkdir_p(project_path)
      template_path = File.join(dir, "prompts", "default.txt")
      FileUtils.mkdir_p(File.dirname(template_path))
      File.write(template_path, "Test prompt {{task_key}}")

      runner = {
        "name" => "default",
        "prompt_template" => "prompts/default.txt",
        "trigger" => { "type" => "tracker", "query" => 'Queue: TI AND Status: "New"' }
      }.merge(extra_runner)

      data = {
        "project_path" => project_path,
        "tracker" => { "token" => "t", "org_id" => "o" },
        "runners" => [runner],
        "messenger" => { "webhook_url" => "https://example.com/h" }
      }

      config_path = File.join(dir, "config.yml")
      File.write(config_path, data.to_yaml)
      config = AgentDaemon::Config.new(config_path)
      yield config, template_path
    end
  end

  def test_runner_defaults_applied_when_keys_absent
    with_config do |config, _|
      runner = config.runners.first
      assert_equal "claude", runner["backend"]
      assert_equal "task-analyst", runner["agent"]
      assert_equal 1200, runner["timeout"]
      assert_equal 3, runner["max_attempts"]
      assert_equal "", runner["extra_flags"]
      assert_equal 60, runner["trigger"]["interval"]
    end
  end

  def test_runner_overrides_defaults
    with_config(extra_runner: { "timeout" => 600, "max_attempts" => 5 }) do |config, _|
      runner = config.runners.first
      assert_equal 600, runner["timeout"]
      assert_equal 5, runner["max_attempts"]
    end
  end

  def test_message_dir_defaults_to_to_message
    with_config do |config, _|
      assert_equal File.join(config.project_path, "to_message"), config.message_dir
    end
  end

  def test_prompt_template_path_resolves_relative_to_config_dir
    with_config do |config, template_path|
      assert_equal template_path, config.runners.first["prompt_template_path"]
    end
  end
end
