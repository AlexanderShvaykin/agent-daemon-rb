# frozen_string_literal: true

require "io/wait"
require "json"

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

        # Story 3.6: the first payload-carrying frames in the codebase. The
        # three record-carrying frames (output/output_run/output_lagged) each
        # carry an SSE `id:` line so the browser's automatic reconnect replays
        # the right `Last-Event-ID` (AC 10) — EventSource updates its
        # last-event-id buffer from ANY named event that carries one, not
        # only the default "message" event. `output_state` deliberately does
        # NOT: it advances no cursor, and giving it an `id:` would let a state
        # change alone rewrite the browser's resume point.

        # The `id:` line is a control line in a line-oriented protocol, so no
        # byte of it may come from a value this class does not control. Run
        # ids are Integers from Backend::Base#run_seq today, but OutputBuffers
        # type-checks nothing on the way in — one `\n` in a future non-Backend
        # producer's id would inject arbitrary SSE fields. Whitelist rather
        # than coerce, so a legitimately non-numeric id still round-trips.
        SSE_ID_UNSAFE = /[^A-Za-z0-9_.-]/.freeze

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

        def initialize(event_bus:, state_registry:, output_buffers: nil, clock: MONOTONIC, wait: WAIT)
          @event_bus = event_bus
          @state_registry = state_registry
          @output_buffers = output_buffers
          @clock = clock
          @wait = wait
          @stopping = false
        end

        def stop! = @stopping = true

        # Server#stop latches #stopping for the drain; Server#start is
        # re-enterable, so without this a restarted console would accept
        # streams and break out of every one of them on its first iteration.
        def resume! = @stopping = false

        # entity_id/after_generation/after_run_id/after_seq are Story 3.6's
        # output multiplex (AC 1): when entity_id is nil (the fleet page) or
        # @output_buffers was never wired, the loop is byte-identical to the
        # pre-3.6 stream. The bootstrap cursor is the (generation, run_id,
        # seq) triple — App#events resolves it from Last-Event-ID or the
        # page's rendered cursor before calling here, all three or none, so
        # this never sees a partial cursor (that combination only reaches
        # @output_buffers.snapshot, which raises loudly — a caller bug, not
        # attacker input, and is handled by the StandardError rescue below
        # like any other unexpected fault).
        def stream(io, authorized:, entity_id: nil, after_generation: nil, after_run_id: nil, after_seq: nil)
          @event_bus.subscribe(from: :tail) do |cursor|
            revision = @state_registry.revision
            dropped = @event_bus.dropped(cursor)
            last_heartbeat = @clock.call
            output_generation = after_generation
            output_run_id = after_run_id
            output_seq = after_seq
            output_state = nil

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

              if entity_id && @output_buffers
                output_generation, output_run_id, output_seq, output_state =
                  emit_output(io, entity_id, output_generation, output_run_id, output_seq, output_state)
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

        # Dev Notes DR: never subscribes to OutputPipeline (producer-thread
        # fanout must never touch socket IO) — this is a copy-on-read poll of
        # OutputBuffers#snapshot, called once per existing 250 ms tick.
        # Returns the (generation, run_id, seq, state) tuple to carry into the
        # next tick. `seq` is always `tail_seq || 0` when a run is retained, so
        # a started-but-silent run (tail_seq nil) still yields a valid Integer
        # cursor half for the next call, never nil paired with a non-nil run.
        #
        # Generation is part of the cursor because `run_id` alone cannot
        # identify a run across a respawn: RunnerSupervisor#spawn! builds a
        # FRESH Backend per generation (runner_supervisor.rb) and
        # Backend::Base starts `@run_seq = 0`, so generation 4's first run is
        # `run_id == 1` exactly like generation 3's was. Comparing run ids
        # only, a client holding (run 1, seq 57) from the previous generation
        # reads the restarted run as "same run, nothing newer than 57" and
        # silently swallows its opening output — the crash-diagnosis case this
        # panel exists for. OutputBuffers#snapshot has no generation kwarg, so
        # a changed generation is re-read cursor-less to get the full window.
        def emit_output(io, entity_id, generation, run_id, seq, state)
          snapshot = @output_buffers.snapshot(entity_id, after_run_id: run_id, after_seq: seq)
          return [generation, run_id, seq, state] if snapshot.status == :empty

          respawned = !generation.nil? && snapshot.generation != generation
          snapshot = @output_buffers.snapshot(entity_id) if respawned

          event =
            if respawned || snapshot.run_id != run_id then :output_run
            elsif snapshot.lagged then :output_lagged
            elsif snapshot.records.any? then :output
            end
          write_frame(io, output_records_frame(event, snapshot)) if event

          new_state = { finished: snapshot.finished, reason: snapshot.reason, truncated: snapshot.truncated }
          write_frame(io, output_state_frame(new_state)) if new_state != state

          [snapshot.generation, snapshot.run_id, snapshot.tail_seq || 0, new_state]
        end

        # AD-7: record `text` is attacker-influenceable — JSON-encode it (one
        # line, transport-safe) and never interpolate it into anything else.
        # `stream` is a Symbol (:stdout/:stderr) in the Record struct; encoded
        # as its String form since JSON has no Symbol type.
        def output_records_frame(event, snapshot)
          seq = snapshot.tail_seq || 0
          payload = JSON.generate(
            "generation" => snapshot.generation,
            "run" => snapshot.run_id,
            "records" => snapshot.records.map { |r| { "seq" => r.seq, "stream" => r.stream.to_s, "text" => r.text } }
          )
          id = "#{sse_id_token(snapshot.generation)}:#{sse_id_token(snapshot.run_id)}:#{sse_id_token(seq)}"
          "event: #{event}\nid: #{id}\ndata: #{payload}\n\n"
        end

        def sse_id_token(value) = value.to_s.gsub(SSE_ID_UNSAFE, "")

        # `reason` is passed through raw (nil stays JSON null; DR4: reason.nil?
        # is never "still running" — `finished` carries that). The outcome
        # whitelist/clamp for the CSS class lives client-side, mirroring
        # App#terminal_state_line's own reason-is-opaque contract.
        def output_state_frame(state)
          payload = JSON.generate(
            "finished" => state[:finished],
            "reason" => state[:reason]&.to_s,
            "truncated" => state[:truncated]
          )
          "event: output_state\ndata: #{payload}\n\n"
        end

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
