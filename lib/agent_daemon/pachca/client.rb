# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentDaemon
  module Pachca
    # Thin stdlib client over Pachca's REST API, covering exactly what the
    # poller trigger needs: read the bot's retained event history, and
    # acknowledge one event by deleting it.
    #
    # Pachca has no realtime API — outgoing webhooks and this history endpoint
    # are the only two ways to receive events — and the history needs no public
    # URL at all (the bot's "save event history" setting works with an empty
    # Webhook URL). Read plus delete makes it a queue with an explicit ack,
    # which is why the trigger is an ordinary poller and not an HTTP server.
    class Client
      DEFAULT_BASE_URL = "https://api.pachca.com"
      API_PREFIX       = "/api/shared/v1"
      DEFAULT_BACKOFF  = 60
      DEFAULT_LIMIT    = 50

      def initialize(config)
        @token           = config.fetch("token")
        @base_url        = URI(config.fetch("base_url", DEFAULT_BASE_URL))
        @default_backoff = config.fetch("default_backoff", DEFAULT_BACKOFF)
      end

      # One page of the bot's retained events, oldest first. Each entry is
      # {"id" => <ULID>, "event_type" => ..., "payload" => {...}, "created_at" => ...}.
      #
      # Sorted here rather than trusted from the API: an event id is a ULID, so
      # lexicographic order is chronological order, and a chat bot must answer
      # the oldest question first whichever way the endpoint happens to page.
      def events(limit: DEFAULT_LIMIT)
        body = get("/webhooks/events?limit=#{limit.to_i}")
        Array(body["data"]).sort_by { |event| event["id"].to_s }
      end

      # Acknowledge one event. Deleting is what keeps the history bounded and
      # what stops a processed event coming back on the next poll. A 404 counts
      # as success: the event is gone, which is the state we asked for.
      def delete_event(id)
        delete("/webhooks/events/#{URI.encode_www_form_component(id.to_s)}")
        true
      end

      # Post one message. `entity_type` is "discussion" (a chat or channel),
      # "thread", or "user" — the last one addresses a person directly and
      # opens the conversation on first contact, so a DM needs no channel
      # created first. `parent_message_id` threads the post as a reply.
      #
      # The API nests everything under a "message" object; a flat body is
      # rejected as a validation error, not silently ignored.
      def create_message(entity_type:, entity_id:, content:, parent_message_id: nil)
        message = {
          "entity_type" => entity_type,
          "entity_id" => entity_id,
          "content" => content.to_s
        }
        message["parent_message_id"] = parent_message_id if parent_message_id

        post("/messages", "message" => message)
      end

      # The thread hanging off a message, created if it is not there yet. This
      # is what answering "in a thread" requires when the question was a plain
      # channel message: such a message has no thread of its own, so posting
      # back with its entity pair lands in the channel, not under it.
      # Idempotent — an existing thread is returned rather than duplicated.
      def create_thread(message_id)
        body = post("/messages/#{Integer(message_id)}/thread", nil)
        body["data"] || body
      end

      # Put a reaction on a message. `code` is the emoji itself for a stock
      # one; a custom reaction is identified by `name` (":agent-thinking:"),
      # which is what the agent-thinking indicator uses — Pachca renders a live
      # timer instead of a counter for a reaction by that name.
      def add_reaction(message_id, code:, name: nil)
        body = { "code" => code }
        body["name"] = name if name
        post("/messages/#{Integer(message_id)}/reactions", body)
      end

      def remove_reaction(message_id, code:, name: nil)
        body = { "code" => code }
        body["name"] = name if name
        delete("/messages/#{Integer(message_id)}/reactions", body)
      end

      private

      def get(path)
        request(Net::HTTP::Get.new(API_PREFIX + path))
      end

      def delete(path, body = nil)
        req = Net::HTTP::Delete.new(API_PREFIX + path)
        req.body = JSON.generate(body) if body
        request(req, allow_not_found: true)
      end

      def post(path, body)
        req = Net::HTTP::Post.new(API_PREFIX + path)
        req.body = JSON.generate(body) if body
        request(req)
      end

      def request(req, allow_not_found: false)
        req["Authorization"] = "Bearer #{@token}"
        req["Content-Type"]  = "application/json"

        response = http.request(req)

        if response.is_a?(Net::HTTPTooManyRequests)
          raise RateLimitError.new(retry_after_seconds(response), "Pachca API 429: rate limited, retry after #{retry_after_seconds(response)}s")
        end
        return {} if allow_not_found && response.is_a?(Net::HTTPNotFound)

        unless response.is_a?(Net::HTTPSuccess)
          raise "Pachca #{req.method} #{req.path} returned #{response.code}: #{error_detail(response)}"
        end

        body = response.body.to_s
        body.empty? ? {} : JSON.parse(body)
      end

      # Parse the Retry-After header (integer-seconds form only). Absent, blank
      # or non-numeric (an HTTP-date) falls back to the configured backoff, so
      # the caller always gets a usable duration.
      def retry_after_seconds(response)
        value = response["Retry-After"]
        return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

        @default_backoff
      end

      # Pachca reports errors in two JSON shapes — ApiError
      # {"errors":[{key,value,message,code}]} for validation/permission problems
      # and OAuthError {"error","error_description"} for auth ones — but the
      # request-frequency limiter answers text/plain, not JSON. So the body is
      # parsed only when it claims to be JSON, and anything unrecognized is
      # passed through verbatim rather than swallowed.
      def error_detail(response)
        raw = response.body.to_s
        parsed = parse_json_body(response, raw)

        detail =
          if parsed.is_a?(Hash) && parsed["errors"].is_a?(Array)
            parsed["errors"].map { |e| [e["key"], e["message"] || e["code"]].compact.join(" ") }.join("; ")
          elsif parsed.is_a?(Hash) && parsed["error"]
            [parsed["error"], parsed["error_description"]].compact.join(": ")
          else
            raw
          end

        detail.to_s.strip.slice(0, 500)
      end

      def parse_json_body(response, raw)
        return nil unless response["Content-Type"].to_s.include?("json")

        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      def http
        @http ||= begin
          h = Net::HTTP.new(@base_url.host, @base_url.port)
          h.use_ssl = @base_url.scheme == "https"
          h.open_timeout = 15
          h.read_timeout = 30
          h
        end
      end
    end
  end
end
