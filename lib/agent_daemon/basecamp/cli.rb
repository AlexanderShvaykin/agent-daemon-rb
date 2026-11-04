# frozen_string_literal: true

require "json"
require "open3"

require_relative "../rate_limit_error"

module AgentDaemon
  module Basecamp
    # Talks to Basecamp through 37signals' own `basecamp` CLI rather than over
    # HTTP, which is the one place this gem's triggers differ from each other.
    #
    # The reason is authentication. Basecamp is OAuth 2.1: no personal access
    # token exists, an access token lives two weeks, and keeping one means
    # holding a refresh token and writing the rotated result back somewhere.
    # This daemon deliberately owns no store — secrets arrive through ENV and
    # nothing is persisted — so an HTTP client here would have had to invent
    # one. The CLI already refreshes on its own, and the agent needs it
    # installed anyway to answer, so the token has exactly one keeper.
    #
    # No new dependency comes with it: Open3 and JSON are stdlib. What does
    # come is a binary that must exist on the host, which is why a missing one
    # is reported as plainly as an authentication failure.
    class CLI
      DEFAULT_EXECUTABLE = "basecamp"

      # The CLI wraps every answer in an envelope: `{"ok": true, "data": ...}`
      # or `{"ok": false, "error": ..., "code": ..., "retryable": ...}`.
      # `--quiet` would strip it, and with it the only machine-readable account
      # of what went wrong, so it is not used.
      #
      # `retryable` speaks in one direction: true means the CLI classified the
      # failure as its own plight, false means nothing classified it — not that
      # a retry is hopeless. So the codes below widen it and never narrow it.
      TRANSIENT_CODES = %w[network timeout rate_limit].freeze
      RATE_LIMIT_CODE = "rate_limit"

      # Basecamp's own announcements arrive as notifications too, and the
      # inbox is shared with every project the account belongs to.
      NOTIFICATION_SECTION = "inbox"

      class Error < StandardError; end

      # The CLI never got an answer: asking again later may well work, so a
      # poller should keep its cadence rather than treat this as a verdict.
      class TransientError < Error; end

      def initialize(trigger_config = {})
        @executable = trigger_config["executable"] || DEFAULT_EXECUTABLE
        @account    = trigger_config["account"]&.to_s
      end

      # Unread notifications, newest first, exactly as the inbox shows them.
      # Bubble-ups and their counts are dropped: they are Basecamp resurfacing
      # something old, not somebody asking for anything.
      def notifications
        data = run("notifications", "list")
        Array(data.is_a?(Hash) ? data["unreads"] : data)
      end

      # Marking read is the ack, and it is destructive in the same sense as
      # deleting a Pachca event: the request is gone from the queue afterwards.
      #
      # `--page` is not passed because the CLI resolves ids against the page it
      # would have listed, and this client only ever reads the first one. Were
      # paging added here, the page would have to be echoed back on the ack.
      def mark_read(id)
        run("notifications", "read", id.to_s)
        true
      end

      # A recording — card, to-do, message — with its comments inlined, which
      # is why the runner needs no second call for context.
      def show(recording_id)
        run("show", recording_id.to_s)
      end

      private

      def run(*args)
        argv = [@executable, *args, "--json"]
        argv.push("--account", @account) if @account && !@account.empty?

        stdout, stderr, status = capture(argv)
        envelope = parse(stdout, stderr, status)

        return envelope["data"] if envelope["ok"]

        raise_failure(envelope)
      end

      def capture(argv)
        Open3.capture3(*argv)
      rescue Errno::ENOENT
        raise Error, "#{@executable} not found in PATH — install the Basecamp CLI and authenticate it " \
                     "(`#{@executable} auth login --remote`) as the user the daemon runs as"
      end

      # Only stdout is parsed. The CLI writes diagnostics to stderr — on a host
      # without a system keyring it announces on every single invocation that
      # credentials are in a plain file — and mixing the two would turn that
      # notice into a parse failure.
      def parse(stdout, stderr, status)
        JSON.parse(stdout)
      rescue JSON::ParserError
        detail = stderr.to_s.strip
        detail = stdout.to_s.strip if detail.empty?
        raise TransientError, "#{@executable} returned no JSON (exit #{status.exitstatus}): #{detail.slice(0, 300)}"
      end

      def raise_failure(envelope)
        code    = envelope["code"].to_s
        message = "#{envelope['error']} (#{code})"

        raise ::AgentDaemon::RateLimitError, message if code == RATE_LIMIT_CODE
        raise TransientError, message if envelope["retryable"] == true || TRANSIENT_CODES.include?(code)

        raise Error, message
      end
    end
  end
end
