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
    # pipeline wait. The same non-blocking contract covers the two optional
    # lifecycle methods below.
    #
    # #call(record) is the one MANDATORY method. #run_started(entity_id,
    # run_id, generation) and #run_finished(entity_id, run_id, reason,
    # generation) are OPTIONAL and respond_to?-guarded (DR3) — an observer
    # that implements only #call, like the read model's per-line consumers,
    # keeps working unmodified.
    #
    # Lifecycle delivery order is NOT serialized across generations: the
    # notifications run outside the pipeline mutex, so around a supervisor
    # restart an old generation's run_finished can arrive after the new
    # generation's run_started. An observer that keys state per entity must
    # guard writes by (run_id, generation) compare-and-set, the way
    # OutputBuffers does — it cannot trust arrival order alone.
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

      # Default matches Supervisor::Config's output_buffer_bytes default
      # (Story 3.4 DR9), so a pipeline built with only redactor: (every
      # pre-3.4 call site) keeps compiling unchanged.
      DEFAULT_MAX_LINE_BYTES = 262_144

      def initialize(redactor:, max_line_bytes: DEFAULT_MAX_LINE_BYTES)
        @redactor = redactor
        @max_line_bytes = max_line_bytes
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

          forced = force_emit_if_over_cap(state, entity_id, generation, stream, buffer)
          emit << forced if forced
          emit
        end

        fan_out(records)
      end

      def begin_run(entity_id, run_id, generation = nil)
        @mutex.synchronize do
          state = state_for(entity_id)
          state[:buffers] = {}
          state[:run_id] = run_id
          state[:seq] = 0
        end
        notify_lifecycle(:run_started, entity_id, run_id, generation)
        nil
      end

      # Flushes any residual partial line on every stream as a final record,
      # then drops the entity's buffers and per-run sequence so the next run
      # cannot inherit a fragment. `reason` satisfies the sink protocol and is
      # dropped here — it is not on the Record; a consumer that needs the
      # terminal reason reads it at the sink seam (Sinks::Bundle#end_output_run).
      def end_run(entity_id, run_id, reason, generation = nil)
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

        # Ordering is part of the contract (DR3): the residual-line records
        # must be inside the buffer before the run is marked terminal, or the
        # last line of a crashed agent is lost to the very consumer that
        # exists to show it.
        fan_out(records)
        notify_lifecycle(:run_finished, entity_id, run_id, reason, generation)
        nil
      end

      private

      # Caller holds @mutex. `buffer` is the binary partial-line buffer for
      # this (entity_id, stream).
      #
      # The cut must not create a redaction hole (AD-8): redact the WHOLE
      # accumulated buffer FIRST, before deciding where to cut. Any secret
      # already fully present in `buffer` is caught right here regardless of
      # where the cut later falls, so slicing the now-redacted text afterward
      # can never split an already-complete secret — cutting apart
      # "...x[RE" / "DACTED]..." leaks nothing, since the marker carries no
      # secret bytes. Only a still-incomplete occurrence — one that needs
      # more bytes from a future append to finish — can remain unmatched, and
      # holding back the redactor's longest known value minus one byte is
      # exactly enough: such an occurrence cannot need more than
      # max_value_length total bytes, so if it is not yet complete it
      # necessarily starts within that trailing span and is matched whole on
      # a later emission. Capped at half of max_line_bytes so a
      # pathologically long secret cannot stall retention — the Master warns
      # at boot when a known secret exceeds that cap, because an incomplete
      # occurrence longer than the cap CAN be cut and leak.
      #
      # Two carve-outs keep the whole-buffer pass safe and bounded:
      # - A torn trailing multibyte sequence (a chunk boundary mid-character)
      #   is excluded from the pass entirely and kept raw: scrubbing it now
      #   would rewrite it to U+FFFD forever, and a known secret containing
      #   that character would then never match again — a permanent
      #   redaction hole, not a cosmetic one.
      # - The redacted remainder is stored back even when nothing can be
      #   emitted (cut == 0, reachable when redaction collapses the over-cap
      #   buffer below hold_back): keeping the raw form instead would
      #   re-redact an ever-growing buffer on every append without ever
      #   shrinking it.
      def force_emit_if_over_cap(state, entity_id, generation, stream, buffer)
        return nil unless buffer.bytesize > @max_line_bytes

        pending = trailing_incomplete_sequence(buffer)
        stable = buffer.byteslice(0, buffer.bytesize - pending.bytesize)
        redacted = @redactor.redact(stable.force_encoding(Encoding::UTF_8).scrub)

        hold_back = [@redactor.max_value_length - 1, 0].max
        hold_back = [hold_back, @max_line_bytes / 2].min
        cut = character_floor(redacted, [redacted.bytesize - hold_back, 0].max)

        forced_text = cut.zero? ? nil : redacted.byteslice(0, cut)
        buffer.replace(redacted.byteslice(cut, redacted.bytesize - cut).b << pending)
        return nil unless forced_text

        finalize_record(state, entity_id, generation, stream, forced_text.freeze)
      end

      # Caller holds @mutex. Returns the trailing bytes of the binary
      # `buffer` that form an incomplete UTF-8 sequence still waiting for its
      # continuation bytes, or an empty binary string when the buffer ends on
      # a complete character or on bytes no future append can complete
      # (those are left for scrub). At most 3 bytes — a torn character can
      # only sit at the very end, since earlier tears were healed by the
      # appends that followed them.
      def trailing_incomplete_sequence(buffer)
        1.upto([buffer.bytesize, 3].min) do |i|
          byte = buffer.getbyte(buffer.bytesize - i)
          next if (byte & 0xC0) == 0x80

          break unless byte >= 0xC0

          expected = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
          return buffer.byteslice(buffer.bytesize - i, i) if expected > i

          break
        end
        +"".b
      end

      # `text` is valid UTF-8 (already scrubbed). Walks `index` back to the
      # nearest character boundary so a byteslice at the result can never
      # split a multibyte character — finalize_record's "already scrubbed"
      # contract means an invalid fragment would reach consumers unhealed.
      def character_floor(text, index)
        index -= 1 while index.positive? && (text.getbyte(index) & 0xC0) == 0x80
        index
      end

      # Caller holds @mutex.
      def state_for(entity_id)
        @entities[entity_id] ||= { buffers: {}, run_id: nil, seq: 0 }
      end

      # Caller holds @mutex. `raw` is a binary String without its trailing
      # newline. Scrub before redaction: a 4096-byte read can tear a multibyte
      # character, and a raise here would reach the backend's select loop.
      def build_record(state, entity_id, generation, stream, raw)
        text = @redactor.redact(raw.dup.force_encoding(Encoding::UTF_8).scrub)
        finalize_record(state, entity_id, generation, stream, text)
      end

      # Caller holds @mutex. `text` is already scrubbed and redacted.
      def finalize_record(state, entity_id, generation, stream, text)
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

        observers = snapshot_observers
        records.each do |record|
          isolate_each(observers) { |observer| observer.call(record) }
        end
        nil
      end

      # Same isolation shape as #fan_out, for the two optional lifecycle
      # methods (DR3): respond_to?-guarded, called outside @mutex, one
      # observer's fault logged and never starving the others.
      def notify_lifecycle(method, *args)
        observers = snapshot_observers
        isolate_each(observers) do |observer|
          next unless observer.respond_to?(method)

          observer.public_send(method, *args)
        end
        nil
      end

      def snapshot_observers
        @mutex.synchronize { @observers.dup }
      end

      def isolate_each(observers)
        observers.each do |observer|
          yield observer
        rescue StandardError => e
          Log.warn("[OutputPipeline] observer error isolated: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
