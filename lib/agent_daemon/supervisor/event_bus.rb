# frozen_string_literal: true

require "time"

module AgentDaemon
  module Supervisor
    # The single master-owned bounded event bus (AD-4). IS the event-sink
    # adapter — implements the exact Sinks::NullEvent protocol
    # (#publish(entity_id, event)).
    #
    # Pull-based subscription only: a subscriber calls #read(cursor) (or
    # cursor.read) to drain. There is deliberately no push/callback path — a
    # callback invoked on the producer's thread would let a slow subscriber
    # back-pressure a runner, which is exactly what AC5 forbids. Do not
    # "optimize" this into callbacks later.
    #
    # Bounded ring with drop-oldest on overflow: each registered subscriber
    # whose cursor has not yet read past the evicted record's seq has its
    # own `dropped` counter incremented, and the bus-wide aggregate
    # `events_dropped_total` (the Epic 6 metric name, AD-4) is incremented
    # once per eviction regardless of who missed it.
    class EventBus
      DEFAULT_CAPACITY = 2000

      # Opaque per-subscriber handle returned by #subscribe. Delegates
      # #read to the owning bus so a caller can use either `bus.read(cursor)`
      # or `cursor.read`.
      class Cursor
        def initialize(bus)
          @bus = bus
        end

        def read
          @bus.read(self)
        end
      end

      def initialize(capacity: DEFAULT_CAPACITY)
        @capacity = capacity
        @records = []
        @next_seq = 1
        @subscribers = {}
        @events_dropped_total = 0
        @mutex = Mutex.new
      end

      def publish(entity_id, event)
        @mutex.synchronize do
          record = event.merge(seq: @next_seq, entity_id: entity_id)
          record[:at] ||= Time.now.utc.iso8601
          @next_seq += 1
          @records << record
          evict_if_needed
        end
      end

      def subscribe
        cursor = Cursor.new(self)
        @mutex.synchronize { @subscribers[cursor] = { position: 0, dropped: 0 } }
        cursor
      end

      def unsubscribe(cursor)
        @mutex.synchronize { @subscribers.delete(cursor) }
      end

      # Copy-on-read, same contract as StateRegistry#snapshot/#all: the ring
      # keeps its records for every other subscriber (and for every future
      # subscriber replaying the backlog), so a consumer that transforms what
      # it drains — deleting keys, merging in render fields — must not be
      # handed the retained hash itself.
      def read(cursor)
        @mutex.synchronize do
          sub = @subscribers.fetch(cursor)
          fresh = @records.select { |record| record[:seq] > sub[:position] }
          sub[:position] = fresh.last[:seq] if fresh.any?
          fresh.map(&:dup)
        end
      end

      def dropped(cursor)
        @mutex.synchronize { @subscribers.fetch(cursor)[:dropped] }
      end

      # Non-consuming, non-registering snapshot of the retained ring, in seq
      # order (Story 2.5). Deliberately NOT #read: a page render must not
      # register a subscriber - #subscribe's cursors are only ever removed by
      # an explicit #unsubscribe, so one leaked per request would accumulate
      # forever AND slow every publish, since evict_if_needed walks every
      # registered subscriber on the producer's thread. Cursor lifecycle is
      # Story 2.6's; this reader has none.
      #
      # Copy-on-read, same contract as #read: the ring keeps its records for
      # every subscriber, so a consumer that transforms what it reads must not
      # be handed the retained hash itself.
      def records
        @mutex.synchronize { @records.map(&:dup) }
      end

      def events_dropped_total
        @mutex.synchronize { @events_dropped_total }
      end

      private

      def evict_if_needed
        while @records.size > @capacity
          evicted = @records.shift
          @events_dropped_total += 1
          @subscribers.each_value { |sub| sub[:dropped] += 1 if sub[:position] < evicted[:seq] }
        end
      end
    end
  end
end
