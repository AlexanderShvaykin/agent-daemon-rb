# frozen_string_literal: true

require_relative "runner_identity"

module AgentDaemon
  module Supervisor
    # The read-side join that answers "what has this entity been doing" (AC1,
    # FR8): a bounded, newest-first timeline of one entity's lifecycle events,
    # read from the EventBus without subscribing (AC5). NOT a supervised
    # entity (AD-13) and NOT under console/ - this is a read-model join
    # Epic 5's history browser and Epic 6's exporter will also need, console/
    # stays the HTTP layer.
    #
    # Stdlib only, and it touches nothing but EventBus#records - never a
    # runner, a RunnerSupervisor, a thread, or the StateRegistry (AD-3). Do
    # not memoise: the page must show current state, same rule Fleet carries
    # in its header.
    class ActivityLog
      # A runner emits three events per work item, so 50 rows is ~16 recent
      # items - enough to read a pattern (three timeouts in a row, a crash
      # after every pickup) on one screen without paginating. Deliberately far
      # below the bus's 2000-record capacity, so that in a fleet whose entities
      # publish at comparable rates this limit is what truncates a timeline.
      # It is NOT a floor: the ring is shared and eviction is drop-oldest
      # across all producers (event_bus.rb), so one chatty runner can displace
      # a quiet entity's records entirely and leave its page reading "No
      # activity recorded." Recorded in deferred-work.md, code review of
      # story-2-5; a per-entity floor is a bus change and durable history is
      # Epic 5.
      DEFAULT_LIMIT = 50

      # Members are copied out of the bus record, never the record itself -
      # #records already dup'd; building a Struct means no consumer can hand
      # a bus hash to a renderer and no unexpected key rides along into the
      # page.
      Entry = Struct.new(:seq, :type, :at, :generation,
                          :work_item, :attempt, :reason, :actor,
                          keyword_init: true)

      # Read by the console so the section heading advertises the limit this
      # instance actually applies, never the class default it may not use.
      attr_reader :limit

      def initialize(event_bus:, limit: DEFAULT_LIMIT)
        @event_bus = event_bus
        @limit = limit
      end

      # id is the console's String id - the same value Fleet::Entry#id
      # carries and the same value /entity?id=... receives. Compare, never
      # parse: no RunnerIdentity is reconstructed from a request string.
      # Unknown id -> [], not nil, not a raise.
      def recent(id, limit: @limit)
        matching = @event_bus.records.select { |record| RunnerIdentity.key_for(record[:entity_id]) == id }
        matching.sort_by { |record| record[:seq] }
                .last(limit)
                .reverse
                .map { |record| build_entry(record) }
      end

      private

      def build_entry(record)
        Entry.new(
          seq: record[:seq],
          type: record[:type],
          at: record[:at],
          generation: record[:generation],
          work_item: record[:work_item],
          attempt: record[:attempt],
          reason: record[:reason],
          actor: record[:actor]
        )
      end
    end
  end
end
