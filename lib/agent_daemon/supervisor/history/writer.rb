# frozen_string_literal: true

require "json"
require "time"

require_relative "../../log"
require_relative "../runner_identity"
require_relative "output_queue"

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
      # Story 5.4 output:
      # - Source: an OutputQueue subscribed to the OutputPipeline, the same
      #   redacted stream the live tail reads. Producers only append to it in
      #   memory; it evicts its oldest lines over budget and leaves a :lost
      #   marker, which sets the run's output_incomplete.
      # - Merge: each iteration reads the bus first, then drains the queue.
      #   Drained entries join the per-entity pending output, which is part of
      #   the batch (snapshotted and restored with the other maps, re-applied
      #   by a retry). An entity's pending output is flushed before each of
      #   its lifecycle records and at the end of every batch, so a run's
      #   lines commit in the same transaction as its finished, never after.
      # - Binding: a pipeline run binds to the entity's open run once that
      #   run's started is applied, at most once per run. A finished that
      #   closes a never-bound run (its started was evicted) adopts a fully
      #   pending pipeline run of the same generation. A run_started that
      #   still cannot bind at the end of the second batch that carried it is
      #   an orphan and is dropped with its lines (one gap warn).
      # - Cap: each run keeps at most output_buffer_bytes of text; the oldest
      #   rows go first, never the newest one, and output_truncated is set.
      # - A failed run gets a JSON error_summary: reason, attempt and the
      #   last stored stderr line.
      #
      # Story 5.6 retention: the pruner lives on this same thread and
      # connection, with no cron and no second process. A cycle runs on the
      # first iteration and then every prune_interval_seconds (monotonic,
      # from the previous cycle's start). It captures its cutoff once and
      # deletes, one batch = one transaction per iteration so ordinary drains
      # run between batches: expired runs with their events and output (a
      # run the writer still holds open is always kept), expired restart
      # actions, then entities nothing references and the roster does not
      # name. A failed batch rolls back, ends the cycle and marks prune
      # degraded until a later cycle succeeds. A stop starts no cycle and no
      # further batch. There is never a VACUUM: freed pages are reused.
      # #status is an in-memory snapshot for the console.
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
        STREAMS = %w[stdout stderr].freeze

        PRUNE_PHASES = %i[runs restart_actions entities].freeze

        # A record that cannot be stored; skipped with one warn line.
        class Skip < StandardError; end

        # What the console shows about history (Story 5.6).
        Status = Struct.new(:retention_days, :last_pruned_at, :writer_degraded, :prune_degraded)

        attr_reader :thread

        def initialize(database:, event_bus:, roster:, output_pipeline: nil, output_buffer_bytes: 262_144,
                       poll_interval: 0.5, retry_count: 3, backoff_ceiling_ms: 2_000,
                       sleeper: ->(seconds) { sleep(seconds) }, retention_days: 30,
                       prune_interval_seconds: 21_600, prune_batch_size: 500, clock: -> { Time.now })
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
          @output_buffer_bytes = output_buffer_bytes
          # entity_key => frozen Array of queue entries, FIFO. The Hash itself
          # is frozen and replaced, so #unflushed_count can read it from
          # another thread.
          @pending = {}.freeze
          # entity_key => frozen { generation:, pipeline_run:, run_row: }
          @bindings = {}
          # [entity_key, generation, pipeline_run] => batch ends a blocked
          # run_started has waited through.
          @waits = {}
          @inflight_output = nil
          # Run rows still bound when a batch carrying their output was lost;
          # the next committed batch marks them output_incomplete.
          @lost_runs = [].freeze
          @retention_days = retention_days
          @prune_interval_seconds = prune_interval_seconds
          @prune_batch_size = prune_batch_size
          @clock = clock
          # nil, or the running cycle: frozen { cutoff:, now:, phase:, counts: }.
          @prune = nil
          @next_prune_at = nil
          @last_pruned_at = nil
          @prune_degraded = false
          @stopping = false
          @thread = nil
          @cursor = event_bus.subscribe(from: :backlog)
          @output_queue = OutputQueue.new(budget_bytes: output_buffer_bytes * [roster.size, 1].max)
          output_pipeline&.subscribe(@output_queue)
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

        # Safe from any thread: reads only instance variables that are
        # replaced, never mutated.
        def status
          Status.new(@retention_days, @last_pruned_at, degraded?, @prune_degraded).freeze
        end

        # The in-flight batch plus every bus record past it (or past the last
        # settled seq when nothing is in flight), plus the output entries in
        # flight, pending, and still queued.
        def unflushed_count
          inflight = @inflight
          inflight_output = @inflight_output
          settled = @settled
          past = inflight ? inflight.last[:seq] : settled
          (inflight ? inflight.size : 0) + @event_bus.records.count { |record| record[:seq] > past } +
            (inflight_output ? inflight_output.size : 0) + pending_size + @output_queue.size
        end

        # Applies records, and the output entries drained with them, in one
        # transaction. Returns true when the batch committed (or had nothing
        # new), false when it was rolled back. One attempt only: the thread's
        # retry wrapper re-applies it.
        def write(records, output = [])
          fresh = records.select { |record| record[:seq] > @watermark }
          return true if fresh.empty? && output.empty? && @pending.empty? && @lost_runs.empty?

          saved = [@open_runs.dup, @entity_ids.dup, @watermark, @pending, @bindings.dup, @waits.dup, @lost_runs]
          @dropped_lines = 0
          @orphans = 0
          begin
            @db.transaction(:immediate) do
              mark_lost_runs
              enqueue(output)
              fresh.each { |record| apply(record) }
              finish_batch
              @watermark = fresh.last[:seq] unless fresh.empty?
            end
            log_dropped_output
            true
          rescue StandardError => e
            @open_runs, @entity_ids, @watermark, @pending, @bindings, @waits, @lost_runs = saved
            rollback_quietly
            also = output.empty? ? "" : " and #{output.size} output entr(ies)"
            Log.error("[History] failed to write a batch of #{fresh.size} record(s)#{also}: #{e.class}: #{e.message}")
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

            prune_step
            sleep(@poll_interval)
          end
          left = pending_size
          Log.warn("[History] gap: dropped #{left} pending output entr(ies) at stop") if left.positive?
        end

        # The bus is read before the queue is drained: every line in this
        # drain was produced after its run's started was published, so a
        # finished in this batch has all of its run's lines here too.
        def drain
          batch = @cursor.read
          note_evictions
          output = @output_queue.drain
          return if batch.empty? && output.empty? && @pending.empty?

          @inflight = batch unless batch.empty?
          @inflight_output = output
          lose_batch(batch, output) unless with_retries { write(batch, output) }
          @settled = batch.last[:seq] unless batch.empty?
          @inflight = nil
          @inflight_output = nil
        end

        # The pending output was part of every rejected attempt, so it is lost
        # with the batch; keeping it would re-fail every later iteration.
        def lose_batch(batch, output)
          @degraded = true
          @lost_runs = (@lost_runs + @bindings.values.map { |binding| binding[:run_row] }).uniq.freeze
          lost_output = output.size + pending_size
          @pending = {}.freeze
          @waits = {}
          lost = []
          lost << "#{batch.size} record(s), seq #{batch.first[:seq]}..#{batch.last[:seq]}" unless batch.empty?
          lost << "#{lost_output} output entr(ies)" if lost_output.positive?
          Log.error("[History] gap: lost #{lost.join(' and ')}, after #{@retry_count} retries")
        end

        def mark_lost_runs
          @lost_runs.each { |run_row| @db.execute("UPDATE run SET output_incomplete = 1 WHERE id = ?", [run_row]) }
          @lost_runs = [].freeze
        end

        def pending_size
          @pending.sum { |_key, entries| entries.size }
        end

        # dropped is cumulative per cursor; only the delta is new.
        def note_evictions
          dropped = @event_bus.dropped(@cursor)
          return unless dropped > @dropped_seen

          Log.warn("[History] gap: #{dropped - @dropped_seen} bus record(s) evicted before the writer read them")
          @dropped_seen = dropped
        end

        # --- Retention (Story 5.6) ---------------------------------------------

        # At most one batch per call. Its failure ends the cycle; the next
        # scheduled cycle is the retry.
        def prune_step
          return if @stopping

          if @prune.nil?
            return unless prune_due?

            start_prune
          end
          prune = @prune
          deleted = prune_batch(prune)
          counts = prune[:counts].dup
          counts[prune[:phase]] += deleted
          phase = deleted < @prune_batch_size ? prune[:phase] + 1 : prune[:phase]
          if phase == PRUNE_PHASES.size
            finish_prune(prune, counts)
          else
            @prune = prune.merge(phase: phase, counts: counts.freeze).freeze
          end
        rescue StandardError => e
          rollback_quietly
          @prune = nil
          @prune_degraded = true
          Log.error("[History] prune failed: #{e.class}: #{e.message}")
        end

        def prune_due?
          @next_prune_at.nil? || monotonic >= @next_prune_at
        end

        def start_prune
          @next_prune_at = monotonic + @prune_interval_seconds
          now = @clock.call.getutc
          cutoff = (now - (@retention_days * 86_400)).iso8601(3)
          @prune = { cutoff: cutoff, now: now.iso8601(3), phase: 0, counts: [0, 0, 0].freeze }.freeze
        end

        def finish_prune(prune, counts)
          @prune = nil
          @last_pruned_at = prune[:now]
          @prune_degraded = false
          runs, actions, entities = counts
          return unless counts.any?(&:positive?)

          Log.info("[History] pruned #{runs} run(s), #{actions} restart action(s), #{entities} entit(ies) " \
                   "older than #{prune[:cutoff]}")
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # One transaction, one batch of parents. Children go first and pick
        # the same ids, so no orphan row survives.
        def prune_batch(prune)
          @db.transaction(:immediate) do
            case PRUNE_PHASES[prune[:phase]]
            when :runs then prune_runs(prune[:cutoff])
            when :restart_actions then prune_restart_actions(prune[:cutoff])
            else prune_entities
            end
          end
        end

        def prune_runs(cutoff)
          open_ids = JSON.generate(@open_runs.values.map { |run| run[:id] })
          pick = "SELECT id FROM run WHERE (finished_at IS NOT NULL AND finished_at < ?1) OR " \
                 "(finished_at IS NULL AND started_at < ?1 AND id NOT IN (SELECT value FROM json_each(?2))) " \
                 "ORDER BY id LIMIT ?3"
          binds = [cutoff, open_ids, @prune_batch_size]
          %w[run_output run_event].each { |table| @db.execute("DELETE FROM #{table} WHERE run_id IN (#{pick})", binds) }
          @db.execute("DELETE FROM run WHERE id IN (#{pick})", binds)
          @db.changes
        end

        def prune_restart_actions(cutoff)
          @db.execute("DELETE FROM restart_action WHERE id IN (SELECT id FROM restart_action WHERE requested_at < ? " \
                      "ORDER BY id LIMIT ?)", [cutoff, @prune_batch_size])
          @db.changes
        end

        # Roster entities are always kept, so @entity_ids never names a
        # deleted row.
        def prune_entities
          @db.execute("DELETE FROM supervised_entity WHERE id IN (SELECT e.id FROM supervised_entity e " \
                      "WHERE NOT EXISTS (SELECT 1 FROM run WHERE run.entity_id = e.id) " \
                      "AND NOT EXISTS (SELECT 1 FROM restart_action a WHERE a.entity_id = e.id) " \
                      "AND e.entity_key NOT IN (SELECT value FROM json_each(?)) ORDER BY e.id LIMIT ?)",
                      [JSON.generate(@roster.keys), @prune_batch_size])
          @db.changes
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
          flush(entity_key)
          generation = required_generation(record)
          at = timestamp(record[:at], "at")
          entity_id = entity_row_id(entity_key, rostered, at)
          run = run_for(entity_key, entity_id, generation, record, at)
          @db.execute("INSERT INTO run_event (run_id, seq, event, reason, occurred_at) VALUES (?, ?, ?, ?, ?)",
                      [run[:id], record[:seq], record[:type].to_s, reason(record), at])
          # Replaced, never mutated: the rollback snapshot is a shallow dup.
          @open_runs[entity_key] = run.merge(started: true).freeze if record[:type] == :started && !run[:started]
          return unless record[:type] == :finished

          adopt_pending_run(entity_key, run, generation) unless run[:bound]
          @db.execute("UPDATE run SET finished_at = ?, reason = ?, error_summary = ? WHERE id = ?",
                      [at, reason(record), error_summary(record, run), run[:id]])
          unbind(entity_key, run)
          # Only when this finished closed the open run itself: a finished that
          # opened its own run must not displace it.
          @open_runs.delete(entity_key) if @open_runs[entity_key].equal?(run)
        end

        # Built from structured fields and stored rows only, never from logs.
        def error_summary(record, run)
          return nil unless reason(record) == "failed"

          attempt = @db.get_first_value("SELECT attempt FROM run WHERE id = ?", [run[:id]])
          last_stderr = @db.get_first_value("SELECT text FROM run_output WHERE run_id = ? AND stream = 'stderr' " \
                                            "ORDER BY seq DESC LIMIT 1", [run[:id]])
          JSON.generate({ "reason" => "failed", "attempt" => attempt, "last_stderr" => last_stderr })
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

          if open
            @db.execute("UPDATE run SET incomplete = 1 WHERE id = ?", [open[:id]])
            unbind(entity_key, open)
          end
          @open_runs[entity_key] = run
        end

        # --- Output (Story 5.4) -------------------------------------------------

        # Entries of an entity outside the roster have nowhere to go.
        def enqueue(output)
          return if output.empty?

          pending = @pending.dup
          output.group_by { |entry| RunnerIdentity.key_for(entry[:entity_id]) }.each do |entity_key, entries|
            if @roster.key?(entity_key)
              pending[entity_key] = ((pending[entity_key] || []) + entries).freeze
            else
              @dropped_lines += entries.count { |entry| entry[:kind] == :output }
            end
          end
          @pending = pending.freeze
        end

        # Processes an entity's pending entries in order until a run_started
        # that cannot bind yet, or (with through:) until that pipeline run's
        # run_finished.
        def flush(entity_key, through: nil)
          entries = @pending[entity_key]
          return if entries.nil?

          touched = {}
          index = 0
          while index < entries.size
            entry = entries[index]
            binding = @bindings[entity_key]
            bound = !binding.nil? && binding[:generation] == entry[:generation] &&
                    binding[:pipeline_run] == entry[:run_id]
            case entry[:kind]
            when :run_started
              break unless bind(entity_key, entry)
            when :output
              if bound && store_line(binding[:run_row], entry)
                touched[binding[:run_row]] = true
              else
                @dropped_lines += 1
              end
            when :lost
              @db.execute("UPDATE run SET output_incomplete = 1 WHERE id = ?", [binding[:run_row]]) if bound
            when :run_finished
              @bindings.delete(entity_key) if bound
            end
            index += 1
            break if through && entry[:kind] == :run_finished && same_pipeline_run?(entry, through)
          end
          set_pending(entity_key, entries.drop(index)) if index.positive?
          touched.each_key { |run_row| cap(run_row) }
        end

        # A pipeline run belongs to the open run once that run's started is
        # applied, and each run takes exactly one pipeline run.
        def bind(entity_key, entry)
          open = @open_runs[entity_key]
          return false unless open && open[:started] && !open[:bound] && open[:generation] == entry[:generation]

          @open_runs[entity_key] = open.merge(bound: true).freeze
          @bindings[entity_key] = { generation: entry[:generation], pipeline_run: entry[:run_id],
                                    run_row: open[:id] }.freeze
          true
        end

        def unbind(entity_key, run)
          @bindings.delete(entity_key) if @bindings[entity_key]&.fetch(:run_row) == run[:id]
        end

        # A finished closing a run nothing was bound to (its started was
        # evicted): the pending pipeline run of the same generation, complete
        # through its run_finished, is this run's output.
        def adopt_pending_run(entity_key, run, generation)
          entries = @pending[entity_key]
          head = entries&.first
          return unless head && head[:kind] == :run_started && head[:generation] == generation
          return unless entries.any? { |entry| entry[:kind] == :run_finished && same_pipeline_run?(entry, head) }

          @bindings[entity_key] = { generation: generation, pipeline_run: head[:run_id], run_row: run[:id] }.freeze
          set_pending(entity_key, entries.drop(1))
          flush(entity_key, through: head)
        end

        def same_pipeline_run?(entry, other)
          entry[:generation] == other[:generation] && entry[:run_id] == other[:run_id]
        end

        def store_line(run_row, entry)
          stream = entry[:stream].to_s
          return false unless STREAMS.include?(stream)

          @db.execute("INSERT OR IGNORE INTO run_output (run_id, seq, stream, text) VALUES (?, ?, ?, ?)",
                      [run_row, entry[:seq], stream, entry[:text]])
          true
        end

        # Oldest rows first, never the newest one: a single line over the cap
        # is kept whole.
        def cap(run_row)
          total = @db.get_first_value("SELECT COALESCE(SUM(length(CAST(text AS BLOB))), 0) FROM run_output " \
                                      "WHERE run_id = ?", [run_row])
          return if total <= @output_buffer_bytes

          sizes = @db.execute("SELECT seq, length(CAST(text AS BLOB)) FROM run_output WHERE run_id = ? ORDER BY seq",
                              [run_row])
          cut = nil
          sizes[0...-1].each do |seq, bytes|
            break if total <= @output_buffer_bytes

            total -= bytes
            cut = seq
          end
          return if cut.nil?

          @db.execute("DELETE FROM run_output WHERE run_id = ? AND seq <= ?", [run_row, cut])
          @db.execute("UPDATE run SET output_truncated = 1 WHERE id = ?", [run_row])
        end

        def set_pending(entity_key, entries)
          @pending = if entries.empty?
                       @pending.reject { |key, _| key == entity_key }.freeze
                     else
                       @pending.merge(entity_key => entries.freeze).freeze
                     end
        end

        # Flushes every entity, then ages each blocked run_started once. One
        # that has now waited through two batch ends is an orphan: it is
        # dropped with its pipeline run's entries, and what follows it is
        # flushed.
        def finish_batch
          waits = {}
          @pending.each_key do |entity_key|
            loop do
              flush(entity_key)
              head = @pending[entity_key]&.first
              break if head.nil?

              wait_key = [entity_key, head[:generation], head[:run_id]]
              waited = @waits.fetch(wait_key, 0) + 1
              if waited < 2
                waits[wait_key] = waited
                break
              end

              drop_orphan(entity_key, head)
            end
          end
          @waits = waits
        end

        def drop_orphan(entity_key, head)
          orphaned, kept = @pending[entity_key].partition { |entry| same_pipeline_run?(entry, head) }
          @orphans += 1
          @dropped_lines += orphaned.count { |entry| entry[:kind] == :output }
          set_pending(entity_key, kept)
        end

        def log_dropped_output
          return unless @dropped_lines.positive? || @orphans.positive?

          Log.warn("[History] gap: dropped #{@dropped_lines} output line(s) no run could claim " \
                   "(#{@orphans} unclaimed run start(s))")
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
