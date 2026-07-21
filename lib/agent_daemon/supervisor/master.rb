# frozen_string_literal: true

require_relative "../../agent_daemon"
require_relative "config"
require_relative "runner_supervisor"

module AgentDaemon
  module Supervisor
    # Boots every workflow's runners and Messenger as threads in one MRI
    # process, sharing exactly one ShutdownFlag (AD-1/FR5) and exactly one
    # EventMachine reactor across all workflows' mattermost runners (AD-13).
    #
    # Each factory constructs the exact same core classes the standalone
    # Daemon uses, from each workflow's own unchanged AgentDaemon::Config,
    # plus a per-generation sink bundle carrying the (workflow, runner)
    # composite identity — AC4's per-runner behavioral guarantee holds by
    # construction.
    #
    # Crash auto-restart, generation minting, and the non-blocking restart
    # delay all live one layer down: each thread key is wrapped in a
    # RunnerSupervisor (Story 1.5), and #start drives all of them through a
    # single non-blocking tick loop instead of the old idle wait.
    class Master
      # Per-thread join timeout for the drain (AC2). Exposed as the default of
      # an initialize kwarg so tests can inject a short timeout instead of
      # waiting out the real 30s — same pattern as RunnerSupervisor's
      # RESTART_DELAY / restart_delay:.
      JOIN_TIMEOUT = 30

      def initialize(supervisor_config, join_timeout: JOIN_TIMEOUT)
        @config = supervisor_config
        @join_timeout = join_timeout
        @shutdown_flag = AgentDaemon::ShutdownFlag.new
        @entity_factories = {}
        @entity_ids = {}
        @log_levels = {}
        @supervisors = {}
      end

      def start
        Log.info("Supervisor starting (#{@config.workflows.size} workflow(s))")
        setup_signal_handlers
        build_factories
        build_supervisors
        start_supervisors
        begin
          supervise_until_shutdown
          wait_for_threads
        ensure
          # The sweep is the last-resort orphan guard, so it must also run when
          # supervision or the drain raised — that is exactly when an agent is
          # most likely to be left behind.
          finalize_supervisors
          sweep_orphaned_agents
        end
        Log.info("Supervisor stopped")
      end

      private

      def setup_signal_handlers
        %w[INT TERM].each do |signal|
          trap(signal) do
            @shutdown_flag.set!
            $stderr.write("Received SIG#{signal}, shutting down...\n")
          end
        end
      end

      def build_supervisors
        @entity_factories.each do |key, factory|
          @supervisors[key] = RunnerSupervisor.new(
            @entity_ids.fetch(key),
            entity_factory: factory,
            shutdown_flag: @shutdown_flag,
            log_level: @log_levels[key]
          )
        end
      end

      def start_supervisors
        @supervisors.each_value(&:spawn!)
      end

      # The only driver of every entity's state machine: non-blocking, ~1/s.
      # Replaces the old sleep(1) until flag idle wait — a crashed entity's
      # restart delay is now a recorded deadline inside its own supervisor,
      # never a blocking sleep here (AC1/C6).
      def supervise_until_shutdown
        until @shutdown_flag.value
          @supervisors.each_value(&:tick)
          sleep(1)
        end
      end

      # AC2 fixes the timeout PER THREAD, so the worst case is sequential:
      # N wedged entities take N * @join_timeout before the sweep below runs.
      # Operator note: set the unit's TimeoutStopSec comfortably above that
      # (90-120s for a ~20-runner fleet) or systemd's own SIGKILL preempts the
      # drain and the orphan sweep.
      def wait_for_threads
        Log.info("Waiting for threads to finish...")
        @supervisors.each do |_key, supervisor|
          thread = supervisor.thread
          next unless thread

          thread.join(@join_timeout)
          Log.warn("#{supervisor.log_prefix} thread did not finish within #{@join_timeout}s") if thread.alive?
        end
      end

      # One last tick after the drain: an entity whose thread ended during
      # shutdown would otherwise stay frozen at {status: :running} in every
      # state sink, because the supervision loop exits the moment the flag is
      # set and never observes the death. Stragglers are still alive, so their
      # tick is a no-op.
      def finalize_supervisors
        @supervisors.each do |_key, supervisor|
          supervisor.tick
        rescue => e
          Log.error("#{supervisor.log_prefix} final tick failed: #{e.message}")
        end
      end

      # Orphan sweep (Task 4): a thread still alive after the join above never
      # observed the shared flag inside its own poll loop (wedged outside the
      # backend's select loop). Force-kill its last known in-flight agent
      # process group directly — never Thread#kill (AD-2a); the thread itself
      # is abandoned to process exit.
      def sweep_orphaned_agents
        @supervisors.each do |_key, supervisor|
          thread = supervisor.thread
          next unless thread&.alive?

          entity = supervisor.entity
          unless entity.respond_to?(:kill_in_flight_agent)
            Log.warn("#{supervisor.log_prefix} straggler #{entity.class} owns no agent to sweep, abandoning it to process exit")
            next
          end

          Log.warn("#{supervisor.log_prefix} sweeping orphaned agent after join timeout")
          begin
            entity.kill_in_flight_agent
          rescue => e
            # One entity's failure must not strand the rest of the fleet.
            Log.error("#{supervisor.log_prefix} sweep failed: #{e.message}")
          end
        end
      end

      def build_factories
        @config.workflows.each do |workflow|
          build_runner_factories(workflow)
          build_messenger_factory(workflow)
        end

        build_reactor_factory
      end

      def build_runner_factories(workflow)
        log_level = resolve_log_level(workflow[:config].logging["level"])
        workflow[:config].runners.zip(workflow[:identities]) do |runner_config, identity|
          key = identity.thread_key
          @entity_factories[key] = runner_factory_for(workflow[:config], runner_config)
          @entity_ids[key] = identity
          @log_levels[key] = log_level
        end
      end

      def build_messenger_factory(workflow)
        unless Messenger.configured?(workflow[:config].messenger)
          Log.info("[Messenger] transport is not configured for workflow #{workflow[:name]}, messenger thread will not start")
          return
        end

        config = workflow[:config]
        key = :"messenger:#{workflow[:name]}"
        @entity_factories[key] = ->(bundle) { Messenger.new(config, @shutdown_flag, sinks: bundle) }
        @entity_ids[key] = "messenger:#{workflow[:name]}"
        @log_levels[key] = resolve_log_level(config.logging["level"])
      end

      # Maps a workflow's `logging.level` string (e.g. "info") to a
      # ::Logger::Severity int via Log::SEVERITY — the same map the per-tag
      # gate compares against (Story 1.7 AC2). Validated against the known
      # level names so a null or typo'd level surfaces as a clear ConfigError
      # at boot instead of a cryptic NoMethodError/NameError from the master
      # thread (which would abort the whole fleet). Only the four gated
      # severities are supported here — that is the per-tag vocabulary.
      def resolve_log_level(level_string)
        level = level_string.to_s.downcase.to_sym
        unless Log::SEVERITY.key?(level)
          raise AgentDaemon::ConfigError,
                "invalid logging.level #{level_string.inspect} " \
                "(expected one of: #{Log::SEVERITY.keys.join(', ')})"
        end
        Log::SEVERITY.fetch(level)
      end

      # Mirrors Daemon#runner_factory_for's type dispatch exactly, but as a
      # 1-arg callable receiving the per-generation Sinks::Bundle a
      # RunnerSupervisor builds on each (re)spawn (Story 1.5). Kept
      # duplicated rather than shared with Daemon (see Dev Notes design
      # decision 4).
      def runner_factory_for(config, runner_config)
        type = runner_config.fetch("trigger").fetch("type")
        message_dir = config.message_dir
        project_path = config.project_path
        tracker_config = config.tracker if type == "tracker"

        case type
        when "tracker"
          ->(bundle) { Runner::Tracker.new(runner_config, message_dir, project_path, @shutdown_flag, tracker_config, sinks: bundle) }
        when "file"
          ->(bundle) { Runner::File.new(runner_config, message_dir, project_path, @shutdown_flag, sinks: bundle) }
        when "mattermost"
          ->(bundle) { Runner::Mattermost.new(runner_config, message_dir, project_path, @shutdown_flag, sinks: bundle) }
        else
          raise ArgumentError, "Unknown trigger type #{type.inspect} in runner #{runner_config['name'].inspect}"
        end
      end

      # Generalizes Daemon#reactor_factory_for from per-config to fleet-wide:
      # EventMachine's reactor is a process singleton, so every workflow's
      # mattermost runners share exactly one reactor thread, no matter which
      # workflow they belong to. Its supervisor's respawn rebuilds ALL
      # listeners (accepted AD-13 caveat) — a mattermost runner's own
      # supervisor cycles only its file-poll consumer, never the listener.
      def build_reactor_factory
        mattermost_runners = @config.workflows.flat_map do |workflow|
          workflow[:config].runners.select { |r| r.dig("trigger", "type") == "mattermost" }
        end
        return if mattermost_runners.empty?

        @entity_factories[:mattermost_reactor] = lambda do |bundle|
          listeners = mattermost_runners.map do |runner_config|
            Mattermost::Listener.new(runner_config.fetch("trigger"), @shutdown_flag)
          end
          Mattermost::Reactor.new(listeners, @shutdown_flag, sinks: bundle)
        end
        @entity_ids[:mattermost_reactor] = "mattermost_reactor"
        # The reactor is fleet-wide (AD-13) — one entity spanning every
        # workflow's mattermost runners — so it has no single owning workflow
        # to take a level from. Default to INFO; a listener's own lines
        # therefore carry [mattermost_reactor gen<N>], not a per-workflow tag
        # (accepted AD-13 consequence).
        @log_levels[:mattermost_reactor] = ::Logger::INFO
      end
    end
  end
end
