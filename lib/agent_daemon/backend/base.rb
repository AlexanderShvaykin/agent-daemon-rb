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

    def self.for(runner_config, shutdown_flag, message_dir:, project_path:, sinks: nil, cancel_flag: nil)
      name = runner_config.fetch("backend", "claude")
      case name
      when "claude"
        Claude.new(runner_config, shutdown_flag, message_dir: message_dir, project_path: project_path, sinks: sinks, cancel_flag: cancel_flag)
      when "opencode"
        OpenCode.new(runner_config, shutdown_flag, message_dir: message_dir, project_path: project_path, sinks: sinks, cancel_flag: cancel_flag)
      else
        raise ArgumentError, "Unsupported backend #{name.inspect} in runner #{runner_config['name'].inspect}. Valid values: claude, opencode"
      end
    end

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
      end

      def run(prompt)
        cmd = build_command(prompt)
        timeout = @runner_config.fetch("timeout", 1200)
        execute(cmd, timeout: timeout)
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

        Open3.popen3(cmd, pgroup: true) do |stdin, out, err, wait_thr|
          stdin.close
          pid = wait_thr.pid
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
        end

        success = reason == :ok
        Result.new(success, stdout_buf, stderr_buf, reason, started_at, finished_at, pid)
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
