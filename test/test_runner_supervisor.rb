# frozen_string_literal: true

require "test_helper"

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

class TestRunnerSupervisor < Minitest::Test
  ISO8601_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  def setup
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, nil)
  end

  # Builds a supervisor whose default sinks_factory is swapped for one
  # wrapping recording sinks (instead of Null) in the real GenerationStamp,
  # so generation stamping is observable without touching the class's
  # production default.
  def build_supervisor(entity_id, entity_factory, shutdown_flag: AgentDaemon::ShutdownFlag.new, restart_delay: 0.05)
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
      sinks_factory: sinks_factory
    )
    [supervisor, state_recorder, event_recorder]
  end

  # --- AC1: crash auto-restart, generation bump, non-blocking delay ------

  def test_crash_moves_to_restarting_and_publishes_crashed_status_at_gen1
    supervisor, state_recorder = build_supervisor("ent-1", ->(_bundle) { RunnerSupervisorCrashingFake.new })

    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick

    assert_equal :restarting, supervisor.state
    assert_equal [["ent-1", { status: :crashed, generation: 1 }]], state_recorder.calls
  end

  def test_deadline_respawns_with_bumped_generation_and_emits_restart_event
    supervisor, _state, event_recorder = build_supervisor("ent-1", ->(_bundle) { RunnerSupervisorCrashingFake.new })

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
  ensure
    supervisor&.thread&.join(1)
  end

  def test_tick_during_pending_delay_returns_immediately
    supervisor, = build_supervisor("ent-1", ->(_bundle) { RunnerSupervisorCrashingFake.new }, restart_delay: 5)
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
    s1, = build_supervisor("ent-1", ->(_bundle) { RunnerSupervisorCrashingFake.new }, restart_delay: 5)
    s2, = build_supervisor("ent-2", ->(_bundle) { RunnerSupervisorCrashingFake.new }, restart_delay: 0.05)

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
    supervisor, state_recorder = build_supervisor("ent-1", ->(_bundle) { RunnerSupervisorCleanExitFake.new })
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

  # --- AC3: generation stamps every publication ---------------------------

  def test_late_publish_through_old_bundle_still_carries_old_generation
    supervisor, state_recorder = build_supervisor("ent-1", ->(bundle) { RunnerSupervisorLatePublishFake.new(bundle) })

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
    supervisor, state_recorder = build_supervisor("ent-1", ->(bundle) { RunnerSupervisorPublishingFake.new(bundle) })

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
    supervisor, _state, event_recorder = build_supervisor("ent-1", ->(_bundle) { RunnerSupervisorCrashingFake.new })

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

  def test_intent_while_thread_alive_moves_to_stopping_without_a_second_thread
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    supervisor, = build_supervisor(
      "ent-1", ->(_bundle) { RunnerSupervisorLoopingFake.new(shutdown_flag) }, shutdown_flag: shutdown_flag
    )
    supervisor.spawn!
    first_thread = supervisor.thread

    supervisor.request_restart(:manual)
    supervisor.tick

    assert_equal :stopping, supervisor.state
    assert_same first_thread, supervisor.thread
    assert first_thread.alive?
  ensure
    shutdown_flag&.set!
    first_thread&.join(1)
  end

  def test_clean_death_in_stopping_honours_the_queued_intent_and_respawns
    stop_flag = AgentDaemon::ShutdownFlag.new
    supervisor, state_recorder, event_recorder = build_supervisor(
      "ent-1", ->(_bundle) { RunnerSupervisorStoppableFake.new(stop_flag) }
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
    assert_equal [["ent-1", { status: :exited, generation: 1 }]], state_recorder.calls

    sleep(0.06)
    supervisor.tick

    assert_equal :running, supervisor.state
    assert_equal 2, supervisor.generation
    refute_same first_thread, supervisor.thread

    _entity_id, event = event_recorder.calls.last

    assert_equal :restart, event[:type]
    assert_equal [:manual], event[:actor]
  ensure
    stop_flag&.set!
    supervisor&.thread&.join(1)
  end

  def test_crash_in_stopping_still_takes_the_crash_path
    crash_flag = AgentDaemon::ShutdownFlag.new
    supervisor, state_recorder = build_supervisor(
      "ent-1", ->(_bundle) { RunnerSupervisorDeferredCrashFake.new(crash_flag) }
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
    assert_equal [["ent-1", { status: :crashed, generation: 1 }]], state_recorder.calls
  ensure
    crash_flag&.set!
    supervisor&.thread&.join(1)
  end

  def test_spawn_is_refused_while_the_current_thread_is_still_alive
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    supervisor, = build_supervisor(
      "ent-1", ->(_bundle) { RunnerSupervisorLoopingFake.new(shutdown_flag) }, shutdown_flag: shutdown_flag
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
    factory = lambda do |_bundle|
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
    supervisor, = build_supervisor("ent-1", ->(_bundle) { RunnerSupervisorCleanExitFake.new })

    assert_raises(ArgumentError) { supervisor.request_restart(nil) }
  end

  # --- AC5: one state machine for all three entity kinds ------------------

  def test_state_machine_is_kind_agnostic_for_messenger_and_reactor_ids
    ["messenger:wf", "mattermost_reactor"].each do |entity_id|
      supervisor, state_recorder = build_supervisor(entity_id, ->(_bundle) { RunnerSupervisorCrashingFake.new })

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
      "ent-1", ->(_bundle) { RunnerSupervisorCrashingFake.new }, shutdown_flag: shutdown_flag
    )
    supervisor.spawn!
    supervisor.thread.join(1)
    supervisor.tick

    shutdown_flag.set!
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
        nil, entity_factory: ->(_bundle) {}, shutdown_flag: AgentDaemon::ShutdownFlag.new
      )
    end
  end
end
