# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"

# AD-5 lazy-require isolation: required explicitly here, never from the core
# `require "agent_daemon"` graph.
require "agent_daemon/supervisor/runner_supervisor"

# Records every publish call in order, as [entity_id, record] pairs.
class RunnerSupervisorRecordingSink
  attr_reader :calls

  def initialize
    @calls = []
  end

  def publish(entity_id, record)
    @calls << [entity_id, record]
  end
end

class RunnerSupervisorCrashingFake
  def run
    raise "boom"
  end
end

class RunnerSupervisorCleanExitFake
  def run
  end
end

class RunnerSupervisorLoopingFake
  def initialize(shutdown_flag)
    @shutdown_flag = shutdown_flag
  end

  def run
    sleep(0.01) until @shutdown_flag.value
  end
end

# Holds onto its own bundle so a test can drive a publish through it after
# the supervisor has already moved on to a newer generation (AC3's
# "late-publish through the old bundle" guarantee).
class RunnerSupervisorLatePublishFake
  attr_reader :bundle

  def initialize(bundle)
    @bundle = bundle
  end

  def run
    raise "boom"
  end
end

# Publishes through whatever bundle its generation was built with, so a test
# can assert what the CURRENT (post-respawn) entity stamps.
class RunnerSupervisorPublishingFake
  def initialize(bundle)
    @bundle = bundle
  end

  def run
    @bundle.publish_state(status: :hello)
    raise "boom"
  end
end

# Loops until the flag like a real entity, then returns cleanly — the
# cooperative-stop shape Epic 4's manual restart produces.
class RunnerSupervisorStoppableFake
  def initialize(stop_flag)
    @stop_flag = stop_flag
  end

  def run
    sleep(0.01) until @stop_flag.value
  end
end

class RunnerSupervisorCancelBackend
  def initialize(cancel_token)
    @cancel_token = cancel_token
  end

  def run(_prompt)
    sleep(0.01) until @cancel_token.value
    AgentDaemon::Backend::Result.new(false, "", "", :killed)
  end
end

# Stays alive until the flag is set, then crashes — lets a test reach
# :stopping with a live thread and still exercise the crash branch.
class RunnerSupervisorDeferredCrashFake
  def initialize(crash_flag)
    @crash_flag = crash_flag
  end

  def run
    sleep(0.01) until @crash_flag.value
    raise "boom"
  end
end

# Drives the supervisor's injected `clock:` seam. Only the supervising thread
# reads it, so the plain accessor needs no synchronisation — and unlike a
# Time.now monkeypatch it leaves concurrently running entity threads alone.
class RunnerSupervisorStubClock
  attr_accessor :now

  def initialize(now)
    @now = now
  end

  def call
    @now
  end
end

