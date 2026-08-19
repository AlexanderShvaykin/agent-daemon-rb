# frozen_string_literal: true

module AgentDaemon
  module Supervisor
    class RestartControl
      def initialize(supervisors:, shutdown_flag:)
        @supervisors = supervisors.dup.freeze
        @shutdown_flag = shutdown_flag
      end

      def request_restart(id, actor:)
        supervisor = @supervisors[id]
        return unless supervisor
        return :refused if @shutdown_flag.value

        # MRI makes the Integer read atomic. Read it before enqueueing: during
        # a coalescing window the generation has not moved, so every coalesced
        # requester computes the same target (AC8). It is not a promise — a
        # tick draining an earlier intent between the read and the enqueue can
        # still make the number one behind, which is why the page gates the
        # flash on the read model rather than trusting this value.
        target_generation = supervisor.generation + 1
        supervisor.request_restart(actor)
        target_generation
      end
    end
  end
end
