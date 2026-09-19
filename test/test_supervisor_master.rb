# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

# AD-5 lazy-require isolation: the supervisor file is loaded explicitly here
# and is NOT part of the core `require "agent_daemon"` graph.
require "agent_daemon/supervisor/master"

class TestSupervisorMaster < Minitest::Test
  include LogStubbing

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
  # `console:` splices a Story 2.2 console block into the supervisor config;
  # omitting it (every pre-2.2 caller) leaves the config exactly as before.
  def with_config(specs, console: nil, history: nil)
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
        data["description"] = spec[:description] if spec[:description]
        data["support"] = spec[:support] if spec[:support]
        File.write(File.join(wf_dir, "#{spec[:name]}.yml"), data.to_yaml)
      end

      entries = specs.map { |s| { "name" => s[:name], "config" => "workflows/#{s[:name]}.yml" } }
      path = File.join(dir, "supervisor.yml")
      supervisor_data = { "workflows" => entries }
      supervisor_data["console"] = console if console
      supervisor_data["history"] = history if history
      File.write(path, supervisor_data.to_yaml)

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
  # Factories receive the per-generation Sinks::Bundle and an optional
  # generation cancel token. One-arg calls remain the compatibility proof.

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

      token = AgentDaemon::Supervisor::CancelToken.new
      token_instance = factories.fetch(:"runner:wf:t").call(AgentDaemon::Sinks::Bundle.null(identity), token)
      assert_same token, token_instance.instance_variable_get(:@cancel_flag)
      assert_same token, token_instance.instance_variable_get(:@backend).instance_variable_get(:@cancel_flag)

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

      token = AgentDaemon::Supervisor::CancelToken.new
      token_instance = factories.fetch(:"runner:wf:f").call(AgentDaemon::Sinks::Bundle.null, token)
      assert_same token, token_instance.instance_variable_get(:@cancel_flag)
      assert_same token, token_instance.instance_variable_get(:@backend).instance_variable_get(:@cancel_flag)
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

      token = AgentDaemon::Supervisor::CancelToken.new
      token_instance = factories.fetch(:"runner:wf:m").call(AgentDaemon::Sinks::Bundle.null, token)
      assert_same token, token_instance.instance_variable_get(:@cancel_flag)
      assert_same token, token_instance.instance_variable_get(:@backend).instance_variable_get(:@cancel_flag)
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
      token = AgentDaemon::Supervisor::CancelToken.new
      token_instance = factories.fetch(:mattermost_reactor).call(
        AgentDaemon::Sinks::Bundle.null("mattermost_reactor"), token
      )
      assert_instance_of AgentDaemon::Mattermost::Reactor, token_instance
      assert_same token, token_instance.instance_variable_get(:@cancel_flag)
    end
  end

  # AC16's second half — "no listener threads are spawned outside its
  # ownership" — is a property of the *real* factory, and the story's pin for
  # it drives a RunnerSupervisorStoppableFake under the id string
  # "mattermost_reactor", so build_reactor_factory is never invoked there.
  # Restart turnover calls this lambda once per generation: each call must mint
  # its own listeners, or a replacement reactor would adopt objects the
  # superseded generation still owns.
  def test_each_reactor_generation_owns_freshly_built_listeners
    with_config(
      [
        { name: "wfA", runners: [mattermost_runner("m1")] },
        { name: "wfB", runners: [mattermost_runner("m2")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      factory = master.instance_variable_get(:@entity_factories).fetch(:mattermost_reactor)

      generations = 2.times.map do
        factory.call(AgentDaemon::Sinks::Bundle.null("mattermost_reactor"),
                     AgentDaemon::Supervisor::CancelToken.new)
      end
      first, second = generations.map { |r| r.instance_variable_get(:@listeners) }

      refute_same generations[0], generations[1]
      assert_equal 2, first.size
      assert_equal 2, second.size
      assert_empty first.map(&:object_id) & second.map(&:object_id),
                   "a replacement reactor generation must not adopt the superseded generation's listeners"
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
      token = AgentDaemon::Supervisor::CancelToken.new
      token_instance = factories.fetch(:"messenger:wfA").call(
        AgentDaemon::Sinks::Bundle.null("messenger:wfA"), token
      )
      assert_instance_of AgentDaemon::Messenger, token_instance
      assert_same token, token_instance.instance_variable_get(:@cancel_flag)
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
      master.instance_variable_get(:@entity_factories)[:"runner:wf:a"] = ->(_bundle, _cancel_token = nil) { raising }

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
        ->(_bundle, _cancel_token = nil) { Class.new { def run = raise("boom") }.new }
      master.instance_variable_get(:@entity_factories)[:"runner:wf:b"] =
        ->(_bundle, _cancel_token = nil) { Class.new { def run = nil }.new }

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

  # --- Console wiring (Story 2.2, AC7/AC8) ---------------------------------

  CONSOLE_BLOCK = {
    "base_url" => "https://console.example.com",
    "auth" => {
      "gitlab_host" => "https://gitlab.example.com",
      "app_id" => "app-id",
      "app_secret" => "app-secret",
      "allowed_groups" => ["backoffice"]
    }
  }.freeze

  # Records the lifecycle instead of binding a socket — Puma itself is covered
  # end to end in test_console_server.rb.
  class ConsoleSpy
    attr_reader :config, :events
    attr_accessor :alive

    def initialize(config, port: 9292, fail_on: nil)
      @config = config
      @port = port
      @fail_on = fail_on
      @alive = true
      @events = []
    end

    def port = @port

    def running? = @alive

    def start
      @events << :start
      raise "console boom" if @fail_on == :start

      self
    end

    def stop
      @events << :stop
      raise "stop boom" if @fail_on == :stop
    end
  end

  def spy_factory(spies, **kwargs)
    lambda do |console_config, _fleet, _activity_log, _event_bus, _state_registry, _output_buffers,
               restart_control: nil, history: nil|
      spies << ConsoleSpy.new(console_config, **kwargs)
      spies.last.instance_variable_set(:@restart_control, restart_control)
      spies.last.instance_variable_set(:@history, history)
      spies.last
    end
  end

  # Swaps the null logger this file installs for a StringIO one just for the
  # block, and returns the ERROR lines emitted inside it. Restores the null
  # logger afterwards so nothing leaks into the rest of the file.
  def capture_log_errors
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.level = ::Logger::ERROR
    prior = AgentDaemon::Log.instance_variable_get(:@logger)
    AgentDaemon::Log.use(logger)
    yield
    io.string.lines.map(&:chomp).reject(&:empty?)
  ensure
    AgentDaemon::Log.instance_variable_set(:@logger, prior)
  end

  def test_console_is_started_with_the_configured_block
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory(spies))
      master.send(:start_console)

      assert_equal 1, spies.size
      assert_equal [:start], spies.first.events
      # The factory receives the DEFAULTS-merged block, not the raw YAML.
      assert_equal "127.0.0.1", spies.first.config["bind"]
      assert_equal 28_800, spies.first.config["session_ttl"]
      assert_equal "https://console.example.com", spies.first.config["base_url"]
    end
  end

  # The console is not a supervised entity (AD-13), so nothing restarts it —
  # but a dead Puma thread must not be invisible either. The tick observes it
  # and says so exactly once, rather than once per second forever.
  def test_a_dead_console_is_reported_once_by_the_supervision_tick
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory(spies))
      master.send(:start_console)

      assert_empty capture_log_errors { master.send(:check_console) },
                   "a healthy console must say nothing"

      spies.first.alive = false
      errors = capture_log_errors do
        master.send(:check_console)
        master.send(:check_console)
      end

      assert_equal 1, errors.size, "the death must be reported once, not once per tick"
      assert_match(/no longer running/, errors.first)
    end
  end

  def test_console_never_checked_when_no_console_is_configured
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:start_console)

      errors = capture_log_errors { master.send(:check_console) }

      assert_empty errors
    end
  end

  def test_console_is_stopped_on_shutdown
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory(spies))
      master.send(:start_console)
      master.send(:stop_console)

      assert_equal %i[start stop], spies.first.events
    end
  end

  # AC8 — a config with no console block must construct nothing at all.
  def test_no_console_block_never_constructs_a_server
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      assert_nil config.console

      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory(spies))
      master.send(:start_console)
      master.send(:stop_console)

      assert_empty spies, "no console block must mean no console object"
      assert_nil master.instance_variable_get(:@console)
    end
  end

  # AC7 / AD-3 / NFR4 — the console is an observer: its failure degrades the
  # console, never the fleet.
  def test_a_console_that_fails_to_start_does_not_stop_the_fleet
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory(spies, fail_on: :start))
      master.send(:build_factories)
      master.send(:build_supervisors)
      master.send(:start_console)
      master.send(:start_supervisors)

      supervisors = master.instance_variable_get(:@supervisors)
      refute_empty supervisors
      supervisors.each_value { |supervisor| refute_nil supervisor.thread }

      # Nothing was retained, so shutdown has nothing to take down either.
      assert_nil master.instance_variable_get(:@console)
      master.send(:stop_console)
      assert_equal [:start], spies.first.events
    ensure
      # `master` is nil if with_config or Master.new raised; without the guard
      # this ensure would mask the real failure with a NoMethodError.
      if master
        master.instance_variable_get(:@shutdown_flag).set!
        master.send(:wait_for_threads)
      end
    end
  end

  # A factory that blows up before returning an object is the misconfiguration
  # case (bad base_url, unusable auth block) — same rule applies.
  def test_a_console_factory_that_raises_does_not_stop_the_fleet
    exploding = lambda do |_console_config, _fleet, _activity_log, _event_bus, _state_registry, _output_buffers,
                          restart_control: nil, history: nil|
      raise "factory boom"
    end
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: exploding)
      master.send(:build_factories)
      master.send(:build_supervisors)
      master.send(:start_console)
      master.send(:start_supervisors)

      assert_nil master.instance_variable_get(:@console)
      refute_empty master.instance_variable_get(:@supervisors)
    ensure
      # `master` is nil if with_config or Master.new raised; without the guard
      # this ensure would mask the real failure with a NoMethodError.
      if master
        master.instance_variable_get(:@shutdown_flag).set!
        master.send(:wait_for_threads)
      end
    end
  end

  # Story 1.6's reasoning applied to the console: a console that will not stop
  # must not cost the fleet its final tick and orphan sweep.
  def test_a_console_that_fails_to_stop_does_not_raise
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory(spies, fail_on: :stop))
      master.send(:start_console)

      master.send(:stop_console) # must not raise

      assert_equal %i[start stop], spies.first.events
    end
  end

  # The console must come down BEFORE the final tick and the orphan sweep, so
  # no request thread can observe a half-finalized fleet.
  def test_start_stops_the_console_before_finalizing_supervisors
    # Master#start installs its own INT/TERM handlers; save and restore the
    # real ones (test_supervisor_shutdown.rb's precedent).
    original_term = Signal.trap("TERM", "DEFAULT")
    original_int = Signal.trap("INT", "DEFAULT")

    order = []
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, console_factory: spy_factory(spies))
      master.define_singleton_method(:stop_console) { order << :stop_console; super() }
      master.define_singleton_method(:finalize_supervisors) { order << :finalize; super() }
      master.define_singleton_method(:sweep_orphaned_agents) { order << :sweep; super() }
      master.instance_variable_get(:@shutdown_flag).set!

      master.start

      assert_equal %i[stop_console finalize sweep], order
      assert_equal %i[start stop], spies.first.events
    end
  ensure
    Signal.trap("TERM", original_term)
    Signal.trap("INT", original_int)
  end

  # --- Story 2.3: the roster the console factory receives -----------------

  def test_console_factory_receives_a_fleet_whose_roster_covers_runners_messenger_and_reactor_in_order
    received_fleet = nil
    factory = lambda do |console_config, fleet, _activity_log, _event_bus, _state_registry, _output_buffers,
                        restart_control: nil, history: nil|
      received_fleet = fleet
      ConsoleSpy.new(console_config)
    end

    with_config(
      [{
        name: "wf",
        runners: [tracker_runner("a"), mattermost_runner("m")],
        messenger: { "webhook_url" => "https://example.com/h" }
      }],
      console: CONSOLE_BLOCK
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: factory)
      master.send(:build_factories)
      master.send(:start_console)

      entries = received_fleet.entries
      assert_equal %i[runner runner messenger reactor], entries.map(&:kind)
      assert_equal %w[a m messenger mattermost_reactor], entries.map(&:name)
      assert_equal ["tracker", "mattermost", nil, nil], entries.map(&:trigger_type)
    end
  end

  # The config is the only source of these — a Master that reads them from the
  # wrong place ships a console whose descriptions are permanently blank with a
  # green suite, the same failure mode the restart_delay wiring test guards.
  def test_console_factory_receives_a_fleet_carrying_config_authored_descriptions
    received_fleet = nil
    factory = lambda do |console_config, fleet, _activity_log, _event_bus, _state_registry, _output_buffers,
                        restart_control: nil, history: nil|
      received_fleet = fleet
      ConsoleSpy.new(console_config)
    end
    documented_runner = tracker_runner("a").merge(
      "description" => "Picks up open tasks.",
      "support" => { "owner" => "@alexander" }
    )

    with_config(
      [{
        name: "wf",
        runners: [documented_runner, tracker_runner("b")],
        description: "Analyses tracker tasks.",
        support: { "runbook" => "https://wiki.example.com/flows" }
      }],
      console: CONSOLE_BLOCK
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: factory)
      master.send(:build_factories)
      master.send(:start_console)

      documented, undocumented = received_fleet.entries
      workflow_doc = received_fleet.workflow_doc("wf")

      assert_equal "Picks up open tasks.", documented.doc.description
      assert_equal({ "owner" => "@alexander" }, documented.doc.support)
      assert_nil undocumented.doc
      assert_equal "Analyses tracker tasks.", workflow_doc.description
      assert_equal({ "runbook" => "https://wiki.example.com/flows" }, workflow_doc.support)
    end
  end

  # A workflow whose config says nothing must not appear in the docs map at
  # all — the console renders a Doc iff it exists.
  def test_a_workflow_without_descriptions_has_no_doc
    received_fleet = nil
    factory = lambda do |console_config, fleet, _activity_log, _event_bus, _state_registry, _output_buffers,
                        restart_control: nil, history: nil|
      received_fleet = fleet
      ConsoleSpy.new(console_config)
    end

    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: factory)
      master.send(:build_factories)
      master.send(:start_console)

      assert_nil received_fleet.workflow_doc("wf")
      assert_nil received_fleet.entries.first.doc
    end
  end

  # Story 2.5: a Master that wires the wrong bus (or none) into the console
  # factory would ship a permanently empty activity timeline with a green
  # suite — the same failure mode 2.4 wrote its restart_delay: wiring test to
  # catch. Prove it by publishing onto the Master's own event_bus and reading
  # it back through the activity_log the factory received.
  def test_console_factory_receives_an_activity_log_reading_the_masters_own_event_bus
    received_activity_log = nil
    factory = lambda do |console_config, _fleet, activity_log, _event_bus, _state_registry, _output_buffers,
                        restart_control: nil, history: nil|
      received_activity_log = activity_log
      ConsoleSpy.new(console_config)
    end

    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: factory)
      master.send(:build_factories)
      master.send(:start_console)

      identity = master.instance_variable_get(:@entity_ids).fetch(:"runner:wf:a")
      master.event_bus.publish(identity, { type: :picked_up, work_item: "T-1", generation: 1 })

      assert_equal 1, received_activity_log.recent("runner:wf:a").size
    end
  end


  def test_console_factory_receives_the_masters_exact_event_bus_and_state_registry
    received = nil
    factory = lambda do |console_config, _fleet, _activity_log, event_bus, state_registry, _output_buffers,
                        restart_control: nil, history: nil|
      received = [event_bus, state_registry]
      ConsoleSpy.new(console_config)
    end

    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: factory)
      master.send(:start_console)

      assert_same master.event_bus, received[0]
      assert_same master.state_registry, received[1]
    end
  end

  # DR1: the default CONSOLE_FACTORY must forward the Master's OWN
  # output_buffers, not a fresh empty store — the same wiring-guard shape
  # DR10 demanded for event_bus/state_registry above. A fresh store would
  # make snapshot(entry.entity_id) return :empty forever, silently.
  def test_console_factory_receives_the_masters_exact_output_buffers
    received = nil
    factory = lambda do |console_config, _fleet, _activity_log, _event_bus, _state_registry, output_buffers,
                        restart_control: nil, history: nil|
      received = output_buffers
      ConsoleSpy.new(console_config)
    end

    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: factory)
      master.send(:start_console)

      assert_same master.output_buffers, received
    end
  end

  def test_console_factory_receives_a_restart_control_for_the_supervised_roster
    received = nil
    factory = lambda do |console_config, _fleet, _activity_log, _event_bus, _state_registry, _output_buffers,
                        restart_control: nil, history: nil|
      received = restart_control
      ConsoleSpy.new(console_config)
    end

    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: factory)
      master.send(:build_factories)
      master.send(:build_supervisors)
      master.send(:start_console)

      assert_instance_of AgentDaemon::Supervisor::RestartControl, received
      assert_equal 1, received.request_restart("runner:wf:a", actor: "console:alice")
    end
  end

  # The console looks an id up in two maps built at different points:
  # Fleet keys rows off Rostered#entity_id, RestartControl off
  # RunnerIdentity.key_for(@entity_ids). Proving the runner id resolves proves
  # only the case where both happen to be a RunnerIdentity. AC14 (a Messenger
  # restart is scoped to its own workflow) and AC15/AC16 (the global reactor)
  # both ride on the String-keyed half, which nothing exercised.
  def test_the_restart_control_resolves_every_console_id_the_fleet_can_render
    received = nil
    factory = lambda do |console_config, fleet, _activity_log, _event_bus, _state_registry, _output_buffers,
                        restart_control: nil, history: nil|
      received = [restart_control, fleet]
      ConsoleSpy.new(console_config)
    end

    with_config(
      [{
        name: "wf",
        runners: [tracker_runner("a"), mattermost_runner("m")],
        messenger: { "webhook_url" => "https://example.com/h" }
      }],
      console: CONSOLE_BLOCK
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: factory)
      master.send(:build_factories)
      master.send(:build_supervisors)
      master.send(:start_console)

      control, fleet = received
      ids = fleet.entries.map(&:id)

      assert_includes ids, "messenger:wf"
      assert_includes ids, "mattermost_reactor"
      ids.each do |id|
        assert_equal 1, control.request_restart(id, actor: "console:alice"),
                     "the console can render #{id} but the restart control cannot resolve it"
      end
    end
  end

  # Fleet's header claims the roster "can never drift" from @entity_ids
  # because both are written at the same three sites. That is an invariant,
  # not a comment: an entity wired into @entity_factories without a matching
  # roster line vanishes from the console silently, and a monitoring surface
  # that shows fewer entities than exist fails in the worst direction.
  def test_the_roster_covers_exactly_the_supervised_entity_ids
    with_config(
      [{
        name: "wf",
        runners: [tracker_runner("a"), mattermost_runner("m")],
        messenger: { "webhook_url" => "https://example.com/h" }
      }],
      console: CONSOLE_BLOCK
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory([]))
      master.send(:build_factories)

      roster_ids = master.instance_variable_get(:@roster).map(&:entity_id)
      entity_ids = master.instance_variable_get(:@entity_ids).values

      assert_equal entity_ids.size, roster_ids.size
      assert_empty entity_ids - roster_ids, "supervised entities missing from the console roster"
      assert_empty roster_ids - entity_ids, "roster rows with no supervised entity behind them"
    end
  end

  # Story 2.4: restart_delay is injected into Fleet, not imported, so nothing
  # keeps the two in sync but this test. A Master that forgot to pass it
  # would silently disable the stuck-restart flag (Fleet defaults to nil).
  def test_fleet_carries_the_supervisors_real_restart_delay
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory([]))

      fleet = master.send(:fleet)

      assert_equal AgentDaemon::Supervisor::RunnerSupervisor::RESTART_DELAY,
                   fleet.instance_variable_get(:@restart_delay)
      assert_equal config.restart_warning_margin_seconds,
                   fleet.instance_variable_get(:@restart_warning_margin)
    end
  end

  # Master#fleet advertises that it tolerates being called before
  # build_factories. It only does if Fleet copies the roster instead of
  # freezing Master's own array.
  def test_starting_the_console_before_build_factories_does_not_wedge_the_roster
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, console_factory: spy_factory([]))
      master.send(:start_console)
      master.send(:build_factories)

      assert_equal %w[a], master.instance_variable_get(:@roster).map(&:name)
    end
  end

  # --- Story 3.3 / DR6: the output pipeline is wired into the fleet ---------

  class PipelineObserver
    attr_reader :records

    def initialize
      @records = []
    end

    def call(record)
      @records << record
    end
  end

  # The guard the deferred "hand-copy nothing keeps in sync" finding asked
  # for: this must fail if the Master's output sink is ever reverted to
  # NullOutput.
  def test_the_master_built_bundle_publishes_output_into_the_masters_own_pipeline
    with_config([{ name: "wf", runners: [tracker_runner("r")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      observer = PipelineObserver.new
      master.output_pipeline.subscribe(observer)

      bundle = master.send(:read_model_sinks_factory, :"runner:wf:r").call(5)
      bundle.begin_output_run(1)
      bundle.append_output(:stdout, "hello\n")

      record = observer.records.fetch(0)
      assert_equal 5, record.generation
      assert_equal 1, record.run_id
      assert_equal :stdout, record.stream
      assert_equal "hello", record.text
      assert_equal AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "r"), record.entity_id
    end
  end

  def test_a_respawn_stamps_the_new_generation_on_output
    with_config([{ name: "wf", runners: [tracker_runner("r")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      observer = PipelineObserver.new
      master.output_pipeline.subscribe(observer)
      factory = master.send(:read_model_sinks_factory, :"runner:wf:r")

      factory.call(1).append_output(:stdout, "gen-one\n")
      factory.call(2).append_output(:stdout, "gen-two\n")

      assert_equal [[1, "gen-one"], [2, "gen-two"]],
                   observer.records.map { |r| [r.generation, r.text] }
    end
  end

  def test_the_bundle_closes_the_run_so_a_newlineless_tail_is_flushed
    with_config([{ name: "wf", runners: [tracker_runner("r")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      observer = PipelineObserver.new
      master.output_pipeline.subscribe(observer)

      bundle = master.send(:read_model_sinks_factory, :"runner:wf:r").call(1)
      bundle.begin_output_run(1)
      bundle.append_output(:stdout, "tail")
      assert_empty observer.records, "a partial line must not escape before the run closes"
      bundle.end_output_run(1, :ok)

      assert_equal ["tail"], observer.records.map(&:text)
    end
  end

  # RunnerSupervisor's own default is intentionally NOT the pipeline: it
  # serves the no-supervisor path, and only the Master has one to inject.
  def test_the_runner_supervisor_default_output_sink_stays_null
    bundle = AgentDaemon::Supervisor::RunnerSupervisor
             .new("ent", entity_factory: ->(_b, _cancel_token = nil) {}, shutdown_flag: AgentDaemon::ShutdownFlag.new)
             .send(:default_sinks_factory, 1)

    assert_instance_of AgentDaemon::Sinks::NullOutput, bundle.instance_variable_get(:@output)
  end

  # DR2: the Redactor is the union of the supervisor's and EVERY workflow's
  # resolved secrets — a workflow secret the supervisor config never saw must
  # still be redacted.
  def test_a_secret_declared_only_in_a_workflow_config_is_redacted
    with_env("WF_ONLY_SECRET" => "sekret-value-1") do
      with_erb_workflow_config do |config|
        master = AgentDaemon::Supervisor::Master.new(config)
        master.send(:build_factories)
        observer = PipelineObserver.new
        master.output_pipeline.subscribe(observer)

        bundle = master.send(:read_model_sinks_factory, :"runner:wf:r").call(1)
        bundle.append_output(:stdout, "token=sekret-value-1 ok\n")

        assert_equal ["token=[REDACTED] ok"], observer.records.map(&:text)
      end
    end
  end

  # DR2's "and vice versa": a secret the supervisor config resolved but no
  # workflow config ever saw must still be redacted in pipeline output.
  def test_a_secret_declared_only_in_the_supervisor_config_is_redacted
    with_env("SUP_ONLY_SECRET" => "sup-sekret-1") do
      Dir.mktmpdir do |dir|
        wf_dir = File.join(dir, "workflows")
        FileUtils.mkdir_p(File.join(wf_dir, "prompts"))
        File.write(File.join(wf_dir, "prompts", "default.txt"), "Prompt {{task_key}}")
        File.write(File.join(wf_dir, "wf.yml"), <<~YAML)
          project_path: #{File.join(dir, "proj-wf")}
          message_dir: to_message
          tracker:
            token: t
            org_id: o
          runners:
            - name: r
              prompt_template: prompts/default.txt
              trigger:
                type: tracker
                query: 'Queue: TI'
        YAML

        path = File.join(dir, "supervisor.yml")
        File.write(path, <<~YAML)
          note: <%= secret('SUP_ONLY_SECRET') %>
          workflows:
            - name: wf
              config: workflows/wf.yml
        YAML

        master = AgentDaemon::Supervisor::Master.new(AgentDaemon::Supervisor::Config.new(path))
        master.send(:build_factories)
        observer = PipelineObserver.new
        master.output_pipeline.subscribe(observer)

        bundle = master.send(:read_model_sinks_factory, :"runner:wf:r").call(1)
        bundle.append_output(:stdout, "token=sup-sekret-1 ok\n")

        assert_equal ["token=[REDACTED] ok"], observer.records.map(&:text)
      end
    end
  end

  # --- Story 3.4 / DR10: OutputBuffers is wired into the Master ------------

  # The guard DR10 asks for: this must fail if the Master's `subscribe`
  # call into OutputBuffers is ever deleted.
  def test_output_published_through_the_master_lands_in_output_buffers
    with_config([{ name: "wf", runners: [tracker_runner("r")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      identity = master.instance_variable_get(:@entity_ids).fetch(:"runner:wf:r")

      bundle = master.send(:read_model_sinks_factory, :"runner:wf:r").call(3)
      bundle.begin_output_run(1)
      bundle.append_output(:stdout, "hello\n")
      bundle.end_output_run(1, :ok)

      snap = master.output_buffers.snapshot(identity)
      assert_equal :retained, snap.status
      assert_equal 3, snap.generation
      assert_equal 1, snap.run_id
      assert_equal ["hello"], snap.records.map(&:text)
      assert snap.finished
      assert_equal :ok, snap.reason
    end
  end

  # Both the store's capacity and the pipeline's max_line_bytes come from the
  # same config value: construct a Master from a config with a non-default
  # output_buffer_bytes and observe eviction happening at that size.
  def test_output_buffer_bytes_from_config_bounds_both_the_store_and_the_pipeline
    Dir.mktmpdir do |dir|
      wf_dir = File.join(dir, "workflows")
      FileUtils.mkdir_p(File.join(wf_dir, "prompts"))
      File.write(File.join(wf_dir, "prompts", "default.txt"), "Prompt {{task_key}}")
      File.write(File.join(wf_dir, "wf.yml"), {
        "project_path" => File.join(dir, "proj-wf"),
        "message_dir" => "to_message",
        "tracker" => { "token" => "t", "org_id" => "o" },
        "runners" => [tracker_runner("r")]
      }.to_yaml)

      path = File.join(dir, "supervisor.yml")
      File.write(path, {
        "workflows" => [{ "name" => "wf", "config" => "workflows/wf.yml" }],
        "output_buffer_bytes" => 16_384
      }.to_yaml)

      config = AgentDaemon::Supervisor::Config.new(path)
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      identity = master.instance_variable_get(:@entity_ids).fetch(:"runner:wf:r")

      bundle = master.send(:read_model_sinks_factory, :"runner:wf:r").call(1)
      bundle.begin_output_run(1)
      bundle.append_output(:stdout, "#{'a' * 10_000}\n")
      bundle.append_output(:stdout, "#{'b' * 10_000}\n")

      snap = master.output_buffers.snapshot(identity)
      assert snap.truncated, "the small non-default capacity must already have evicted the first line"
      assert_equal ["b" * 10_000], snap.records.map(&:text)

      # The pipeline half of the wiring: a newline-free chunk over the
      # configured 16_384 (but under the 262_144 default) must be
      # force-emitted — this fails if master.rb stops passing max_line_bytes.
      bundle.append_output(:stdout, "c" * 20_000)
      snap = master.output_buffers.snapshot(identity)
      forced = snap.records.map(&:text).select { |t| t.start_with?("c") }
      refute_empty forced,
                   "the configured max_line_bytes must force-emit a newline-free over-cap chunk"
    end
  end

  # A known secret longer than the forced-cut hold-back cap
  # (output_buffer_bytes / 2) can be split across forced records and leak;
  # the Master must say so at boot. The value itself must never be logged.
  def test_master_warns_at_boot_when_a_known_secret_exceeds_the_forced_cut_hold_back
    secret = "s" * 9_000
    with_env("WF_ONLY_SECRET" => secret) do
      Dir.mktmpdir do |dir|
        wf_dir = File.join(dir, "workflows")
        FileUtils.mkdir_p(File.join(wf_dir, "prompts"))
        File.write(File.join(wf_dir, "prompts", "default.txt"), "Prompt {{task_key}}")
        File.write(File.join(wf_dir, "wf.yml"), <<~YAML)
          project_path: #{File.join(dir, "proj-wf")}
          message_dir: to_message
          tracker:
            token: <%= secret('WF_ONLY_SECRET') %>
            org_id: o
          runners:
            - name: r
              prompt_template: prompts/default.txt
              trigger:
                type: tracker
                query: 'Queue: TI'
        YAML

        path = File.join(dir, "supervisor.yml")
        File.write(path, {
          "workflows" => [{ "name" => "wf", "config" => "workflows/wf.yml" }],
          "output_buffer_bytes" => 16_384
        }.to_yaml)

        log_io = StringIO.new
        prior = AgentDaemon::Log.instance_variable_get(:@logger)
        AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(log_io))
        begin
          AgentDaemon::Supervisor::Master.new(AgentDaemon::Supervisor::Config.new(path))
        ensure
          AgentDaemon::Log.instance_variable_set(:@logger, prior)
        end

        assert_includes log_io.string, "forced-cut hold-back"
        refute_includes log_io.string, secret
      end
    end
  end

  def test_output_with_no_known_secret_passes_through_the_masters_pipeline_unchanged
    with_env("WF_ONLY_SECRET" => "sekret-value-1") do
      with_erb_workflow_config do |config|
        master = AgentDaemon::Supervisor::Master.new(config)
        master.send(:build_factories)
        observer = PipelineObserver.new
        master.output_pipeline.subscribe(observer)

        bundle = master.send(:read_model_sinks_factory, :"runner:wf:r").call(1)
        bundle.append_output(:stdout, "nothing to hide\n")

        assert_equal ["nothing to hide"], observer.records.map(&:text)
      end
    end
  end

  def with_env(vars)
    saved = {}
    vars.each { |k, v| saved[k] = ENV[k]; ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # A supervisor config with NO secret() of its own, referencing a workflow
  # config that resolves one through ERB (written raw so the tag survives).
  def with_erb_workflow_config
    Dir.mktmpdir do |dir|
      wf_dir = File.join(dir, "workflows")
      FileUtils.mkdir_p(File.join(wf_dir, "prompts"))
      File.write(File.join(wf_dir, "prompts", "default.txt"), "Prompt {{task_key}}")
      File.write(File.join(wf_dir, "wf.yml"), <<~YAML)
        project_path: #{File.join(dir, "proj-wf")}
        message_dir: to_message
        tracker:
          token: <%= secret('WF_ONLY_SECRET') %>
          org_id: o
        runners:
          - name: r
            prompt_template: prompts/default.txt
            trigger:
              type: tracker
              query: 'Queue: TI'
      YAML

      path = File.join(dir, "supervisor.yml")
      File.write(path, { "workflows" => [{ "name" => "wf", "config" => "workflows/wf.yml" }] }.to_yaml)

      yield AgentDaemon::Supervisor::Config.new(path)
    end
  end

  # --- Story 5.1: history is opened before the fleet and never stops it -----

  # Master#start installs its own INT/TERM handlers; save and restore the real
  # ones (test_supervisor_shutdown.rb's precedent). The flag is preset, so
  # start runs one full boot-to-shutdown cycle and returns.
  def boot_and_shut_down(master)
    original_term = Signal.trap("TERM", "DEFAULT")
    original_int = Signal.trap("INT", "DEFAULT")
    master.instance_variable_get(:@shutdown_flag).set!
    master.start
  ensure
    Signal.trap("TERM", original_term)
    Signal.trap("INT", original_int)
  end

  def raising_opener(error)
    ->(_history_config) { raise error }
  end

  # Story 5.6: a real writer prunes at startup against the real clock, so
  # persisted fixtures are dated relative to now (an hour ago plus offset),
  # never to a fixed day that would one day fall out of retention. A
  # constant, so the singleton methods defined on a master can reach it.
  RECENT = ->(offset = 0) { (Time.now.utc - 3600 + offset).iso8601(3) }

  def test_a_history_open_failure_degrades_history_and_the_fleet_still_supervises
    require "sqlite3"
    [SQLite3::CantOpenException.new("unable to open database file"), LoadError.new("cannot load such file -- sqlite3")]
      .each do |error|
      with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
        master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, history_opener: raising_opener(error))
        errors = capture_log_errors { boot_and_shut_down(master) }

        assert_equal :degraded, master.history_state
        assert_nil master.history
        history_lines = errors.grep(/\[History\]/)
        assert_equal 1, history_lines.size, errors.inspect
        assert_includes history_lines.first, config.history["database_path"]
        assert_includes history_lines.first, error.class.name
        refute_empty master.instance_variable_get(:@supervisors)
        master.instance_variable_get(:@supervisors).each_value { |supervisor| refute_nil supervisor.thread }
      end
    end
  end

  def test_history_opens_after_the_factories_are_built_and_before_any_entity_spawns
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      seen = nil
      master = nil
      opener = lambda do |_history_config|
        seen = { factories: master.instance_variable_get(:@entity_factories).size,
                 supervisors: master.instance_variable_get(:@supervisors).size }
        raise "stop here"
      end
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, history_opener: opener)
      boot_and_shut_down(master)

      assert_equal({ factories: 1, supervisors: 0 }, seen)
    end
  end

  def test_the_default_opener_applies_the_configured_busy_timeout
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], history: { "busy_timeout_ms" => 250 }) do |_dir, config|
      busy_timeout = nil
      opener = lambda do |history_config|
        store = AgentDaemon::Supervisor::Master::HISTORY_OPENER.call(history_config)
        busy_timeout = store.busy_timeout_ms
        store
      end
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, history_opener: opener)
      boot_and_shut_down(master)

      assert_equal :ready, master.history_state
      assert_equal 250, busy_timeout
    end
  end

  # --- Story 5.2: the history writer -----------------------------------------

  def test_events_published_before_start_are_persisted_by_the_writer
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      identity = AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "a")
      stamp = AgentDaemon::Supervisor::GenerationStamp.new(2, master.event_bus)
      stamp.publish(identity, type: :picked_up, work_item: "TI-1", at: RECENT[])
      stamp.publish(identity, type: :restart, actor: [:crash_auto], requested_at: RECENT[-60],
                              at: RECENT[])
      boot_and_shut_down(master)

      assert_equal :ready, master.history_state
      refute master.history_writer.thread.alive?
      assert master.history.db.closed?
      db = SQLite3::Database.new(File.join(dir, "history", "history.sqlite3"))
      assert_equal [[2, "TI-1"]], db.execute("SELECT generation, work_item FROM run")
      assert_equal [[1, 2, '["crash_auto"]']],
                   db.execute("SELECT source_generation, target_generation, actors FROM restart_action")
      db.close
    end
  end

  def test_the_writer_is_built_before_any_entity_spawns
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      seen = nil
      master = nil
      factory = lambda do |database, event_bus, output_pipeline, roster, supervisor_config|
        seen = { supervisors: master.instance_variable_get(:@supervisors).size, roster: roster.size }
        AgentDaemon::Supervisor::Master::HISTORY_WRITER_FACTORY.call(database, event_bus, output_pipeline, roster,
                                                                     supervisor_config)
      end
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, history_writer_factory: factory)
      boot_and_shut_down(master)

      assert_equal({ supervisors: 0, roster: 1 }, seen)
    end
  end

  # The writer's final drain must see what entities publish while they are
  # finalized (a killed run's `finished`), so it stops only after them.
  def test_an_event_published_while_entities_are_finalized_is_persisted
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      identity = AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "a")
      stamp = AgentDaemon::Supervisor::GenerationStamp.new(1, master.event_bus)
      master.define_singleton_method(:finalize_supervisors) do
        super()
        stamp.publish(identity, type: :finished, work_item: "TI-1", reason: :killed, attempt: 1,
                                at: RECENT[])
      end
      boot_and_shut_down(master)

      db = SQLite3::Database.new(File.join(dir, "history", "history.sqlite3"))
      assert_equal [["TI-1", "killed"]], db.execute("SELECT work_item, reason FROM run")
      db.close
    end
  end

  # Story 5.4: the writer observes the master's own pipeline, so a runner's
  # line reaches the store without any change to the producer path.
  def test_a_runners_output_line_through_the_masters_pipeline_is_persisted
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      identity = AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "a")
      stamp = AgentDaemon::Supervisor::GenerationStamp.new(1, master.event_bus)
      ingress = master.output_pipeline.ingress(1)
      master.define_singleton_method(:finalize_supervisors) do
        super()
        stamp.publish(identity, type: :picked_up, work_item: "TI-1", at: RECENT[])
        stamp.publish(identity, type: :started, work_item: "TI-1", attempt: 1, at: RECENT[1])
        ingress.begin_run(identity, 1)
        ingress.append(identity, :stderr, "boom\n")
        ingress.end_run(identity, 1, :failed)
        stamp.publish(identity, type: :finished, work_item: "TI-1", reason: :failed, attempt: 1,
                                at: RECENT[2])
      end
      boot_and_shut_down(master)

      assert_equal config.output_buffer_bytes, master.history_writer.instance_variable_get(:@output_buffer_bytes)
      db = SQLite3::Database.new(File.join(dir, "history", "history.sqlite3"))
      assert_equal [%w[stderr boom]], db.execute("SELECT stream, text FROM run_output")
      assert_equal '{"reason":"failed","attempt":1,"last_stderr":"boom"}',
                   db.get_first_value("SELECT error_summary FROM run")
      db.close
    end
  end

  def test_a_writer_that_fails_to_build_degrades_history_and_the_fleet_still_supervises
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      store = nil
      opener = ->(c) { store = AgentDaemon::Supervisor::Master::HISTORY_OPENER.call(c) }
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, history_opener: opener,
                                                           history_writer_factory: ->(*) { raise "no writer" })
      errors = capture_log_errors { boot_and_shut_down(master) }

      assert_equal :degraded, master.history_state
      assert_nil master.history
      assert_nil master.history_writer
      assert store.db.closed?
      assert_equal 1, errors.grep(/\[History\]/).size, errors.inspect
      master.instance_variable_get(:@supervisors).each_value { |supervisor| refute_nil supervisor.thread }
    end
  end

  StuckWriter = Struct.new(:stopped_with) do
    def start = self

    def stop(timeout:)
      self.stopped_with = timeout
      false
    end

    def unflushed_count = 7

    def degraded? = false

    def status = nil
  end

  def test_a_writer_that_misses_the_flush_deadline_leaves_the_store_open
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], history: { "shutdown_flush_seconds" => 3 }) do |_d, config|
      writer = StuckWriter.new
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, history_writer_factory: ->(*) { writer })
      log = capture_log { boot_and_shut_down(master) }

      assert_equal 3, writer.stopped_with
      refute master.history.db.closed?
      deadline_lines = log.lines.grep(/\[History\].*did not finish/)
      assert_equal 1, deadline_lines.size, log
      assert_includes deadline_lines.first, "3s"
      assert_includes deadline_lines.first, "7 accepted record(s) unflushed"
      master.history.close
    end
  end

  # --- Story 5.3: degraded state, retry wiring, restart recovery -------------

  DegradedWriter = Struct.new(:degraded) do
    def start = self
    def stop(timeout:) = true
    def degraded? = degraded
    def status = nil
  end

  def test_history_state_is_degraded_while_the_writer_reports_degraded
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      writer = DegradedWriter.new(false)
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, history_writer_factory: ->(*) { writer })
      boot_and_shut_down(master)

      assert_equal :ready, master.history_state
      writer.degraded = true
      assert_equal :degraded, master.history_state
    end
  end

  def test_the_default_factory_hands_the_configured_retry_policy_to_the_writer
    history = { "write_retry_count" => 7, "write_retry_backoff_ceiling_ms" => 900 }
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], history: history) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      boot_and_shut_down(master)

      writer = master.history_writer
      assert_equal [7, 900], [writer.instance_variable_get(:@retry_count),
                              writer.instance_variable_get(:@backoff_ceiling_ms)]
    end
  end

  def test_a_second_boot_marks_the_first_boots_open_run_incomplete
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |dir, config|
      identity = AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "a")
      first = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      stamp = AgentDaemon::Supervisor::GenerationStamp.new(1, first.event_bus)
      stamp.publish(identity, type: :picked_up, work_item: "TI-1", at: RECENT[])
      stamp.publish(identity, type: :started, work_item: "TI-1", attempt: 1, at: RECENT[1])
      boot_and_shut_down(first)

      second = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      boot_and_shut_down(second)

      assert_equal :ready, second.history_state
      db = SQLite3::Database.new(File.join(dir, "history", "history.sqlite3"))
      assert_equal [["TI-1", nil, nil, 1]], db.execute("SELECT work_item, finished_at, reason, incomplete FROM run")
      db.close
    end
  end

  def test_disabled_history_is_never_opened_and_creates_nothing
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], history: { "enabled" => false }) do |dir, config|
      opened = false
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2,
                                                           history_opener: ->(_c) { opened = true })
      boot_and_shut_down(master)

      assert_equal :disabled, master.history_state
      refute opened
      refute File.exist?(File.join(dir, "history"))
    end
  end

  def test_default_history_is_created_owner_only_and_survives_a_second_boot
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |dir, config|
      history_dir = File.join(dir, "history")
      db_path = File.join(history_dir, "history.sqlite3")

      first = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      boot_and_shut_down(first)

      assert_equal :ready, first.history_state
      assert first.history.db.closed?, "the store is closed on shutdown"
      assert_equal 0o700, File.stat(history_dir).mode & 0o777
      assert_equal 0o600, File.stat(db_path).mode & 0o777
      schema = ->(db) { db.execute("SELECT type, name, sql FROM sqlite_master ORDER BY name") }
      db = SQLite3::Database.new(db_path)
      before = schema.call(db)
      assert_equal AgentDaemon::Supervisor::History::Schema::LATEST, db.get_first_value("PRAGMA user_version")
      db.close
      assert_equal %w[restart_action run run_event run_output supervised_entity],
                   before.select { |type, _, _| type == "table" }.map { |_, name, _| name }

      second = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      boot_and_shut_down(second)

      db = SQLite3::Database.new(db_path)
      assert_equal before, schema.call(db)
      assert_equal AgentDaemon::Supervisor::History::Schema::LATEST, db.get_first_value("PRAGMA user_version")
      db.close
    end
  end

  def test_an_unopenable_database_path_degrades_history_with_the_real_opener
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], history: { "database_path" => "taken" }) do |dir, config|
      FileUtils.mkdir_p(File.join(dir, "taken"))
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      errors = capture_log_errors { boot_and_shut_down(master) }

      assert_equal :degraded, master.history_state
      assert_equal 1, errors.grep(/\[History\]/).size, errors.inspect
      refute_empty master.instance_variable_get(:@supervisors)
    end
  end

  # --- Story 5.5: the console's history reader -------------------------------

  def test_with_history_enabled_the_console_receives_the_masters_reader
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, console_factory: spy_factory(spies))
      boot_and_shut_down(master)

      assert_instance_of AgentDaemon::Supervisor::History::Reader, master.history_reader
      assert_same master.history_reader, spies.last.instance_variable_get(:@history)
      assert_equal config.history["page_size"], master.history_reader.page_size
    end
  end

  def test_with_history_disabled_the_console_receives_no_reader
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK,
                                                                  history: { "enabled" => false }) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, console_factory: spy_factory(spies))
      boot_and_shut_down(master)

      assert_nil master.history_reader
      assert_nil spies.last.instance_variable_get(:@history)
    end
  end

  def test_a_history_opener_that_raises_gives_the_console_no_reader
    spies = []
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], console: CONSOLE_BLOCK) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2, console_factory: spy_factory(spies),
                                                           history_opener: raising_opener(RuntimeError.new("no store")))
      capture_log_errors { boot_and_shut_down(master) }

      assert_equal :degraded, master.history_state
      assert_nil master.history_reader
      assert_nil spies.last.instance_variable_get(:@history)
    end
  end

  def test_a_writer_that_fails_to_start_builds_no_reader
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2,
                                                           history_writer_factory: ->(*) { raise "no writer" })
      boot_and_shut_down(master)

      assert_nil master.history_reader
    end
  end

  def test_the_reader_is_closed_at_shutdown
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      master.define_singleton_method(:finalize_supervisors) do
        super()
        history_reader.runs # opens the connection while the writer is live
      end
      boot_and_shut_down(master)

      assert_nil master.history_reader.instance_variable_get(:@db)
    end
  end

  # The reader closes even when the writer misses its flush deadline and
  # close_history returns early.
  def test_the_reader_is_closed_even_when_the_writer_misses_its_deadline
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      closed = []
      reader = Object.new
      reader.define_singleton_method(:close) { closed << true }
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2,
                                                           history_writer_factory: ->(*) { StuckWriter.new },
                                                           history_reader_factory: ->(_c, _s) { reader })
      capture_log { boot_and_shut_down(master) }

      assert_equal [true], closed
      master.history.close
    end
  end

  def test_a_reader_factory_that_raises_leaves_the_writer_running
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2,
                                                           history_reader_factory: ->(_c, _s) { raise "no reader" })
      errors = capture_log_errors { boot_and_shut_down(master) }

      assert_equal :ready, master.history_state
      assert_nil master.history_reader
      refute_nil master.history_writer
      assert_equal 1, errors.grep(/\[History\] reader unavailable/).size, errors.inspect
    end
  end

  # --- Story 5.6: retention -------------------------------------------------

  def test_the_masters_reader_reports_the_writers_status
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], history: { "retention_days" => 7, "prune_interval_seconds" => 900,
                                                                            "prune_batch_size" => 120 }) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      boot_and_shut_down(master)

      status = master.history_reader.status
      assert_instance_of AgentDaemon::Supervisor::History::Writer::Status, status
      assert_equal 7, status.retention_days
      refute status.writer_degraded
      writer = master.history_writer
      assert_equal [900, 120], [writer.instance_variable_get(:@prune_interval_seconds),
                                writer.instance_variable_get(:@prune_batch_size)]
    end
  end

  def test_a_started_master_prunes_runs_older_than_retention_without_operator_action
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |dir, config|
      path = File.join(dir, "history", "history.sqlite3")
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      store = AgentDaemon::Supervisor::History::Database.open(path: path, busy_timeout_ms: 1000)
      old = (Time.now.utc - (40 * 86_400)).iso8601(3)
      store.db.execute("INSERT INTO supervised_entity (entity_key, kind, workflow, runner, first_seen_at) " \
                       "VALUES ('runner:wf:a', 'runner', 'wf', 'a', ?)", [old])
      store.db.execute("INSERT INTO run (entity_id, generation, started_at, finished_at, reason) " \
                       "VALUES (1, 1, ?, ?, 'ok')", [old, old])
      store.db.execute("INSERT INTO run_event (run_id, seq, event, occurred_at) VALUES (1, 1, 'finished', ?)", [old])
      store.db.execute("INSERT INTO run_output (run_id, seq, stream, text) VALUES (1, 1, 'stdout', 'old')")
      store.close

      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      master.define_singleton_method(:finalize_supervisors) do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.01 until history_writer.status.last_pruned_at ||
                         Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        super()
      end
      boot_and_shut_down(master)

      db = SQLite3::Database.new(path)
      assert_equal [0, 0, 0], %w[run run_event run_output].map { |t| db.get_first_value("SELECT COUNT(*) FROM #{t}") }
      db.close
      refute_nil master.history_writer.status.last_pruned_at
    end
  end

  # AC1: Fleet -> entity -> Persisted history -> Older runs -> a run, every
  # page 200 from the master's real reader, the last showing that run's output.
  def test_an_operator_walks_from_the_fleet_to_a_persisted_runs_output
    require "rack"
    with_config([{ name: "wf", runners: [tracker_runner("a")] }], history: { "page_size" => 10 }) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      identity = AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "a")
      bodies = []
      master.define_singleton_method(:finalize_supervisors) do
        super()
        stamp = AgentDaemon::Supervisor::GenerationStamp.new(1, event_bus)
        ingress = output_pipeline.ingress(1)
        (1..11).each do |n|
          at = RECENT[n]
          stamp.publish(identity, type: :picked_up, work_item: "TI-#{n}", at: at)
          stamp.publish(identity, type: :started, work_item: "TI-#{n}", attempt: 1, at: at)
          if n == 1
            ingress.begin_run(identity, 1)
            ingress.append(identity, :stdout, "persisted-agent-line\n")
            ingress.end_run(identity, 1, :ok)
          end
          stamp.publish(identity, type: :finished, work_item: "TI-#{n}", reason: :ok, attempt: 1, at: at)
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until history_reader.runs.next_cursor
          raise "runs never persisted" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.01
        end

        app = AgentDaemon::Supervisor::Console::App.new(
          fleet: send(:fleet), activity_log: send(:activity_log),
          live_updates: AgentDaemon::Supervisor::Console::LiveUpdates.new(event_bus: event_bus,
                                                                          state_registry: state_registry),
          output_buffers: output_buffers, history: history_reader
        )
        session = AgentDaemon::Supervisor::Console::SessionStore.new(ttl: 60).then do |store|
          pending = store.create_pending(state: "s")
          store.claim_pending(pending.id, "s")
          store.promote(pending.id, username: "alice")
        end
        request = Rack::MockRequest.new(Rack::Lint.new(app))
        visit = lambda do |path|
          response = request.get(path, AgentDaemon::Supervisor::Console::Auth::SESSION_ENV_KEY => session)
          bodies << [path, response.status, response.body]
          response.body
        end
        link = ->(body, text) { body[/<a (?:rel="next" )?href="([^"]+)">#{text}<\/a>/, 1].gsub("&amp;", "&") }

        fleet_page = visit.call("/")
        entity_page = visit.call(link.call(fleet_page, "a"))
        history_page = visit.call(link.call(entity_page, "Persisted history"))
        older = visit.call(link.call(history_page, "Older runs"))
        visit.call(older[%r{<h3><a href="(/history/run\?id=\d+)">}, 1])
      end
      boot_and_shut_down(master)

      assert_equal 5, bodies.size
      bodies.each { |path, status, _body| assert_equal 200, status, path }
      assert_includes bodies.last[2], "persisted-agent-line"
      assert_includes bodies.last[2], "<div><dt>Work item</dt><dd>TI-1</dd></div>"
    end
  end
end
