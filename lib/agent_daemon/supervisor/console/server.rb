# frozen_string_literal: true

require "puma"
require "puma/log_writer"
require "uri"

require_relative "../../log"
require_relative "app"
require_relative "auth"
require_relative "gitlab_oauth"
require_relative "live_updates"
require_relative "session_store"

module AgentDaemon
  module Supervisor
    module Console
      # Embeds Puma in the master process and composes the console's middleware
      # stack (AD-6). This is where the default-deny property is wired: the app
      # is constructed already wrapped in Auth, so there is no way to mount it
      # bare (security review F1).
      #
      # SINGLE PROCESS, never clustered. A forked Puma worker could not see the
      # master's in-process StateRegistry/EventBus, which is the entire point of
      # AD-1/AD-4 and of Story 2.3 onward.
      #
      # The server thread is a plain master-owned thread, NOT a supervised
      # entity: AD-13 enumerates exactly three entity kinds (runner, messenger,
      # reactor) and the console is none of them.
      class Server
        # Puma's accept loop stops synchronously; this bounds the wait for the
        # thread that was serving in-flight requests.
        STOP_TIMEOUT = 5

        # Puma's own stop can consume the whole budget, and Thread#join(0)
        # returns nil immediately even for a thread microseconds from exiting
        # — which would warn about a deadline the thread never got, then drop
        # the reference to a thread that is still running.
        JOIN_FLOOR = 0.5

        attr_reader :port

        def initialize(console_config, fleet:, activity_log:, event_bus:, state_registry:, output_buffers:,
                       log_writer: Puma::LogWriter.stdio)
          @bind = console_config.fetch("bind")
          @port = console_config.fetch("port")
          @max_threads = console_config.fetch("max_threads")
          @session_ttl = console_config.fetch("session_ttl")
          @secure_cookies = console_config.fetch("secure_cookies")
          @base_url = console_config.fetch("base_url")
          @auth_config = console_config.fetch("auth")
          @fleet = fleet
          @activity_log = activity_log
          @output_buffers = output_buffers
          @live_updates = LiveUpdates.new(event_bus: event_bus, state_registry: state_registry)
          @log_writer = log_writer
        end

        def start
          # #stop latches the stream loop for the drain; this object is
          # re-enterable, so a restarted console must un-latch it or every
          # stream it accepts would close on its first iteration.
          @live_updates.resume!
          @server = Puma::Server.new(app, nil, {
                                       min_threads: 0,
                                       # Must exceed the peak count of concurrent
                                       # SSE streams (AD-6): from Story 2.6 each
                                       # live stream parks one thread for its
                                       # whole lifetime.
                                       max_threads: @max_threads,
                                       # Load-bearing. Puma's #stop(true) joins
                                       # its thread with NO timeout, and the
                                       # pool waits forever because
                                       # force_shutdown_after defaults to -1. So
                                       # one wedged request — a callback blocked
                                       # on a hung GitLab today, a parked SSE
                                       # stream from Story 2.6 — would make
                                       # Master#stop_console never return, and
                                       # the orphan sweep behind it never run.
                                       # Master's rescue cannot help: it catches
                                       # exceptions, not hangs.
                                       force_shutdown_after: STOP_TIMEOUT,
                                       log_writer: @log_writer
                                     })
          # Returns the TCPServer; with port 0 the OS assigns one, so the bound
          # port is only knowable from the listener itself.
          io = @server.add_tcp_listener(@bind, @port)
          @port = io.addr[1]
          @thread = run_server
          self
        rescue StandardError
          # The listener is bound before the thread exists, and Master records
          # the server only after #start returns — so without this the socket
          # would stay bound for the life of the master with nothing able to
          # close it.
          close_listener
          raise
        end

        def stop
          return unless @server

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @live_updates.stop!
          @server.stop(true)
          remaining = [STOP_TIMEOUT - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started), JOIN_FLOOR].max
          if @thread && !@thread.join(remaining)
            waited = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
            Log.warn("[Console] server thread did not finish within #{waited}s")
          end
          @server = nil
          @thread = nil
        end

        def running?
          !!@thread&.alive?
        end

        private

        # Its own method so a test can make the window between "listener bound"
        # and "thread running" fail on purpose — the window the rescue above
        # exists for.
        def run_server
          @server.run
        end

        def close_listener
          @server&.binder&.close
        rescue StandardError
          nil
        ensure
          @server = nil
          @thread = nil
        end

        # Memoized: the store IS the session state. Building it twice would
        # silently invalidate every live session, so the single-construction
        # contract is enforced here rather than left to call order.
        def app
          @app ||= build_app
        end

        def build_app
          @sessions = SessionStore.new(ttl: @session_ttl)
          Auth.new(
            App.new(fleet: @fleet, activity_log: @activity_log, live_updates: @live_updates,
                    output_buffers: @output_buffers),
            sessions: @sessions,
            gitlab: gitlab,
            allowed_groups: @auth_config.fetch("allowed_groups"),
            secure_cookies: @secure_cookies
          )
        end

        def gitlab
          GitlabOAuth.new(
            host: @auth_config.fetch("gitlab_host"),
            app_id: @auth_config.fetch("app_id"),
            app_secret: @auth_config.fetch("app_secret"),
            # Built ONCE, from the explicitly configured public origin rather
            # than from attacker-influenceable Host/X-Forwarded-* headers, and
            # reused byte-identically by both the authorize redirect and the
            # token exchange — GitLab rejects the exchange otherwise.
            redirect_uri: URI.join(@base_url, "/auth/callback").to_s
          )
        end
      end
    end
  end
end