class TestRunnerSupervisor < Minitest::Test
  ISO8601_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
  ISO8601_MS_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/

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

  # Swaps in a DEBUG-level StringIO-backed logger (undone by teardown's
  # restore) so a test can assert on captured tagged output.
  def capture_log
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.level = ::Logger::DEBUG
    logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
    AgentDaemon::Log.use(logger)
    io
  end

  # Builds a supervisor whose default sinks_factory is swapped for one
  # wrapping recording sinks (instead of Null) in the real GenerationStamp,
  # so generation stamping is observable without touching the class's
  # production default.
  def build_supervisor(entity_id, entity_factory, shutdown_flag: AgentDaemon::ShutdownFlag.new, restart_delay: 0.05,
                        log_level: nil, clock: -> { Time.now.utc })
    state_recorder = RunnerSupervisorRecordingSink.new
    event_recorder = RunnerSupervisorRecordingSink.new
    sinks_factory = lambda do |generation|
      AgentDaemon::Sinks::Bundle.new(
        entity_id: entity_id,
        state: AgentDaemon::Supervisor::GenerationStamp.new(generation, state_recorder),
        event: AgentDaemon::Supervisor::GenerationStamp.new(generation, event_recorder)
      )
    end
    supervisor = AgentDaemon::Supervisor::RunnerSupervisor.new(
      entity_id,
      entity_factory: entity_factory,
      shutdown_flag: shutdown_flag,
      restart_delay: restart_delay,
      sinks_factory: sinks_factory,
      log_level: log_level,
      clock: clock
    )
    [supervisor, state_recorder, event_recorder]
  end

  # --- Story 4.1 AC1/AC3: per-generation cancellation --------------------

  def test_cancel_token_is_a_monotonic_one_way_boolean
    token = AgentDaemon::Supervisor::CancelToken.new

    refute token.value

    token.set!

    assert token.value
    token.set!
    assert token.value
  end

  def test_entity_factory_receives_the_supervisors_generation_token
    captured = nil
    factory = lambda do |_bundle, cancel_token|
      captured = cancel_token
      RunnerSupervisorCleanExitFake.new
    end
    supervisor, = build_supervisor("ent-1", factory)

    assert supervisor.spawn!
    assert_same supervisor.cancel_token, captured
  ensure
    supervisor&.thread&.join(1)
  end

  def test_respawn_mints_a_fresh_unset_cancel_token
    supervisor, = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new }, restart_delay: 0
    )

    supervisor.spawn!
    first_token = supervisor.cancel_token
    first_token.set!
    supervisor.thread.join(2)
    supervisor.tick
    supervisor.tick

    # Pin that a respawn actually happened, so the token assertions below
    # cannot pass against a supervisor that never reached generation 2.
    assert_equal :running, supervisor.state
    assert_equal 2, supervisor.generation

    refute_same first_token, supervisor.cancel_token
    assert first_token.value
    refute supervisor.cancel_token.value
  ensure
    supervisor&.thread&.join(2)
  end

  # --- AC1: crash auto-restart, generation bump, non-blocking delay ------

  def test_crash_moves_to_restarting_and_publishes_crashed_status_at_gen1
    supervisor, state_recorder = build_supervisor("ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new })

    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick

    assert_equal :restarting, supervisor.state
    assert_equal [["ent-1", { status: :crashed, generation: 1 }]], state_recorder.calls
  end

  def test_deadline_respawns_with_bumped_generation_and_emits_restart_event
    supervisor, _state, event_recorder = build_supervisor("ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new })

    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick
    sleep(0.06)
    supervisor.tick

    assert_equal :running, supervisor.state
    assert_equal 2, supervisor.generation

    entity_id, event = event_recorder.calls.last
    assert_equal "ent-1", entity_id
    assert_equal :restart, event[:type]
    assert_equal [:crash_auto], event[:actor]
    assert_equal 2, event[:generation]
    assert_match ISO8601_RE, event[:at]
    # The crash path is the only restart producer reachable in production
    # today, so AC14's request timestamp has to be pinned here and not only on
    # the manual-intent tests: :crash_auto goes through the same intent queue
    # precisely so this field is populated.
    assert_match ISO8601_MS_RE, event[:requested_at]
  ensure
    supervisor&.thread&.join(1)
  end

  def test_tick_during_pending_delay_returns_immediately
    supervisor, = build_supervisor("ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new }, restart_delay: 5)
    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    supervisor.tick
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_operator elapsed, :<, 0.1
    assert_equal :restarting, supervisor.state
  end

  def test_second_supervisors_crash_is_handled_while_first_still_awaits_delay
    s1, = build_supervisor("ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new }, restart_delay: 5)
    s2, = build_supervisor("ent-2", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new }, restart_delay: 0.05)

    s1.spawn!
    s1.thread.join(1)
    s1.tick

    s2.spawn!
    s2.thread.join(1)
    s2.tick

    sleep(0.06)
    s2.tick

    assert_equal :restarting, s1.state
    assert_equal :running, s2.state
    assert_equal 2, s2.generation
  ensure
    s2&.thread&.join(1)
  end

  # --- AC2: clean exit is never auto-restarted ----------------------------

  def test_clean_exit_is_terminal_and_never_restarted
    supervisor, state_recorder = build_supervisor("ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCleanExitFake.new })
    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick

    assert_equal :exited, supervisor.state
    assert_equal [["ent-1", { status: :exited, generation: 1 }]], state_recorder.calls

    sleep(0.06)
    supervisor.tick

    assert_equal :exited, supervisor.state
    assert_equal 1, supervisor.generation
  end

  def test_manual_intent_restarts_a_terminal_exited_entity
    supervisor, state_recorder, event_recorder = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCleanExitFake.new }, restart_delay: 0
    )
    supervisor.spawn!
    supervisor.thread.join(2)
    supervisor.tick

    supervisor.request_restart(:manual)
    supervisor.tick

    assert_equal :restarting, supervisor.state
    assert_equal [
      ["ent-1", { status: :exited, generation: 1 }],
      ["ent-1", { status: :restart_requested, generation: 1 }]
    ], state_recorder.calls

    supervisor.tick

    assert_equal :running, supervisor.state
    assert_equal 2, supervisor.generation
    assert_equal [:manual], event_recorder.calls.last.last[:actor]
  ensure
    supervisor&.thread&.join(2)
  end

  def test_shutdown_rejects_an_intent_against_a_terminal_exited_entity
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    supervisor, state_recorder = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCleanExitFake.new },
      shutdown_flag: shutdown_flag,
      restart_delay: 0
    )
    supervisor.spawn!
    supervisor.thread.join(2)
    supervisor.tick

    shutdown_flag.set!
    supervisor.request_restart(:manual)
    supervisor.tick

    assert_equal :exited, supervisor.state
    assert_equal 1, supervisor.generation
    assert_equal [["ent-1", { status: :exited, generation: 1 }]], state_recorder.calls
  end

  def test_shutdown_rejects_an_intent_against_a_still_live_entity
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    supervisor, state_recorder = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorLoopingFake.new(shutdown_flag) }, shutdown_flag: shutdown_flag
    )
    supervisor.spawn!
    first_thread = supervisor.thread
    first_token = supervisor.cancel_token

    # Positive control: without the flag this very sequence is accepted (see
    # test_intent_while_thread_alive_publishes_restart_requested_once_...).
    shutdown_flag.set!
    supervisor.request_restart(:manual)
    supervisor.tick

    # Master#finalize_supervisors ticks once after the flag is set; accepting
    # here would strand the entity rendering `restarting` with no respawn ever
    # coming (AC12).
    assert_equal :running, supervisor.state
    refute first_token.value
    assert_empty state_recorder.calls
  ensure
    shutdown_flag&.set!
    first_thread&.join(1)
  end

  # --- AC3: generation stamps every publication ---------------------------

  def test_late_publish_through_old_bundle_still_carries_old_generation
    supervisor, state_recorder = build_supervisor("ent-1", ->(bundle, _cancel_token = nil) { RunnerSupervisorLatePublishFake.new(bundle) })

    supervisor.spawn!
    old_entity = supervisor.entity
    supervisor.thread.join(1)
    supervisor.tick
    sleep(0.06)
    supervisor.tick

    assert_equal 2, supervisor.generation

    old_entity.bundle.publish_state(status: :late)

    assert_equal ["ent-1", { status: :late, generation: 1 }], state_recorder.calls.last
  ensure
    supervisor&.thread&.join(1)
  end

  def test_entity_publishes_carry_gen1_before_and_gen2_after_respawn
    supervisor, state_recorder = build_supervisor("ent-1", ->(bundle, _cancel_token = nil) { RunnerSupervisorPublishingFake.new(bundle) })

    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick
    sleep(0.06)
    supervisor.tick
    supervisor.thread.join(1)

    entity_publishes = state_recorder.calls.select { |_id, record| record[:status] == :hello }

    assert_equal [["ent-1", { status: :hello, generation: 1 }], ["ent-1", { status: :hello, generation: 2 }]],
                 entity_publishes
  ensure
    supervisor&.thread&.join(1)
  end

  # --- AC4: single restart-intent queue, at-most-one live instance -------

  def test_coalesced_restart_intents_produce_one_respawn_with_merged_actors
    supervisor, _state, event_recorder = build_supervisor("ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new })

    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.request_restart(:manual_a)
    supervisor.tick # crash observed -> :restarting; drains [:manual_a, :crash_auto]

    supervisor.request_restart(:manual_b) # arrives during the delay window

    sleep(0.06)
    supervisor.tick

    assert_equal :running, supervisor.state
    assert_equal 2, supervisor.generation

    _entity_id, event = event_recorder.calls.last
    assert_equal %i[crash_auto manual_a manual_b], event[:actor].sort
  ensure
    supervisor&.thread&.join(1)
  end

  def test_intent_while_thread_alive_publishes_restart_requested_once_and_activates_its_token
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    supervisor, state_recorder = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorLoopingFake.new(shutdown_flag) }, shutdown_flag: shutdown_flag
    )
    supervisor.spawn!
    first_thread = supervisor.thread
    first_token = supervisor.cancel_token

    supervisor.request_restart(:manual)
    supervisor.tick

    assert_equal :stopping, supervisor.state
    assert_same first_thread, supervisor.thread
    assert first_thread.alive?
    assert first_token.value
    assert_equal [["ent-1", { status: :restart_requested, generation: 1 }]], state_recorder.calls

    supervisor.tick

    assert_equal 1, state_recorder.calls.length, "restart_requested must publish only on acceptance"
  ensure
    shutdown_flag&.set!
    first_thread&.join(1)
  end

  def test_clean_death_in_stopping_honours_the_queued_intent_and_respawns
    stop_flag = AgentDaemon::ShutdownFlag.new
    supervisor, state_recorder, event_recorder = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorStoppableFake.new(stop_flag) }
    )
    supervisor.spawn!
    first_thread = supervisor.thread

    supervisor.request_restart(:manual)
    supervisor.tick

    assert_equal :stopping, supervisor.state

    stop_flag.set!
    first_thread.join(1)
    supervisor.tick

    assert_equal :restarting, supervisor.state
    # Twice, and only twice: once on acceptance, once on the confirmed
    # turnover. The second one is what keeps the entity off `dead` while the
    # restart delay runs — the entity's own last publish on this generation is
    # terminal and would otherwise win the equal-generation CAS.
    assert_equal [
      ["ent-1", { status: :restart_requested, generation: 1 }],
      ["ent-1", { status: :restart_requested, generation: 1 }]
    ], state_recorder.calls

    sleep(0.06)
    supervisor.tick

    assert_equal :running, supervisor.state
    assert_equal 2, supervisor.generation
    assert_equal 2, state_recorder.calls.length, "the respawn itself must not publish a third status"
    refute_same first_thread, supervisor.thread

    _entity_id, event = event_recorder.calls.last

    assert_equal :restart, event[:type]
    assert_equal [:manual], event[:actor]
  ensure
    stop_flag&.set!
    supervisor&.thread&.join(1)
  end

  def test_live_runner_cancel_finishes_before_delayed_respawn_with_fresh_token
    Dir.mktmpdir do |dir|
      message_dir = File.join(dir, "messages")
      input_dir = File.join(dir, "inbox")
      template_path = File.join(dir, "prompt.txt")
      FileUtils.mkdir_p(message_dir)
      FileUtils.mkdir_p(input_dir)
      File.write(template_path, "review {{input_file}}")
      config = {
        "name" => "reviewer",
        "backend" => "claude",
        "extra_flags" => "",
        "timeout" => 30,
        "max_attempts" => 2,
        "prompt_template" => "prompt.txt",
        "prompt_template_path" => template_path,
        "trigger" => {
          "type" => "file",
          "input_dir" => input_dir,
          "archive_dir" => File.join(input_dir, "archive"),
          "failed_dir" => File.join(input_dir, "failed"),
          "interval" => 60
        }
      }
      shutdown_flag = AgentDaemon::ShutdownFlag.new
      recorder = RunnerSupervisorRecordingSink.new
      sinks_factory = lambda do |generation|
        stamped = AgentDaemon::Supervisor::GenerationStamp.new(generation, recorder)
        AgentDaemon::Sinks::Bundle.new(entity_id: "ent-1", state: stamped, event: stamped)
      end
      tokens = []
      factory = lambda do |bundle, cancel_token|
        tokens << cancel_token
        runner = AgentDaemon::Runner::File.new(
          config, message_dir, dir, shutdown_flag,
          sinks: bundle, cancel_flag: cancel_token
        )
        runner.instance_variable_set(:@backend, RunnerSupervisorCancelBackend.new(cancel_token))
        runner
      end
      supervisor = AgentDaemon::Supervisor::RunnerSupervisor.new(
        "ent-1", entity_factory: factory, shutdown_flag: shutdown_flag,
        restart_delay: 0.05, sinks_factory: sinks_factory
      )
      File.write(File.join(input_dir, "TASK-1.yml"), "body")

      assert supervisor.spawn!
      100.times do
        break if recorder.calls.any? { |_id, record| record[:type] == :started }

        sleep(0.01)
      end
      assert recorder.calls.any? { |_id, record| record[:type] == :started },
             "positive control: the live runner must start the work item"

      first_token = supervisor.cancel_token
      supervisor.request_restart(:console)
      supervisor.tick
      assert_equal :stopping, supervisor.state
      assert first_token.value
      assert supervisor.thread.join(2), "cancelled runner did not return cooperatively"

      supervisor.tick
      assert_equal :restarting, supervisor.state
      refute supervisor.thread.alive?
      supervisor.tick
      assert_equal 1, supervisor.generation, "replacement spawned before the restart delay"

      sleep(0.06)
      supervisor.tick

      assert_equal 2, supervisor.generation
      assert_equal 2, tokens.length
      assert_same first_token, tokens.first
      refute_same tokens.first, tokens.last
      refute tokens.last.value

      records = recorder.calls.map(&:last)
      finished_index = records.index do |record|
        record[:type] == :finished && record[:reason] == :killed && record[:generation] == 1
      end
      restart_index = records.index { |record| record[:type] == :restart && record[:generation] == 2 }
      refute_nil finished_index
      refute_nil restart_index
      assert_operator finished_index, :<, restart_index
      finished = records.fetch(finished_index)
      assert_equal "TASK-1.yml", finished[:work_item]
      assert_equal 1, finished[:attempt]

      old_states = records.select { |record| record[:status] && record[:generation] == 1 }
      assert_equal :restart_requested, old_states.last[:status]
      restart_requested_index = old_states.index { |record| record[:status] == :restart_requested }
      refute old_states.drop(restart_requested_index + 1).any? { |record| %i[waiting stopped].include?(record[:status]) }
    ensure
      shutdown_flag&.set!
      supervisor&.cancel_token&.set!
      supervisor&.thread&.join(2)
    end
  end

  def test_crash_in_stopping_still_takes_the_crash_path
    crash_flag = AgentDaemon::ShutdownFlag.new
    supervisor, state_recorder = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorDeferredCrashFake.new(crash_flag) }
    )
    supervisor.spawn!
    first_thread = supervisor.thread

    # Enter :stopping while the thread is still alive, then let it die by
    # crashing rather than by returning cleanly.
    supervisor.request_restart(:manual)
    supervisor.tick

    assert_equal :stopping, supervisor.state

    crash_flag.set!
    first_thread.join(1)
    supervisor.tick

    assert_equal :restarting, supervisor.state
    assert_equal [
      ["ent-1", { status: :restart_requested, generation: 1 }],
      ["ent-1", { status: :crashed, generation: 1 }]
    ], state_recorder.calls
  ensure
    crash_flag&.set!
    supervisor&.thread&.join(1)
  end

  def test_manual_and_crash_intents_coalesce_with_the_earliest_request_time
    crash_flag = AgentDaemon::ShutdownFlag.new
    requested_at = Time.utc(2026, 8, 15, 12, 0, 0)
    stopping_at = Time.utc(2026, 8, 15, 12, 0, 0, 500_000)
    crash_at = Time.utc(2026, 8, 15, 12, 0, 1)
    delayed_at = Time.utc(2026, 8, 15, 12, 0, 1, 500_000)
    completed_at = Time.utc(2026, 8, 15, 12, 0, 2)
    clock = RunnerSupervisorStubClock.new(requested_at)
    supervisor, _state, event_recorder = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorDeferredCrashFake.new(crash_flag) }, restart_delay: 0, clock: clock
    )
    supervisor.spawn!

    supervisor.request_restart(:manual)
    supervisor.tick
    clock.now = stopping_at
    supervisor.request_restart(:manual)
    crash_flag.set!
    supervisor.thread.join(2)
    clock.now = crash_at
    supervisor.tick
    clock.now = delayed_at
    supervisor.request_restart(:operator_b)
    clock.now = completed_at
    supervisor.tick

    assert_equal 2, supervisor.generation
    restart_calls = event_recorder.calls.select { |_entity_id, event| event[:type] == :restart }
    assert_equal 1, restart_calls.length
    entity_id, event = restart_calls.first
    assert_equal "ent-1", entity_id
    assert_equal 2, event[:generation]
    assert_equal %i[crash_auto manual operator_b], event[:actor].sort
    # Millisecond precision is what makes this assertion discriminating: at
    # whole-second granularity requested_at and stopping_at serialise
    # identically and the test would pass even if the code took the latest.
    assert_equal requested_at.iso8601(3), event[:requested_at]
    refute_equal stopping_at.iso8601(3), event[:requested_at]
    assert_equal completed_at.iso8601, event[:at]
  ensure
    crash_flag&.set!
    supervisor&.thread&.join(2)
  end

  def test_failed_replacement_retains_actor_and_request_time_without_consuming_generation
    calls = 0
    factory = lambda do |_bundle, _cancel_token = nil|
      calls += 1
      raise "cannot construct replacement" if calls == 2

      RunnerSupervisorCleanExitFake.new
    end
    requested_at = Time.utc(2026, 8, 15, 13, 0, 0)
    supervisor, _state, event_recorder = build_supervisor(
      "ent-1", factory, restart_delay: 0, clock: RunnerSupervisorStubClock.new(requested_at)
    )
    supervisor.spawn!
    supervisor.thread.join(2)
    supervisor.tick
    supervisor.request_restart(:manual)
    supervisor.tick

    supervisor.tick

    assert_equal :restarting, supervisor.state
    assert_equal 1, supervisor.generation
    assert_empty event_recorder.calls
    assert_nil supervisor.cancel_token, "a failed replacement must not retain the dead generation's token"

    supervisor.tick

    assert_equal 2, supervisor.generation
    refute_nil supervisor.cancel_token
    refute supervisor.cancel_token.value
    event = event_recorder.calls.fetch(0).last
    assert_equal [:manual], event[:actor]
    assert_equal requested_at.iso8601(3), event[:requested_at]
  ensure
    supervisor&.thread&.join(2)
  end

  def test_spawn_is_refused_while_the_current_thread_is_still_alive
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    supervisor, = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorLoopingFake.new(shutdown_flag) }, shutdown_flag: shutdown_flag
    )
    supervisor.spawn!
    first_thread = supervisor.thread

    refute supervisor.spawn!
    assert_same first_thread, supervisor.thread
    assert_equal 1, supervisor.generation
  ensure
    shutdown_flag&.set!
    first_thread&.join(1)
  end

  def test_raising_factory_is_contained_and_retried_without_burning_a_generation
    attempts = 0
    factory = lambda do |_bundle, _cancel_token = nil|
      attempts += 1
      raise "cannot construct" if attempts == 1

      RunnerSupervisorLoopingFake.new(AgentDaemon::ShutdownFlag.new)
    end
    supervisor, = build_supervisor("ent-1", factory)

    refute supervisor.spawn!
    assert_equal :restarting, supervisor.state
    assert_equal 0, supervisor.generation
    assert_nil supervisor.thread

    sleep(0.06)
    supervisor.tick

    assert_equal :running, supervisor.state
    assert_equal 1, supervisor.generation
  ensure
    supervisor&.thread&.kill
  end

  def test_request_restart_rejects_nil_actor
    supervisor, = build_supervisor("ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCleanExitFake.new })

    assert_raises(ArgumentError) { supervisor.request_restart(nil) }
  end

  # --- AC5: one state machine for all three entity kinds ------------------

  def test_state_machine_is_kind_agnostic_for_messenger_and_reactor_ids
    ["messenger:wf", "mattermost_reactor"].each do |entity_id|
      supervisor, state_recorder = build_supervisor(entity_id, ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new })

      supervisor.spawn!
      supervisor.thread.join(1)
      supervisor.tick

      assert_equal :restarting, supervisor.state
      assert_equal [[entity_id, { status: :crashed, generation: 1 }]], state_recorder.calls

      sleep(0.06)
      supervisor.tick

      assert_equal :running, supervisor.state
      assert_equal 2, supervisor.generation
      supervisor.thread.join(1)
    end
  end

  # --- Shutdown boundary (consumed by Story 1.6) ---------------------------

  def test_shutdown_flag_prevents_respawn_after_delay_expires
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    supervisor, = build_supervisor(
      "ent-1", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new }, shutdown_flag: shutdown_flag
    )
    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick

    shutdown_flag.set!
    supervisor.request_restart(:manual_after_shutdown)
    sleep(0.06)
    supervisor.tick

    assert_equal :restarting, supervisor.state
    assert_equal 1, supervisor.generation
  end

  # --- Constructor guards ---------------------------------------------------

  def test_constructor_rejects_entity_factory_without_call
    assert_raises(ArgumentError) do
      AgentDaemon::Supervisor::RunnerSupervisor.new("ent", entity_factory: nil, shutdown_flag: AgentDaemon::ShutdownFlag.new)
    end
  end

  def test_constructor_rejects_nil_entity_id
    assert_raises(ArgumentError) do
      AgentDaemon::Supervisor::RunnerSupervisor.new(
        nil, entity_factory: ->(_bundle, _cancel_token = nil) {}, shutdown_flag: AgentDaemon::ShutdownFlag.new
      )
    end
  end

  # --- Story 1.7: centralized logging tagged per entity and generation ---

  # Logs a fixed line on every #run, then crashes — lets a test observe the
  # ambient tag+generation on the entity's OWN thread across a respawn.
  class RunnerSupervisorLoggingCrashFake
    def run
      AgentDaemon::Log.info("hello from run")
      raise "boom"
    end
  end

  def test_ambient_tag_and_generation_bump_across_respawn
    io = capture_log
    supervisor, = build_supervisor("wf:r", ->(_bundle, _cancel_token = nil) { RunnerSupervisorLoggingCrashFake.new })

    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick
    sleep(0.06)
    supervisor.tick
    supervisor.thread.join(1)

    lines = io.string.lines.select { |line| line.include?("hello from run") }
    assert_equal ["[wf:r gen1] hello from run\n", "[wf:r gen2] hello from run\n"], lines
  end

  def test_ambient_level_gates_the_entitys_own_lines_but_not_the_crash_log
    io = capture_log
    supervisor, = build_supervisor(
      "wf:r", ->(_bundle, _cancel_token = nil) { RunnerSupervisorLoggingCrashFake.new }, log_level: ::Logger::WARN
    )

    supervisor.spawn!
    supervisor.thread.join(1)

    refute_includes io.string, "hello from run"
    assert_match(/\[wf:r gen1\] Thread crashed: boom/, io.string)
  end

  def test_crash_log_carries_a_single_tag_not_a_double_prefix
    io = capture_log
    supervisor, = build_supervisor("wf:r", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new })

    supervisor.spawn!
    supervisor.thread.join(1)

    assert_match(/\A\[wf:r gen1\] Thread crashed: boom/, io.string)
  end

  def test_crash_path_logs_entering_restarting_and_successful_respawn_generation
    io = capture_log
    supervisor, = build_supervisor("wf:r", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCrashingFake.new })

    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick
    sleep(0.06)
    supervisor.tick

    assert_match(/\[wf:r gen1\] entering :restarting \(restart deadline in 0\.05s\)/, io.string)
    assert_match(/\[wf:r gen2\] respawned as generation 2/, io.string)
  ensure
    supervisor&.thread&.join(1)
  end

  def test_clean_exit_logs_terminal_line
    io = capture_log
    supervisor, = build_supervisor("wf:r", ->(_bundle, _cancel_token = nil) { RunnerSupervisorCleanExitFake.new })

    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick

    assert_match(/\[wf:r gen1\] exited cleanly, terminal/, io.string)
  end

  def test_stopping_clean_death_logs_exit_and_entering_restarting
    io = capture_log
    stop_flag = AgentDaemon::ShutdownFlag.new
    supervisor, = build_supervisor("wf:r", ->(_bundle, _cancel_token = nil) { RunnerSupervisorStoppableFake.new(stop_flag) })
    supervisor.spawn!
    first_thread = supervisor.thread

    supervisor.request_restart(:manual)
    supervisor.tick

    stop_flag.set!
    first_thread.join(1)
    supervisor.tick

    assert_match(/\[wf:r gen1\] exited cleanly\n/, io.string)
    assert_match(/\[wf:r gen1\] entering :restarting \(restart deadline in 0\.05s\)/, io.string)
  ensure
    stop_flag&.set!
    supervisor&.thread&.join(1)
  end

  def test_failed_spawn_logs_spawn_failed_and_entering_restarting
    io = capture_log
    attempts = 0
    factory = lambda do |_bundle, _cancel_token = nil|
      attempts += 1
      raise "cannot construct" if attempts == 1

      RunnerSupervisorLoopingFake.new(AgentDaemon::ShutdownFlag.new)
    end
    supervisor, = build_supervisor("wf:r", factory)

    refute supervisor.spawn!

    assert_match(/\[wf:r\] Spawn failed: cannot construct/, io.string)
    assert_match(/\[wf:r gen0\] entering :restarting \(restart deadline in 0\.05s\)/, io.string)
  ensure
    supervisor&.thread&.kill
  end
end
