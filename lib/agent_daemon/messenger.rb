# frozen_string_literal: true

require "yaml"
require "fileutils"

module AgentDaemon
  class Messenger
    MAX_CONSECUTIVE_ERRORS = 3

    # The Messenger thread starts only when the selected transport has what it
    # needs. config.rb validation already guarantees the mattermost keys are
    # present (or the config raised); webhook_url stays optional, so an empty
    # one simply leaves the messenger disabled.
    def self.configured?(messenger_config)
      case messenger_config["type"]
      when "mattermost"
        Config::MATTERMOST_REQUIRED.all? { |key| !messenger_config[key].to_s.empty? }
      else
        !messenger_config["webhook_url"].to_s.empty?
      end
    end

    def initialize(config, shutdown_flag, sinks: nil, cancel_flag: nil)
      @config = config
      @shutdown_flag = shutdown_flag
      @cancel_flag = cancel_flag
      @sinks = sinks || Sinks::Bundle.null("messenger")
      @messenger_config = config.messenger
      @transport = Transport.for(@messenger_config)
      @consecutive_errors = 0
    end

    def run
      Log.info("[Messenger] Thread started")
      @sinks.publish_state(status: :running)

      until stopping?
        iterate
        wait_interval
      end

      @sinks.publish_state(status: :stopped) unless cancelling?
      Log.info("[Messenger] Thread stopping gracefully")
    end

    private

    def iterate
      files = Dir.glob(File.join(to_message_path, "*.{yml,yaml}")).sort
      return if files.empty?

      Log.info("[Messenger] Found #{files.size} message(s) to send")

      files.each do |file|
        break if stopping?
        process_file(file)
      end
    rescue => e
      Log.error("[Messenger] Unexpected error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      raise
    end

    def process_file(file)
      message_data = YAML.safe_load_file(file)
      route_system_alert(message_data)
      task_key = message_data["task_key"]
      Log.info("[Messenger] Sending message for #{task_key}")

      @transport.deliver(message_data)

      @consecutive_errors = 0
      move_to_sent(file)
      Log.info("[Messenger] Sent successfully: #{task_key}")
    rescue => e
      @consecutive_errors += 1
      Log.error("[Messenger] Failed to send #{message_data&.dig('task_key')} (#{@consecutive_errors}/#{MAX_CONSECUTIVE_ERRORS}): #{e.message}")

      if @consecutive_errors >= MAX_CONSECUTIVE_ERRORS
        Log.error("[Messenger] CRITICAL: #{MAX_CONSECUTIVE_ERRORS} consecutive failures, message transport may be unavailable")
        @consecutive_errors = 0
      end
    end

    def move_to_sent(file)
      sent_dir = File.join(to_message_path, "sent")
      FileUtils.mkdir_p(sent_dir)
      FileUtils.mv(file, File.join(sent_dir, File.basename(file)))
    end

    def route_system_alert(message_data)
      return unless message_data["system_alert"]
      return unless @messenger_config["type"] == "mattermost"

      alerts = @messenger_config["alerts"]
      return unless alerts

      message_data.delete("channel_id")
      message_data.delete("channel")
      message_data.delete("user")
      message_data.delete("root_id")
      destination = alerts.key?("user") ? "user" : "channel"
      message_data[destination] = alerts.fetch(destination)
    end

    def to_message_path
      @config.message_dir
    end

    def wait_interval
      interval = @messenger_config["interval"]
      elapsed = 0
      while elapsed < interval && !stopping?
        sleep(1)
        elapsed += 1
      end
    end

    def stopping?
      @shutdown_flag.value || @cancel_flag&.value
    end

    def cancelling?
      @cancel_flag&.value && !@shutdown_flag.value
    end
  end
end
