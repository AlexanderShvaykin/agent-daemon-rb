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

  def test_tail_subscription_receives_only_records_published_after_subscribing
    @bus.publish("ent-1", { type: :before, generation: 1 })

    cursor = @bus.subscribe(from: :tail)
    assert_empty cursor.read

    @bus.publish("ent-1", { type: :after, generation: 1 })
    assert_equal [:after], cursor.read.map { |record| record[:type] }
  end

  def test_default_subscription_still_replays_retained_records
    @bus.publish("ent-1", { type: :before, generation: 1 })

    assert_equal [:before], @bus.subscribe.read.map { |record| record[:type] }
  end

  def test_block_subscription_unsubscribes_after_normal_return
    result = @bus.subscribe(from: :tail) do |cursor|
      assert_equal 1, @bus.instance_variable_get(:@subscribers).size
      assert_empty cursor.read
      :done
    end

    assert_equal :done, result
    assert_empty @bus.instance_variable_get(:@subscribers)
  end

  def test_block_subscription_unsubscribes_after_raise
    cursor = nil

    error = assert_raises(RuntimeError) do
      @bus.subscribe(from: :tail) do |subscribed|
        cursor = subscribed
        raise "stream failed"
      end
    end

    assert_equal "stream failed", error.message
    assert_raises(KeyError) { @bus.dropped(cursor) }
    assert_empty @bus.instance_variable_get(:@subscribers)
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

  # --- Story 2.5: #records is a non-consuming, non-registering snapshot ----

  def test_records_returns_the_whole_ring_in_seq_order
    @bus.publish("ent-1", { type: :picked_up, generation: 1 })
    @bus.publish("ent-2", { type: :picked_up, generation: 1 })

    records = @bus.records

    assert_equal %w[ent-1 ent-2], records.map { |r| r[:entity_id] }
    assert_equal [1, 2], records.map { |r| r[:seq] }
  end

  def test_records_does_not_register_a_subscriber_and_does_not_consume
    @bus.publish("ent-1", { type: :picked_up, generation: 1 })

    first_call = @bus.records
    second_call = @bus.records

    assert_equal first_call, second_call
    assert_equal 0, @bus.instance_variable_get(:@subscribers).size, "#records must never register a cursor"
  end

  def test_records_leaves_a_pre_existing_subscribers_read_unaffected
    cursor = @bus.subscribe
    @bus.publish("ent-1", { type: :picked_up, generation: 1 })

    @bus.records
    @bus.records

    assert_equal 1, @bus.read(cursor).size, "repeated #records calls must not advance any subscriber's cursor"
  end

  def test_records_leaves_drop_accounting_untouched
    bus = AgentDaemon::Supervisor::EventBus.new(capacity: 1)
    cursor = bus.subscribe
    bus.publish("ent-1", { type: :e1, generation: 1 })
    bus.publish("ent-1", { type: :e2, generation: 1 })

    before_total = bus.events_dropped_total
    before_dropped = bus.dropped(cursor)
    bus.records
    bus.records

    assert_equal before_total, bus.events_dropped_total
    assert_equal before_dropped, bus.dropped(cursor)
  end

  # Copy-on-read, same property #read already pins: mutating what #records
  # returns must not corrupt the retained ring.
  def test_records_copies_each_record_hash_so_top_level_keys_cannot_be_corrupted
    @bus.publish("ent-1", { type: :started, work_item: "TASK-1.yml", generation: 1 })

    drained = @bus.records.first
    drained[:work_item] = "TAMPERED"
    drained[:injected] = true

    fresh = @bus.records.first
    assert_equal "TASK-1.yml", fresh[:work_item]
    refute fresh.key?(:injected)
  end

  # The copy is one level deep, exactly as #read's is - this pins where the
  # boundary actually falls so no consumer mistakes it for a deep copy. `actor`
  # is the only nested collection in the vocabulary (AD-9), and the rule that
  # keeps this safe is "do not mutate what the bus hands you": ActivityLog
  # copies it into an Entry Struct and the console only joins it for display.
  def test_records_copies_one_level_deep_so_a_nested_actor_array_is_still_shared
    @bus.publish("ent-1", { type: :restart, actor: [:crash_auto], generation: 2 })

    @bus.records.first[:actor] << :INJECTED

    assert_equal %i[crash_auto INJECTED], @bus.records.first[:actor],
                 "nested values are shared by design; if this ever becomes a deep copy, " \
                 "update EventBus#records' contract comment and ActivityLog's dup caveat"
  end
end
