# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

# AD-5 lazy-require isolation: the supervisor file is loaded explicitly here
# and is NOT part of the core `require "agent_daemon"` graph.
require "agent_daemon/supervisor/master"

class TestSupervisorMaster < Minitest::Test
  def setup
    @prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, @prior_logger)
    AgentDaemon::Log.clear_context
  end

  # Builds a real Supervisor::Config from workflow specs written to disk
  # (mirrors test_supervisor_config.rb's with_supervisor). `specs` is a list
  # of { name:, runners: [...], messenger: {...} | nil } — each becomes its
  # own referenced per-workflow config with a distinct project_path/message_dir
  # so 1.1's collision validation never rejects the fixture itself.
  def with_config(specs)
    Dir.mktmpdir do |dir|
      wf_dir = File.join(dir, "workflows")
      FileUtils.mkdir_p(File.join(wf_dir, "prompts"))
      File.write(File.join(wf_dir, "prompts", "default.txt"), "Prompt {{task_key}}")

      specs.each do |spec|
        data = {
          "project_path" => File.join(dir, "proj-#{spec[:name]}"),
          "message_dir" => "to_message",
          "tracker" => { "token" => "t", "org_id" => "o" },
          "runners" => spec[:runners]
        }
        data["messenger"] = spec[:messenger] if spec[:messenger]
        data["logging"] = spec[:logging] if spec[:logging]
        File.write(File.join(wf_dir, "#{spec[:name]}.yml"), data.to_yaml)
      end

      entries = specs.map { |s| { "name" => s[:name], "config" => "workflows/#{s[:name]}.yml" } }
      path = File.join(dir, "supervisor.yml")
      File.write(path, { "workflows" => entries }.to_yaml)

      yield dir, AgentDaemon::Supervisor::Config.new(path)
    end
  end

  def tracker_runner(name)
    { "name" => name, "prompt_template" => "prompts/default.txt",
      "trigger" => { "type" => "tracker", "query" => "Queue: TI" } }
  end

  # input_dir/archive_dir/failed_dir resolve relative to project_path (core
  # Config#resolve_trigger_dirs), so relative names are enough here.
  def file_runner(name)
    {
      "name" => name, "prompt_template" => "prompts/default.txt",
      "trigger" => {
        "type" => "file",
        "input_dir" => "inbox",
        "archive_dir" => "inbox/archive",
        "failed_dir" => "inbox/failed"
      }
    }
  end

  def mattermost_runner(name)
    {
      "name" => name, "prompt_template" => "prompts/default.txt",
      "trigger" => {
        "type" => "mattermost",
        "base_url" => "https://mm.example.com",
        "token" => "tok",
        "team" => "eng",
        "channels" => ["town-square"]
      }
    }
  end

  # --- Composite keys (the point of the epic) --------------------------------

  def test_composite_keys_do_not_collide_across_workflows
    with_config(
      [
        { name: "wfA", runners: [tracker_runner("r")] },
        { name: "wfB", runners: [tracker_runner("r")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factories = master.instance_variable_get(:@entity_factories)

      assert factories.key?(:"runner:wfA:r")
      assert factories.key?(:"runner:wfB:r")
    end
  end

  # --- Factory products --------------------------------------------------
  # Factories are now 1-arg (Story 1.5: they receive the per-generation
  # Sinks::Bundle a RunnerSupervisor builds), so each call site here passes
  # one explicitly instead of relying on a captured null bundle.

  def test_factory_products_per_trigger_type
    with_config(
      [
        { name: "wf", runners: [tracker_runner("t")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factories = master.instance_variable_get(:@entity_factories)
      identity = master.instance_variable_get(:@entity_ids).fetch(:"runner:wf:t")

      instance = factories.fetch(:"runner:wf:t").call(AgentDaemon::Sinks::Bundle.null(identity))
      assert_instance_of AgentDaemon::Runner::Tracker, instance

      sink_entity_id = instance.instance_variable_get(:@sinks).instance_variable_get(:@entity_id)
      assert_instance_of AgentDaemon::Supervisor::RunnerIdentity, sink_entity_id
      assert_equal "wf", sink_entity_id.workflow
      assert_equal "t", sink_entity_id.runner
    end
  end

  def test_factory_products_file
    with_config(
      [
        { name: "wf", runners: [file_runner("f")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factories = master.instance_variable_get(:@entity_factories)

      instance = factories.fetch(:"runner:wf:f").call(AgentDaemon::Sinks::Bundle.null)
      assert_instance_of AgentDaemon::Runner::File, instance
    end
  end

  def test_factory_products_mattermost
    with_config(
      [
        { name: "wf", runners: [mattermost_runner("m")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factories = master.instance_variable_get(:@entity_factories)

      instance = factories.fetch(:"runner:wf:m").call(AgentDaemon::Sinks::Bundle.null)
      assert_instance_of AgentDaemon::Runner::Mattermost, instance
    end
  end

  # --- One reactor fleet-wide (AC2) --------------------------------------

  def test_one_reactor_fleet_wide_across_workflows
    with_config(
      [
        { name: "wfA", runners: [mattermost_runner("m1")] },
        { name: "wfB", runners: [mattermost_runner("m2")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factories = master.instance_variable_get(:@entity_factories)

      assert factories.key?(:mattermost_reactor)
      reactor = factories.fetch(:mattermost_reactor).call(AgentDaemon::Sinks::Bundle.null("mattermost_reactor"))
      assert_instance_of AgentDaemon::Mattermost::Reactor, reactor
      listeners = reactor.instance_variable_get(:@listeners)
      assert_equal 2, listeners.size
    end
  end

  def test_no_reactor_without_mattermost_runners
    with_config(
      [
        { name: "wfA", runners: [tracker_runner("a")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factories = master.instance_variable_get(:@entity_factories)

      refute factories.key?(:mattermost_reactor)
    end
  end

  # --- Messenger per workflow ---------------------------------------------

  def test_messenger_per_workflow
    with_config(
      [
        { name: "wfA", runners: [tracker_runner("a")], messenger: { "webhook_url" => "https://example.com/h" } },
        { name: "wfB", runners: [tracker_runner("b")], messenger: nil }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factories = master.instance_variable_get(:@entity_factories)

      assert factories.key?(:"messenger:wfA")
      refute factories.key?(:"messenger:wfB")
    end
  end

  # --- Graceful-exit smoke (AC4) ------------------------------------------
  # Story 1.5: threads are now spawned/tracked one layer down, inside each
  # entity's RunnerSupervisor, so this drives build_supervisors/
  # start_supervisors and asserts through the supervisors' #thread readers.

  def test_graceful_exit_smoke_with_empty_inbox
    with_config(
      [
        { name: "wf", runners: [file_runner("f")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      master.send(:build_supervisors)
      master.send(:start_supervisors)

      master.instance_variable_get(:@shutdown_flag).set!
      master.send(:wait_for_threads)

      supervisors = master.instance_variable_get(:@supervisors)
      assert_equal 1, supervisors.size
      supervisors.each_value do |supervisor|
        refute supervisor.thread.alive?
        refute supervisor.thread[:crashed]
      end
    end
  end

  # --- Crash flag preserved for 1.5 ---------------------------------------

  def test_crash_flag_preserved_on_raising_factory
    with_config(
      [
        { name: "wf", runners: [tracker_runner("a")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      raising = Class.new { def run = raise("boom") }.new
      master.instance_variable_get(:@entity_factories)[:"runner:wf:a"] = ->(_bundle) { raising }

      # Drive the real production path (build_supervisors/start_supervisors ->
      # RunnerSupervisor#spawn! -> factory.call(bundle).run), not a
      # hand-rolled spawn_thread block, so the injected factory is actually
      # consumed.
      master.send(:build_supervisors)
      master.send(:start_supervisors)
      supervisor = master.instance_variable_get(:@supervisors).fetch(:"runner:wf:a")
      supervisor.thread.join

      refute supervisor.thread.alive?
      assert supervisor.thread[:crashed]
      assert_instance_of RuntimeError, supervisor.thread[:crash_error]
    end
  end

  # --- Story 1.5: supervision wiring --------------------------------------

  def test_supervisors_exist_for_every_thread_key
    with_config(
      [
        {
          name: "wf",
          runners: [tracker_runner("a"), mattermost_runner("m")],
          messenger: { "webhook_url" => "https://example.com/h" }
        }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      master.send(:build_supervisors)
      supervisors = master.instance_variable_get(:@supervisors)

      expected = [:"runner:wf:a", :"runner:wf:m", :"messenger:wf", :mattermost_reactor]
      assert_equal expected.sort_by(&:to_s), supervisors.keys.sort_by(&:to_s)
      supervisors.each_value { |s| assert_instance_of AgentDaemon::Supervisor::RunnerSupervisor, s }
    end
  end

  def test_crashed_runner_respawns_while_second_entity_keeps_ticking
    with_config(
      [
        { name: "wf", runners: [tracker_runner("a"), tracker_runner("b")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      master.instance_variable_get(:@entity_factories)[:"runner:wf:a"] =
        ->(_bundle) { Class.new { def run = raise("boom") }.new }
      master.instance_variable_get(:@entity_factories)[:"runner:wf:b"] =
        ->(_bundle) { Class.new { def run = nil }.new }

      master.send(:build_supervisors)
      supervisors = master.instance_variable_get(:@supervisors)
      a = supervisors.fetch(:"runner:wf:a")
      b = supervisors.fetch(:"runner:wf:b")
      a.instance_variable_set(:@restart_delay, 0.02)

      master.send(:start_supervisors)
      a.thread.join(1)
      b.thread.join(1)

      a.tick
      b.tick

      assert_equal :restarting, a.state
      assert_equal :exited, b.state # clean exit, never auto-restarted (AC2)

      sleep(0.05)
      a.tick

      assert_equal :running, a.state
      assert_equal 2, a.generation
      a.thread.join(1)
    end
  end

  # --- Story 1.7: per-workflow logging.level injection (AC2) --------------

  def test_log_level_is_resolved_per_workflow_and_injected_into_supervisors
    with_config(
      [
        { name: "wfA", runners: [tracker_runner("a")], logging: { "level" => "warn" } },
        { name: "wfB", runners: [tracker_runner("b")], logging: { "level" => "debug" } }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      master.send(:build_supervisors)
      supervisors = master.instance_variable_get(:@supervisors)

      assert_equal ::Logger::WARN, supervisors.fetch(:"runner:wfA:a").instance_variable_get(:@log_level)
      assert_equal ::Logger::DEBUG, supervisors.fetch(:"runner:wfB:b").instance_variable_get(:@log_level)
    end
  end

  def test_messenger_gets_its_owning_workflows_log_level
    with_config(
      [
        {
          name: "wf", runners: [tracker_runner("a")],
          messenger: { "webhook_url" => "https://example.com/h" },
          logging: { "level" => "error" }
        }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      master.send(:build_supervisors)
      supervisors = master.instance_variable_get(:@supervisors)

      assert_equal ::Logger::ERROR, supervisors.fetch(:"messenger:wf").instance_variable_get(:@log_level)
    end
  end

  # The reactor is fleet-wide (AD-13) and has no single owning workflow to
  # take a level from, so it defaults to INFO regardless of any workflow's
  # own `logging.level`.
  def test_reactor_defaults_to_info_log_level_regardless_of_workflow_level
    with_config(
      [{ name: "wf", runners: [mattermost_runner("m")], logging: { "level" => "debug" } }]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      master.send(:build_supervisors)
      supervisors = master.instance_variable_get(:@supervisors)

      assert_equal ::Logger::INFO, supervisors.fetch(:mattermost_reactor).instance_variable_get(:@log_level)
    end
  end

  # --- Story 1.7 AC3: logging.file is ignored under the supervisor -------

  def test_logging_file_is_ignored_under_the_supervisor
    Dir.mktmpdir do |tmp|
      log_file = File.join(tmp, "supervisor-story-1-7-should-not-exist.log")

      with_config(
        [{ name: "wf", runners: [file_runner("f")], logging: { "level" => "info", "output" => "file", "file" => log_file } }]
      ) do |_dir, config|
        master = AgentDaemon::Supervisor::Master.new(config)
        master.send(:build_factories)
        master.send(:build_supervisors)
        master.send(:start_supervisors)

        master.instance_variable_get(:@shutdown_flag).set!
        master.send(:wait_for_threads)

        refute File.exist?(log_file)
      end
    end
  end

  # A null or typo'd logging.level must fail fast with a clear ConfigError at
  # boot, not a cryptic NoMethodError/NameError that aborts the whole fleet.
  def test_resolve_log_level_rejects_null_or_unknown_level
    with_config([{ name: "wf", runners: [file_runner("f")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)

      assert_equal ::Logger::WARN, master.send(:resolve_log_level, "warn")

      err = assert_raises(AgentDaemon::ConfigError) { master.send(:resolve_log_level, "verbose") }
      assert_match(/invalid logging.level "verbose"/, err.message)

      assert_raises(AgentDaemon::ConfigError) { master.send(:resolve_log_level, nil) }
    end
  end
end
