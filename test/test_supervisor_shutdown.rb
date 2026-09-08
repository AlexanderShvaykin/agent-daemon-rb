# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

# AD-5 lazy-require isolation: supervisor files are loaded explicitly here and
# are NOT part of the core `require "agent_daemon"` graph.
require "agent_daemon/supervisor/master"

class TestSupervisorShutdown < Minitest::Test
  # Backend whose command is a fixed, overridable sleep regardless of prompt —
  # lets tests drive the real select-loop kill semantics without invoking a
  # real CLI agent. Nested so these fixtures do not leak into the global
  # namespace shared by every other test file in a `rake test` run.
  class SleepBackend < AgentDaemon::Backend::Base
    def initialize(seconds, *args, **kwargs)
      super(*args, **kwargs)
      @seconds = seconds
    end

    def build_command(_prompt, images: [])
      "sleep #{@seconds}"
    end
  end

  # Records the Result its select loop produced, so a test can assert on
  # `reason` instead of inferring it from side effects.
  class RecordingSleepBackend < SleepBackend
    attr_reader :last_result

    def run(prompt, images: [])
      @last_result = super
    end
  end

  # Counts kill_process_group invocations without signalling anything.
  class KillSpyBackend < SleepBackend
    attr_reader :kill_calls

    def initialize(*args, **kwargs)
      super
      @kill_calls = 0
    end

    def kill_process_group(_pid)
      @kill_calls += 1
    end
  end

  # A flag that never reports shutdown — simulates a backend whose own select
  # loop never gets a chance to observe the master's real flag (the "wedged
  # thread" scenario Task 4's sweep exists for).
  class NeverShutdown
    def value
      false
    end
  end

  # A stub runner entity owning a real SleepBackend on a flag that never fires —
  # the only way to stop its in-flight child is the master's sweep delegate.
  class WedgedRunnerStub
    attr_reader :backend

    def initialize(project_path)
      @backend = SleepBackend.new(
        60, {}, NeverShutdown.new,
        message_dir: File.join(project_path, "msg"), project_path: project_path
      )
    end

    def run
      @backend.run("prompt")
    end

    def kill_in_flight_agent
      @backend.kill_current_process_group
    end
  end

  # A cooperative stub entity whose thread exits as soon as the shared flag is set.
  class CooperativeStub
    def initialize(shutdown_flag)
      @shutdown_flag = shutdown_flag
    end

    def run
      sleep(0.01) until @shutdown_flag.value
    end
  end

  # A stub entity whose thread never observes the flag and never exits on its
  # own — models a thread wedged with no in-flight agent to sweep.
  class StuckStub
    def run
      sleep(3)
    end
  end

  # A no-op mattermost listener: #prepare succeeds (so the reactor enters real
  # EM.run) and #start does nothing (no real socket).
  class NoopMattermostListener
    def prepare
      self
    end

    def start; end
  end

  def setup
    @previous_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    @null_logger = ::Logger.new(File::NULL)
    @null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, @null_logger)
    @leaked_threads = []
  end

  def teardown
    # Restore, never clobber: AgentDaemon::Log is a process-wide singleton and
    # every later test file in this `rake test` run inherits whatever is left.
    AgentDaemon::Log.instance_variable_set(:@logger, @previous_logger)
    @leaked_threads.each { |t| t&.kill }
  end

  # Threads a test deliberately leaves running (stragglers) still have to die
  # with the test, or they bleed into the next one.
  def reap_after_test(thread)
    @leaked_threads << thread
    thread
  end

  # Mirrors test_supervisor_master.rb's with_config fixture builder.
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

  # Blocks until the process group is gone, so the assertion does not race the
  # child's reap — Process.kill(0, ...) succeeds against a not-yet-reaped zombie.
  #
  # EPERM is accepted alongside ESRCH for the same reason test_backend_execute
  # accepts it: once our group is reaped its gid can be recycled by a group
  # another user owns, and the probe then reports EPERM instead of ESRCH. It
  # is a deliberate, narrow loosening — a group WE still own always answers
  # signal 0 successfully, so a genuinely surviving agent still fails here.
  def assert_process_group_reaped(pid)
    100.times do
      Process.kill(0, -pid)
      sleep(0.05)
    rescue Errno::ESRCH, Errno::EPERM
      return pass
    end
    flunk("process group #{pid} still alive after the sweep")
  end

  # --- AC1: centralized signal -> shared flag fan-out ---------------------

  def test_trap_registration_installs_master_handler
    original_term = Signal.trap("TERM", "DEFAULT")
    original_int = Signal.trap("INT", "DEFAULT")

    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:setup_signal_handlers)

      installed_term = Signal.trap("TERM", "DEFAULT")
      flag = master.instance_variable_get(:@shutdown_flag)
      refute flag.value

      _out, err = capture_io { installed_term.call }

      assert flag.value
      assert_match(/Received SIGTERM/, err)
    end
  ensure
    Signal.trap("TERM", original_term)
    Signal.trap("INT", original_int)
  end

  def test_shared_shutdown_flag_identity_across_entity_kinds
    with_config(
      [
        {
          name: "wfA", runners: [tracker_runner("a")],
          messenger: { "webhook_url" => "https://example.com/h" }
        },
        { name: "wfB", runners: [file_runner("b")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      shared_flag = master.instance_variable_get(:@shutdown_flag)
      factories = master.instance_variable_get(:@entity_factories)

      runner_a = factories.fetch(:"runner:wfA:a").call(AgentDaemon::Sinks::Bundle.null)
      runner_b = factories.fetch(:"runner:wfB:b").call(AgentDaemon::Sinks::Bundle.null)
      messenger = factories.fetch(:"messenger:wfA").call(AgentDaemon::Sinks::Bundle.null)

      assert_same shared_flag, runner_a.instance_variable_get(:@shutdown_flag)
      assert_same shared_flag, runner_a.instance_variable_get(:@backend).instance_variable_get(:@shutdown_flag)
      assert_same shared_flag, runner_b.instance_variable_get(:@shutdown_flag)
      assert_same shared_flag, messenger.instance_variable_get(:@shutdown_flag)
    end
  end

  def test_flag_stops_all_cooperative_threads_without_thread_kill
    with_config(
      [
        {
          name: "wfA", runners: [tracker_runner("a")],
          messenger: { "webhook_url" => "https://example.com/h" }
        },
        { name: "wfB", runners: [file_runner("b")] }
      ]
    ) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      flag = master.instance_variable_get(:@shutdown_flag)
      # Stub the runner entities: a real Runner::Tracker would issue a live
      # request to api.tracker.yandex.net on its first iterate.
      factories = master.instance_variable_get(:@entity_factories)
      factories[:"runner:wfA:a"] = ->(_bundle, _cancel_token = nil) { CooperativeStub.new(flag) }
      factories[:"runner:wfB:b"] = ->(_bundle, _cancel_token = nil) { CooperativeStub.new(flag) }

      master.send(:build_supervisors)
      master.send(:start_supervisors)

      flag.set!
      master.send(:wait_for_threads)

      supervisors = master.instance_variable_get(:@supervisors)
      assert_equal 3, supervisors.size
      supervisors.each_value do |supervisor|
        refute supervisor.thread.alive?
        refute supervisor.thread[:crashed]
      end
    end
  end

  def test_start_runs_the_full_drain_sequence_and_returns
    original_term = Signal.trap("TERM", "DEFAULT")
    original_int = Signal.trap("INT", "DEFAULT")

    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      master.send(:build_factories)
      flag = master.instance_variable_get(:@shutdown_flag)
      master.instance_variable_get(:@entity_factories)[:"runner:wf:a"] =
        ->(_bundle, _cancel_token = nil) { CooperativeStub.new(flag) }

      driver = Thread.new do
        sleep(0.05) until master.instance_variable_get(:@supervisors).any?
        flag.set!
      end

      runner = Thread.new { master.start }
      assert runner.join(10), "Master#start should return once the flag is set"
      driver.join(1)

      supervisor = master.instance_variable_get(:@supervisors).fetch(:"runner:wf:a")
      refute supervisor.thread.alive?
      # The post-drain finalize tick must move a cleanly-ended entity off
      # :running, or every state sink keeps reporting it as live forever.
      assert_equal :exited, supervisor.state
    end
  ensure
    Signal.trap("TERM", original_term)
    Signal.trap("INT", original_int)
  end

  # --- AC2: bounded thread drain --------------------------------------------

  def test_wait_for_threads_joins_all_cooperative_threads_within_timeout
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 2)
      master.send(:build_factories)
      flag = master.instance_variable_get(:@shutdown_flag)
      master.instance_variable_get(:@entity_factories)[:"runner:wf:a"] = ->(_bundle, _cancel_token = nil) { CooperativeStub.new(flag) }

      master.send(:build_supervisors)
      master.send(:start_supervisors)
      flag.set!

      master.send(:wait_for_threads)

      supervisor = master.instance_variable_get(:@supervisors).fetch(:"runner:wf:a")
      refute supervisor.thread.alive?
    end
  end

  def test_wait_for_threads_returns_after_timeout_and_logs_straggler
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |_dir, config|
      io = StringIO.new
      warn_logger = ::Logger.new(io)
      warn_logger.level = ::Logger::WARN
      AgentDaemon::Log.instance_variable_set(:@logger, warn_logger)

      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 0.2)
      master.send(:build_factories)
      master.instance_variable_get(:@entity_factories)[:"runner:wf:a"] = ->(_bundle, _cancel_token = nil) { StuckStub.new }

      master.send(:build_supervisors)
      master.send(:start_supervisors)
      master.instance_variable_get(:@shutdown_flag).set!

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      master.send(:wait_for_threads)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - elapsed

      supervisor = master.instance_variable_get(:@supervisors).fetch(:"runner:wf:a")
      reap_after_test(supervisor.thread)
      assert supervisor.thread.alive?, "straggler thread should still be alive after its timeout"
      assert_operator elapsed, :<, 2
      assert_match(/\[wf:a gen1\] .*did not finish/, io.string)
    end
  end

  def test_no_respawn_once_shutdown_has_begun
    flag = AgentDaemon::ShutdownFlag.new
    spawned = 0
    supervisor = AgentDaemon::Supervisor::RunnerSupervisor.new(
      "runner:wf:a",
      entity_factory: ->(_bundle, _cancel_token = nil) { spawned += 1; StuckStub.new },
      shutdown_flag: flag,
      restart_delay: 0
    )

    supervisor.spawn!
    assert_equal 1, spawned
    reap_after_test(supervisor.thread)

    # Force the state machine onto the restart path with an already-expired
    # deadline, then begin shutdown: the expiry must become a no-op.
    supervisor.instance_variable_set(:@state, :restarting)
    supervisor.instance_variable_set(:@restart_at, 0)
    flag.set!

    supervisor.tick

    assert_equal 1, spawned, "a crashed entity must not respawn after shutdown begins"
    assert_equal :restarting, supervisor.state
  end

  # --- AC3: no orphaned agent; :killed semantics preserved ------------------

  def test_cooperative_kill_via_shared_flag_rolls_back_attempt
    with_config([{ name: "wf", runners: [file_runner("f")] }]) do |dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      flag = master.instance_variable_get(:@shutdown_flag)

      runner = master.instance_variable_get(:@entity_factories)
                     .fetch(:"runner:wf:f")
                     .call(AgentDaemon::Sinks::Bundle.null)

      input_dir = File.join(dir, "proj-wf", "inbox")
      path = File.join(input_dir, "TASK-1.yml")
      File.write(path, "body")

      backend = RecordingSleepBackend.new(
        30, {}, flag,
        message_dir: File.join(dir, "proj-wf", "to_message"), project_path: File.join(dir, "proj-wf")
      )
      runner.instance_variable_set(:@backend, backend)

      thread = Thread.new { runner.send(:process_item, path) }
      sleep(0.3)
      flag.set!
      thread.join(5)

      assert_equal :killed, backend.last_result.reason
      refute File.exist?(File.join(dir, "proj-wf", "inbox", "archive", "TASK-1.yml"))
      assert File.exist?(path)
      attempts = runner.instance_variable_get(:@attempts)
      # @attempts is a Hash.new(0), so the key must be present too — otherwise
      # this also passes when process_item never ran at all.
      assert attempts.key?("TASK-1.yml"), "the item should have been attempted"
      assert_equal 0, attempts["TASK-1.yml"]
    end
  end

  def test_cooperative_kill_via_generation_token_reaps_and_preserves_file
    with_config([{ name: "wf", runners: [file_runner("f")] }]) do |dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      token = AgentDaemon::Supervisor::CancelToken.new
      runner = master.instance_variable_get(:@entity_factories)
                     .fetch(:"runner:wf:f")
                     .call(AgentDaemon::Sinks::Bundle.null, token)

      input_dir = File.join(dir, "proj-wf", "inbox")
      path = File.join(input_dir, "TASK-1.yml")
      File.write(path, "body")
      backend = RecordingSleepBackend.new(
        30, {}, master.instance_variable_get(:@shutdown_flag),
        message_dir: File.join(dir, "proj-wf", "to_message"),
        project_path: File.join(dir, "proj-wf"),
        cancel_flag: token
      )
      runner.instance_variable_set(:@backend, backend)
      thread = Thread.new { runner.send(:process_item, path) }

      pid = nil
      30.times do
        pid = backend.instance_variable_get(:@current_pid)
        break if pid

        sleep(0.05)
      end
      refute_nil pid, "positive control: the subprocess must have started"

      token.set!
      assert thread.join(5), "runner did not finish its local-cancel path"

      assert_equal :killed, backend.last_result.reason
      assert_process_group_reaped(pid)
      attempts = runner.instance_variable_get(:@attempts)
      assert attempts.key?("TASK-1.yml"), "positive control: the item must have been attempted"
      assert_equal 0, attempts["TASK-1.yml"]
      assert_operator attempts["TASK-1.yml"], :>=, 0
      assert File.exist?(path)
      refute File.exist?(File.join(input_dir, "archive", "TASK-1.yml"))
      refute File.exist?(File.join(input_dir, "failed", "TASK-1.yml"))
    ensure
      backend&.kill_current_process_group
      thread&.join(1)
    end
  end

  def test_sweep_kills_wedged_backend_after_join_timeout
    with_config([{ name: "wf", runners: [tracker_runner("a")] }]) do |dir, config|
      master = AgentDaemon::Supervisor::Master.new(config, join_timeout: 0.2)
      master.send(:build_factories)
      stub = WedgedRunnerStub.new(File.join(dir, "wedged"))
      master.instance_variable_get(:@entity_factories)[:"runner:wf:a"] = ->(_bundle, _cancel_token = nil) { stub }

      master.send(:build_supervisors)
      master.send(:start_supervisors)

      pid = nil
      30.times do
        pid = stub.backend.instance_variable_get(:@current_pid)
        break if pid

        sleep(0.05)
      end
      refute_nil pid, "child pid should have been captured"

      master.instance_variable_get(:@shutdown_flag).set!
      master.send(:wait_for_threads)
      reap_after_test(master.instance_variable_get(:@supervisors).fetch(:"runner:wf:a").thread)
      master.send(:sweep_orphaned_agents)

      assert_process_group_reaped(pid)
    ensure
      stub&.backend&.kill_current_process_group
    end
  end

  def test_runner_delegates_kill_in_flight_agent_to_its_backend
    with_config([{ name: "wf", runners: [file_runner("f")] }]) do |dir, config|
      master = AgentDaemon::Supervisor::Master.new(config)
      master.send(:build_factories)
      runner = master.instance_variable_get(:@entity_factories)
                     .fetch(:"runner:wf:f")
                     .call(AgentDaemon::Sinks::Bundle.null)

      spy = KillSpyBackend.new(
        1, {}, master.instance_variable_get(:@shutdown_flag),
        message_dir: File.join(dir, "proj-wf", "to_message"), project_path: File.join(dir, "proj-wf")
      )
      spy.instance_variable_set(:@current_pid, 4242)
      runner.instance_variable_set(:@backend, spy)

      # Exercises the production Runner::Base#kill_in_flight_agent delegate,
      # not a stub's re-implementation of it.
      runner.kill_in_flight_agent

      assert_equal 1, spy.kill_calls
    end
  end

  def test_kill_current_process_group_is_noop_without_inflight_child
    Dir.mktmpdir do |dir|
      backend = KillSpyBackend.new(1, {}, NeverShutdown.new, message_dir: File.join(dir, "msg"), project_path: dir)

      backend.kill_current_process_group

      assert_equal 0, backend.kill_calls, "no in-flight child means no signal at all"
    end
  end

  # --- AC4: reactor stops EM cleanly -----------------------------------------

  def test_reactor_stops_em_when_flag_is_set
    flag = AgentDaemon::ShutdownFlag.new
    reactor = AgentDaemon::Mattermost::Reactor.new([NoopMattermostListener.new], flag)

    thread = Thread.new { reactor.run }
    sleep(0.1)
    flag.set!

    thread.join(5)
    refute thread.alive?
  end
end
