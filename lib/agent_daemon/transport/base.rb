# frozen_string_literal: true

module AgentDaemon
  module Transport
    VALID_TYPES = %w[webhook mattermost].freeze

    # Dispatch on messenger_config["type"] (default "webhook"), mirroring
    # Backend.for. An unknown type raises ArgumentError listing valid values.
    def self.for(messenger_config)
      type = messenger_config.fetch("type", "webhook")
      case type
      when "webhook"
        Webhook.new(messenger_config)
      when "mattermost"
        Mattermost.new(messenger_config)
      else
        raise ArgumentError, "Unsupported messenger type #{type.inspect}. Valid values: #{VALID_TYPES.join(', ')}"
      end
    end

    class Base
      def initialize(messenger_config)
        @messenger_config = messenger_config
      end

      # Deliver one message. message_data is the parsed YAML hash written by the
      # agent (keys: "message", optional "channel"/"user", "task_key", ...).
      # Raises on failure; the return value is not relied upon.
      def deliver(_message_data)
        raise NotImplementedError, "#{self.class}#deliver is not implemented"
      end
    end
  end
end
