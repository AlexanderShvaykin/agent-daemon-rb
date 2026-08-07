# frozen_string_literal: true

module AgentDaemon
  module Supervisor
    # Replaces every occurrence of a known secret value with one fixed marker
    # (AD-8). Built once at Master boot from the union of the supervisor
    # config's and every workflow config's `resolved_secrets`, and applied by
    # the OutputPipeline on complete line boundaries, before any consumer can
    # read the line.
    #
    # Best-effort by design: only values a config resolved through `secret()`
    # are known here. Output can still carry secrets this object has never
    # seen (NFR3) — access control (AD-7) is the primary barrier, not this.
    #
    # The instance holds resolved secret values. Never log it, `inspect` it,
    # serialize it, or expose its inputs.
    class Redactor
      MARKER = "[REDACTED]"

      def initialize(values)
        candidates = Array(values).select { |v| v.is_a?(String) && !v.empty? }
        # Normalize each value to the scrubbed-UTF-8 form the pipeline emits:
        # the lines being redacted have been force_encoding(UTF_8).scrub'ed,
        # so a value carrying binary-encoded or invalid bytes would otherwise
        # raise Encoding::CompatibilityError inside gsub on every non-ASCII
        # line (silently dropped by the sink guard) — and could never match
        # the scrubbed form the output actually takes.
        candidates = candidates.map { |v| v.dup.force_encoding(Encoding::UTF_8).scrub }.uniq
        # Longest-first: Regexp alternation is leftmost-first, so without this
        # a short secret that prefixes a longer one would match first and
        # leave the longer one's tail in the output.
        candidates.sort_by! { |v| -v.length }
        # An empty set gets no Regexp at all — Regexp.union([]) is a pattern
        # that matches nothing useful, and an empty alternation branch would
        # match at every position (exactly the AC5 failure).
        @pattern = candidates.empty? ? nil : Regexp.union(candidates)
        # The pipeline's forced-cut (DR9) needs the longest known value's
        # BYTE length: any occurrence that would straddle a cut necessarily
        # starts within the last (max_value_length - 1) bytes of the buffer.
        @max_value_length = candidates.map(&:bytesize).max || 0
      end

      attr_reader :max_value_length

      # Takes and returns a String. Knows nothing about lines, streams, runs,
      # or entities — the pipeline feeds it one complete line at a time.
      def redact(text)
        return text if @pattern.nil?

        text.gsub(@pattern, MARKER)
      end

      # The compiled Regexp embeds every secret verbatim, so the default
      # #inspect would print all of them into whatever interpolated it — a
      # backtrace, a log line, an error message. Nothing in this repo inspects
      # a Redactor today; this makes sure nothing ever can. The OutputPipeline
      # that holds one inherits the protection through its own default
      # #inspect, which recurses into this.
      def inspect
        "#<#{self.class.name}>"
      end
      alias to_s inspect
    end
  end
end
