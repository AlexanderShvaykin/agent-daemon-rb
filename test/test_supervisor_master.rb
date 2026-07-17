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
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, nil)
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
      factories = master.instance_variable_get(:@factories)

      assert factories.key?(:"runner:wfA:r")
      assert factories.key?(:"runner:wfB:r")
    end
  end

  # --- Factory products --------------------------------------------------

  def test_factory_products_per_trigger_type
    with_config(
      [
        { name: "wf", runners: [tracker_runner("t")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factories = master.instance_variable_get(:@factories)

      instance = factories.fetch(:"runner:wf:t").call
      assert_instance_of AgentDaemon::Runner::Tracker, instance

      identity = instance.instance_variable_get(:@sinks).instance_variable_get(:@entity_id)
      assert_instance_of AgentDaemon::Supervisor::RunnerIdentity, identity
      assert_equal "wf", identity.workflow
      assert_equal "t", identity.runner
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
      factories = master.instance_variable_get(:@factories)

      instance = factories.fetch(:"runner:wf:f").call
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
      factories = master.instance_variable_get(:@factories)

      instance = factories.fetch(:"runner:wf:m").call
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
      factories = master.instance_variable_get(:@factories)

      assert factories.key?(:mattermost_reactor)
      reactor = factories.fetch(:mattermost_reactor).call
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
      factories = master.instance_variable_get(:@factories)

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
      factories = master.instance_variable_get(:@factories)

      assert factories.key?(:"messenger:wfA")
      refute factories.key?(:"messenger:wfB")
    end
  end

  # --- Graceful-exit smoke (AC4) ------------------------------------------

  def test_graceful_exit_smoke_with_empty_inbox
    with_config(
      [
        { name: "wf", runners: [file_runner("f")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      master.send(:start_threads)

      master.instance_variable_get(:@shutdown_flag).set!
      master.send(:wait_for_threads)

      threads = master.instance_variable_get(:@threads)
      assert_equal 1, threads.size
      threads.each_value do |thread|
        refute thread.alive?
        refute thread[:crashed]
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
      raising = Class.new { def run = raise("boom") }.new
      master.instance_variable_get(:@factories)[:"runner:wf:a"] = -> { raising }

      # Drive the real production path (start_threads → factory.call.run), not a
      # hand-rolled spawn_thread block, so the injected factory is actually
      # consumed — matches Task 6's "inject a raising fake factory into
      # @factories, spawn, join".
      master.send(:start_threads)
      thread = master.instance_variable_get(:@threads).fetch(:"runner:wf:a")
      thread.join

      refute thread.alive?
      assert thread[:crashed]
      assert_instance_of RuntimeError, thread[:crash_error]
    end
  end
end
