# frozen_string_literal: true

require "securerandom"

module AgentDaemon
  module Supervisor
    module Console
      # Server-side session store for the web console (AD-7). The browser holds
      # only an opaque id in a cookie; everything else lives here, in this
      # process, behind one mutex.
      #
      # Why not Rack::Session::Cookie: (1) Rack 3 moved Rack::Session into a
      # separate rack-session gem, which is a dependency AD-6 does not
      # authorize; (2) AC5 needs real revocation — logout must invalidate a live
      # session on the spot, and Story 2.6's mid-stream SSE re-check must be
      # able to consult the same mechanism. A signed client-side cookie can do
      # neither: it is valid until it expires, no matter what the server thinks.
      #
      # Expiry is measured on the MONOTONIC clock, so an NTP step or a manual
      # date change can neither extend nor prematurely kill a session. The clock
      # is injectable so tests advance time instead of sleeping.
      #
      # AD-5 isolation: reachable only from the console tree; stdlib only.
      class SessionStore
        # kind ∈ :pending (pre-login; carries the OAuth `state`)
        #      | :authenticated (post-login; carries username + csrf_token)
        Session = Struct.new(:id, :kind, :username, :state, :csrf_token, :expires_at, keyword_init: true)

        # A login that has not come back from GitLab within 10 minutes is
        # abandoned, not honoured — the pending record holds the `state` that
        # authorizes a callback, so its lifetime is the window of exposure.
        PENDING_TTL = 600

        # 32 bytes of CSPRNG entropy per id and per CSRF token.
        ID_BYTES = 32

        # Hard ceiling on live entries. /auth/login is reachable with no
        # authentication at all, so without a ceiling an anonymous client can
        # grow this hash for PENDING_TTL seconds at a time inside the process
        # that also owns the fleet. Refusing a login is recoverable; an OOM in
        # the master is not. NFR7 sizes the real fleet at <10 viewers, so this
        # is three orders of magnitude above legitimate use.
        MAX_SESSIONS = 1_000

        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

        def initialize(ttl:, clock: MONOTONIC)
          @ttl = ttl
          @clock = clock
          @mutex = Mutex.new
          @sessions = {}
        end

        # Starts a login. Sweeps opportunistically: there is no timer thread
        # here on purpose — AD-13 enumerates exactly three supervised entity
        # kinds and a sweeper is none of them, and at NFR7's <10 viewers a
        # login-time sweep is more than enough to bound the hash.
        #
        # Returns nil when the store is at MAX_SESSIONS. The caller must treat
        # that as a refusal, not as a session: the sweep runs first, so a full
        # store means genuinely live entries, i.e. a flood.
        def create_pending(state:)
          now = @clock.call
          @mutex.synchronize do
            purge_expired(now)
            return nil if @sessions.size >= MAX_SESSIONS

            session = Session.new(
              id: mint_id,
              kind: :pending,
              state: state,
              expires_at: now + PENDING_TTL
            )
            @sessions[session.id] = session
          end
        end

        # Completes a login: consumes the pending session and mints a session
        # under a BRAND-NEW id (AC4 anti-fixation rotation).
        #
        # Returns nil — and mints nothing, and destroys nothing — when the id
        # is unknown, expired, or not actually pending. That is not a defensive
        # impossibility: the OAuth round-trip between #create_pending and here
        # is network-bound and can outlive PENDING_TTL, and the caller must then
        # deny.
        #
        # Only a genuinely pending id is consumed. Deleting first and checking
        # afterwards would let a caller revoke an authenticated session by
        # handing its id to #promote, which is exactly the forced-logout shape
        # the middleware is careful to avoid.
        def promote(pending_id, username:)
          now = @clock.call
          @mutex.synchronize do
            pending = live(pending_id, now)
            return nil unless pending&.kind == :pending

            # Consumed on both outcomes below, so a `state` is single-use.
            @sessions.delete(pending_id)

            session = Session.new(
              id: mint_id,
              kind: :authenticated,
              username: username,
              csrf_token: SecureRandom.urlsafe_base64(ID_BYTES),
              expires_at: now + @ttl
            )
            @sessions[session.id] = session
          end
        end

        # The live session, or nil when the id is unknown or expired. Never
        # raises: it is called with whatever arbitrary cookie value a client
        # sent, on every single request.
        def fetch(id)
          return nil if id.nil?

          now = @clock.call
          @mutex.synchronize { live(id, now) }
        end

        # Idempotent revocation.
        def destroy(id)
          return if id.nil?

          @mutex.synchronize { @sessions.delete(id) }
          nil
        end

        def sweep_expired!
          now = @clock.call
          @mutex.synchronize { purge_expired(now) }
          nil
        end

        # Live session count. Exists so expiry and sweeping are observable —
        # #fetch alone cannot distinguish "swept" from "deleted on read".
        def size
          @mutex.synchronize { @sessions.size }
        end

        private

        # Caller holds the lock. Deletes on read when expired, so an expired
        # entry can never be resurrected by a later clock question.
        def live(id, now)
          session = @sessions[id]
          return nil unless session

          if session.expires_at <= now
            @sessions.delete(id)
            return nil
          end

          session
        end

        def purge_expired(now)
          @sessions.delete_if { |_id, session| session.expires_at <= now }
        end

        def mint_id
          SecureRandom.urlsafe_base64(ID_BYTES)
        end
      end
    end
  end
end
