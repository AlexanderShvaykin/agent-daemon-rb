# frozen_string_literal: true

require "time"

require_relative "redactor"

module AgentDaemon
  module Supervisor
    # The one output-sink adapter (AD-8/AD-14). It IS the sink the core's
    # Sinks::Bundle publishes into — implementing NullOutput's
    # `#append(entity_id, stream, chunk)` plus the run lifecycle
    # `#begin_run` / `#end_run` — exactly the way EventBus is the event sink
    # rather than sitting behind one.
    #
    # Raw chunks are buffered per (entity_id, stream) as binary, split on
    # complete line boundaries, scrubbed to valid UTF-8, redacted, and only
    # then emitted as immutable Records to registered observers. Nothing
    # unredacted is ever retained or handed out.
    #
    # OBSERVER CONTRACT — an output observer MUST be a non-blocking in-memory
    # append: no synchronous IO, no network, no lock it does not own. The
    # fanout runs on the producer's thread (the backend select loop), so
    # observer latency is a runner-loop stall. An observer that needs to do IO
    # queues internally (Epic 5's history writer, NFR4); it must not make the
    # pipeline wait.
    #
    # Output records deliberately do NOT travel the lifecycle EventBus (DR7):
    # ActivityLog renders every bus record for an entity as a timeline row, so
    # one row per output line would evict the real lifecycle events.
    class OutputPipeline
      Record = Struct.new(:entity_id, :generation, :run_id, :stream, :seq, :at, :text, keyword_init: true)

      NEWLINE = "\n".b

      # Per-generation view of the pipeline. GenerationStamp implements
      # #publish only and cannot decorate this protocol, so the generation is
      # attached here instead of widening it (DR6).
      class Ingress
        def initialize(generation, pipeline)
          @generation = generation
          @pipeline = pipeline
        end

        def append(entity_id, stream, chunk)
          @pipeline.append(entity_id, stream, chunk, @generation)
        end

        def begin_run(entity_id, run_id)
          @pipeline.begin_run(entity_id, run_id, @generation)
        end

        def end_run(entity_id, run_id, reason)
          @pipeline.end_run(entity_id, run_id, reason, @generation)
        end
      end

      def initialize(redactor:)
        @redactor = redactor
        @observers = []
        @entities = {}
        # Several runner threads share one pipeline, so its mutable state has
        # no single owning thread (Consistency Conventions). The lock is never
        # held across an observer call.
        @mutex = Mutex.new
      end

      def ingress(generation)
        Ingress.new(generation, self)
      end

      # Registers an object responding to #call(record). See the observer
      # contract above.
      def subscribe(observer)
        @mutex.synchronize { @observers << observer }
        observer
      end

      def append(entity_id, stream, chunk, generation = nil)
        records = @mutex.synchronize do
          state = state_for(entity_id)
          buffer = state[:buffers][stream] ||= +"".b
          buffer << chunk.to_s.b

          emit = []
          while (index = buffer.index(NEWLINE))
            line = buffer.slice!(0, index)
            # Drop the newline itself; a "\r\n" keeps its "\r" in the text —
            # stripping that is a rendering decision, not an ingress one.
            buffer.slice!(0, 1)
            emit << build_record(state, entity_id, generation, stream, line)
          end
          emit
        end

        fan_out(records)
      end

      def begin_run(entity_id, run_id, _generation = nil)
        @mutex.synchronize do
          state = state_for(entity_id)
          state[:buffers] = {}
          state[:run_id] = run_id
          state[:seq] = 0
        end
        nil
      end

      # Flushes any residual partial line on every stream as a final record,
      # then drops the entity's buffers and per-run sequence so the next run
      # cannot inherit a fragment. `reason` satisfies the sink protocol and is
      # dropped here — it is not on the Record; a consumer that needs the
      # terminal reason reads it at the sink seam (Sinks::Bundle#end_output_run).
      def end_run(entity_id, run_id, _reason, generation = nil)
        records = @mutex.synchronize do
          state = state_for(entity_id)
          state[:run_id] = run_id

          emit = state[:buffers].filter_map do |stream, buffer|
            next if buffer.empty?

            build_record(state, entity_id, generation, stream, buffer)
          end

          state[:buffers] = {}
          state[:run_id] = nil
          state[:seq] = 0
          emit
        end

        fan_out(records)
      end

      private

      # Caller holds @mutex.
      def state_for(entity_id)
        @entities[entity_id] ||= { buffers: {}, run_id: nil, seq: 0 }
      end

      # Caller holds @mutex. `raw` is a binary String without its trailing
      # newline. Scrub before redaction: a 4096-byte read can tear a multibyte
      # character, and a raise here would reach the backend's select loop.
      def build_record(state, entity_id, generation, stream, raw)
        text = @redactor.redact(raw.dup.force_encoding(Encoding::UTF_8).scrub)
        state[:seq] += 1

        Record.new(
          entity_id: entity_id,
          generation: generation,
          run_id: state[:run_id],
          stream: stream,
          seq: state[:seq],
          at: Time.now.utc.iso8601,
          text: text.freeze
        ).freeze
      end

      # Fanout happens outside the lock. Each observer is isolated on its own
      # (AC8/AD-3): a broken one is logged and never starves the others or
      # reaches the runner. StandardError only — signals and exits propagate,
      # matching Sinks::Bundle#guard.
      def fan_out(records)
        return nil if records.empty?

        observers = @mutex.synchronize { @observers.dup }
        records.each do |record|
          observers.each do |observer|
            observer.call(record)
          rescue StandardError => e
            Log.warn("[OutputPipeline] observer error isolated: #{e.class}: #{e.message}")
          end
        end
        nil
      end
    end
  end
end
