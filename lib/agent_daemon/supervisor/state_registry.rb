# frozen_string_literal: true

require "time"

module AgentDaemon
  module Supervisor
    # The single master-owned read model for supervised-entity state (AD-4).
    # IS the state-sink adapter — implements the exact Sinks::NullState
    # protocol (#publish(entity_id, snapshot)), so the Master injects it
    # directly with no separate adapter class.
    #
    # Registry updates are generation compare-and-set (AD-16): a write whose
    # generation is OLDER than the current entry is dropped; equal
    # generations are accepted (last write within a generation wins) — this
    # is what lets a same-generation `:crashed` snapshot supersede the dying
    # instance's own last `:in_progress` snapshot (see runner_supervisor.rb's
    # handle_thread_death). A missing/nil generation compares as 0 and never
    # raises, since a hand-built Sinks::Bundle with an unstamped sink is
    # legal (used by the standalone CLI path and tests).
    #
    # No status allowlist: every status in the published vocabulary is
    # accepted and retained (AC3) — filtering here would silently drop a
    # kind Story 2.4's liveness derivation needs a source for.
    #
    # Cross-thread writers: N entity threads plus the master thread
    # (RunnerSupervisor publishes :crashed/:exited from #tick, called on the
    # master thread) — guarded with an explicit Mutex, not the GIL.
    #
    # POPULATE-ON-PUBLISH, NOT AN INVENTORY. The registry holds only entities
    # that have published at least once, so an entity whose very first spawn!
    # raised (runner_supervisor.rb's rescue) is simply absent, and #snapshot
    # returns nil for it exactly as it does for an unknown id. Story 2.3 must
    # therefore source the fleet roster from Supervisor::Config/Master and
    # LEFT-JOIN the registry for state — do not treat this object as the
    # entity inventory, and do not add pre-registration here.
    class StateRegistry
      def initialize
        @entries = {}
        @mutex = Mutex.new
      end

      def publish(entity_id, snapshot)
        incoming_generation = snapshot[:generation] || 0

        @mutex.synchronize do
          current = @entries[entity_id]
          current_generation = current && (current[:generation] || 0)
          next if current && incoming_generation < current_generation

          # A full overwrite, never a merge into the previous entry: :crashed
          # and :exited snapshots carry no work_item/attempt, and that
          # absence must show up as gone, not stale (Story 2.4's
          # stale-work-item suppression depends on this).
          @entries[entity_id] = snapshot.merge(
            observed_at: Time.now.utc.iso8601,
            observed_monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC)
          )
        end
      end

      def snapshot(entity_id)
        @mutex.synchronize { @entries[entity_id]&.dup }
      end

      def all
        @mutex.synchronize { @entries.transform_values(&:dup) }
      end
    end
  end
end
