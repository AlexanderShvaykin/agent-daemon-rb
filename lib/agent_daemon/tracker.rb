# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentDaemon
  class Tracker
    DEFAULT_BASE_URL = "https://api.tracker.yandex.net"
    DEFAULT_BACKOFF  = 60

    # Raised on an HTTP 429, carrying how long to wait before polling again.
    class RateLimitError < AgentDaemon::RateLimitError
      def initialize(retry_after)
        super(retry_after, "Tracker API 429: rate limited, retry after #{retry_after}s")
      end
    end

    def initialize(tracker_config)
      @token = tracker_config.fetch("token")
      @org_id = tracker_config.fetch("org_id")
      @base_url = tracker_config.fetch("base_url", DEFAULT_BASE_URL)
      @default_backoff = tracker_config.fetch("default_backoff", DEFAULT_BACKOFF)
    end

    # Returns an array of issues (hashes with keys "key", "summary", etc.)
    def search_issues(query)
      uri = URI("#{@base_url}/v2/issues/_search")
      body = { "query" => query }

      response = post(uri, body)

      if response.is_a?(Net::HTTPTooManyRequests)
        raise RateLimitError, retry_after_seconds(response)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "Tracker API #{response.code}: #{response.body&.slice(0, 500)}"
      end

      JSON.parse(response.body)
    end

    private

    # Parse the Retry-After header (integer-seconds form only). Anything absent,
    # blank, or non-numeric (e.g. an HTTP-date) falls back to the configured
    # default backoff so the caller always gets a usable duration.
    def retry_after_seconds(response)
      value = response["Retry-After"]
      return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

      @default_backoff
    end

    def post(uri, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 15
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "OAuth #{@token}"
      req["X-Org-ID"] = @org_id
      req["Content-Type"] = "application/json"
      req.body = body.to_json

      http.request(req)
    end
  end
end
