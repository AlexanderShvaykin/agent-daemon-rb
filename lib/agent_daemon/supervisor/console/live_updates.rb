# frozen_string_literal: true

require "io/wait"

require_relative "../../log"

module AgentDaemon
  module Supervisor
    module Console
      # Owns one authenticated SSE connection. It observes only the master's
      # read models and emits fixed invalidation frames; page HTML remains the
      # single rendering contract.
      class LiveUpdates
        POLL_INTERVAL = 0.25
        HEARTBEAT_INTERVAL = 15.0

        # A hijacked socket is raw: a client that stops reading fills the send
        # buffer and a plain #write then blocks forever, INSIDE the write —
        # never at the #stopping check — so the thread is unrecoverable and
        # the cursor stays registered. One stalled tab must cost one dropped
        # stream, not one permanently parked Puma thread out of max_threads
        # (AC5). Dropping is safe: the browser's EventSource reconnects.
        WRITE_TIMEOUT = 5.0

        RETRY_FRAME = "retry: 1000\n\n"
        REFRESH_FRAME = "event: refresh\ndata: refresh\n\n"
        AUTHORIZATION_LOST_FRAME = "event: authorization_lost\ndata: authorization_lost\n\n"
        HEARTBEAT_FRAME = ": heartbeat\n\n"

        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        WAIT = ->(seconds) { sleep(seconds) }

        # The whole ordinary "the client went away" family. A closing browser
        # tab is not a fleet error, and each missing errno here is one ERROR
        # line per normal disconnect: macOS/BSD raise EPROTOTYPE writing to a
        # socket whose peer has gone, and ETIMEDOUT is what #write_frame
        # raises for a client that stopped reading.
        DISCONNECT_ERRORS = [
          IOError, EOFError,
          Errno::EPIPE, Errno::EBADF, Errno::ECONNRESET, Errno::ECONNABORTED,
          Errno::ENOTCONN, Errno::ETIMEDOUT, Errno::EPROTOTYPE
        ].freeze

        def initialize(event_bus:, state_registry:, clock: MONOTONIC, wait: WAIT)
          @event_bus = event_bus
          @state_registry = state_registry
          @clock = clock
          @wait = wait
          @stopping = false
        end

        def stop! = @stopping = true

        # Server#stop latches #stopping for the drain; Server#start is
        # re-enterable, so without this a restarted console would accept
        # streams and break out of every one of them on its first iteration.
        def resume! = @stopping = false

        def stream(io, authorized:)
          @event_bus.subscribe(from: :tail) do |cursor|
            revision = @state_registry.revision
            dropped = @event_bus.dropped(cursor)
            last_heartbeat = @clock.call

            write_frame(io, RETRY_FRAME)
            write_frame(io, REFRESH_FRAME)

            loop do
              break if @stopping

              unless authorized.call
                best_effort_write(io, AUTHORIZATION_LOST_FRAME)
                break
              end

              records = cursor.read
              current_revision = @state_registry.revision
              current_dropped = @event_bus.dropped(cursor)
              if records.any? || current_revision != revision || current_dropped != dropped
                write_frame(io, REFRESH_FRAME)
                revision = current_revision
                dropped = current_dropped
              end

              now = @clock.call
              if now - last_heartbeat >= HEARTBEAT_INTERVAL
                write_frame(io, HEARTBEAT_FRAME)
                last_heartbeat = now
              end

              @wait.call(POLL_INTERVAL)
            end
          end
        rescue *DISCONNECT_ERRORS
          nil
        rescue StandardError => e
          Log.error("[Console] live-update stream failed: #{e.class}")
          nil
        ensure
          best_effort_close(io)
        end

        private

        def best_effort_write(io, frame)
          write_frame(io, frame)
        rescue StandardError
          nil
        end

        # Bounded write. A raw socket gets the non-blocking path with a
        # writability deadline; anything else (a StringIO, a test harness)
        # keeps the plain #write it already supports.
        def write_frame(io, frame)
          return io.write(frame) unless io.respond_to?(:write_nonblock) && io.respond_to?(:wait_writable)

          remaining = frame
          until remaining.empty?
            written = io.write_nonblock(remaining, exception: false)
            case written
            when :wait_writable
              raise Errno::ETIMEDOUT unless io.wait_writable(WRITE_TIMEOUT)
            when nil then raise IOError, "stream closed"
            else remaining = remaining.byteslice(written, remaining.bytesize - written)
            end
          end
          frame.bytesize
        end

        def best_effort_close(io)
          io.close
        rescue StandardError
          nil
        end
      end
    end
  end
end
