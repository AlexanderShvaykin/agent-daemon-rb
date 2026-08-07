# frozen_string_literal: true

module AgentDaemon
  # The publish seam: core components (runner, backend, messenger, reactor)
  # report state, events, and agent output only through these narrow sink
  # protocols. The defaults are no-ops, so the standalone CLI path discards
  # everything; a supervisor injects real adapters at construction without the
  # core ever knowing about it.
  module Sinks
    class NullState
      def publish(entity_id, snapshot); end
    end

    class NullEvent
      def publish(entity_id, event); end
    end

    # The output protocol is #append plus an optional run lifecycle: an
    # adapter that buffers partial lines needs to know where a run starts and
    # ends so it can flush the final newline-less line and scope a per-run
    # sequence. Bundle calls the two lifecycle methods only when the injected
    # sink responds to them, so a minimal one-method sink stays valid.
    class NullOutput
      def append(entity_id, stream, chunk); end

      def begin_run(entity_id, run_id); end

      def end_run(entity_id, run_id, reason); end
    end

    # The single injection object each core component receives. Carries the
    # component's opaque entity_id plus the three sinks, and stamps the id on
    # every record so no call site can forget it. Every publish is guarded:
    # a broken observer degrades to a warning and never reaches the caller's
    # loop (StandardError only — signals and exits still propagate).
    class Bundle
      def initialize(entity_id:, state: NullState.new, event: NullEvent.new, output: NullOutput.new)
        @entity_id = entity_id
        @state = state
        @event = event
        @output = output
      end

      def self.null(entity_id = nil)
        new(entity_id: entity_id)
      end

      def publish_state(snapshot)
        guard { @state.publish(@entity_id, snapshot) }
      end

      def publish_event(event)
        guard { @event.publish(@entity_id, event) }
      end

      def append_output(stream, chunk)
        guard { @output.append(@entity_id, stream, chunk) }
      end

      # The two run-lifecycle publishes are conditional on the sink actually
      # implementing them: a one-method output sink is still a valid sink, and
      # letting guard swallow a NoMethodError would turn every run into two
      # spurious WARN lines.
      def begin_output_run(run_id)
        return unless @output.respond_to?(:begin_run)

        guard { @output.begin_run(@entity_id, run_id) }
      end

      # `reason` is normally one of :ok/:failed/:timeout/:killed, but is nil
      # when the backend's execute body raised before a terminal reason was
      # assigned (the ensure still closes the run) — sinks must treat it as
      # opaque and tolerate nil.
      def end_output_run(run_id, reason)
        return unless @output.respond_to?(:end_run)

        guard { @output.end_run(@entity_id, run_id, reason) }
      end

      private

      def guard
        yield
      rescue StandardError => e
        Log.warn("[Sinks] #{@entity_id} sink error isolated: #{e.class}: #{e.message}")
      end
    end
  end
end
