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
  # `console:` splices a Story 2.2 console block into the supervisor config;
  # omitting it (every pre-2.2 caller) leaves the config exactly as before.
  def with_config(specs, console: nil)
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
      supervisor_data = { "workflows" => entries }
      supervisor_data["console"] = console if console
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
    lambda do |console_config, _fleet, _activity_log, _event_bus, _state_registry|
      spies << ConsoleSpy.new(console_config, **kwargs)
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
    exploding = ->(_console_config, _fleet, _activity_log, _event_bus, _state_registry) { raise "factory boom" }
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
    factory = lambda do |console_config, fleet, _activity_log, _event_bus, _state_registry|
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
    end
  end

  # Story 2.5: a Master that wires the wrong bus (or none) into the console
  # factory would ship a permanently empty activity timeline with a green
  # suite — the same failure mode 2.4 wrote its restart_delay: wiring test to
  # catch. Prove it by publishing onto the Master's own event_bus and reading
  # it back through the activity_log the factory received.
  def test_console_factory_receives_an_activity_log_reading_the_masters_own_event_bus
    received_activity_log = nil
    factory = lambda do |console_config, _fleet, activity_log, _event_bus, _state_registry|
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
    factory = lambda do |console_config, _fleet, _activity_log, event_bus, state_registry|
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
end
