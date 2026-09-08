# frozen_string_literal: true

require "set"

require_relative "base"

module AgentDaemon
  module Runner
    # Turns "@bot, take a look" on a pull request into an agent run: the agent
    # reads the diff and posts a review itself, through whatever CLI the
    # operator gave it.
    #
    # A poller over the notification inbox, not a webhook receiver. GitHub's
    # notifications are already a queue — read plus mark-read is an explicit
    # ack — so the daemon needs no public URL and stays an outbound client, the
    # same shape as Runner::Pachca.
    #
    # The review itself goes to the pull request, but the agent also writes a
    # short message file saying it posted one. That is not bookkeeping for its
    # own sake: marking a notification read is a destructive ack, so a run that
    # exits 0 having posted nothing would lose the request silently — the exact
    # failure expects_message_file? exists to catch. The file doubles as a
    # notification in chat that a review landed.
    class GitHub < Base
      DEFAULT_REASONS = %w[mention review_requested].freeze
      SUBJECT_TYPE    = "PullRequest"

      def initialize(runner_config, message_dir, project_path, shutdown_flag, sinks: nil, cancel_flag: nil)
        super
        trigger = runner_config.fetch("trigger")
        @client        = ::AgentDaemon::GitHub::Client.new(trigger)
        @repos         = Array(trigger["repos"]).map(&:to_s)
        @allowed_users = Array(trigger["allowed_users"]).map { |login| login.to_s.downcase }
        @reasons       = Array(trigger.fetch("reasons", DEFAULT_REASONS)).map(&:to_s)
        @settled       = Set.new

        Log.info("[#{log_tag}] watching #{scope_description}")
      end

      private

      # A review goes to the pull request, not to message_dir — but the agent
      # is asked to write a one-line report there as well, and its absence is
      # what tells this runner the run did nothing. Marking read without it
      # would discard the request; see Runner::Base#expects_message_file?.
      def expects_message_file?
        true
      end

      # Stated at startup rather than left to be inferred: with no allowlist,
      # the right to spend the agent's time — and to have it post publicly under
      # this account — belongs to anyone who can comment on a watched repo.
      def scope_description
        repos = @repos.empty? ? "every repository this account is notified about" : @repos.join(", ")
        who   = @allowed_users.empty? ? "ANY author" : @allowed_users.join(", ")
        "#{repos}; summoned by #{who}"
      end

      def fetch_work_items
        acknowledged = @settled.dup
        retry_settled_acks

        fresh = @client.notifications.reject { |n| acknowledged.include?(n["id"]) }
        wanted, ignored = fresh.partition { |n| actionable?(n) }

        acknowledge_ignored(ignored)
        wanted
      end

      # A notification this runner will not act on is marked read too. GitHub's
      # inbox is not infinite and `participating=true` keeps returning unread
      # threads: leaving them would mean re-examining the same notifications on
      # every poll forever, and eventually re-fetching their comments too.
      def acknowledge_ignored(notifications)
        notifications.each do |notification|
          Log.debug("[#{log_tag}] ignoring #{notification["id"]} (#{notification["reason"]}), marking read")
          settle(notification["id"])
        end
      end

      def work_item_key(notification)
        notification["id"]
      end

      # Two gates on the notification itself, then one on the comment behind
      # it. The comment costs a request, so it is fetched only for a
      # notification that already passed the cheap checks.
      def actionable?(notification)
        return false unless @reasons.include?(notification["reason"].to_s)
        return false unless notification.dig("subject", "type") == SUBJECT_TYPE
        return false unless watched_repo?(notification)
        return false unless somebody_asked?(notification)

        summoned_by_allowed_author?(notification)
      end

      # A thread comes back unread on any activity, not just a comment: a merge,
      # a push, a label — and the review this runner just posted. GitHub then
      # points latest_comment_url at the pull request itself rather than at a
      # comment, and reading an author from it yields the PR's author, who is
      # exactly the person likely to be on the allowlist. Observed live: one
      # pull request reviewed twice, and merging re-armed the rest.
      #
      # So a mention has to arrive as a comment. A review request does not —
      # nobody types anything to ask for one.
      def somebody_asked?(notification)
        return true if notification["reason"].to_s == "review_requested"

        comment_url?(notification.dig("subject", "latest_comment_url"))
      end

      def comment_url?(url)
        url.to_s.include?("/comments/")
      end

      def watched_repo?(notification)
        return true if @repos.empty?

        @repos.include?(notification.dig("repository", "full_name").to_s)
      end

      # An empty allowlist means anyone who can comment can summon the agent —
      # and the agent answers publicly, under this account. That is a wider
      # boundary than a chat reply, so a runner without an allowlist is
      # allowed but says so at startup.
      #
      # An unattributable notification is never acted on: without knowing who
      # asked, the gate cannot be applied at all, and acting anyway would make
      # the allowlist decorative.
      def summoned_by_allowed_author?(notification)
        author = comment_author(notification)
        return false if author.nil?
        # Checked before the allowlist and not through it: with no allowlist
        # every author passes, and the agent would answer its own review for
        # as long as the poll runs.
        return false if own?(author)
        return true if @allowed_users.empty?

        @allowed_users.include?(author.downcase)
      end

      def own?(author)
        login = @client.login
        !login.nil? && author.downcase == login.downcase
      end

      def comment_author(notification)
        comment = @client.comment(notification.dig("subject", "latest_comment_url"))
        comment&.dig("user", "login")
      end

      def render_prompt(notification)
        @prompt_template.render(base_template_variables.merge(notification_variables(notification)))
      end

      def notification_variables(notification)
        subject = notification["subject"] || {}
        comment = @client.comment(subject["latest_comment_url"]) || {}

        {
          "notification_id" => notification["id"],
          "reason"          => notification["reason"],
          "repo"            => notification.dig("repository", "full_name"),
          "pr_title"        => subject["title"],
          "pr_number"       => pull_number(subject["url"]),
          "pr_url"          => subject["url"],
          "summoned_by"     => comment.dig("user", "login"),
          "request"         => comment["body"],
          "updated_at"      => notification["updated_at"]
        }
      end

      # The API url ends in /pulls/<n>; the number is what `gh` takes.
      def pull_number(url)
        url.to_s[%r{/pulls/(\d+)\z}, 1]
      end

      def after_success(notification)
        settle(notification["id"])
      end

      def after_exhausted(notification)
        Log.error("[#{log_tag}] #{work_item_key(notification)} exhausted #{@max_attempts} attempts, marking read")
        settle(notification["id"])
        @attempts.delete(work_item_key(notification))
      end

      def settle(id)
        @settled << id
        @settled.delete(id) if mark_read(id)
      end

      def retry_settled_acks
        @settled.dup.each { |id| @settled.delete(id) if mark_read(id) }
      end

      def mark_read(id)
        @client.mark_read(id)
      rescue StandardError => e
        Log.warn("[#{log_tag}] could not mark #{id} read: #{e.message}; will retry next poll")
        false
      end
    end
  end
end
