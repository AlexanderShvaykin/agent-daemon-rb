# frozen_string_literal: true

require "logger"
require "fileutils"

module AgentDaemon
  module Log
    # Maps our public severity names to ::Logger::Severity ints, so the
    # ambient per-tag level gate (below) compares on the same scale the
    # supervisor resolves a workflow's `logging.level` string into.
    SEVERITY = {
      debug: ::Logger::DEBUG,
      info: ::Logger::INFO,
      warn: ::Logger::WARN,
      error: ::Logger::ERROR
    }.freeze

    def self.setup(config)
      log_config = config.logging
      output = log_config["output"] || "file"

      logger = if output == "stdout"
        ::Logger.new($stdout)
      else
        log_path = log_config["file"]
        FileUtils.mkdir_p(File.dirname(log_path))
        ::Logger.new(log_path, 5, 10 * 1024 * 1024)
      end

      logger.level = ::Logger.const_get(log_config["level"].upcase)
      logger.formatter = if output == "stdout"
        proc { |severity, _datetime, _progname, msg| "#{severity}: #{msg}\n" }
      else
        proc { |severity, datetime, _progname, msg| "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n" }
      end

      @logger = logger
    end

    def self.logger
      @logger || ::Logger.new($stdout)
    end

    # Install a pre-built logger directly (bypasses core #setup's Config
    # dependency). Without this, callers without a core Config fall back to
    # #logger's default, which allocates a fresh Logger.new($stdout) per call
    # at DEBUG level — runner Log.debug full-output dumps would flood stdout.
    def self.use(logger) = @logger = logger

    # Ambient per-thread tag+generation+level context (Story 1.7). The
    # supervisor binds this on an entity's own thread at spawn
    # (RunnerSupervisor#spawn!) so every Log.* call from Runner/Backend/
    # Messenger/Listener is tagged without touching any of their call sites.
    # Absent on the standalone daemon's threads, so Log.* there delegates
    # exactly as before (AC4/NFR5) — this is the ONLY thing that must stay
    # true for the standalone CLI to be untouched.
    def self.bind_context(tag:, generation:, level: nil)
      Thread.current[:ad_log_context] = { tag: tag, generation: generation, level: level }
    end

    def self.clear_context
      Thread.current[:ad_log_context] = nil
    end

    # Single source of format truth for tag+generation prefixes — reused
    # verbatim by the supervisor's own explicit master-thread lifecycle
    # lines (no ambient context there; see RunnerSupervisor#log_prefix).
    def self.tag_prefix(tag, generation) = "[#{tag} gen#{generation}]"

    def self.info(msg)  = emit(:info, msg)
    def self.warn(msg)  = emit(:warn, msg)
    def self.error(msg) = emit(:error, msg)
    def self.debug(msg) = emit(:debug, msg)

    def self.emit(severity, msg)
      context = Thread.current[:ad_log_context]
      if context
        return if context[:level] && SEVERITY.fetch(severity) < context[:level]

        msg = "#{tag_prefix(context[:tag], context[:generation])} #{msg}"
      end
      logger.public_send(severity, msg)
    end
    private_class_method :emit
  end
end
