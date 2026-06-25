# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentDaemon
  module Transport
    # Delivers via the Mattermost (Loop) bot REST API using one bot token.
    # Resolves human-readable channel names and usernames to ids, caching each
    # resolution for the lifetime of the daemon (ids are stable). Routes by
    # precedence: `channel_id` (posted verbatim, skipping name resolution) →
    # `user` (DM) → `channel` (named channel) → `default_channel`. An optional
    # `root_id` threads the post as a reply. stdlib only — Net::HTTP + json + uri.
    class Mattermost < Base
      def initialize(messenger_config)
        super
        @base_url = URI(messenger_config.fetch("base_url"))
        @token = messenger_config.fetch("token")
        @team = messenger_config.fetch("team")
        @default_channel = messenger_config.fetch("default_channel")
        @cache = {}
      end

      def deliver(message_data)
        explicit_id = presence(message_data["channel_id"])
        channel = presence(message_data["channel"])
        user = presence(message_data["user"])
        root_id = presence(message_data["root_id"])

        if channel && user
          raise "message specifies both channel (#{channel.inspect}) and user (#{user.inspect}); refusing to guess a destination"
        end

        channel_id =
          if explicit_id
            explicit_id
          elsif user
            dm_channel_id(user)
          elsif channel
            channel_id_by_name(channel)
          else
            channel_id_by_name(@default_channel)
          end

        body = { channel_id: channel_id, message: message_data["message"] }
        body[:root_id] = root_id if root_id
        post("/api/v4/posts", body)
      end

      private

      def bot_id
        @cache[:bot_id] ||= get("/api/v4/users/me").fetch("id")
      end

      def team_id
        @cache[:team_id] ||= get("/api/v4/teams/name/#{escape(@team)}").fetch("id")
      end

      def channel_id_by_name(name)
        (@cache[:channels] ||= {})[name] ||=
          get("/api/v4/teams/#{team_id}/channels/name/#{escape(name)}").fetch("id")
      end

      def dm_channel_id(username)
        (@cache[:dms] ||= {})[username] ||= begin
          user_id = get("/api/v4/users/username/#{escape(username)}").fetch("id")
          post("/api/v4/channels/direct", [bot_id, user_id]).fetch("id")
        end
      end

      def presence(value)
        value if value.is_a?(String) && !value.strip.empty?
      end

      def escape(segment)
        URI.encode_www_form_component(segment)
      end

      def get(path)
        request(Net::HTTP::Get.new(path))
      end

      def post(path, body)
        req = Net::HTTP::Post.new(path)
        req.body = body.to_json
        request(req)
      end

      def request(req)
        req["Authorization"] = "Bearer #{@token}"
        req["Content-Type"] = "application/json"

        response = http.request(req)

        unless response.is_a?(Net::HTTPSuccess)
          raise "Mattermost #{req.method} #{req.path} returned #{response.code}: #{response.body}"
        end

        body = response.body.to_s
        body.empty? ? {} : JSON.parse(body)
      end

      def http
        @http ||= begin
          h = Net::HTTP.new(@base_url.host, @base_url.port)
          h.use_ssl = @base_url.scheme == "https"
          h.open_timeout = 10
          h.read_timeout = 10
          h
        end
      end
    end
  end
end
