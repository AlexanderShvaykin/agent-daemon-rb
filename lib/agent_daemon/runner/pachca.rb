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

      def initialize(runner_config, message_dir, project_path, shutdown_flag, sinks: nil, cancel_flag: nil)
        super
        trigger = runner_config.fetch("trigger")
        @client        = ::AgentDaemon::Pachca::Client.new(trigger)
        @bot_user_id   = trigger.fetch("bot_user_id").to_i
        @chats         = Array(trigger.fetch("chats")).map(&:to_i)
        @allowed_users = Array(trigger["allowed_users"]).map(&:to_i)
        @event_types   = Array(trigger.fetch("event_types", DEFAULT_EVENT_TYPES))
        @limit         = trigger.fetch("limit", ::AgentDaemon::Pachca::Client::DEFAULT_LIMIT)
        @settled       = Set.new
      end

      private

      # The snapshot is taken BEFORE retrying the pending deletes, and it is
      # what filters the page. Filtering against the live set would reopen the
      # hole it exists to close: a delete that succeeds on this poll empties
      # the set, and a page fetched from a history that has not caught up yet
      # would sail through and be answered a second time.
      def fetch_work_items
        acknowledged = @settled.dup
        retry_settled_deletes

        @client.events(limit: @limit)
               .reject { |event| acknowledged.include?(event["id"]) }
               .select { |event| actionable?(event) }
      end

      def work_item_key(event)
        event["id"]
      end

      def render_prompt(event)
        @prompt_template.render(base_template_variables.merge(event_variables(event)))
      end

      def after_success(event)
        settle(event["id"])
      end

      # An event nobody could process would otherwise be re-fetched forever.
      # Acknowledge it and drop the attempt counter, mirroring Runner::File
      # moving an exhausted work item to failed_dir — except the history has no
      # failed shelf, so the log line is the record.
      def after_exhausted(event)
        Log.error("[#{log_tag}] #{work_item_key(event)} exhausted #{@max_attempts} attempts, acknowledging and dropping it")
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
        return false unless @chats.include?(payload["chat_id"].to_i)
        return false unless @allowed_users.empty? || @allowed_users.include?(user_id)

        true
      end

      # The documented payload fields, flattened for the template. A nil (a
      # root message has no parent_message_id) renders as an empty string, not
      # as a literal {{...}} — PromptTemplate only leaves a placeholder when
      # the key is absent entirely.
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
          "thread_id"         => payload.dig("thread", "id"),
          "sender_id"         => payload["user_id"],
          "created_at"        => payload["created_at"]
        }
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
