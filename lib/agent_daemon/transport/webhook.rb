# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentDaemon
  module Transport
    # Posts to a single fixed incoming webhook URL. Routing fields (channel/user)
    # are ignored — a webhook is one fixed destination, so the same message YAML
    # is portable across transports.
    class Webhook < Base
      def initialize(messenger_config)
        super
        @webhook_url = URI(messenger_config["webhook_url"])
      end

      def deliver(message_data)
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
          raise "Webhook returned #{response.code}: #{response.body}"
        end

        Log.debug("[Messenger] Webhook response: #{response.body}")
      end
    end
  end
end
