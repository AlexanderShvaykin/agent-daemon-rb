# frozen_string_literal: true

module AgentDaemon
  module Supervisor
    # The bounded per-run output store (AD-14). IS the OutputPipeline observer
    # — implements #call(record) plus the two optional lifecycle methods
    # (Story 3.3 DR8 / this story's DR3) — registered by the Master
    # (DR10), never called directly by a runner or a RunnerSupervisor.
    #
    # Holds at most ONE run buffer per entity_id: the selected run (AC4/AC5/
    # AC6). A new run's #run_started replaces the previous buffer wholesale,
    # so the store's memory ceiling is capacity_bytes × rostered entities
    # (~20, NFR7) and nothing accumulates for a dead entity.
    #
    # Deliberately NOT built on EventBus (Story 3.3 DR7): ActivityLog renders
    # every bus record as a timeline row, and output does not belong there.
    # Deliberately its own file, not an extension of OutputPipeline: it is a
    # pipeline OBSERVER, one layer downstream, with its own retention and
    # cursor concerns.
    #
    # Byte accounting is record.text.bytesize, summed over retained records —
    # not the Struct's object size, not the character count. This is what an
    # operator's output_buffer_bytes intuitively bounds and what Epic 5 will
    # persist.
    #
    # Thread safety: N runner threads write (via the pipeline's fanout, on
    # the producer's thread) while Puma request threads read #snapshot. One
    # explicit Mutex guards all state; nothing outside the store is ever
    # called while holding it (AD-4: this is a read-model, its faults must
    # never reach a producer).
    class OutputBuffers
      # Returned by value from #snapshot. `records` is a frozen Array of
      # already-frozen OutputPipeline::Record, ascending seq. `head_seq` /
      # `tail_seq` are nil only when status is :empty or nothing has been
      # retained yet. `finished`/`reason` are independent of each other's
      # nilness by design: Sinks::Bundle#end_output_run may pass reason: nil
      # when the backend aborted before a terminal reason was assigned, so
      # reason.nil? must never be read as "still running" (finished does
      # that job).
      Snapshot = Struct.new(
        :status, :entity_id, :generation, :run_id, :records,
        :head_seq, :tail_seq, :truncated, :finished, :reason, :lagged,
        keyword_init: true
      )

      def initialize(capacity_bytes:)
        @capacity_bytes = capacity_bytes
        @buffers = {}
        @mutex = Mutex.new
      end

      # Pipeline observer protocol — the one MANDATORY method.
      def call(record)
        @mutex.synchronize do
          buf = @buffers[record.entity_id]
          next unless buf
          next if buf[:run_id] != record.run_id
          next if stale_generation?(buf, record.generation)

          append_record(buf, record)
        end
        nil
      end

      # Replaces the entity's buffer wholesale with a fresh, empty one for
      # (run_id, generation) — replacing, not appending, is what makes AC6's
      # "records from the previous run are never presented" true by
      # construction rather than by filtering.
      def run_started(entity_id, run_id, generation)
        @mutex.synchronize do
          current = @buffers[entity_id]
          next if current && stale_generation?(current, generation)

          @buffers[entity_id] = {
            run_id: run_id,
            generation: generation,
            records: [],
            bytes: 0,
            truncated: false,
            finished: false,
            reason: nil
          }
        end
        nil
      end

      def run_finished(entity_id, run_id, reason, generation)
        @mutex.synchronize do
          buf = @buffers[entity_id]
          next unless buf
          next if buf[:run_id] != run_id
          next if stale_generation?(buf, generation)

          buf[:finished] = true
          buf[:reason] = reason
        end
        nil
      end

      # The cursor is the pair (run_id, seq), never a bare sequence — seq
      # restarts at 1 on every run, so a bare sequence is ambiguous across
      # runs. Both kwargs nil means "give me the full retained window"
      # (Story 3.5's first-render call); exactly one given is a caller bug
      # and raises loudly, since this runs on a Puma thread, never a runner
      # thread.
      def snapshot(entity_id, after_run_id: nil, after_seq: nil)
        if after_run_id.nil? ^ after_seq.nil?
          raise ArgumentError, "after_run_id and after_seq must both be given, or neither"
        end
        if !after_seq.nil? && !after_seq.is_a?(Integer)
          raise ArgumentError, "after_seq must be an Integer (got #{after_seq.class})"
        end

        @mutex.synchronize do
          buf = @buffers[entity_id]
          next empty_snapshot(entity_id) unless buf

          build_snapshot(entity_id, buf, after_run_id, after_seq)
        end
      end

      private

      # Caller holds @mutex. A missing generation compares as 0 and never
      # raises — a hand-built Sinks::Bundle with an unstamped sink is legal.
      def stale_generation?(buf, generation)
        (generation || 0) < (buf[:generation] || 0)
      end

      # Caller holds @mutex.
      def append_record(buf, record)
        buf[:records] << record
        buf[:bytes] += record.text.bytesize
        evict(buf)
      end

      # Caller holds @mutex. Oldest-complete-record-first, but eviction stops
      # at one record: an operator whose agent printed a single 1MB line must
      # still see that line, not an empty panel. Any eviction sets a sticky
      # `truncated` flag for the rest of the run — it is never cleared, since
      # a reader arriving after the evicted window closed still needs to know
      # the head is not the run's real start.
      def evict(buf)
        while buf[:bytes] > @capacity_bytes && buf[:records].size > 1
          evicted = buf[:records].shift
          buf[:bytes] -= evicted.text.bytesize
          buf[:truncated] = true
        end
      end

      # Caller holds @mutex. Always returned, never nil — that is what makes
      # AC7 provable: nil would be indistinguishable from "the lookup
      # failed", which is exactly the distinction AC7 asks for.
      def empty_snapshot(entity_id)
        Snapshot.new(
          status: :empty,
          entity_id: entity_id,
          generation: nil,
          run_id: nil,
          records: [].freeze,
          head_seq: nil,
          tail_seq: nil,
          truncated: false,
          finished: false,
          reason: nil,
          lagged: false
        ).freeze
      end

      # Caller holds @mutex. `records` is already frozen by the pipeline, so
      # copy-on-read means dup'ing the ARRAY (via #resolve_cursor's #dup /
      # #select, both of which already return a new Array), not the records
      # — unlike EventBus#read, which dups mutable Hashes.
      def build_snapshot(entity_id, buf, after_run_id, after_seq)
        records = buf[:records]
        head_seq = records.first&.seq
        tail_seq = records.last&.seq
        window, lagged = resolve_cursor(records, buf[:run_id], head_seq, after_run_id, after_seq)

        Snapshot.new(
          status: :retained,
          entity_id: entity_id,
          generation: buf[:generation],
          run_id: buf[:run_id],
          records: window.freeze,
          head_seq: head_seq,
          tail_seq: tail_seq,
          truncated: buf[:truncated],
          finished: buf[:finished],
          reason: buf[:reason],
          lagged: lagged
        ).freeze
      end

      # Caller holds @mutex. DR6's resolution rule table, in order:
      # 1 (no selected run) is handled by the caller before this is reached.
      # 2: no cursor ⇒ full window, not lagged.
      # 3: exactly-one-kwarg raises before #build_snapshot is ever entered.
      # 4: a different run_id ⇒ a run change, not a lag — full window.
      # 5: cursor precedes the retained head ⇒ full window, lagged.
      # 6: otherwise ⇒ only the newer records, not lagged (also covers an
      #    after_seq at or above tail_seq — both yield "nothing new").
      def resolve_cursor(records, run_id, head_seq, after_run_id, after_seq)
        return [records.dup, false] if after_run_id.nil?
        return [records.dup, false] if after_run_id != run_id
        return [records.dup, true] if head_seq && after_seq < head_seq - 1

        [records.select { |r| r.seq > after_seq }, false]
      end
    end
  end
end
