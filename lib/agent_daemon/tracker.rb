# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentDaemon
  class Tracker
    DEFAULT_BASE_URL = "https://api.tracker.yandex.net"

    def initialize(tracker_config)
      @token = tracker_config.fetch("token")
      @org_id = tracker_config.fetch("org_id")
      @base_url = tracker_config.fetch("base_url", DEFAULT_BASE_URL)
    end

    # Returns an array of issues (hashes with keys "key", "summary", etc.)
    def search_issues(query)
      uri = URI("#{@base_url}/v2/issues/_search")
      body = { "query" => query }

      response = post(uri, body)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Tracker API #{response.code}: #{response.body&.slice(0, 500)}"
      end

      JSON.parse(response.body)
    end

    private

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
