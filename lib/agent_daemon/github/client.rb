# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module AgentDaemon
  module GitHub
    # Thin stdlib client over the parts of GitHub's REST API this trigger
    # needs: the notification inbox, the comment that caused a notification,
    # and marking a thread read.
    #
    # Notifications are the poller's equivalent of an event queue — read plus
    # mark-read is an explicit ack, the same shape as Pachca's history. No
    # webhook and no public URL: the daemon stays an outbound client.
    class Client
      DEFAULT_BASE_URL = "https://api.github.com"
      DEFAULT_BACKOFF  = 60

      def initialize(config)
        @token    = config.fetch("token")
        @base_url = URI(config.fetch("base_url", DEFAULT_BASE_URL))
        @default_backoff = config.fetch("default_backoff", DEFAULT_BACKOFF)
      end

      # Unread notifications, oldest first. `participating: true` narrows the
      # inbox to threads this account was mentioned in or asked to review,
      # which is the only kind this trigger acts on.
      def notifications
        Array(get("/notifications?participating=true")).sort_by { |n| n["updated_at"].to_s }
      end

      # The comment that produced a notification — this is where the summoning
      # author comes from, since the notification itself names only the thread.
      # Returns nil when the URL is absent or unreadable: an unattributable
      # notification must not be acted on rather than acted on blindly.
      def comment(url)
        return nil if url.nil? || url.empty?

        get_url(url)
      rescue StandardError => e
        Log.warn("[GitHub] could not read #{url}: #{e.message}")
        nil
      end

      # The login this token belongs to, asked once. Needed to tell the agent's
      # own comments from everyone else's: without it a runner with no
      # allowlist answers itself, since a review it posts brings the thread
      # back unread.
      def login
        return @login if defined?(@login)

        @login = get("/user")&.fetch("login", nil)
      rescue StandardError => e
        Log.warn("[GitHub] could not resolve own login: #{e.message}")
        @login = nil
      end

      # Acknowledge a thread. Marking read is what stops a handled mention
      # coming back on the next poll, so it is the ack — and, as with any ack,
      # doing it for work that did not happen loses the request.
      def mark_read(thread_id)
        patch("/notifications/threads/#{Integer(thread_id)}")
        true
      end

      private

      def get(path)
        get_url(@base_url.to_s.chomp("/") + path)
      end

      def get_url(url)
        request(Net::HTTP::Get.new(URI(url)), URI(url))
      end

      def patch(path)
        uri = URI(@base_url.to_s.chomp("/") + path)
        request(Net::HTTP::Patch.new(uri), uri, allow_empty: true)
      end

      def request(req, uri, allow_empty: false)
        req["Authorization"] = "Bearer #{@token}"
        req["Accept"] = "application/vnd.github+json"
        req["X-GitHub-Api-Version"] = "2022-11-28"

        response = http(uri).request(req)

        # GitHub answers 403 with a rate-limit header rather than 429, so a
        # throttle has to be recognised before the generic error path turns it
        # into a trigger failure that escalates.
        if rate_limited?(response)
          raise RateLimitError.new(retry_after_seconds(response),
                                   "GitHub API rate limited, retry after #{retry_after_seconds(response)}s")
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "GitHub #{req.method} #{uri.path} returned #{response.code}: #{error_detail(response)}"
        end

        body = response.body.to_s
        return {} if body.empty? && allow_empty

        body.empty? ? {} : JSON.parse(body)
      end

      def rate_limited?(response)
        return true if response.is_a?(Net::HTTPTooManyRequests)

        response.is_a?(Net::HTTPForbidden) && response["X-RateLimit-Remaining"].to_s == "0"
      end

      # Retry-After when present; otherwise the seconds until the window
      # resets, which is what GitHub actually sends on a primary rate limit.
      def retry_after_seconds(response)
        after = response["Retry-After"]
        return after.to_i if after.is_a?(String) && after.match?(/\A\d+\z/)

        reset = response["X-RateLimit-Reset"]
        if reset.is_a?(String) && reset.match?(/\A\d+\z/)
          seconds = reset.to_i - Time.now.to_i
          return seconds if seconds.positive?
        end

        @default_backoff
      end

      def error_detail(response)
        parsed = JSON.parse(response.body.to_s) rescue nil
        detail = parsed.is_a?(Hash) ? (parsed["message"] || parsed.inspect) : response.body.to_s
        detail.to_s.strip.slice(0, 500)
      end

      def http(uri)
        h = Net::HTTP.new(uri.host, uri.port)
        h.use_ssl = uri.scheme == "https"
        h.open_timeout = 15
        h.read_timeout = 30
        h
      end
    end
  end
end
