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

    class NullOutput
      def append(entity_id, stream, chunk); end
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

      private

      def guard
        yield
      rescue StandardError => e
        Log.warn("[Sinks] #{@entity_id} sink error isolated: #{e.class}: #{e.message}")
      end
    end
  end
end
