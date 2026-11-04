# frozen_string_literal: true

require "set"

require_relative "base"

module AgentDaemon
  module Runner
    # Turns "@agent, have a look" on a Basecamp card, to-do or message into an
    # agent run. The agent reads the recording and answers with a comment of
    # its own, through the same CLI this runner polls with.
    #
    # A poller over the notification inbox, the same shape as Runner::GitHub
    # and for the same reason: Basecamp's inbox is already a queue, listing
    # plus marking read is an explicit ack, and neither needs a public URL. The
    # official connector takes the other road — webhooks, and a tunnel to reach
    # a laptop — which buys latency at the price of an address on the internet.
    #
    # Assignments were the obvious alternative and are the wrong queue. A to-do
    # assigned to the agent has no ack short of completing or unassigning it,
    # both of which change somebody's board; and an assignment says what to do
    # but never who asked, so the allowlist every other trigger enforces would
    # have had nothing to check.
    class Basecamp < Base
      # Basecamp's own product announcements land in the same inbox, so the
      # default is narrow: somebody typed the agent's name on purpose.
      DEFAULT_KINDS = %w[Mention].freeze

      def initialize(runner_config, message_dir, project_path, shutdown_flag, sinks: nil, cancel_flag: nil)
        super
        trigger = runner_config.fetch("trigger")
        @client        = ::AgentDaemon::Basecamp::CLI.new(trigger)
        @projects      = Array(trigger["projects"]).map(&:to_s)
        @allowed_users = Array(trigger["allowed_users"]).map(&:to_s)
        @kinds         = Array(trigger.fetch("kinds", DEFAULT_KINDS)).map(&:to_s)
        @settled       = Set.new

        Log.info("[#{log_tag}] watching #{scope_description}")
      end

      private

      # The answer goes to Basecamp as a comment, but the agent also writes a
      # short report here — and its absence is what tells this runner the run
      # did nothing. Marking read without it would discard the request; see
      # Runner::Base#expects_message_file?.
      def expects_message_file?
        true
      end

      # Stated at startup rather than left to be inferred: with no allowlist,
      # the right to spend the agent's time — and to have it answer publicly
      # under this account — belongs to anyone who can mention it.
      def scope_description
        where = @projects.empty? ? "every project this account belongs to" : @projects.join(", ")
        who   = @allowed_users.empty? ? "ANYONE" : @allowed_users.join(", ")
        "#{where}; summoned by #{who}"
      end

      def fetch_work_items
        acknowledged = @settled.dup
        retry_settled_acks

        fresh = @client.notifications.reject { |n| acknowledged.include?(work_item_key(n)) }
        wanted, ignored = fresh.partition { |notification| actionable?(notification) }

        acknowledge_ignored(ignored)
        wanted
      end

      # A notification this runner will not act on is marked read too. The
      # inbox keeps returning unread items, so leaving them would mean
      # re-examining the same product announcement on every poll forever — and
      # eventually pushing a real request off the first page.
      def acknowledge_ignored(notifications)
        notifications.each do |notification|
          Log.debug("[#{log_tag}] ignoring #{work_item_key(notification)} (#{notification["type"]}), marking read")
          settle(notification)
        end
      end

      def work_item_key(notification)
        notification["id"].to_s
      end

      def actionable?(notification)
        return false unless @kinds.include?(notification["type"].to_s)
        return false unless watched_project?(notification)

        summoned_by_allowed_author?(notification)
      end

      # By project name, because that is what a notification carries — the
      # bucket id appears only inside the URLs. A rename therefore silently
      # narrows the scope to nothing, which is the safe direction to fail but
      # worth knowing when a runner suddenly goes quiet.
      def watched_project?(notification)
        return true if @projects.empty?

        @projects.include?(notification["bucket_name"].to_s)
      end

      # Matched against the author's numeric id or their display name. Not
      # their email: Basecamp masks it in API responses for everyone but the
      # authenticated user, so an allowlist of addresses would match nobody.
      #
      # An unattributable notification is never acted on: without knowing who
      # asked, the gate cannot be applied at all, and acting anyway would make
      # the allowlist decorative.
      def summoned_by_allowed_author?(notification)
        return true if @allowed_users.empty?

        creator = notification["creator"] || {}
        candidates = [creator["id"], creator["name"]].compact.map(&:to_s)
        return false if candidates.empty?

        candidates.any? { |candidate| @allowed_users.include?(candidate) }
      end

      def render_prompt(notification)
        @prompt_template.render(base_template_variables.merge(notification_variables(notification)))
      end

      def notification_variables(notification)
        creator = notification["creator"] || {}
        bucket, recording = recording_path(notification)

        {
          "notification_id" => work_item_key(notification),
          "kind"            => notification["type"],
          "project"         => notification["bucket_name"],
          "title"           => notification["title"],
          # The plain-text excerpt, not the comment's own body: that arrives as
          # HTML in which an @-mention is a multi-line <bc-attachment> blob
          # carrying an avatar, and the question is three words at the end.
          # The agent can fetch the full thread itself; this is what to fetch it
          # about.
          "request"         => notification["content_excerpt"],
          "summoned_by"     => creator["name"],
          "summoned_by_id"  => creator["id"],
          "bucket_id"       => bucket,
          "recording_id"    => recording,
          "url"             => notification["app_url"],
          "created_at"      => notification["created_at"]
        }
      end

      # subscription_url is the one field that spells both ids out plainly:
      # https://3.basecampapi.com/<account>/buckets/<bucket>/recordings/<id>/subscription.json
      # app_url would need a different pattern per recording type (cards live
      # under card_tables, to-dos do not), so it is left for people to click.
      def recording_path(notification)
        match = notification["subscription_url"].to_s.match(%r{/buckets/(\d+)/recordings/(\d+)/})
        return [nil, nil] unless match

        [match[1], match[2]]
      end

      def after_success(notification)
        settle(notification)
      end

      def after_exhausted(notification)
        key = work_item_key(notification)
        Log.error("[#{log_tag}] #{key} exhausted #{@max_attempts} attempts, marking read")
        settle(notification)
        @attempts.delete(key)
      end

      # An ack that fails is remembered and retried on the next poll rather
      # than dropped: until Basecamp agrees the notification is read, it comes
      # back in the next listing, and acting on it twice would post the same
      # answer twice.
      def settle(notification)
        key = work_item_key(notification)
        @settled << key
        @settled.delete(key) if mark_read(key)
      end

      def retry_settled_acks
        @settled.dup.each { |key| @settled.delete(key) if mark_read(key) }
      end

      def mark_read(key)
        @client.mark_read(key)
      rescue ::AgentDaemon::Basecamp::CLI::Error => e
        Log.warn("[#{log_tag}] could not mark #{key} read (#{e.message}); will retry next poll")
        false
      end
    end
  end
end
