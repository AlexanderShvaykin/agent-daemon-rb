# frozen_string_literal: true

require "json"
require "time"

require_relative "../../log"
require_relative "../runner_identity"

module AgentDaemon
  module Supervisor
    module History
      # The single history writer (Story 5.2): one thread, one read-only
      # EventBus cursor, one SQLite connection. Producers only ever publish to
      # the bus; this thread pulls through its own cursor and never blocks
      # them. The cursor is created in #initialize, so building the writer
      # before any entity spawns means startup events are never missed.
      #
      # Correlation is in memory and per entity: at most one open run per
      # entity_key. Only observed events are stored; a missing transition is
      # never synthesized.
      #
      # Each drained batch commits in one transaction. On failure the
      # transaction rolls back and the in-memory maps are restored, so the
      # watermark (the highest bus seq committed) makes re-applying a batch
      # write nothing twice.
      #
      # Story 5.3 hardening:
      # - Gaps: records the bus evicted before this cursor read them are
      #   logged as one `[History] gap:` warn with the count. Nothing is
      #   synthesized for them.
      # - Retry: a rejected batch is re-applied (the same batch) up to
      #   retry_count times with capped exponential backoff. Exhaustion logs a
      #   `[History] gap:` error, makes the writer degraded for good, and moves
      #   on, so a later batch is still served.
      # - Recovery: before its first drain the thread marks every run a
      #   previous master left open as incomplete. A run displaced in memory
      #   by a newer one is marked the same way, so while a master is live
      #   `finished_at IS NULL AND incomplete = 0` means its writer still holds
      #   the run open. Runs still open at a graceful shutdown keep
      #   incomplete = 0 until the next master's writer marks them at start.
      # - Bounded shutdown: #unflushed_count tells the master what a missed
      #   flush deadline leaves behind.
      #
      # Log lines carry counts, seqs, attempts and delays, never field values;
      # every value reaches SQLite through bind parameters.
      #
      # Never references SQLite3:: constants, so loading this file never needs
      # the gem.
      class Writer
        THREAD_NAME = "history_writer"
        LIFECYCLE_TYPES = %i[picked_up started finished].freeze
        REASONS = %w[ok failed timeout killed].freeze

        # A record that cannot be stored; skipped with one warn line.
        class Skip < StandardError; end

        attr_reader :thread

        def initialize(database:, event_bus:, roster:, poll_interval: 0.5, retry_count: 3,
                       backoff_ceiling_ms: 2_000, sleeper: ->(seconds) { sleep(seconds) })
          @db = database.db
          @event_bus = event_bus
          @poll_interval = poll_interval
          @retry_count = retry_count
          @backoff_ceiling_ms = backoff_ceiling_ms
          @sleeper = sleeper
          @degraded = false
          @dropped_seen = 0
          @inflight = nil
          @settled = 0
          @roster = roster.to_h { |rostered| [RunnerIdentity.key_for(rostered.entity_id), rostered] }
          @open_runs = {}
          @entity_ids = {}
          @watermark = 0
          @stopping = false
          @thread = nil
          @cursor = event_bus.subscribe(from: :backlog)
        end

        def start
          @thread = Thread.new { run_loop }
          # Named from here, so the name is set before #start returns.
          @thread.name = THREAD_NAME
          self
        end

        # Requests a stop and waits up to timeout for the final drain. Returns
        # true when the thread finished. A thread still running keeps its
        # cursor, so its next read does not fail.
        def stop(timeout:)
          @stopping = true
          finished = @thread.nil? || !@thread.join(timeout).nil?
          @event_bus.unsubscribe(@cursor) if finished
          finished
        end

        # Sticky: once a batch is lost the session's history has a hole that
        # no later batch fills. A thread that died without a stop request
        # counts too.
        def degraded?
          return true if @degraded

          thread = @thread
          !thread.nil? && !thread.alive? && !@stopping
        end

        # The in-flight batch plus every bus record past it (or past the last
        # settled seq when nothing is in flight).
        def unflushed_count
          inflight = @inflight
          settled = @settled
          past = inflight ? inflight.last[:seq] : settled
          (inflight ? inflight.size : 0) + @event_bus.records.count { |record| record[:seq] > past }
        end

        # Applies records in one transaction. Returns true when the batch
        # committed (or had nothing new), false when it was rolled back. One
        # attempt only: the thread's retry wrapper re-applies it.
        def write(records)
          fresh = records.select { |record| record[:seq] > @watermark }
          return true if fresh.empty?

          saved = [@open_runs.dup, @entity_ids.dup, @watermark]
          begin
            @db.transaction(:immediate) do
              fresh.each { |record| apply(record) }
              @watermark = fresh.last[:seq]
            end
            true
          rescue StandardError => e
            @open_runs, @entity_ids, @watermark = saved
            rollback_quietly
            Log.error("[History] failed to write a batch of #{fresh.size} record(s): #{e.class}: #{e.message}")
            false
          end
        end

        private

        # stopping is read before the drain, so the drain that follows a stop
        # request is always the last one.
        def run_loop
          recover
          loop do
            stopping = @stopping
            begin
              drain
            rescue StandardError => e
              Log.error("[History] writer iteration failed: #{e.class}: #{e.message}")
            end
            break if stopping

            sleep(@poll_interval)
          end
        end

        def drain
          batch = @cursor.read
          note_evictions
          return if batch.empty?

          @inflight = batch
          unless with_retries { write(batch) }
            @degraded = true
            Log.error("[History] gap: lost #{batch.size} record(s), seq #{batch.first[:seq]}..#{batch.last[:seq]}, " \
                      "after #{@retry_count} retries")
          end
          @settled = batch.last[:seq]
          @inflight = nil
        end

        # dropped is cumulative per cursor; only the delta is new.
        def note_evictions
          dropped = @event_bus.dropped(@cursor)
          return unless dropped > @dropped_seen

          Log.warn("[History] gap: #{dropped - @dropped_seen} bus record(s) evicted before the writer read them")
          @dropped_seen = dropped
        end

        # Runs a previous master left open can never be finished by this one.
        def recover
          marked = 0
          recovered = with_retries do
            @db.execute("UPDATE run SET incomplete = 1 WHERE finished_at IS NULL AND incomplete = 0")
            marked = @db.changes
            true
          rescue StandardError => e
            Log.error("[History] failed to mark runs left open as incomplete: #{e.class}: #{e.message}")
            false
          end
          if recovered
            Log.info("[History] marked #{marked} run(s) left open by a previous master as incomplete") if marked.positive?
          else
            @degraded = true
            Log.error("[History] gap: runs left open by a previous master stay unmarked after #{@retry_count} retries")
          end
        end

        # At most 1 + retry_count attempts; before retry n (1-based) sleeps
        # min(100 ms * 2^(n-1), ceiling).
        def with_retries
          (0..@retry_count).each do |n|
            @sleeper.call(backoff(n)) if n.positive?
            return true if yield
          end
          false
        end

        def backoff(retry_number)
          [100 * (2**(retry_number - 1)), @backoff_ceiling_ms].min / 1000.0
        end

        # A failed COMMIT leaves the transaction open, and the next BEGIN would
        # then fail forever.
        def rollback_quietly
          @db.rollback if @db.transaction_active?
        rescue StandardError
          nil
        end

        def apply(record)
          case record[:type]
          when *LIFECYCLE_TYPES then apply_lifecycle(record)
          when :restart then apply_restart(record)
          else raise Skip, "unknown type"
          end
        rescue Skip => e
          Log.warn("[History] skipped bus record seq #{record[:seq]} (#{record[:type]}): #{e.message}")
        end

        def apply_lifecycle(record)
          entity_key, rostered = rostered_for(record)
          generation = required_generation(record)
          at = timestamp(record[:at], "at")
          entity_id = entity_row_id(entity_key, rostered, at)
          run = run_for(entity_key, entity_id, generation, record, at)
          @db.execute("INSERT INTO run_event (run_id, seq, event, reason, occurred_at) VALUES (?, ?, ?, ?, ?)",
                      [run[:id], record[:seq], record[:type].to_s, reason(record), at])
          return unless record[:type] == :finished

          @db.execute("UPDATE run SET finished_at = ?, reason = ? WHERE id = ?", [at, reason(record), run[:id]])
          # Only when this finished closed the open run itself: a finished that
          # opened its own run must not displace it.
          @open_runs.delete(entity_key) if @open_runs[entity_key].equal?(run)
        end

        def reason(record)
          REASONS.include?(record[:reason].to_s) ? record[:reason].to_s : nil
        end

        # picked_up always opens a new run, abandoning any earlier open one:
        # it is marked incomplete, never given an invented end. started/finished
        # attach to the open run when generation and work item match,
        # otherwise they open a new run from what was seen.
        def run_for(entity_key, entity_id, generation, record, at)
          open = @open_runs[entity_key]
          if record[:type] != :picked_up && open &&
             open[:generation] == generation && open[:work_item] == record[:work_item]
            unless record[:attempt].nil?
              @db.execute("UPDATE run SET attempt = ? WHERE id = ?", [record[:attempt], open[:id]])
            end
            return open
          end

          @db.execute("INSERT INTO run (entity_id, generation, work_item, attempt, started_at) VALUES (?, ?, ?, ?, ?)",
                      [entity_id, generation, record[:work_item]&.to_s, record[:attempt], at])
          run = { id: @db.last_insert_row_id, generation: generation, work_item: record[:work_item] }.freeze
          # A run opened by finished is already closed, so it never becomes the
          # open run. Replaced, never mutated: the rollback snapshot is a
          # shallow dup.
          return run if record[:type] == :finished

          @db.execute("UPDATE run SET incomplete = 1 WHERE id = ?", [open[:id]]) if open
          @open_runs[entity_key] = run
        end

        def apply_restart(record)
          entity_key, rostered = rostered_for(record)
          generation = required_generation(record)
          completed_at = timestamp(record[:at], "at")
          requested_at = timestamp(record[:requested_at], "requested_at")
          entity_id = entity_row_id(entity_key, rostered, completed_at)
          actors = JSON.generate(Array(record[:actor]).map(&:to_s))
          @db.execute("INSERT INTO restart_action (entity_id, source_generation, target_generation, actors, " \
                      "requested_at, completed_at) VALUES (?, ?, ?, ?, ?, ?)",
                      [entity_id, generation - 1, generation, actors, requested_at, completed_at])
        end

        def rostered_for(record)
          key = RunnerIdentity.key_for(record[:entity_id])
          rostered = @roster[key]
          raise Skip, "entity not in roster" unless rostered

          [key, rostered]
        end

        def required_generation(record)
          generation = record[:generation]
          raise Skip, "missing generation" unless generation.is_a?(Integer)

          generation
        end

        def timestamp(value, field)
          raise Skip, "missing #{field}" if value.nil?

          Time.iso8601(value.to_s).utc.iso8601(3)
        rescue ArgumentError
          raise Skip, "unparseable #{field}"
        end

        # Created on the entity's first persisted event; the id is cached.
        def entity_row_id(entity_key, rostered, first_seen_at)
          @entity_ids[entity_key] ||= begin
            workflow, runner = entity_columns(rostered)
            @db.execute("INSERT OR IGNORE INTO supervised_entity (entity_key, kind, workflow, runner, first_seen_at) " \
                        "VALUES (?, ?, ?, ?, ?)", [entity_key, rostered.kind.to_s, workflow, runner, first_seen_at])
            @db.get_first_value("SELECT id FROM supervised_entity WHERE entity_key = ?", [entity_key])
          end
        end

        def entity_columns(rostered)
          case rostered.kind
          when :runner then [rostered.workflow, rostered.name]
          when :messenger then [rostered.workflow, nil]
          else [nil, nil]
          end
        end
      end
    end
  end
end
