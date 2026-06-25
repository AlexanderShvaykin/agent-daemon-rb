# frozen_string_literal: true

require "eventmachine"

module AgentDaemon
  module Mattermost
    # The single shared EventMachine reactor thread that hosts every Mattermost
    # listener. EventMachine's reactor is a process singleton (`EM.run` runs once
    # per process), so the daemon registers exactly one of these — a peer to the
    # Messenger — no matter how many mattermost runners exist.
    #
    # The thread body (#run) is what the Daemon's factory invokes; it is
    # restartable by `monitor_threads` exactly like the Messenger/runner threads,
    # because it holds no un-recreatable state and re-enters EM.run fresh on every
    # call (reconnecting all clients).
    #
    # Each listener's bot id is resolved up front in #prepare_listeners (a
    # blocking HTTP call) BEFORE EM.run, so the reactor thread never blocks on
    # network IO inside the loop. A listener that fails to prepare is logged and
    # skipped without preventing the others from starting — that skip-on-failure
    # logic is the pure, directly-testable seam; the EM.run body itself is
    # smoke-test-only.
    class Reactor
      def initialize(listeners, shutdown_flag)
        @listeners = listeners
        @shutdown_flag = shutdown_flag
      end

      # Thread entrypoint. Resolves every listener's bot id, then enters the
      # reactor loop where each prepared listener opens its connection and a 1s
      # periodic timer bridges the cooperative shutdown flag into EM.stop.
      def run
        Log.info("[Mattermost::Reactor] Thread started")
        prepared = prepare_listeners

        if prepared.empty?
          Log.warn("[Mattermost::Reactor] no listeners prepared, nothing to run")
          return
        end

        EM.run do
          prepared.each(&:start)
          EM.add_periodic_timer(1) { EM.stop if @shutdown_flag.value }
        end

        Log.info("[Mattermost::Reactor] Thread stopping gracefully")
      end

      # Calls #prepare on each listener, dropping (and logging) any that raise so
      # one misconfigured bot does not take down the others. Returns the prepared
      # listeners. No EventMachine involved — directly unit-testable.
      def prepare_listeners
        @listeners.filter_map do |listener|
          listener.prepare
        rescue => e
          Log.error("[Mattermost::Reactor] skipping listener that failed to prepare: #{e.message}")
          nil
        end
      end
    end
  end
end
