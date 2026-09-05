# frozen_string_literal: true

module AgentDaemon
  # A trigger's source is pacing us, not failing. Runner::Base treats this
  # separately from a trigger error: it backs off for `retry_after` seconds
  # without touching the consecutive-error counter, so a throttle never
  # escalates to a SYSTEM:<runner> notification.
  #
  # Every polling client raises this on an HTTP 429; Tracker::RateLimitError
  # is the original, kept as a subclass so existing configs, rescues and tests
  # keep working unchanged.
  class RateLimitError < StandardError
    attr_reader :retry_after

    def initialize(retry_after, message = nil)
      @retry_after = retry_after
      super(message || "rate limited, retry after #{retry_after}s")
    end
  end
end
