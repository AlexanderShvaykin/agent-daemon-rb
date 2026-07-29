# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "yaml"
require "time"
require "fileutils"

require "faye/websocket"

module AgentDaemon
  module Mattermost
    # Per-runner WebSocket handler hosted inside the shared EventMachine reactor.
    # It does NOT own a thread; the Reactor creates the faye client and drives the
    # callbacks. Responsibilities: resolve the bot id once (blocking, in #prepare,
    # before the reactor loop), connect + authenticate, filter `posted` events
    # (not-self + allowlisted DM sender or channel mention), de-dup by post id, and
    # write a `<post_id>.yml` work-item into the inbox for the consumer runner.
    #
    # The pure seams — #prepare, #on_message, #handle_event — are directly
    # callable without a live reactor or socket and are what the tests exercise.
    # The faye client creation and reconnect/backoff timers live in #start and
    # private helpers that are only reached on a real reactor.
    class Listener
      INITIAL_BACKOFF = 1
      MAX_BACKOFF = 30

      def initialize(trigger_config, shutdown_flag)
        @base_url = URI(trigger_config.fetch("base_url"))
        @token = trigger_config.fetch("token")
        @team = trigger_config.fetch("team")
        @channels = Array(trigger_config.fetch("channels"))
        @direct_users = Array(trigger_config["direct_users"])
        @input_dir = trigger_config.fetch("input_dir")
        @archive_dir = trigger_config.fetch("archive_dir")
        @failed_dir = trigger_config.fetch("failed_dir")
        @shutdown_flag = shutdown_flag

        @bot_id = nil
        @team_id = nil
        @backoff = INITIAL_BACKOFF
        @ws = nil
      end

      attr_reader :bot_id, :team_id, :backoff

      # Blocking bot-id + team-id resolution. Called by the reactor BEFORE EM.run
      # so the reactor thread never blocks on network IO. Raises on failure so
      # the reactor can log-and-skip this listener.
      def prepare
        @bot_id = resolve_bot_id
        @team_id = resolve_team_id
        self
      end

      # Opens the faye client and wires the open/message/close callbacks. Runs on
      # the reactor thread only; not exercised by unit tests.
      def start
        @ws = build_client

        @ws.on(:open) { handle_open }
        @ws.on(:message) { |event| on_message(event.data) }
        @ws.on(:close) { handle_close }
        @ws.on(:error) { |event| Log.warn("[#{log_tag}] websocket error: #{event.message}") }
        nil
      end

      # Parses a raw WebSocket frame and routes it. Swallows non-JSON frames so a
      # malformed frame can never raise or write. Directly callable in tests.
      def on_message(raw)
        event = JSON.parse(raw)
        handle_event(event) if event.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      # Applies the route filter + de-dup and writes the work-item for a qualifying
      # `posted` event. Directly callable in tests.
      def handle_event(event)
        # `hello` confirms a successful authentication — connection bookkeeping
        # only, never a work-item. Reset the reconnect backoff here (not on open)
        # so a bad/expired token, which still opens the socket, keeps backing off.
        if event["event"] == "hello"
          @backoff = INITIAL_BACKOFF
          return
        end

        return unless event["event"] == "posted"

        data = event["data"]
        return unless data.is_a?(Hash)

        post = parse_json_object(data["post"])
        return unless post

        post_id = post["id"]
        return unless post_id.is_a?(String) && !post_id.empty?

        return if post["user_id"] == @bot_id
        if data["channel_type"] == "D"
          return unless @direct_users.include?(username(data["sender_name"]))
        else
          return unless data["team_id"] == @team_id
          return unless @channels.include?(data["channel_name"])
          return unless mentions(data).include?(@bot_id)
        end
        return if already_seen?(post_id)

        write_work_item(post, data)
      end

      private

      def write_work_item(post, data)
        FileUtils.mkdir_p(@input_dir)

        root_id = post["root_id"]
        root_id = post["id"] if root_id.nil? || root_id.empty?

        item = {
          "message" => post["message"],
          "channel_id" => post["channel_id"],
          "root_id" => root_id,
          "sender" => data["sender_name"],
          "channel_name" => data["channel_name"],
          "post_id" => post["id"],
          "created_at" => Time.now.utc.iso8601
        }

        path = ::File.join(@input_dir, "#{post['id']}.yml")
        ::File.write(path, YAML.dump(item))
        Log.info("[#{log_tag}] wrote work-item #{post['id']}.yml from #{data['sender_name']} in #{data['channel_name']}")
      end

      def already_seen?(post_id)
        name = "#{post_id}.yml"
        [@input_dir, @archive_dir, @failed_dir].any? { |dir| ::File.exist?(::File.join(dir, name)) }
      end

      # data.mentions is a JSON-encoded string array of user ids, and is absent
      # when no one is mentioned (treat absent as empty).
      def mentions(data)
        parsed = parse_json_value(data["mentions"])
        parsed.is_a?(Array) ? parsed : []
      end

      def username(sender_name)
        sender_name.to_s.delete_prefix("@")
      end

      def parse_json_object(raw)
        value = parse_json_value(raw)
        value.is_a?(Hash) ? value : nil
      end

      def parse_json_value(raw)
        return nil unless raw.is_a?(String) && !raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      # ---- reactor-only wiring (not unit-tested) ----

      def handle_open
        Log.info("[#{log_tag}] websocket open, sending authentication_challenge")
        @ws.send(JSON.generate(seq: 1, action: "authentication_challenge", data: { token: @token }))
        # Backoff is reset only once the server confirms auth with a `hello`
        # event (see #handle_event), not here — a bad token still opens the
        # socket and would otherwise hot-loop at the 1s floor.
      end

      def handle_close
        @ws = nil
        return if @shutdown_flag.value

        delay = @backoff
        @backoff = [@backoff * 2, MAX_BACKOFF].min
        Log.warn("[#{log_tag}] websocket closed, reconnecting in #{delay}s")
        EM.add_timer(delay) { reconnect }
      end

      def reconnect
        return if @shutdown_flag.value

        start
      end

      def build_client
        Faye::WebSocket::Client.new(websocket_url, nil, ping: 30)
      end

      def websocket_url
        scheme = @base_url.scheme == "https" ? "wss" : "ws"
        port = @base_url.port
        host = port ? "#{@base_url.host}:#{port}" : @base_url.host
        "#{scheme}://#{host}/api/v4/websocket"
      end

      def log_tag
        "Mattermost::Listener #{@base_url.host}"
      end

      # ---- blocking HTTP (prepare only) ----

      def resolve_bot_id
        get_json("/api/v4/users/me").fetch("id")
      end

      def resolve_team_id
        get_json("/api/v4/teams/name/#{escape(@team)}").fetch("id")
      end

      def get_json(path)
        req = Net::HTTP::Get.new(path)
        req["Authorization"] = "Bearer #{@token}"
        req["Content-Type"] = "application/json"

        response = http.request(req)
        unless response.is_a?(Net::HTTPSuccess)
          raise "Mattermost GET #{path} returned #{response.code}: #{response.body}"
        end

        JSON.parse(response.body.to_s)
      end

      def escape(segment)
        URI.encode_www_form_component(segment)
      end

      def http
        h = Net::HTTP.new(@base_url.host, @base_url.port)
        h.use_ssl = @base_url.scheme == "https"
        h.open_timeout = 10
        h.read_timeout = 10
        h
      end
    end
  end
end
