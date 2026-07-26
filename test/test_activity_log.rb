# frozen_string_literal: true

require "test_helper"

# AD-5 lazy-require isolation: required explicitly here, never from the core
# `require "agent_daemon"` graph.
require "agent_daemon/supervisor/activity_log"
require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/runner_identity"
require "agent_daemon/supervisor/runner_supervisor"

class TestActivityLog < Minitest::Test
  ActivityLog = AgentDaemon::Supervisor::ActivityLog
  EventBus = AgentDaemon::Supervisor::EventBus
  RunnerIdentity = AgentDaemon::Supervisor::RunnerIdentity
  GenerationStamp = AgentDaemon::Supervisor::GenerationStamp

  # No LogStubbing here on purpose: activity_log.rb makes no Log.* call.

  def setup
    @bus = EventBus.new
  end

  def runner_identity(workflow, runner)
    RunnerIdentity.new(workflow: workflow, runner: runner)
  end

  # --- AC6: String-comparable id, across all three entity-id shapes --------

  def test_recent_is_looked_up_by_the_consoles_string_id_for_all_three_entity_kinds
    runner_id = runner_identity("wf", "alpha")
    @bus.publish(runner_id, { type: :picked_up, work_item: "T-1" })
    @bus.publish("messenger:wf", { type: :restart, actor: [:crash_auto] })
    @bus.publish("mattermost_reactor", { type: :restart, actor: [:crash_auto] })

    log = ActivityLog.new(event_bus: @bus)

    assert_equal 1, log.recent("runner:wf:alpha").size
    assert_equal 1, log.recent("messenger:wf").size
    assert_equal 1, log.recent("mattermost_reactor").size
  end

  def test_recent_returns_empty_array_for_an_unknown_id_never_nil
    @bus.publish(runner_identity("wf", "alpha"), { type: :picked_up })

    log = ActivityLog.new(event_bus: @bus)

    assert_equal [], log.recent("no-such-entity")
  end

  # --- Events for other entities are excluded -------------------------------

  def test_events_for_other_entities_are_excluded
    id_a = runner_identity("wf", "a")
    id_b = runner_identity("wf", "b")
    @bus.publish(id_a, { type: :picked_up, work_item: "T-A" })
    @bus.publish(id_b, { type: :picked_up, work_item: "T-B" })
    @bus.publish(id_a, { type: :started, work_item: "T-A", attempt: 1 })

    log = ActivityLog.new(event_bus: @bus)
    entries = log.recent("runner:wf:a")

    assert_equal 2, entries.size
    assert entries.all? { |entry| entry.work_item == "T-A" }
  end

  # --- Newest-first ordering is by seq, never by :at ------------------------

  def test_ordering_is_by_seq_even_when_at_is_deliberately_out_of_order
    id = runner_identity("wf", "alpha")
    @bus.publish(id, { type: :picked_up, work_item: "first", at: "2020-01-01T00:00:00Z" })
    @bus.publish(id, { type: :started, work_item: "second", attempt: 1, at: "1999-01-01T00:00:00Z" })

    log = ActivityLog.new(event_bus: @bus)
    entries = log.recent("runner:wf:alpha")

    assert_equal %i[started picked_up], entries.map(&:type), "seq order, not at order, must win"
  end

  # --- The limit returns the newest N, not the oldest N ---------------------

  def test_limit_returns_the_newest_n_not_the_oldest_n
    id = runner_identity("wf", "alpha")
    5.times { |i| @bus.publish(id, { type: :picked_up, work_item: "item-#{i}" }) }

    log = ActivityLog.new(event_bus: @bus, limit: 2)
    entries = log.recent("runner:wf:alpha")

    assert_equal %w[item-4 item-3], entries.map(&:work_item)
  end

  # --- AC4: two generations of the same entity stay distinguishable --------

  def test_two_generations_of_the_same_entity_survive_on_their_own_records_in_seq_order
    id = runner_identity("wf", "alpha")
    gen1 = GenerationStamp.new(1, @bus)
    gen2 = GenerationStamp.new(2, @bus)
    gen1.publish(id, { type: :picked_up, work_item: "T-1" })
    gen1.publish(id, { type: :finished, work_item: "T-1", attempt: 1, reason: :ok })
    gen2.publish(id, { type: :picked_up, work_item: "T-2" })

    log = ActivityLog.new(event_bus: @bus)
    entries = log.recent("runner:wf:alpha")

    assert_equal [2, 1, 1], entries.map(&:generation)
    assert_equal [3, 2, 1], entries.map(&:seq)
  end
end
