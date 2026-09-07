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

  def mattermost_runner(overrides = {})
    {
      "name" => "mention-bot",
      "prompt_template" => "prompts/default.txt",
      "trigger" => {
        "type" => "mattermost",
        "base_url" => "https://mm.example.com",
        "token" => "bot-token",
        "team" => "engineering",
        "channels" => %w[general dev]
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

  def test_mattermost_trigger_defaults_and_dir_resolution
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, [mattermost_runner]))
      config = AgentDaemon::Config.new(path)

      trigger = config.runners.first["trigger"]
      assert_equal 2, trigger["interval"]
      assert_equal 0, trigger["jitter"]
      assert_equal File.join(project_path, "mentions/mention-bot/inbox"),  trigger["input_dir"]
      assert_equal File.join(project_path, "mentions/mention-bot/done"),   trigger["archive_dir"]
      assert_equal File.join(project_path, "mentions/mention-bot/failed"), trigger["failed_dir"]
    end
  end

  def test_mattermost_explicit_dir_resolves_under_project_path
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = mattermost_runner
      runner["trigger"]["input_dir"] = "custom/in"
      path = write_config(dir, base_config(project_path, [runner]))
      config = AgentDaemon::Config.new(path)

      trigger = config.runners.first["trigger"]
      assert_equal File.join(project_path, "custom/in"), trigger["input_dir"]
    end
  end

  def test_rejects_mattermost_missing_connection_keys
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = mattermost_runner("trigger" => { "type" => "mattermost", "channels" => %w[general] })
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "trigger.base_url"
      assert_includes err.message, "trigger.token"
      assert_includes err.message, "trigger.team"
    end
  end

  def test_rejects_mattermost_empty_channels
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = mattermost_runner
      runner["trigger"]["channels"] = []
      path = write_config(dir, base_config(project_path, [runner]))
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "trigger.channels"
    end
  end

  def test_accepts_mattermost_direct_users
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = mattermost_runner
      runner["trigger"]["direct_users"] = ["alexander.shvaykin"]
      path = write_config(dir, base_config(project_path, [runner]))

      assert_equal ["alexander.shvaykin"], AgentDaemon::Config.new(path).runners.first.dig("trigger", "direct_users")
    end
  end

  def test_accepts_direct_message_only_mattermost_runner
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = mattermost_runner
      runner["trigger"]["channels"] = []
      runner["trigger"]["direct_users"] = ["alexander.shvaykin"]
      path = write_config(dir, base_config(project_path, [runner]))

      assert_equal [], AgentDaemon::Config.new(path).runners.first.dig("trigger", "channels")
    end
  end

  def test_rejects_invalid_mattermost_direct_users
    [nil, [], [""], "alexander.shvaykin"].each do |direct_users|
      Dir.mktmpdir do |dir|
        project_path = with_project(dir)
        runner = mattermost_runner
        runner["trigger"]["direct_users"] = direct_users
        path = write_config(dir, base_config(project_path, [runner]))

        err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
        assert_includes err.message, "trigger.direct_users"
      end
    end
  end

  # `agent: null` means "run the CLI without --agent". Nothing in deep_merge
  # says so explicitly — it survives only because a non-Hash override wins over
  # the RUNNER_DEFAULTS value — so pin it here.
  def test_null_agent_survives_the_merge_with_runner_defaults
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, [tracker_runner("agent" => nil)]))

      runner = AgentDaemon::Config.new(path).runners.first
      assert runner.key?("agent")
      assert_nil runner["agent"]
    end
  end

  def test_rejects_unusable_agent_values
    ["", 42].each do |agent|
      Dir.mktmpdir do |dir|
        project_path = with_project(dir)
        path = write_config(dir, base_config(project_path, [tracker_runner("agent" => agent)]))

        err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
        assert_includes err.message, '"default"'
        assert_includes err.message, "agent must be a non-empty String or null"
      end
    end
  end

  def test_accepts_claude_model
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("claude" => { "model" => "haiku" })
      path = write_config(dir, base_config(project_path, [runner]))

      assert_equal "haiku", AgentDaemon::Config.new(path).runners.first.dig("claude", "model")
    end
  end

  def test_rejects_empty_claude_model
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("claude" => { "model" => "" })
      path = write_config(dir, base_config(project_path, [runner]))

      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, '"default"'
      assert_includes err.message, "claude.model must be a non-empty String"
    end
  end

  # Both new checks feed the shared error list rather than raising on the first
  # problem, like every other runner check.
  def test_collects_agent_and_claude_model_errors_together
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("agent" => "", "claude" => { "model" => "" })
      path = write_config(dir, base_config(project_path, [runner]))

      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "agent must be a non-empty String or null"
      assert_includes err.message, "claude.model must be a non-empty String"
    end
  end

  def test_accepts_valid_fallback_agent
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      fallback = { "command" => "omp", "args" => ["--print", "--model", "gpt"] }
      path = write_config(dir, base_config(project_path, [tracker_runner("fallback_agent" => fallback)]))

      assert_equal fallback, AgentDaemon::Config.new(path).runners.first["fallback_agent"]
    end
  end

  # A String is now a backend name, so "omp" is not rejected for its type but
  # for naming nothing — and the error says which form an arbitrary CLI needs.
  def test_rejects_a_fallback_naming_an_unknown_backend
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, [tracker_runner("fallback_agent" => "omp")]))

      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, 'fallback_agent names an unknown backend "omp"'
      assert_includes err.message, "{command, args}"
    end
  end

  def test_accepts_a_fallback_naming_a_backend
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, [tracker_runner("fallback_agent" => "codex")]))

      assert_equal "codex", AgentDaemon::Config.new(path).runners.first["fallback_agent"]
    end
  end

  def test_rejects_a_fallback_that_is_neither_a_name_nor_a_command
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, [tracker_runner("fallback_agent" => 42)]))

      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "fallback_agent must be a backend name (String) or a Hash"
    end
  end

  def test_accepts_codex_as_a_backend
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("backend" => "codex", "codex" => { "model" => "gpt-5.3-codex" })
      path = write_config(dir, base_config(project_path, [runner]))

      assert_equal "codex", AgentDaemon::Config.new(path).runners.first["backend"]
    end
  end

  # Unlike opencode.model, which is only checked when the command is built, a
  # codex problem surfaces at load rather than hours later on the first question.
  def test_rejects_a_blank_codex_model
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      runner = tracker_runner("backend" => "codex", "codex" => { "model" => "" })
      path = write_config(dir, base_config(project_path, [runner]))

      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "codex.model must be a non-empty String"
    end
  end

  def test_rejects_invalid_fallback_command
    [nil, "", "   ", 42].each do |command|
      Dir.mktmpdir do |dir|
        project_path = with_project(dir)
        fallback = { "command" => command, "args" => [] }
        path = write_config(dir, base_config(project_path, [tracker_runner("fallback_agent" => fallback)]))

        err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
        assert_includes err.message, 'runner "default": fallback_agent.command must be a non-empty String'
      end
    end
  end

  def test_rejects_invalid_fallback_args
    [nil, "--print", ["--print", 42]].each do |args|
      Dir.mktmpdir do |dir|
        project_path = with_project(dir)
        fallback = { "command" => "omp", "args" => args }
        path = write_config(dir, base_config(project_path, [tracker_runner("fallback_agent" => fallback)]))

        err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
        assert_includes err.message, 'runner "default": fallback_agent.args must be an Array of Strings'
      end
    end
  end

  def test_rejects_unknown_fallback_keys_and_aggregates_other_errors
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      fallback = { "command" => "", "args" => "--print", "model" => "gpt" }
      path = write_config(dir, base_config(project_path, [tracker_runner("fallback_agent" => fallback)]))

      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      assert_includes err.message, "fallback_agent has unknown key(s) model"
      assert_includes err.message, "fallback_agent.command must be a non-empty String"
      assert_includes err.message, "fallback_agent.args must be an Array of Strings"
    end
  end

  # opencode.model stays a runtime check inside the backend — the asymmetry
  # with claude.model is deliberate, and this change does not touch it.
  def test_opencode_runner_without_a_model_loads_and_fails_at_command_build
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, [tracker_runner("backend" => "opencode")]))

      runner = AgentDaemon::Config.new(path).runners.first

      flag = Object.new
      def flag.value = false
      backend = AgentDaemon::Backend.for(runner, flag, message_dir: "/tmp/msg", project_path: project_path)
      err = assert_raises(ArgumentError) { backend.send(:build_command, "hello") }
      assert_includes err.message, "opencode.model"
    end
  end
end
