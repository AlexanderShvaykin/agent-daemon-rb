# frozen_string_literal: true

require "yaml"
require "fileutils"
require "net/http"
require "json"
require "uri"

module AgentDaemon
  class Messenger
    MAX_CONSECUTIVE_ERRORS = 3

    def initialize(config, shutdown_flag)
      @config = config
      @shutdown_flag = shutdown_flag
      @messenger_config = config.messenger
      @webhook_url = URI(@messenger_config["webhook_url"])
      @consecutive_errors = 0
    end

    def run
      Log.info("[Messenger] Thread started")

      until @shutdown_flag.value
        iterate
        wait_interval
      end

      Log.info("[Messenger] Thread stopping gracefully")
    end

    private

    def iterate
      files = Dir.glob(File.join(to_message_path, "*.yml"))
      return if files.empty?

      Log.info("[Messenger] Found #{files.size} message(s) to send")

      files.each do |file|
        break if @shutdown_flag.value
        process_file(file)
      end
    rescue => e
      Log.error("[Messenger] Unexpected error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      raise
    end

    def process_file(file)
      message_data = YAML.safe_load_file(file)
      task_key = message_data["task_key"]
      Log.info("[Messenger] Sending message for #{task_key}")

      send_to_loop(message_data)

      @consecutive_errors = 0
      move_to_sent(file)
      Log.info("[Messenger] Sent successfully: #{task_key}")
    rescue => e
      @consecutive_errors += 1
      Log.error("[Messenger] Failed to send #{message_data&.dig('task_key')} (#{@consecutive_errors}/#{MAX_CONSECUTIVE_ERRORS}): #{e.message}")

      if @consecutive_errors >= MAX_CONSECUTIVE_ERRORS
        Log.error("[Messenger] CRITICAL: #{MAX_CONSECUTIVE_ERRORS} consecutive failures, Loop API may be unavailable")
        @consecutive_errors = 0
      end
    end

    def send_to_loop(message_data)
      payload = { text: message_data["message"] }

      http = Net::HTTP.new(@webhook_url.host, @webhook_url.port)
      http.use_ssl = @webhook_url.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 10

      req = Net::HTTP::Post.new(@webhook_url)
      req["Content-Type"] = "application/json"
      req.body = payload.to_json

      response = http.request(req)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Loop webhook returned #{response.code}: #{response.body}"
      end

      Log.debug("[Messenger] Loop webhook response: #{response.body}")
    end

    def move_to_sent(file)
      sent_dir = File.join(to_message_path, "sent")
      FileUtils.mkdir_p(sent_dir)
      FileUtils.mv(file, File.join(sent_dir, File.basename(file)))
    end

    def to_message_path
      @config.message_dir
    end

    def wait_interval
      interval = @messenger_config["interval"]
      elapsed = 0
      while elapsed < interval && !@shutdown_flag.value
        sleep(1)
        elapsed += 1
      end
    end
  end
end
