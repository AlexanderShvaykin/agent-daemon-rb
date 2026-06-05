# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

class TestConfigRunners < Minitest::Test
  def write_config(dir, data)
    config_path = File.join(dir, "config.yml")
    File.write(config_path, data.to_yaml)
    config_path
  end

  def with_project(dir)
    project_path = File.join(dir, "project")
    FileUtils.mkdir_p(project_path)
    template_path = File.join(dir, "prompts", "default.txt")
    FileUtils.mkdir_p(File.dirname(template_path))
    File.write(template_path, "prompt")
    project_path
  end

  def base_config(project_path, runners)
    {
      "project_path" => project_path,
      "tracker" => { "token" => "t", "org_id" => "o" },
      "runners" => runners,
      "messenger" => { "webhook_url" => "https://example.com/h" }
    }
  end

  def tracker_runner(overrides = {})
    {
      "name" => "default",
      "prompt_template" => "prompts/default.txt",
      "trigger" => { "type" => "tracker", "query" => 'Queue: TI AND Status: "New"' }
    }.merge(overrides)
  end

  def file_runner(overrides = {})
    {
      "name" => "reviewer",
      "prompt_template" => "prompts/default.txt",
      "trigger" => {
        "type" => "file",
        "input_dir" => "review_inbox/",
        "archive_dir" => "review_inbox/archive/",
        "failed_dir" => "review_inbox/failed/"
      }
    }.merge(overrides)
  end

  def test_rejects_missing_runners_key
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      data = {
        "project_path" => project_path,
        "tracker" => { "token" => "t", "org_id" => "o" },
        "messenger" => { "webhook_url" => "https://example.com/h" }
      }
      path = write_config(dir, data)

      # runners defaults to [] via DEFAULTS → validation fails on empty list
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "empty"
      assert_includes err.message, path
    end
  end

  def test_rejects_empty_runners
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, []))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "empty"
    end
  end

  def test_rejects_non_array_runners
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, { "not" => "a list" }))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "runners"
    end
  end

  def test_rejects_duplicate_names
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runners = [tracker_runner, tracker_runner]
      path = write_config(dir, base_config(project_path, runners))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "duplicate"
      assert_includes err.message, "\"default\""
    end
  end

  def test_rejects_missing_name
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner
      runner.delete("name")
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "name"
    end
  end

  def test_rejects_missing_prompt_template
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner
      runner.delete("prompt_template")
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "prompt_template"
    end
  end

  def test_rejects_unknown_trigger_type
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("trigger" => { "type" => "webhook" })
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "trigger.type"
      assert_includes err.message, "webhook"
    end
  end

  def test_rejects_tracker_without_query
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("trigger" => { "type" => "tracker" })
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "trigger.query"
    end
  end

  def test_rejects_file_trigger_missing_dirs
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = file_runner("trigger" => { "type" => "file", "input_dir" => "x/" })
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "archive_dir"
      assert_includes err.message, "failed_dir"
    end
  end

  def test_rejects_prompt_template_file_missing
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("prompt_template" => "prompts/nonexistent.txt")
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "nonexistent.txt"
    end
  end

  def test_resolves_paths_relative_to_project_path
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("output_dir" => "out/")
      path = write_config(dir, base_config(project_path, [runner]))
      config = AgentDaemon::Config.new(path)

      assert_equal File.join(project_path, "out"), config.runners.first["output_dir"]
    end
  end

  def test_resolves_file_trigger_paths_relative_to_project_path
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = file_runner
      path = write_config(dir, base_config(project_path, [runner]))
      config = AgentDaemon::Config.new(path)

      trigger = config.runners.first["trigger"]
      assert_equal File.join(project_path, "review_inbox"),         trigger["input_dir"]
      assert_equal File.join(project_path, "review_inbox/archive"), trigger["archive_dir"]
      assert_equal File.join(project_path, "review_inbox/failed"),  trigger["failed_dir"]
      assert_equal 10, trigger["interval"]
    end
  end

  def test_absolute_paths_used_verbatim
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      abs_input = "/var/task-analyst/review"
      abs_archive = "/var/task-analyst/archive"
      abs_failed = "/var/task-analyst/failed"

      runner = file_runner("trigger" => {
        "type" => "file",
        "input_dir" => abs_input,
        "archive_dir" => abs_archive,
        "failed_dir" => abs_failed
      })
      path = write_config(dir, base_config(project_path, [runner]))
      config = AgentDaemon::Config.new(path)

      trigger = config.runners.first["trigger"]
      assert_equal abs_input,   trigger["input_dir"]
      assert_equal abs_archive, trigger["archive_dir"]
      assert_equal abs_failed,  trigger["failed_dir"]
    end
  end

  def test_rejects_negative_jitter
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("trigger" => {
        "type" => "tracker", "query" => "Queue: TI", "jitter" => -1
      })
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "trigger.jitter"
    end
  end

  def test_rejects_negative_default_backoff
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      data = base_config(project_path, [tracker_runner])
      data["tracker"]["default_backoff"] = -5
      path = write_config(dir, data)
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "tracker.default_backoff"
    end
  end

  def test_accepts_valid_config
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, [tracker_runner]))
      config = AgentDaemon::Config.new(path)
      assert_equal 1, config.runners.size
      assert_equal "default", config.runners.first["name"]
    end
  end
end
