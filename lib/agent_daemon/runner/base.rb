# frozen_string_literal: true

require "yaml"
require "time"
require "fileutils"

module AgentDaemon
  module Runner
    class Base
      MAX_CONSECUTIVE_ERRORS = 3

      attr_reader :name

      def initialize(runner_config, message_dir, project_path, shutdown_flag, sinks: nil, cancel_flag: nil)
        @runner_config = runner_config
        @message_dir = message_dir
        @project_path = project_path
        @shutdown_flag = shutdown_flag
        @cancel_flag = cancel_flag
        @name = runner_config.fetch("name")
        @sinks = sinks || Sinks::Bundle.null(@name)
        @max_attempts = runner_config.fetch("max_attempts")
        @interval = runner_config.fetch("trigger").fetch("interval")
        @jitter = runner_config.fetch("trigger").fetch("jitter", 0)
        @attempts = Hash.new(0)
        @consecutive_errors = 0
        @backoff = nil
        @backend = Backend.for(runner_config, shutdown_flag,
                               message_dir: message_dir, project_path: project_path,
                               sinks: @sinks, cancel_flag: cancel_flag)
        @effective_backend = if @backend.is_a?(Backend::ConfiguredAgent)
                               runner_config.fetch("fallback_agent").fetch("command")
                             else
                               runner_config.fetch("backend", "claude")
                             end
        @prompt_template = PromptTemplate.new(runner_config.fetch("prompt_template_path"))
      end

      def run
        Log.info("[#{log_tag}] Thread started")
        @sinks.publish_state(status: :waiting)

        until stopping?
          iterate
          wait_interval(next_wait_seconds)
        end

        @sinks.publish_state(status: :stopped) unless cancelling?
        Log.info("[#{log_tag}] Thread stopping gracefully")
      end

      # Master sweep entry point (Story 1.6 Task 4): reached only when this
      # runner's thread survived the drain join — its own poll loop never
      # observed the shared flag. Delegates to the backend's last-known pid.
      def kill_in_flight_agent
        @backend.kill_current_process_group
      end

      private

      def log_tag
        "Runner #{@name}"
      end

      def stopping?
        @shutdown_flag.value || @cancel_flag&.value
      end

      # Local restart is the SOLE cause of the stop. Gates the two state
      # publishes the supervisor owns during a turnover — never the loop
      # exits, which take either signal. When both are set shutdown wins, so
      # a token latched just before a fleet drain still publishes :stopped
      # and cannot strand the entity on :restart_requested (NFR5, AC13).
      def cancelling?
        @cancel_flag&.value && !@shutdown_flag.value
      end

      def iterate
        items = fetch_work_items_with_escalation
        return if items.nil? || items.empty?

        Log.info("[#{log_tag}] Found #{items.size} work item(s)")

        items.each do |item|
          break if stopping?
          process_item(item)
        end
      rescue => e
        Log.error("[#{log_tag}] Unexpected error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
        raise
      end

      def fetch_work_items_with_escalation
        items = fetch_work_items
        @consecutive_errors = 0
        items
      rescue AgentDaemon::RateLimitError => e
        # A throttle is the server pacing us, not a trigger failure: back off for
        # the suggested duration without touching the consecutive-error counter,
        # so it never escalates to a SYSTEM:<runner> message.
        @backoff = e.retry_after
        Log.warn("[#{log_tag}] rate limited, backing off #{e.retry_after}s")
        []
      rescue => e
        @consecutive_errors += 1
        Log.error("[#{log_tag}] trigger error (#{@consecutive_errors}/#{MAX_CONSECUTIVE_ERRORS}): #{e.message}")

        if @consecutive_errors >= MAX_CONSECUTIVE_ERRORS
          create_error_message("trigger_error", error_text: e.message)
          @consecutive_errors = 0
        end

        []
      end

      def process_item(item)
        key = work_item_key(item)

        if @attempts[key] >= @max_attempts
          Log.error("[#{log_tag}] #{key} skipped: exhausted #{@max_attempts} attempts")
          after_exhausted(item)
          return
        end

        @sinks.publish_event(type: :picked_up, work_item: key, at: Time.now.utc.iso8601)
        prompt = render_prompt(item)
        @attempts[key] += 1
        attempt_no = @attempts[key]
        Log.info("[#{log_tag}] Running #{@effective_backend} for #{key} (attempt #{attempt_no}/#{@max_attempts})")

        @sinks.publish_event(type: :started, work_item: key, attempt: attempt_no, at: Time.now.utc.iso8601)
        @sinks.publish_state(status: :in_progress, work_item: key, attempt: attempt_no)
        before_attempt(item)
        files_before = expects_message_file? ? message_file_snapshot : nil
        result = @backend.run(prompt)

        case result.reason
        when :ok
          # A zero exit code is not the same as work done. Agent CLIs report
          # success for plenty of runs that produced nothing: an
          # unauthenticated `claude -p` prints "Not logged in" and exits 0, a
          # sandbox that refused the write leaves the agent politely explaining
          # it could not save the file, a message_dir that does not exist does
          # the same. For a trigger that archives on success the damage is at
          # least visible; for one that acknowledges by deleting, the work item
          # is gone and nobody learns a question went unanswered.
          #
          # So when a reply was expected and none appeared, this is a failure:
          # attempt counted, work item kept, next cycle retries.
          if files_before && !wrote_message?(files_before)
            Log.error("[#{log_tag}] #{key} exited 0 but wrote no message " \
                      "(attempt #{attempt_no}/#{@max_attempts}): #{result.stdout.lines.last&.strip}")
            Log.debug("[#{log_tag}] Full output:\n#{result.stdout}")
            create_error_message("no_message", work_item: key, error_text: result.stdout) if attempt_no >= @max_attempts
            after_failure(item)
          else
            @attempts.delete(key)
            Log.info("[#{log_tag}] #{key} done: #{result.stdout.lines.first&.strip}")
            Log.debug("[#{log_tag}] Full output:\n#{result.stdout}")
            after_success(item)
          end
        when :timeout
          Log.error("[#{log_tag}] CLI timeout for #{key} (attempt #{attempt_no}/#{@max_attempts})")
          create_error_message("timeout", work_item: key) if attempt_no >= @max_attempts
          after_failure(item)
        when :failed
          Log.error("[#{log_tag}] CLI failed for #{key} (attempt #{attempt_no}/#{@max_attempts}): #{result.stderr.strip}")
          create_error_message("cli_failed", work_item: key, error_text: result.stderr) if attempt_no >= @max_attempts
          after_failure(item)
        when :killed
          @attempts[key] -= 1
          # Same precedence as cancelling?: with both signals set the fleet is
          # draining, and that is what the operator needs to read here.
          cause = @shutdown_flag.value ? "shutdown" : "restart"
          Log.info("[#{log_tag}] CLI killed for #{key} (#{cause}), attempt rolled back")
          after_killed(item)
        end

        @sinks.publish_event(type: :finished, work_item: key, reason: result.reason, attempt: attempt_no, at: Time.now.utc.iso8601)
        @sinks.publish_state(status: :waiting) unless cancelling?
      end

      # --- Extension points ---

      def fetch_work_items
        raise NotImplementedError, "#{self.class}#fetch_work_items"
      end

      def work_item_key(_item)
        raise NotImplementedError, "#{self.class}#work_item_key"
      end

      def render_prompt(_item)
        raise NotImplementedError, "#{self.class}#render_prompt"
      end

      # Whether a run that leaves no message file behind should count as a
      # failure. Off by default: a runner whose agent is expected to act rather
      # than write — move a ticket, start a detached job — has no artefact to
      # look for, and demanding one would turn working setups into failing ones.
      #
      # A trigger that acknowledges by deleting the work item turns this on,
      # because there a silent no-op is unrecoverable.
      def expects_message_file?
        false
      end

      # Message files as name => mtime, including ones the Messenger has
      # already moved to sent/. Both directories are counted because the
      # Messenger polls the same directory: a reply written near the end of a
      # run can be picked up before this check runs, and missing it would mean
      # answering twice.
      #
      # Keyed by name but compared by mtime, because names repeat. A prompt
      # naturally derives the filename from the work item ("write your answer
      # to <event id>.yml"), so a retry — or a second summons on the same PR,
      # which GitHub reports under the notification id it used before — writes
      # the name that is already sitting in sent/ from the previous run. Names
      # alone would call that run silent and retry an answer already delivered.
      def message_file_snapshot
        return {} if @message_dir.nil?

        [@message_dir, ::File.join(@message_dir, "sent")]
          .flat_map { |dir| Dir.glob(::File.join(dir, "*.{yml,yaml}")) }
          .each_with_object({}) do |path, snapshot|
            name = ::File.basename(path)
            # The Messenger may move a file out from under the glob; that file
            # is a delivered reply either way, so skip it rather than lose the
            # whole snapshot to one race.
            mtime = begin
              ::File.mtime(path)
            rescue SystemCallError
              next
            end
            # The same name can sit in both directories at once — a fresh reply
            # in the queue beside the delivered one it replaces. Keep the later
            # of the two: the question is when this name was last written, and
            # taking whichever the glob happened to yield second would hide the
            # new file behind the old one's timestamp.
            snapshot[name] = mtime if snapshot[name].nil? || mtime > snapshot[name]
          end
      rescue SystemCallError
        {}
      end

      # Whether the run left a reply behind: a file that was not there before,
      # or one whose name was there but has been written again since.
      def wrote_message?(before)
        message_file_snapshot.any? { |name, mtime| before[name].nil? || mtime > before[name] }
      end

      # Called once per attempt, immediately before the backend runs — the
      # point where a subclass can tell the source it was heard. A run takes
      # minutes, so for a chat trigger this is the difference between a person
      # seeing an acknowledgement and seeing silence. Must be cheap and must
      # not raise: it sits directly in front of the agent invocation.
      def before_attempt(_item); end

      def after_success(_item); end
      def after_failure(_item); end
      def after_killed(_item); end
      def after_exhausted(_item); end

      # --- Shared helpers ---

      def create_error_message(error_type, work_item: nil, error_text: nil)
        FileUtils.mkdir_p(@message_dir)
        filename = "error-#{@name}-#{Time.now.strftime('%Y%m%d%H%M%S%L')}.yml"
        path = ::File.join(@message_dir, filename)
        message = "Ошибка runner #{@name}: #{error_type}"
        message += "; work item #{work_item}" if work_item
        message += "."
        message += " #{error_text.to_s.strip.slice(0, 500)}" unless error_text.to_s.strip.empty?
        content = {
          "task_key"   => "SYSTEM:#{@name}",
          "summary"    => "Runner #{@name} error",
          "message"    => message,
          "system_alert" => true,
          "runner"     => @name,
          "error_type" => error_type,
          "created_at" => Time.now.iso8601
        }
        content["work_item"] = work_item if work_item
        ::File.write(path, content.to_yaml)
        Log.warn("[#{log_tag}] Created error message file: #{path}")
      end

      def base_template_variables
        vars = @runner_config.transform_keys(&:to_s).merge("message_dir" => @message_dir)
        vars["output_dir"] = @runner_config["output_dir"] if @runner_config["output_dir"]
        vars
      end

      # Duration to wait before the next poll. A pending rate-limit backoff wins
      # (one-shot); otherwise the base interval plus a fresh per-cycle jitter so
      # parallel pollers de-phase instead of firing in the same instant.
      def next_wait_seconds
        if @backoff
          seconds = @backoff
          @backoff = nil
          seconds
        else
          @interval + jitter_amount
        end
      end

      def jitter_amount
        return 0 if @jitter <= 0

        rand * @jitter
      end

      def wait_interval(seconds)
        elapsed = 0
        while elapsed < seconds && !stopping?
          sleep(1)
          elapsed += 1
        end
      end
    end
  end
end
