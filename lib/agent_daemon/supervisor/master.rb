# frozen_string_literal: true

require_relative "../../agent_daemon"
require_relative "config"

module AgentDaemon
  module Supervisor
    # Boots every workflow's runners and Messenger as threads in one MRI
    # process, sharing exactly one ShutdownFlag (AD-1/FR5) and exactly one
    # EventMachine reactor across all workflows' mattermost runners (AD-13).
    #
    # Each factory constructs the exact same core classes the standalone
    # Daemon uses, from each workflow's own unchanged AgentDaemon::Config,
    # plus a null-sink bundle carrying the (workflow, runner) composite
    # identity — AC4's per-runner behavioral guarantee holds by construction.
    #
    # NOT crash-restart: a crashed thread stays dead here (Story 1.5 builds
    # the per-entity supervisor that consumes the :crashed/:crash_error flags
    # this class still sets via #spawn_thread).
    class Master
      def initialize(supervisor_config)
        @config = supervisor_config
        @shutdown_flag = AgentDaemon::ShutdownFlag.new
        @threads = {}
        @factories = {}
      end

      def start
        Log.info("Supervisor starting (#{@config.workflows.size} workflow(s))")
        setup_signal_handlers
        build_factories
        start_threads
        wait_until_shutdown
        wait_for_threads
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

      def wait_until_shutdown
        sleep(1) until @shutdown_flag.value
      end

      def wait_for_threads
        Log.info("Waiting for threads to finish...")
        @threads.each_value { |thread| thread.join(30) }
      end

      def build_factories
        @config.workflows.each do |workflow|
          build_runner_factories(workflow)
          build_messenger_factory(workflow)
        end

        build_reactor_factory
      end

      def build_runner_factories(workflow)
        workflow[:config].runners.zip(workflow[:identities]) do |runner_config, identity|
          @factories[identity.thread_key] = runner_factory_for(workflow[:config], runner_config, identity)
        end
      end

      def build_messenger_factory(workflow)
        unless Messenger.configured?(workflow[:config].messenger)
          Log.info("[Messenger] transport is not configured for workflow #{workflow[:name]}, messenger thread will not start")
          return
        end

        entity_id = "messenger:#{workflow[:name]}"
        @factories[:"messenger:#{workflow[:name]}"] =
          -> { Messenger.new(workflow[:config], @shutdown_flag, sinks: Sinks::Bundle.null(entity_id)) }
      end

      # Mirrors Daemon#runner_factory_for's type dispatch exactly, plus a
      # null-sink bundle stamped with the runner's composite identity. Kept
      # duplicated rather than shared with Daemon (see Dev Notes design
      # decision 4) — 1.5 reshapes supervision anyway.
      def runner_factory_for(config, runner_config, identity)
        type = runner_config.fetch("trigger").fetch("type")
        message_dir = config.message_dir
        project_path = config.project_path
        tracker_config = config.tracker if type == "tracker"
        sinks = Sinks::Bundle.null(identity)

        case type
        when "tracker"
          -> { Runner::Tracker.new(runner_config, message_dir, project_path, @shutdown_flag, tracker_config, sinks: sinks) }
        when "file"
          -> { Runner::File.new(runner_config, message_dir, project_path, @shutdown_flag, sinks: sinks) }
        when "mattermost"
          -> { Runner::Mattermost.new(runner_config, message_dir, project_path, @shutdown_flag, sinks: sinks) }
        else
          raise ArgumentError, "Unknown trigger type #{type.inspect} in runner #{runner_config['name'].inspect}"
        end
      end

      # Generalizes Daemon#reactor_factory_for from per-config to fleet-wide:
      # EventMachine's reactor is a process singleton, so every workflow's
      # mattermost runners share exactly one reactor thread, no matter which
      # workflow they belong to.
      def build_reactor_factory
        mattermost_runners = @config.workflows.flat_map do |workflow|
          workflow[:config].runners.select { |r| r.dig("trigger", "type") == "mattermost" }
        end
        return if mattermost_runners.empty?

        @factories[:mattermost_reactor] = lambda do
          listeners = mattermost_runners.map do |runner_config|
            Mattermost::Listener.new(runner_config.fetch("trigger"), @shutdown_flag)
          end
          Mattermost::Reactor.new(listeners, @shutdown_flag, sinks: Sinks::Bundle.null("mattermost_reactor"))
        end
      end

      def start_threads
        @factories.each do |key, factory|
          @threads[key] = spawn_thread(key) { factory.call.run }
        end
      end

      def spawn_thread(name, &block)
        Thread.new do
          Thread.current.name = name.to_s
          block.call
        rescue => e
          Log.error("[#{name}] Thread crashed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
          Thread.current[:crashed] = true
          Thread.current[:crash_error] = e
        end
      end
    end
  end
end
