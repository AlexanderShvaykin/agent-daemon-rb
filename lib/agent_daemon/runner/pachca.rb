# frozen_string_literal: true

require "set"

require_relative "base"

module AgentDaemon
  module Runner
    # Polls the bot's Pachca event history and turns each qualifying event into
    # one agent run. Pachca has no realtime API, and its history endpoint needs
    # no public URL, so this is an ordinary poller — the same shape as
    # Runner::Tracker, not the listener/reactor split the Mattermost push
    # trigger needs.
    #
    # Read plus delete makes the history a queue with an explicit ack:
    # fetch_work_items reads, after_success deletes. An event whose delete
    # failed is remembered in @settled and retried on the next poll, so a
    # transient failure can never make the agent answer the same message twice
    # — the user-visible symptom (a duplicated reply) is far harder to read
    # than the log line the retry produces.
    class Pachca < Base
      DEFAULT_EVENT_TYPES = %w[message_new].freeze

      # Pachca renders a live timer instead of a reaction counter when the
      # reaction is named agent-thinking, which is exactly the "I heard you"
      # signal a run lasting minutes needs. It only appears once an operator
      # creates a custom reaction by that name, so a missing one disables the
      # indicator for the process rather than warning on every message.
      DEFAULT_THINKING_REACTION = "agent-thinking"

      def initialize(runner_config, message_dir, project_path, shutdown_flag, sinks: nil, cancel_flag: nil)
        super
        trigger = runner_config.fetch("trigger")
        @client        = ::AgentDaemon::Pachca::Client.new(trigger)
        @bot_user_id   = trigger.fetch("bot_user_id").to_i
        @chats         = Array(trigger["chats"]).map(&:to_i)
        @allowed_users = Array(trigger["allowed_users"]).map(&:to_i)
        @event_types   = Array(trigger.fetch("event_types", DEFAULT_EVENT_TYPES))
        @limit         = trigger.fetch("limit", ::AgentDaemon::Pachca::Client::DEFAULT_LIMIT)
        @settled       = Set.new

        @thinking_reaction = trigger.fetch("thinking_reaction", DEFAULT_THINKING_REACTION)
        @thinking          = Set.new
        @thinking_off      = false

        Log.info("[#{log_tag}] listening to #{scope_description}")
      end

      private

      # Stated on startup rather than left to be inferred from the config: with
      # neither list set, the right to command the agent is exactly the right to
      # talk to the bot, and that is worth reading in the log.
      def scope_description
        chats   = @chats.empty? ? "every chat the bot receives" : "chats #{@chats.join(", ")}"
        authors = @allowed_users.empty? ? "any author" : "authors #{@allowed_users.join(", ")}"
        "#{chats}, #{authors}"
      end

      # The snapshot is taken BEFORE retrying the pending deletes, and it is
      # what filters the page. Filtering against the live set would reopen the
      # hole it exists to close: a delete that succeeds on this poll empties
      # the set, and a page fetched from a history that has not caught up yet
      # would sail through and be answered a second time.
      def fetch_work_items
        acknowledged = @settled.dup
        retry_settled_deletes

        fresh = @client.events(limit: @limit).reject { |event| acknowledged.include?(event["id"]) }
        wanted, ignored = fresh.partition { |event| actionable?(event) }

        acknowledge_ignored(ignored)
        wanted
      end

      # An event this runner has decided not to act on is settled just as much
      # as one it answered, so it is deleted too. Without this the history only
      # ever grows: every answer the agent posts comes back as an event from
      # the bot itself, which the author gate drops and nothing ever clears —
      # and once `limit` events of that kind accumulate, real questions are
      # pushed off the page and the runner goes deaf.
      #
      # This is also why one bot token must belong to exactly one runner: a
      # second runner sharing it would find its own events already deleted.
      # (Sharing is already unworkable for a plainer reason — both would answer
      # every question.)
      def acknowledge_ignored(events)
        events.each do |event|
          Log.debug("[#{log_tag}] ignoring #{event["id"]} (#{event["event_type"]}), acknowledging it")
          settle(event["id"])
        end
      end

      def work_item_key(event)
        event["id"]
      end

      def render_prompt(event)
        @prompt_template.render(base_template_variables.merge(event_variables(event)))
      end

      # Tell the chat the question was heard, before the agent spends minutes
      # on it. Fires once per attempt; a retry finds the reaction already there
      # and does nothing.
      def before_attempt(event)
        start_thinking(event)
      end

      def after_success(event)
        stop_thinking(event)
        settle(event["id"])
      end

      # Shutdown or a restart rolled the attempt back, so the question is still
      # unanswered — but the indicator would otherwise sit there over a process
      # that is gone. The next run re-adds it.
      def after_killed(event)
        stop_thinking(event)
      end

      # An event nobody could process would otherwise be re-fetched forever.
      # Acknowledge it and drop the attempt counter, mirroring Runner::File
      # moving an exhausted work item to failed_dir — except the history has no
      # failed shelf, so the log line is the record.
      def after_exhausted(event)
        Log.error("[#{log_tag}] #{work_item_key(event)} exhausted #{@max_attempts} attempts, acknowledging and dropping it")
        stop_thinking(event)
        settle(event["id"])
        @attempts.delete(work_item_key(event))
      end

      # Three gates, all read off the payload the API itself returned. Skipping
      # the bot's own posts is not optional: the agent replies into the same
      # chat, so without it every answer is re-ingested as a new question and
      # the runner loops on itself.
      def actionable?(event)
        payload = event["payload"]
        return false unless payload.is_a?(Hash)
        return false unless @event_types.include?(event["event_type"])

        user_id = payload["user_id"].to_i
        return false if user_id == @bot_user_id
        return false unless in_listed_chat?(payload)
        return false unless @allowed_users.empty? || @allowed_users.include?(user_id)

        true
      end

      # A message posted in a thread carries the THREAD's chat id in chat_id,
      # not the chat the thread hangs in — that one is thread.message_chat_id.
      # So a list naming the chat an operator actually sees would silently miss
      # every threaded message in it; both ids are matched to make `chats` mean
      # what it reads like.
      def in_listed_chat?(payload)
        return true if @chats.empty?

        [payload["chat_id"], payload.dig("thread", "message_chat_id")]
          .compact
          .any? { |id| @chats.include?(id.to_i) }
      end

      # The payload fields, flattened for the template. A nil (a root message
      # has no parent_message_id) renders as an empty string, not as a literal
      # {{...}} — PromptTemplate only leaves a placeholder when the key is
      # absent entirely.
      #
      # There is no separate thread id to expose: replying into the originating
      # thread means echoing entity_type ("thread") and entity_id straight back
      # to POST /messages. The thread object itself carries only the message the
      # thread hangs off of and that message's chat.
      def event_variables(event)
        payload = event["payload"] || {}

        {
          "event_id"          => event["id"],
          "event_type"        => event["event_type"],
          "message"           => payload["content"],
          "message_id"        => payload["id"],
          "chat_id"           => payload["chat_id"],
          "entity_type"       => payload["entity_type"],
          "entity_id"         => payload["entity_id"],
          "parent_message_id" => payload["parent_message_id"],
          "thread_message_id" => payload.dig("thread", "message_id"),
          "thread_chat_id"    => payload.dig("thread", "message_chat_id"),
          "sender_id"         => payload["user_id"],
          "created_at"        => payload["created_at"],
          "url"               => payload["url"]
        }
      end

      def start_thinking(event)
        message_id = event.dig("payload", "id")
        return if message_id.nil? || @thinking.include?(message_id)

        return unless react(:add, message_id)

        @thinking << message_id
      end

      def stop_thinking(event)
        message_id = event.dig("payload", "id")
        return unless @thinking.delete?(message_id)

        react(:remove, message_id)
      end

      # The indicator is a courtesy, never a reason to fail a run, so every
      # failure is swallowed. The first one also switches it off for the life
      # of the process: the overwhelmingly likely cause is that nobody created
      # the custom reaction, and that would otherwise produce one warning per
      # message forever.
      # Verified against the live API: a custom reaction is identified by its
      # BARE name, in both fields. Wrapping it in colons — the very form Pachca
      # returns for stock shortcodes (":+1:") — makes it look the value up as a
      # custom emoji id instead and answer 404. A stock emoji, meanwhile, is
      # just the glyph in `code`; the API fills `name` in itself, and passing
      # one would be the same mistake in reverse. Non-ASCII is the tell.
      def react(action, message_id)
        return false if @thinking_reaction.to_s.empty? || @thinking_off

        value = @thinking_reaction.to_s
        @client.public_send(:"#{action}_reaction", message_id,
                            code: value, name: (value if value.ascii_only?))
        true
      rescue => e
        @thinking_off = true
        Log.warn("[#{log_tag}] thinking indicator off for this process: #{e.message}. " \
                 "Create a custom reaction named #{@thinking_reaction.inspect} in Pachca, " \
                 "or set trigger.thinking_reaction to null to stop trying.")
        false
      end

      # Delete now, and remember the id if the delete failed so the next poll
      # both retries it and refuses to reprocess the event meanwhile.
      def settle(id)
        @settled << id
        @settled.delete(id) if delete_event(id)
      end

      def retry_settled_deletes
        @settled.dup.each { |id| @settled.delete(id) if delete_event(id) }
      end

      def delete_event(id)
        @client.delete_event(id)
      rescue => e
        Log.warn("[#{log_tag}] could not acknowledge event #{id}: #{e.message}; will retry next poll")
        false
      end
    end
  end
end
