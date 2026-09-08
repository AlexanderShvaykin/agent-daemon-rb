# frozen_string_literal: true

require "fileutils"
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

      # file_type as Pachca spells it for a picture. The other values are
      # "file", "audio" and "voice"; only this one is worth putting in front
      # of the model, and only this one it can look at.
      IMAGE_TYPE = "image"

      # Enough for a screenshot or a log, small enough that a stray archive
      # cannot fill the disk while an operator is asleep. A file over the cap
      # is skipped with a warning, not truncated: half a PNG is not a picture.
      DEFAULT_MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024

      # Per run, across the question and the thread behind it. A thread of
      # fifty messages each with a screenshot would otherwise be fifty
      # downloads before the agent says a word.
      DEFAULT_MAX_ATTACHMENTS = 10

      # How many pictures reach the model. A picture is expensive in a way a
      # line of text is not, so the rest are named in the transcript with their
      # paths and the agent can say which one it needs.
      DEFAULT_MAX_IMAGES = 4

      # Pachca renders a live timer instead of a reaction counter when the
      # reaction is named agent-thinking, which is exactly the "I heard you"
      # signal a run lasting minutes needs. It only appears once an operator
      # creates a custom reaction by that name, so a missing one disables the
      # indicator for the process rather than warning on every message.
      DEFAULT_THINKING_REACTION = "agent-thinking"

      # How many earlier messages of the thread to put in front of the
      # question. Only threads: a reply there is routinely unreadable on its
      # own ("а почему?"), while a question asked in a channel carries its own
      # context and the last N unrelated channel messages would be noise.
      # 0 turns it off.
      #
      # The default is what one request returns; the client pages past it on
      # request. The default stays at one request on purpose — most threads
      # never reach it, so raising it would buy nothing and cost a round trip
      # in front of every question. The ceiling is where paging stops being
      # worth its latency: ten requests before the agent starts, and a
      # transcript already far longer than any thread a person will read.
      DEFAULT_CONTEXT_MESSAGES = 50
      MAX_CONTEXT_MESSAGES     = 500
      THREAD_ENTITY_TYPE       = "thread"

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

        @context_messages  = trigger.fetch("context_messages", DEFAULT_CONTEXT_MESSAGES).to_i
        @thinking_reaction = trigger.fetch("thinking_reaction", DEFAULT_THINKING_REACTION)
        @thinking          = Set.new
        @download_attachments  = trigger.fetch("attachments", true)
        @max_attachment_bytes  = trigger.fetch("max_attachment_bytes", DEFAULT_MAX_ATTACHMENT_BYTES).to_i
        # Memoised per event: the summary is built for the prompt and the image
        # list for the backend, and neither should re-download the file.
        @attachments           = {}
        # Per run, reset in render_prompt: files by message id, and the
        # download budget they share.
        @by_message            = {}
        @downloads             = 0
        @max_attachments       = trigger.fetch("max_attachments", DEFAULT_MAX_ATTACHMENTS).to_i
        @max_images            = trigger.fetch("max_images", DEFAULT_MAX_IMAGES).to_i
        @thinking_off      = false

        Log.info("[#{log_tag}] listening to #{scope_description}")
      end

      private

      # This trigger acknowledges by deleting the event from Pachca's history,
      # so a run that exits 0 without writing an answer destroys the question
      # rather than leaving it somewhere visible. Seen live: a message_dir the
      # agent could not write to produced exactly that — the agent said it
      # could not save the file, the CLI exited 0, and the question was gone.
      def expects_message_file?
        true
      end

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
        # Per run: a lifetime budget would leave the tenth question with
        # nothing, spent by the first nine.
        @by_message = {}
        @downloads  = 0

        variables = base_template_variables
                    .merge(event_variables(event))
                    .merge("thread_context" => thread_context(event))
        @prompt_template.render(variables)
      end

      # The thread so far, as a transcript, oldest first. Empty for a question
      # asked outside a thread, and empty — with a warning, never a failure —
      # when the fetch does not come back: an answer written without the
      # earlier messages is worse than one written with them, but far better
      # than no answer at all.
      def thread_context(event)
        payload = event["payload"] || {}
        return "" unless @context_messages.positive?
        return "" unless payload["entity_type"] == THREAD_ENTITY_TYPE

        chat_id = payload["chat_id"]
        return "" if chat_id.nil?

        messages = @client.messages(chat_id: chat_id, limit: @context_messages)
        transcript([root_message(payload), *messages].compact, skip: payload["id"])
      rescue => e
        Log.warn("[#{log_tag}] could not read thread context: #{e.message}; answering without it")
        ""
      end

      # The message a thread hangs off lives in the PARENT chat, not in the
      # thread, so listing the thread returns every reply and not the question
      # that started it. Observed live: an agent asked to follow up inside a
      # thread it had opened saw only its own answer and reported the context
      # as incomplete — the one message that made the rest make sense was the
      # one missing.
      #
      # A standalone thread has no such message and reports message_id as nil,
      # which is exactly the case this returns nothing for.
      def root_message(payload)
        id = payload.dig("thread", "message_id")
        return nil if id.nil?

        @client.message(id)
      rescue => e
        Log.warn("[#{log_tag}] could not read the message this thread hangs off: #{e.message}")
        nil
      end

      # The question itself is already in {{message}}, so it is dropped here
      # rather than repeated. The bot's own lines are labelled: without that a
      # model reads the whole thread as other people talking and loses track of
      # what it already said.
      # uniq because the root message is prepended separately: a thread whose
      # listing happens to include it would otherwise show it twice.
      def transcript(messages, skip:)
        messages
          .uniq { |message| message["id"] }
          .reject { |message| message["id"] == skip }
          .map { |message| transcript_line(message) }
          .join("\n")
      end

      # An earlier message's files are named on its own line, so "что тут не
      # так?" three replies below a screenshot has something to point at. That
      # is the common shape — more common than a file on the question itself.
      def transcript_line(message)
        line = "#{author_label(message["user_id"])}: #{message["content"]}"
        files = attachments_of(message)
        return line if files.empty?

        "#{line} [#{files.map { |file| "#{file["name"]}: #{file["path"]}" }.join(", ")}]"
      end

      # Ids for people, a fixed label for the bot. Resolving names would cost a
      # lookup per author, and the model needs to tell its own lines from
      # everyone else's, not to know who everyone is.
      def author_label(user_id)
        user_id.to_i == @bot_user_id ? "bot" : user_id.to_s
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
          "files"             => attachment_summary(event),
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

      # --- attachments ---------------------------------------------------

      # Pachca's event payload never carries the files: its own documentation
      # says so outright — "по payload нельзя определить, есть ли у сообщения
      # вложение". So finding out costs one GET /messages/{id} per item the
      # runner decided to act on, which is cheap (reads are rate-limited at
      # ~10/s) and only happens for real questions.
      #
      # Downloaded by the daemon rather than left to the agent, for two
      # reasons: a picture has to exist as a file before the backend can name
      # it on the command line, and an agent told to fetch a URL may simply
      # not bother.
      #
      # Failures here never sink the run. An answer written without the
      # screenshot is worse than one written with it, and far better than none.
      def attachments(event)
        return @attachments[event["id"]] if @attachments.key?(event["id"])

        @attachments[event["id"]] = fetch_attachments(event)
      end

      def fetch_attachments(event)
        message_id = event.dig("payload", "id")
        return [] if message_id.nil? || !@download_attachments

        attachments_of(@client.message(message_id))
      rescue ::AgentDaemon::RateLimitError
        raise
      rescue => e
        Log.warn("[#{log_tag}] could not read attachments of #{message_id}: #{e.message}")
        []
      end

      # Files of one message, downloaded once. Thread messages arrive from the
      # context fetch already carrying their `files`, so an old screenshot
      # costs no request at all — only the question itself does, because its
      # event payload has no files to carry.
      #
      # @downloads is the whole run's budget. A thread of fifty messages each
      # with a screenshot would otherwise be fifty downloads before the agent
      # says a word; past the cap, files are named in the transcript but not
      # fetched.
      def attachments_of(message)
        id = message["id"]
        return [] if id.nil? || !@download_attachments
        return @by_message[id] if @by_message.key?(id)

        @by_message[id] = Array(message["files"]).filter_map do |file|
          next nil if @downloads >= @max_attachments

          downloaded = download(file, id)
          @downloads += 1 if downloaded
          downloaded
        end
      end

      def download(file, message_id)
        url = file["url"].to_s
        return nil if url.empty?

        # Under message_dir because that is the one directory the agent is
        # already allowed to write to — the gem passes it to the sandbox as
        # --add-dir. A subdirectory is safe: the Messenger only ever globs
        # *.yml at the top level.
        dir = ::File.join(@message_dir, "attachments", message_id.to_s)
        FileUtils.mkdir_p(dir)
        path = ::File.join(dir, safe_name(file["name"], file["id"]))

        body = @client.fetch_file(url, limit: @max_attachment_bytes)
        return nil if body.nil?

        ::File.binwrite(path, body)
        { "path" => path, "name" => file["name"], "type" => file["file_type"] }
      rescue => e
        Log.warn("[#{log_tag}] could not download #{file['name'].inspect}: #{e.message}")
        nil
      end

      # The name comes from whoever sent the message, so it decides only the
      # basename and never the directory.
      def safe_name(name, id)
        base = ::File.basename(name.to_s.strip)
        base = "attachment-#{id}" if base.empty? || base.start_with?(".")
        base.gsub(%r{[/\\\0]}, "_")
      end

      # What the prompt shows: names and local paths, so the agent can open a
      # log or a CSV itself. Images are also handed to the backend separately —
      # reading a PNG through the shell yields bytes, not a picture.
      def attachment_summary(event)
        downloaded = attachments(event)
        return "" if downloaded.empty?

        downloaded.map { |file| "- #{file['name']} (#{file['type']}): #{file['path']}" }.join("\n")
      end

      # Everything downloaded this run, thread included — render_prompt has
      # already walked the transcript by the time process_item asks for images.
      #
      # Newest first and capped, because a picture is expensive in a way a line
      # of text is not: a thread with a dozen screenshots would spend most of
      # the context on the oldest of them. What does not fit is still named in
      # the transcript with its path, so the agent can say which one it needs.
      def run_images(event)
        own = images_among(attachments(event))
        return own.last(@max_images).map { |file| file["path"] } if own.size >= @max_images

        # Everything else downloaded this run — render_prompt has already walked
        # the transcript by the time process_item asks. Newest first, and the
        # question's own files last of all: they are the ones being asked about.
        message_id = event.dig("payload", "id")
        earlier = images_among(@by_message.reject { |id, _| id == message_id }.values.flatten)

        (earlier.last(@max_images - own.size) + own).map { |file| file["path"] }
      end

      def images_among(files)
        files.select { |file| file["type"] == IMAGE_TYPE }
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
