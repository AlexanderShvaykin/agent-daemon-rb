# frozen_string_literal: true

module AgentDaemon
  class ShutdownFlag
    def initialize
      @value = false
    end

    def value
      @value
    end

    def set!
      @value = true
    end
  end

  class Daemon
    RESTART_DELAY = 60

    def initialize(config)
      @config = config
      @shutdown_flag = ShutdownFlag.new
      @threads = {}
      @runner_factories = {}
    end

    def start
      Log.info("Daemon starting")
      setup_signal_handlers
      build_runner_factories
      start_threads
      monitor_threads
      Log.info("Daemon stopped")
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

    def build_runner_factories
      @config.runners.each do |runner_config|
        name = runner_config.fetch("name")
        factory = runner_factory_for(runner_config)
        @runner_factories[thread_key(name)] = factory
      end

      # EventMachine's reactor is a process singleton, so all mattermost
      # listeners share exactly one reactor thread (a peer to the Messenger).
      # Register it only when at least one mattermost runner exists.
      mattermost_runners = @config.runners.select { |r| r.dig("trigger", "type") == "mattermost" }
      unless mattermost_runners.empty?
        @runner_factories[:mattermost_reactor] = reactor_factory_for(mattermost_runners)
      end

      if messenger_configured?
        @runner_factories[:messenger] = -> { Messenger.new(@config, @shutdown_flag) }
      else
        Log.info("[Messenger] transport is not configured, messenger thread will not start")
      end
    end

    def messenger_configured?
      Messenger.configured?(@config.messenger)
    end

    def runner_factory_for(runner_config)
      type = runner_config.fetch("trigger").fetch("type")
      message_dir = @config.message_dir
      project_path = @config.project_path
      tracker_config = @config.tracker if type == "tracker"

      case type
      when "tracker"
        -> { Runner::Tracker.new(runner_config, message_dir, project_path, @shutdown_flag, tracker_config) }
      when "file"
        -> { Runner::File.new(runner_config, message_dir, project_path, @shutdown_flag) }
      when "mattermost"
        -> { Runner::Mattermost.new(runner_config, message_dir, project_path, @shutdown_flag) }
      when "pachca"
        -> { Runner::Pachca.new(runner_config, message_dir, project_path, @shutdown_flag) }
      when "github"
        -> { Runner::GitHub.new(runner_config, message_dir, project_path, @shutdown_flag) }
      else
        raise ArgumentError, "Unknown trigger type #{type.inspect} in runner #{runner_config['name'].inspect}"
      end
    end

    # Builds the single shared reactor: one Mattermost::Listener per mattermost
    # runner (from its trigger config + the shared shutdown flag), all hosted in
    # one Mattermost::Reactor. The factory is re-invoked fresh by monitor_threads
    # on crash-restart, rebuilding the listeners and re-entering EM.run.
    def reactor_factory_for(mattermost_runners)
      lambda do
        listeners = mattermost_runners.map do |runner_config|
          Mattermost::Listener.new(runner_config.fetch("trigger"), @shutdown_flag)
        end
        Mattermost::Reactor.new(listeners, @shutdown_flag)
      end
    end

    def thread_key(runner_name)
      :"runner:#{runner_name}"
    end

    def start_threads
      @runner_factories.each do |key, factory|
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

    def monitor_threads
      until @shutdown_flag.value
        @threads.each do |name, thread|
          next if thread.alive?
          next unless thread[:crashed]

          Log.warn("[#{name}] Thread died, restarting in #{RESTART_DELAY}s...")
          wait_or_shutdown(RESTART_DELAY)
          break if @shutdown_flag.value

          factory = @runner_factories[name]
          @threads[name] = spawn_thread(name) { factory.call.run }
          Log.info("[#{name}] Thread restarted")
        end

        sleep(1) unless @shutdown_flag.value
      end

      wait_for_threads
    end

    def wait_for_threads
      Log.info("Waiting for threads to finish...")
      @threads.each_value do |thread|
        thread.join(30)
      end
    end

    def wait_or_shutdown(seconds)
      elapsed = 0
      while elapsed < seconds && !@shutdown_flag.value
        sleep(1)
        elapsed += 1
      end
    end
  end
end
