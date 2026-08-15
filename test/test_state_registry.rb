# frozen_string_literal: true

require "test_helper"

# AD-5 lazy-require isolation: required explicitly here, never from the core
# `require "agent_daemon"` graph.
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/runner_identity"

class TestStateRegistry < Minitest::Test
  include LogStubbing

  ISO8601_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  def setup
    stub_null_logger!
    @registry = AgentDaemon::Supervisor::StateRegistry.new
  end

  def teardown
    restore_logger!
  end

  # --- AC1/AC2: generation compare-and-set --------------------------------

  def test_revision_advances_only_for_accepted_publications
    assert_equal 0, @registry.revision

    @registry.publish("ent-1", { status: :waiting, generation: 2 })
    assert_equal 1, @registry.revision

    @registry.publish("ent-1", { status: :running, generation: 1 })
    assert_equal 1, @registry.revision, "a stale generation must not announce a state change"

    @registry.publish("ent-1", { status: :in_progress, generation: 2 })
    assert_equal 2, @registry.revision, "an equal-generation overwrite is accepted"
  end

  # The retro's stale-state defect: a dying instance's :in_progress and the
  # master thread's :crashed publish arrive on the SAME generation. Equal
  # generation must be accepted (last write wins), or the console shows a
  # dead runner as still "working" the stale item.
  def test_equal_generation_overwrites_and_older_generation_is_dropped
    @registry.publish("ent-1", { status: :in_progress, work_item: "TASK-1.yml", attempt: 1, generation: 3 })
    @registry.publish("ent-1", { status: :crashed, generation: 3 })

    entry = @registry.snapshot("ent-1")
    assert_equal :crashed, entry[:status]
    refute entry.key?(:work_item), "crashed overwrite must not carry the old in_progress work_item"

    # A late, older-generation write (e.g. a superseded instance's straggler
    # publish) must be dropped and must not resurrect the stale state.
    @registry.publish("ent-1", { status: :in_progress, work_item: "TASK-1.yml", generation: 2 })

    entry_after_stale_write = @registry.snapshot("ent-1")
    assert_equal :crashed, entry_after_stale_write[:status]
    assert_equal 3, entry_after_stale_write[:generation]
  end

  # The other half of AC1 ("newer wins"), and AC2's actual risk direction: the
  # registry holds a LIVE, already-respawned entity when a straggler from the
  # dead generation arrives. AC2's clause is "the live entity is NOT shown as
  # dead" — the inverse of the sequence above, and the one an operator
  # actually sees on a crash-restart.
  def test_newer_generation_wins_and_a_dead_generations_straggler_cannot_show_a_live_entity_as_dead
    @registry.publish("ent-1", { status: :in_progress, work_item: "TASK-1.yml", attempt: 1, generation: 1 })
    @registry.publish("ent-1", { status: :waiting, generation: 2 })

    respawned = @registry.snapshot("ent-1")
    assert_equal :waiting, respawned[:status], "a newer generation must overwrite the older entry"
    assert_equal 2, respawned[:generation]

    # RunnerSupervisor#handle_thread_death publishes :crashed on the DYING
    # generation's bundle; on a slow master tick that can land after the
    # respawned instance has already reported :waiting.
    @registry.publish("ent-1", { status: :crashed, generation: 1 })

    entry = @registry.snapshot("ent-1")
    assert_equal :waiting, entry[:status], "a dead generation's straggler must not show the live entity as dead"
    assert_equal 2, entry[:generation]
  end

  def test_nil_or_absent_generation_is_treated_as_zero_and_never_raises
    @registry.publish("ent-1", { status: :waiting })
    assert_equal :waiting, @registry.snapshot("ent-1")[:status]

    @registry.publish("ent-1", { status: :running, generation: nil })
    assert_equal :running, @registry.snapshot("ent-1")[:status]

    @registry.publish("ent-1", { status: :stopped, generation: 0 })
    assert_equal :stopped, @registry.snapshot("ent-1")[:status], "generation 0 ties with absent/nil and wins"
  end

  # --- AC3: complete status vocabulary, none silently dropped -------------

  def test_all_statuses_round_trip_across_entity_id_shapes
    identity = AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "r")
    statuses = %i[waiting in_progress stopped running crashed restart_requested exited]

    [identity, "messenger:wf", "mattermost_reactor"].each do |entity_id|
      statuses.each do |status|
        registry = AgentDaemon::Supervisor::StateRegistry.new
        registry.publish(entity_id, { status: status, generation: 1 })

        assert_equal status, registry.snapshot(entity_id)[:status]
      end
    end
  end

  # --- AC7: receipt timestamps ---------------------------------------------

  def test_observed_at_and_observed_monotonic_are_stamped_on_accept
    @registry.publish("ent-1", { status: :waiting, generation: 1 })
    first = @registry.snapshot("ent-1")
    assert_match ISO8601_RE, first[:observed_at]

    @registry.publish("ent-1", { status: :in_progress, generation: 1 })
    second = @registry.snapshot("ent-1")

    assert_operator second[:observed_monotonic], :>=, first[:observed_monotonic]
  end

  def test_publish_does_not_mutate_the_callers_snapshot_hash
    snapshot = { status: :waiting, generation: 1 }
    @registry.publish("ent-1", snapshot)

    assert_equal({ status: :waiting, generation: 1 }, snapshot)
  end

  # --- Copy-on-read ---------------------------------------------------------

  def test_all_returns_a_copy_that_does_not_mutate_the_registry
    @registry.publish("ent-1", { status: :waiting, generation: 1 })

    copy = @registry.all
    copy["ent-1"][:status] = :tampered
    copy["ent-2"] = { status: :ghost }

    assert_equal :waiting, @registry.snapshot("ent-1")[:status]
    assert_nil @registry.snapshot("ent-2")
  end

  def test_snapshot_returns_nil_for_unknown_entity
    assert_nil @registry.snapshot("never-published")
  end

  def test_concurrent_publishes_and_reads_return_complete_mutex_protected_snapshots
    @registry.publish("ent-1", { status: :waiting, generation: 1 })
    errors = Queue.new
    publisher = Thread.new do
      500.times do |index|
        @registry.publish("ent-1", { status: index.even? ? :waiting : :running, generation: 1 })
      end
    end
    readers = Array.new(4) do
      Thread.new do
        500.times do
          snapshot = @registry.snapshot("ent-1")
          errors << snapshot unless %i[waiting running].include?(snapshot[:status]) &&
                                    snapshot[:observed_at] && snapshot[:observed_monotonic]
        end
      end
    end

    ([publisher] + readers).each(&:join)

    assert errors.empty?, "observed an incomplete concurrent snapshot: #{errors.pop.inspect unless errors.empty?}"
    assert_equal 501, @registry.revision
  end
end
