# frozen_string_literal: true

require_relative "base"

module AgentDaemon
  module Transport
    # Delivers via Pachca's REST API with one bot token.
    #
    # Unlike the Mattermost transport there is nothing to resolve and nothing
    # to cache. Pachca addresses everything by numeric id, the pachca trigger
    # already hands those ids to the agent as prompt variables, and a direct
    # message needs no channel opened first — POST /messages with entity_type
    # "user" creates the conversation on first contact.
    #
    # Destination by precedence: a thread entity pair (the question came from
    # inside a thread) -> reply_to_message_id (the question was a plain channel
    # message, so its thread is created and answered in) -> any other entity_id
    # -> user (DM) -> chat_id -> default_chat_id.
    #
    # The first two exist because "answer in the thread" means two different
    # calls depending on where the question was posted, and a prompt cannot be
    # trusted to branch on that. A reply YAML echoes entity_type, entity_id and
    # reply_to_message_id unconditionally, and this decides.
    class Pachca < Base
      DEFAULT_ENTITY_TYPE = "discussion"
      THREAD_ENTITY_TYPE  = "thread"

      def initialize(messenger_config)
        super
        @client = ::AgentDaemon::Pachca::Client.new(messenger_config)
        @default_chat_id = messenger_config.fetch("default_chat_id")
      end

      def deliver(message_data)
        entity_type, entity_id = destination(message_data)

        @client.create_message(
          entity_type: entity_type,
          entity_id: entity_id,
          content: message_data["message"],
          parent_message_id: integer(message_data["parent_message_id"])
        )
      end

      private

      def destination(message_data)
        entity_id = integer(message_data["entity_id"])
        entity_type = presence(message_data["entity_type"])
        user = integer(message_data["user"])
        chat_id = integer(message_data["chat_id"])

        if user && chat_id
          raise "message specifies both user (#{user}) and chat_id (#{chat_id}); refusing to guess a destination"
        end

        # entity_type only means anything alongside an entity_id. On its own it
        # is a half-written destination — most likely a reply whose entity_id
        # never got substituted — and silently sending it to default_chat_id
        # would drop the answer into the wrong place rather than fail loudly.
        if entity_type && entity_id.nil?
          raise "message specifies entity_type (#{entity_type.inspect}) without entity_id; refusing to guess a destination"
        end

        reply_to = integer(message_data["reply_to_message_id"])

        if entity_type == THREAD_ENTITY_TYPE && entity_id
          # The question already came from inside a thread; answer straight
          # into it.
          [entity_type, entity_id]
        elsif reply_to
          # The question was a plain channel message, which has no thread of
          # its own — so posting back with its entity pair would land in the
          # channel, beside the question rather than under it. Ask Pachca for
          # the message's thread (created on first use, returned as-is after)
          # and answer there.
          [THREAD_ENTITY_TYPE, @client.create_thread(reply_to).fetch("id")]
        elsif entity_id
          [entity_type || DEFAULT_ENTITY_TYPE, entity_id]
        elsif user
          ["user", user]
        elsif chat_id
          [DEFAULT_ENTITY_TYPE, chat_id]
        else
          [DEFAULT_ENTITY_TYPE, integer(@default_chat_id)]
        end
      end

      # Ids arrive from a YAML the agent wrote, so a number may well be a
      # String. Anything that is not a whole number is treated as absent, and
      # the precedence above decides instead.
      def integer(value)
        Integer(value)
      rescue TypeError, ArgumentError
        nil
      end

      def presence(value)
        value.strip if value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
