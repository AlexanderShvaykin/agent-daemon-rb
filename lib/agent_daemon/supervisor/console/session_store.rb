# frozen_string_literal: true

require "securerandom"

module AgentDaemon
  module Supervisor
    module Console
      # Server-side storage for pending OAuth states and authenticated console
      # sessions. Token-bearing records never leave this object.
      class SessionStore
        PendingState = Struct.new(:return_to, :expires_at, :claimed, keyword_init: true)
        Session = Struct.new(
          :id, :kind, :username, :states, :csrf_token, :access_token,
          :groups_verified_at, :verification_in_flight, :expires_at,
          keyword_init: true
        )
        PublicSession = Struct.new(:username, :csrf_token, keyword_init: true)

        PENDING_TTL = 600
        MAX_PENDING_STATES = 8

        # A coalesced waiter must not park on the leader's network call: it
        # wakes on this interval to re-check its OWN session, so logout and
        # plain TTL expiry still take effect promptly (DR5), and a leader that
        # dies without broadcasting cannot hold a Puma thread forever.
        VERIFICATION_WAIT_TIMEOUT = 1.0
        ID_BYTES = 32
        MAX_SESSIONS = 1_000
        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

        def initialize(ttl:, clock: MONOTONIC)
          @ttl = ttl
          @clock = clock
          @mutex = Mutex.new
          @verification_changed = ConditionVariable.new
          @sessions = {}
        end

        # Adds a state to this browser's separate pending-login record. The
        # authenticated cookie/id is not consulted or changed.
        def create_pending(state:, pending_id: nil, return_to: "/")
          now = @clock.call
          @mutex.synchronize do
            purge_expired(now)
            pending = live(pending_id, now)
            pending = nil unless pending&.kind == :pending

            if pending
              purge_pending_states(pending, now)
              return nil if pending.states.size >= MAX_PENDING_STATES
            else
              return nil if slot_count >= MAX_SESSIONS

              pending = Session.new(id: mint_id, kind: :pending, states: {})
              @sessions[pending.id] = pending
            end

            return nil if slot_count >= MAX_SESSIONS

            pending.states[state] = PendingState.new(
              return_to: return_to,
              expires_at: now + PENDING_TTL,
              claimed: false
            )
            pending.expires_at = pending.states.values.map(&:expires_at).max
            pending
          end
        end

        # Marks exactly one matching state single-use before network work.
        def claim_pending(id, state)
          now = @clock.call
          @mutex.synchronize do
            pending = live(id, now)
            return nil unless pending&.kind == :pending

            candidate = pending.states[state]
            return nil unless candidate && !candidate.claimed && candidate.expires_at > now

            candidate.claimed = true
            candidate.return_to
          end
        end

        def discard_pending(id, state)
          @mutex.synchronize do
            pending = @sessions[id]
            remove_pending_state(pending, state) if pending&.kind == :pending
          end
          nil
        end

        # Completes a previously claimed state, rotates the authenticated id,
        # and revokes only the authenticated id this browser is replacing.
        def promote(pending_id, username:, access_token: nil, state: nil, replaced_id: nil)
          now = @clock.call
          @mutex.synchronize do
            pending = live(pending_id, now)
            return nil unless pending&.kind == :pending

            state ||= pending.states&.keys&.first
            candidate = pending.states[state]
            # No auto-claim path: #claim_pending is what makes a state
            # single-use, and it runs before the GitLab round-trip. Promoting
            # an unclaimed state here would hand that invariant away.
            return nil unless candidate&.claimed && candidate.expires_at > now

            remove_pending_state(pending, state)
            replaced = live(replaced_id, now)
            @sessions.delete(replaced.id) if replaced&.kind == :authenticated

            session = Session.new(
              id: mint_id,
              kind: :authenticated,
              username: username,
              csrf_token: SecureRandom.urlsafe_base64(ID_BYTES),
              access_token: access_token,
              groups_verified_at: now,
              verification_in_flight: false,
              expires_at: now + @ttl
            )
            @sessions[session.id] = session
          end
        end

        def fetch(id)
          return nil if id.nil?

          now = @clock.call
          @mutex.synchronize { live(id, now) }
        end

        def public_view(session)
          PublicSession.new(
            username: session.username.to_s.dup.freeze,
            csrf_token: session.csrf_token.to_s.dup.freeze
          ).freeze
        end

        # Rechecks a due authenticated session without holding the store mutex
        # across GitLab I/O. Concurrent streams for the same session share one
        # check; unrelated sessions can continue through the released mutex.
        def authorize(id, interval:)
          session = nil
          token = nil
          settled = false

          loop do
            now = @clock.call
            action = @mutex.synchronize do
              current = live(id, now)
              return false unless current&.kind == :authenticated
              return true if now - current.groups_verified_at < interval

              if current.verification_in_flight
                @verification_changed.wait(@mutex, VERIFICATION_WAIT_TIMEOUT)
                :retry
              else
                current.verification_in_flight = true
                session = current
                token = current.access_token
                :check
              end
            end
            break if action == :check
          end

          allowed = yield(token)
          settled = true
          finish_authorization(id, session, allowed)
        rescue StandardError
          settled = true
          finish_authorization(id, session, false)
        ensure
          # #finish_authorization is the only thing that clears the in-flight
          # flag, and it is skipped entirely when this thread leaves by a
          # non-StandardError route — Thread#kill during Puma's
          # force_shutdown_after, or any Exception. Without this the flag
          # stays set on a session nobody is checking and every later waiter
          # blocks on it.
          release_verification(session) unless settled
        end

        def destroy(id)
          return if id.nil?

          @mutex.synchronize do
            @sessions.delete(id)
            @verification_changed.broadcast
          end
          nil
        end

        def sweep_expired!
          now = @clock.call
          @mutex.synchronize { purge_expired(now) }
          nil
        end

        def size
          @mutex.synchronize { @sessions.size }
        end

        private

        def release_verification(checked_session)
          return if checked_session.nil?

          @mutex.synchronize do
            checked_session.verification_in_flight = false
            @verification_changed.broadcast
          end
        end

        def finish_authorization(id, checked_session, allowed)
          @mutex.synchronize do
            current = live(id, @clock.call)
            if current.equal?(checked_session)
              if allowed
                current.groups_verified_at = @clock.call
                current.verification_in_flight = false
              else
                @sessions.delete(id)
              end
            end
            @verification_changed.broadcast
            allowed && current.equal?(checked_session)
          end
        end

        def live(id, now)
          session = @sessions[id]
          return nil unless session

          if session.kind == :pending
            purge_pending_states(session, now)
            return nil unless @sessions.key?(id)
          elsif session.expires_at <= now
            @sessions.delete(id)
            @verification_changed.broadcast
            return nil
          end

          session
        end

        def purge_pending_states(session, now)
          session.states.delete_if { |_state, pending| pending.expires_at <= now }
          if session.states.empty?
            @sessions.delete(session.id)
          else
            session.expires_at = session.states.values.map(&:expires_at).max
          end
        end

        def remove_pending_state(pending, state)
          pending.states.delete(state)
          if pending.states.empty?
            @sessions.delete(pending.id)
          else
            pending.expires_at = pending.states.values.map(&:expires_at).max
          end
        end

        def purge_expired(now)
          @sessions.values.each do |session|
            if session.kind == :pending
              purge_pending_states(session, now)
            elsif session.expires_at <= now
              @sessions.delete(session.id)
            end
          end
          @verification_changed.broadcast
        end

        def slot_count
          @sessions.values.sum { |session| session.kind == :pending ? session.states.size : 1 }
        end

        def mint_id
          SecureRandom.urlsafe_base64(ID_BYTES)
        end
      end
    end
  end
end
