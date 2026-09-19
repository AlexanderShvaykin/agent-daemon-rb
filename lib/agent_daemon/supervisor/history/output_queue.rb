# frozen_string_literal: true

module AgentDaemon
  module Supervisor
    module History
      # The non-blocking handoff from output producers to the history writer
      # (Story 5.4). It is an OutputPipeline observer: #call, #run_started and
      # #run_finished each append one frozen entry under this queue's own
      # mutex, do no IO, and return. The writer thread takes everything with
      # #drain.
      #
      # Entries keep arrival order and are frozen Hashes with :kind
      # (:run_started, :output, :run_finished or :lost), :entity_id,
      # :generation and :run_id; :output adds :stream, :seq and :text.
      #
      # Bounded by the text bytes of queued :output entries. Over budget, the
      # oldest :output entry is evicted and replaced in place by a :lost
      # marker for the same (entity_id, generation, run_id), so the writer can
      # flag that run's capture as incomplete. Lifecycle markers are never
      # evicted. An evicted entry whose key already has a :lost marker in the
      # queue is coalesced into that marker (always earlier and adjacent in
      # that run's own entries), so a stuck writer holds at most one marker
      # per pipeline run.
      class OutputQueue
        def initialize(budget_bytes:)
          @budget_bytes = budget_bytes
          @mutex = Mutex.new
          reset
        end

        def call(record)
          push({ kind: :output, entity_id: record.entity_id, generation: record.generation, run_id: record.run_id,
                 stream: record.stream, seq: record.seq, text: record.text }.freeze)
        end

        def run_started(entity_id, run_id, generation = nil)
          push({ kind: :run_started, entity_id: entity_id, generation: generation, run_id: run_id }.freeze)
        end

        def run_finished(entity_id, run_id, _reason, generation = nil)
          push({ kind: :run_finished, entity_id: entity_id, generation: generation, run_id: run_id }.freeze)
        end

        # Returns every entry in arrival order and empties the queue.
        def drain
          @mutex.synchronize do
            entries = @entries.compact.freeze
            reset
            entries
          end
        end

        def size
          @mutex.synchronize { @entries.size - @holes }
        end

        private

        # Caller holds @mutex (or is #initialize).
        def reset
          @entries = []
          @bytes = 0
          @holes = 0
          # Entries before @head are never :output, so the oldest :output is
          # found by scanning forward only.
          @head = 0
          @lost = {}
        end

        def push(entry)
          @mutex.synchronize do
            @entries << entry
            if entry[:kind] == :output
              @bytes += entry[:text].bytesize
              evict
            end
          end
          nil
        end

        # Caller holds @mutex.
        def evict
          while @bytes > @budget_bytes
            @head += 1 until @entries[@head]&.fetch(:kind) == :output
            evicted = @entries[@head]
            @bytes -= evicted[:text].bytesize
            key = [evicted[:entity_id], evicted[:generation], evicted[:run_id]]
            if @lost.key?(key)
              @entries[@head] = nil
              @holes += 1
            else
              @entries[@head] = { kind: :lost, entity_id: evicted[:entity_id], generation: evicted[:generation],
                                  run_id: evicted[:run_id] }.freeze
              @lost[key] = true
            end
            @head += 1
          end
          compact if @holes > 64 && @holes * 2 > @entries.size
        end

        # Caller holds @mutex. Amortized: runs only when holes outnumber
        # entries.
        def compact
          @head -= @entries.first(@head).count(&:nil?)
          @entries.compact!
          @holes = 0
        end
      end
    end
  end
end
