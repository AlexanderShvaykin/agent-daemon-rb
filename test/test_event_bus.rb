# frozen_string_literal: true

require "test_helper"

# AD-5 lazy-require isolation: required explicitly here, never from the core
# `require "agent_daemon"` graph.
require "agent_daemon/supervisor/event_bus"

class TestEventBus < Minitest::Test
  include LogStubbing

  ISO8601_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  def setup
    stub_null_logger!
    @bus = AgentDaemon::Supervisor::EventBus.new
  end

  def teardown
    restore_logger!
  end

  # --- AC4: record contract ------------------------------------------------

  def test_at_is_preserved_when_present_and_filled_when_absent_generation_and_entity_id_survive
    @bus.publish("ent-1", { type: :picked_up, work_item: "TASK-1.yml", at: "2020-01-01T00:00:00Z", generation: 1 })
    @bus.publish("ent-1", { type: :started, work_item: "TASK-1.yml", attempt: 1, generation: 1 })

    cursor = @bus.subscribe
    records = @bus.read(cursor)

    assert_equal "2020-01-01T00:00:00Z", records[0][:at], "a producer-supplied :at must never be overwritten"
    assert_match ISO8601_RE, records[1][:at], "a missing :at must be filled at ingress"
    assert_equal "ent-1", records[0][:entity_id]
    assert_equal 1, records[0][:generation]
    assert_equal :picked_up, records[0][:type]
  end

  def test_cursor_read_delegates_to_bus_read
    cursor = @bus.subscribe
    @bus.publish("ent-1", { type: :picked_up, generation: 1 })

    records = cursor.read

    assert_equal 1, records.size
    assert_equal :picked_up, records.first[:type]
  end

  # Copy-on-read: the ring retains its records for every other subscriber and
  # for every future subscriber replaying the backlog, so a consumer that
  # transforms what it drains must not be handed the retained hash itself.
  def test_read_returns_copies_so_one_subscriber_cannot_rewrite_anothers_records
    first = @bus.subscribe
    second = @bus.subscribe
    @bus.publish("ent-1", { type: :started, work_item: "TASK-1.yml", generation: 1 })

    drained = @bus.read(first).first
    drained[:work_item] = "TAMPERED"
    drained[:injected] = true

    other = @bus.read(second).first
    assert_equal "TASK-1.yml", other[:work_item]
    refute other.key?(:injected)
  end

  # --- AC5: independent cursors, no back-pressure -------------------------

  def test_independent_cursors_lagging_subscriber_still_sees_its_own_backlog
    fast = @bus.subscribe
    slow = @bus.subscribe

    @bus.publish("ent-1", { type: :picked_up, generation: 1 })
    @bus.publish("ent-1", { type: :started, generation: 1 })

    fast_records = @bus.read(fast)
    assert_equal 2, fast_records.size
    assert_empty @bus.read(fast)

    slow_records = @bus.read(slow)
    assert_equal 2, slow_records.size
  end

  # --- AC5: drop-oldest, counted per-subscriber and bus-wide --------------

  def test_overflow_drops_oldest_and_counts_per_subscriber_and_bus_wide
    bus = AgentDaemon::Supervisor::EventBus.new(capacity: 3)
    fast = bus.subscribe
    slow = bus.subscribe

    5.times do |i|
      bus.publish("ent-1", { type: :"e#{i + 1}", generation: 1 })
      bus.read(fast) # fast drains after every publish, so it never misses a record before eviction
    end

    assert_equal 2, bus.events_dropped_total
    assert_equal 2, bus.dropped(slow)
    assert_equal 0, bus.dropped(fast)

    remaining = bus.read(slow)
    assert_equal %i[e3 e4 e5], remaining.map { |r| r[:type] }
  end

  def test_unsubscribe_stops_further_drop_accounting
    bus = AgentDaemon::Supervisor::EventBus.new(capacity: 2)
    cursor = bus.subscribe
    bus.unsubscribe(cursor)

    5.times { |i| bus.publish("ent-1", { type: :"e#{i}", generation: 1 }) }

    assert_equal 3, bus.events_dropped_total
    assert_raises(KeyError) { bus.dropped(cursor) }
  end
end
