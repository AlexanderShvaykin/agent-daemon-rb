# frozen_string_literal: true

require "logger"
require "fileutils"

module AgentDaemon
  module Log
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

    def self.info(msg)    = logger.info(msg)
    def self.warn(msg)    = logger.warn(msg)
    def self.error(msg)   = logger.error(msg)
    def self.debug(msg)   = logger.debug(msg)
  end
end
