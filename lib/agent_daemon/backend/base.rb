# frozen_string_literal: true

require "open3"
require "shellwords"

module AgentDaemon
  module Backend
    Result = Struct.new(:success, :stdout, :stderr, :reason, :started_at, :finished_at, :pid)

    # How often to wake up from IO.select to check deadline / shutdown.
    POLL_INTERVAL = 0.5
    # Grace period between SIGTERM and SIGKILL when killing process group.
    TERM_GRACE_SECONDS = 2

    BACKENDS = {
      "claude" => -> { Claude },
      "opencode" => -> { OpenCode },
      "codex" => -> { Codex }
    }.freeze

    VALID_NAMES = BACKENDS.keys.freeze

    # Picks the backend class for a runner, honouring an operator-selected
    # fallback.
    #
    # Exact FALLBACK_AGENT=1 swaps in `fallback_agent`; every other value, and
    # a runner without the key, keeps the configured backend. The switch is
    # process-wide on purpose — it exists for the case where one account's
    # quota is exhausted and every runner has to move at once.
    #
    # `fallback_agent` takes either form:
    #
    #   fallback_agent: claude                        # another backend by name
    #   fallback_agent: {command: omp, args: [...]}   # an arbitrary CLI
    #
    # The named form matters because the arbitrary-CLI form inherits none of
    # the flags a backend builds for itself. Writing "claude" as a raw command
    # means restating --add-dir, --model, --agent, --output-format and
    # --dangerously-skip-permissions by hand, and getting one of them wrong is
    # a fallback that fails exactly when it is needed.
    def self.for(runner_config, shutdown_flag, message_dir:, project_path:, sinks: nil, cancel_flag: nil)
      name = runner_config.fetch("backend", "claude")
      unless BACKENDS.key?(name)
        raise ArgumentError, "Unsupported backend #{name.inspect} in runner #{runner_config['name'].inspect}. " \
                             "Valid values: #{VALID_NAMES.join(', ')}"
      end

      klass = fallback_class(runner_config) || BACKENDS.fetch(name).call
      klass.new(runner_config, shutdown_flag, message_dir: message_dir, project_path: project_path,
                                              sinks: sinks, cancel_flag: cancel_flag)
    end

    # The fallback applies to every backend, not just claude: whichever agent a
    # runner normally uses, it is the one that can run out of quota.
    def self.fallback_class(runner_config)
      return nil unless ENV["FALLBACK_AGENT"] == "1"

      fallback = runner_config["fallback_agent"]
      case fallback
      when String then BACKENDS[fallback]&.call
      when Hash then ConfiguredAgent
      end
    end
    private_class_method :fallback_class

    class Base
      def initialize(runner_config, shutdown_flag, message_dir:, project_path:, sinks: nil, cancel_flag: nil)
        @runner_config = runner_config
        @shutdown_flag = shutdown_flag
        @message_dir = message_dir
        @project_path = project_path
        @sinks = sinks || Sinks::Bundle.null
        # Optional per-runner cancel token: any object responding to #value
        # (truthy = cancel), the same protocol as ShutdownFlag. Nothing sets
        # it yet — the supervisor passes a real token when respawn/manual
        # restart lands.
        @cancel_flag = cancel_flag
        @current_pid = nil
        # Per-instance monotonic run id. Deterministic and stdlib; unique
        # enough because every record also carries entity_id and generation,
        # and the supervisor mints a fresh backend per generation.
        @run_seq = 0
      end

      def run(prompt)
        cmd = build_command(prompt)
        timeout = @runner_config.fetch("timeout", 1200)
        execute(cmd, timeout: timeout)
      end

      # Last-resort sweep entry point (Story 1.6 Task 4): the master calls
      # this on a thread that survived the join(30) drain, for a runner whose
      # own select loop never got to observe the shared flag. Ivar read/write
      # is GIL-atomic (same contract as ShutdownFlag) — no mutex needed.
      def kill_current_process_group
        pid = @current_pid
        kill_process_group(pid) if pid
      end

      private

      def build_command(_prompt)
        raise NotImplementedError, "#{self.class}#build_command is not implemented"
      end

      # Run cmd via popen3 with its own process group. Loop on IO.select with
      # POLL_INTERVAL, appending stdout/stderr chunks to buffers and through
      # the output sink, checking the deadline, the shutdown flag, and the
      # optional cancel flag on every wake. Remaining output is drained on
      # every terminal path — including :timeout and :killed — before the
      # child is reaped. Returns a Result whose `reason` is one of :ok,
      # :failed, :timeout, :killed, carrying start/end timestamps and the
      # child pid.
      def execute(cmd, timeout:)
        started_at = Time.now.utc
        deadline = Time.now + timeout
        stdout_buf = +""
        stderr_buf = +""
        reason = nil
        pid = nil
        finished_at = nil
        run_id = (@run_seq += 1)

        # The run is opened before the child exists and closed in an ensure
        # around the WHOLE body — deliberately outside the popen3 block, where
        # a block-level ensure would fire before Open3's own wait_thr.join
        # (see the @current_pid note below). Outside, an exception escaping
        # execute still flushes a buffered partial line and clears the
        # entity's buffers, so the next run cannot inherit a fragment.
        @sinks.begin_output_run(run_id)

        Open3.popen3(cmd, pgroup: true) do |stdin, out, err, wait_thr|
          stdin.close
          pid = wait_thr.pid
          @current_pid = pid
          streams = [out, err]

          loop do
            if @shutdown_flag.value || @cancel_flag&.value
              reason = :killed
              kill_process_group(pid)
              break
            end

            if Time.now > deadline
              reason = :timeout
              kill_process_group(pid)
              break
            end

            ready, = IO.select(streams, nil, nil, POLL_INTERVAL)
            if ready
              ready.each do |io|
                begin
                  chunk = io.read_nonblock(4096)
                  if io == out
                    append_chunk(:stdout, chunk, stdout_buf)
                  else
                    append_chunk(:stderr, chunk, stderr_buf)
                  end
                rescue IO::WaitReadable
                  next
                rescue EOFError
                  streams.delete(io)
                end
              end
            end

            if streams.empty? && !wait_thr.alive?
              break
            end
          end

          # Drain whatever is left — on every terminal path, including
          # :timeout and :killed — and reap the process.
          drain_remaining(out, :stdout, stdout_buf)
          drain_remaining(err, :stderr, stderr_buf)

          status = wait_thr.value
          reason ||= status.success? ? :ok : :failed
          finished_at = Time.now.utc
          # Cleared only once the child is reaped, and deliberately NOT in an
          # ensure: a block-level ensure fires BEFORE Open3's own wait_thr.join,
          # so an exception escaping this block (a raising output sink, say)
          # would drop the pid while the child is still alive — precisely the
          # orphan the master's sweep exists to reap.
          @current_pid = nil
        end

        success = reason == :ok
        Result.new(success, stdout_buf, stderr_buf, reason, started_at, finished_at, pid)
      ensure
        # `reason` is nil here when the body raised before a terminal reason
        # was assigned; sinks accept nil as an opaque "run aborted" value.
        @sinks.end_output_run(run_id, reason)
      end

      # The single ingress for agent output: every chunk — read in the select
      # loop or drained after it — lands in the buffer and goes through the
      # output sink here.
      def append_chunk(stream, chunk, buf)
        buf << chunk
        @sinks.append_output(stream, chunk)
      end

      def drain_remaining(io, stream, buf)
        loop do
          append_chunk(stream, io.read_nonblock(4096), buf)
        rescue IO::WaitReadable, EOFError, IOError
          break
        end
      end

      # Send SIGTERM to the entire process group, wait up to TERM_GRACE_SECONDS,
      # then SIGKILL whatever is left. Tolerates the race where the group is
      # already gone (Errno::ESRCH). pid is the process group leader (the
      # popen3 child started with `pgroup: true`), so its pid equals its pgid.
      def kill_process_group(pid)
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        # Group already gone.
      else
        waited = 0.0
        step = 0.1
        while waited < TERM_GRACE_SECONDS
          begin
            Process.kill(0, -pid)
          rescue Errno::ESRCH, Errno::EPERM
            return
          end
          sleep(step)
          waited += step
        end

        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH, Errno::EPERM
          # Group died between the last probe and KILL.
        end
      end

      def extra_flags
        @runner_config.fetch("extra_flags", "").to_s.strip
      end

      def add_dir_paths
        [@message_dir, @runner_config["output_dir"]].compact.uniq
      end
    end
  end
end
