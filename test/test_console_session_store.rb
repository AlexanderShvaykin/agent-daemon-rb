# frozen_string_literal: true

require "test_helper"

# AD-5 lazy-require isolation: console files are loaded explicitly here and are
# NOT part of the core `require "agent_daemon"` graph.
require "agent_daemon/supervisor/console/session_store"

# Story 2.2 AC4/AC5 — the server-side session store. Every expiry assertion
# advances an INJECTED clock; the suite never sleeps (Epic 1 retro:
# flaky-timing trap).
class TestConsoleSessionStore < Minitest::Test
  Store = AgentDaemon::Supervisor::Console::SessionStore

  # Stands in for Process.clock_gettime(CLOCK_MONOTONIC): a plain callable, so
  # the production default and the test double are the same shape.
  class FakeClock
    def initialize(now = 1_000.0)
      @now = now
    end

    def call = @now

    def advance(seconds)
      @now += seconds
      self
    end
  end

  TTL = 100

  def setup
    @clock = FakeClock.new
    @store = Store.new(ttl: TTL, clock: @clock)
  end

  def test_create_pending_mints_a_pending_session_carrying_the_state
    session = @store.create_pending(state: "abc")

    assert_equal :pending, session.kind
    assert_equal ["abc"], session.states.keys
    refute_nil session.id
    assert_nil session.username
    assert_equal @clock.call + Store::PENDING_TTL, session.expires_at
    assert_equal session, @store.fetch(session.id)
  end

  def test_session_ids_are_unique_and_unguessably_long
    ids = Array.new(5) { @store.create_pending(state: "s").id }

    assert_equal 5, ids.uniq.size
    ids.each { |id| assert_operator id.length, :>=, 32 }
  end

  def test_fetch_returns_nil_for_nil_and_unknown_ids
    assert_nil @store.fetch(nil)
    assert_nil @store.fetch("never-issued")
  end

  def test_pending_session_expires_after_pending_ttl
    session = @store.create_pending(state: "abc")

    @clock.advance(Store::PENDING_TTL - 1)
    assert_equal session, @store.fetch(session.id)

    @clock.advance(1)
    assert_nil @store.fetch(session.id)
    assert_equal 0, @store.size, "expired entry must be dropped on read"
  end

  # AC4's anti-fixation clause: the id the browser held before login is dead
  # afterwards, and the authenticated session lives under a brand-new one.
  def test_promote_rotates_the_session_id_and_destroys_the_pending_one
    pending = @store.create_pending(state: "abc")
    @store.claim_pending(pending.id, "abc")
    session = @store.promote(pending.id, username: "alice")

    refute_nil session
    refute_equal pending.id, session.id
    assert_nil @store.fetch(pending.id), "pending id must be dead after promotion"
    assert_equal session, @store.fetch(session.id)

    assert_equal :authenticated, session.kind
    assert_equal "alice", session.username
    refute_nil session.csrf_token
    assert_operator session.csrf_token.length, :>=, 32
    assert_equal @clock.call + TTL, session.expires_at
  end

  def test_each_promotion_mints_a_fresh_csrf_token
    tokens = Array.new(3) do
      pending = @store.create_pending(state: "s")
      @store.claim_pending(pending.id, "s")
      @store.promote(pending.id, username: "alice").csrf_token
    end

    assert_equal 3, tokens.uniq.size
  end

  def test_promote_refuses_an_unknown_id
    assert_nil @store.promote("never-issued", username: "alice")
    assert_equal 0, @store.size, "a refused promotion must not mint a session"
  end

  # Reachable in production: the OAuth round-trip between create_pending and
  # promote is network-bound and can outlive PENDING_TTL.
  def test_promote_refuses_an_expired_pending_session
    pending = @store.create_pending(state: "abc")
    @store.claim_pending(pending.id, "abc")
    @clock.advance(Store::PENDING_TTL)

    assert_nil @store.promote(pending.id, username: "alice")
    assert_equal 0, @store.size
  end

  # #claim_pending is what makes a state single-use, and it runs before the
  # GitLab round-trip. #promote must not stand in for it: an auto-claim here
  # would let a caller that skipped the claim complete a login on a state that
  # was never consumed, which is the replay the state exists to prevent.
  def test_promote_refuses_a_state_that_was_never_claimed
    pending = @store.create_pending(state: "abc")

    assert_nil @store.promote(pending.id, username: "alice")
    assert_equal 1, @store.size, "a refused promotion must leave the pending state intact"
    assert_equal "/", @store.claim_pending(pending.id, "abc"), "the state must still be claimable"
  end

  # Refusing must also be non-destructive. Consuming the id here would make
  # #promote a way to revoke somebody else's live session by handing it their
  # id — the same forced-logout shape the middleware avoids on /auth/callback.
  def test_promote_refuses_an_already_authenticated_session_without_destroying_it
    pending = @store.create_pending(state: "abc")
    @store.claim_pending(pending.id, "abc")
    session = @store.promote(pending.id, username: "alice")

    assert_nil @store.promote(session.id, username: "mallory")

    survivor = @store.fetch(session.id)
    refute_nil survivor, "a refused promotion must not consume an authenticated session"
    assert_equal "alice", survivor.username
  end

  def test_authenticated_session_expires_after_the_configured_ttl
    pending = @store.create_pending(state: "abc")
    @store.claim_pending(pending.id, "abc")
    session = @store.promote(pending.id, username: "alice")

    @clock.advance(TTL - 1)
    assert_equal session, @store.fetch(session.id)

    @clock.advance(1)
    assert_nil @store.fetch(session.id)
  end

  # AC5 — logout revokes server-side and immediately, which is the whole reason
  # this store is not a signed client-side cookie.
  def test_destroy_revokes_immediately_and_is_idempotent
    pending = @store.create_pending(state: "abc")
    @store.claim_pending(pending.id, "abc")
    session = @store.promote(pending.id, username: "alice")

    @store.destroy(session.id)
    assert_nil @store.fetch(session.id)

    @store.destroy(session.id)
    @store.destroy(nil)
    @store.destroy("never-issued")
    assert_equal 0, @store.size
  end

  def test_sweep_expired_drops_only_expired_entries
    old = @store.create_pending(state: "old")
    @clock.advance(Store::PENDING_TTL - 1)
    fresh = @store.create_pending(state: "fresh")

    @clock.advance(1)
    @store.sweep_expired!

    assert_equal 1, @store.size
    assert_nil @store.fetch(old.id)
    assert_equal fresh, @store.fetch(fresh.id)
  end

  # No timer thread (AD-13 enumerates the supervised entities and a sweeper is
  # not one): the sweep rides along on login attempts instead.
  def test_create_pending_sweeps_opportunistically
    5.times { @store.create_pending(state: "s") }
    assert_equal 5, @store.size

    @clock.advance(Store::PENDING_TTL)
    kept = @store.create_pending(state: "fresh")

    assert_equal 1, @store.size
    assert_equal kept, @store.fetch(kept.id)
  end

  def test_defaults_to_a_monotonic_clock
    store = Store.new(ttl: TTL)
    session = store.create_pending(state: "abc")

    assert_equal session, store.fetch(session.id)
    assert_operator session.expires_at, :>, Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def test_concurrent_writers_do_not_lose_sessions
    threads = Array.new(8) do
      Thread.new { 25.times { @store.create_pending(state: "s") } }
    end
    threads.each(&:join)

    assert_equal 200, @store.size
  end

  def authenticated_session(username: "alice", token: "oauth-token-secret")
    pending = @store.create_pending(state: "s")
    @store.claim_pending(pending.id, "s")
    @store.promote(pending.id, state: "s", username: username, access_token: token)
  end

  def test_public_view_exposes_only_renderer_fields
    session = authenticated_session

    view = @store.public_view(session)

    assert_equal "alice", view.username
    refute_nil view.csrf_token
    refute_respond_to view, :access_token
    assert view.frozen?
    assert_raises(FrozenError) { view.username << "-tampered" }
    assert_raises(FrozenError) { view.csrf_token << "-tampered" }
    assert_equal "oauth-token-secret", @store.fetch(session.id).access_token
  end

  def test_pending_login_states_are_bounded_per_browser_record
    pending = @store.create_pending(state: "state-0")
    (1...Store::MAX_PENDING_STATES).each do |index|
      assert_equal pending.id, @store.create_pending(state: "state-#{index}", pending_id: pending.id).id
    end

    assert_nil @store.create_pending(state: "one-too-many", pending_id: pending.id)
    assert_equal Store::MAX_PENDING_STATES, @store.fetch(pending.id).states.size
    assert_equal 1, @store.size
  end

  def test_authorization_is_cached_then_rechecked_at_the_interval
    session = authenticated_session
    calls = 0
    check = -> { @store.authorize(session.id, interval: 60) { |token| calls += 1; token == "oauth-token-secret" } }

    assert check.call
    @clock.advance(59)
    assert check.call
    assert_equal 0, calls

    @clock.advance(1)
    assert check.call
    assert_equal 1, calls
    assert check.call
    assert_equal 1, calls
  end

  def test_failed_authorization_revokes_and_concurrent_logout_cannot_be_undone
    session = authenticated_session
    @clock.advance(60)
    entered = Queue.new
    release = Queue.new
    result = nil
    thread = Thread.new do
      result = @store.authorize(session.id, interval: 60) do
        entered << true
        release.pop
        true
      end
    end

    entered.pop
    @store.destroy(session.id)
    release << true
    thread.join

    refute result, "a successful remote result must not resurrect a logged-out session"
    assert_nil @store.fetch(session.id)
    refute @store.authorize(session.id, interval: 60) { true }
  end

  def test_concurrent_checks_for_one_session_coalesce_without_blocking_another_session
    first = authenticated_session(username: "first", token: "first-token")
    second = authenticated_session(username: "second", token: "second-token")
    @clock.advance(60)
    entered = Queue.new
    release = Queue.new
    calls = 0

    check_first = lambda do
      @store.authorize(first.id, interval: 60) do |token|
        calls += 1
        assert_equal "first-token", token
        entered << true
        release.pop
        true
      end
    end
    first_thread = Thread.new { check_first.call }
    entered.pop
    second_thread = Thread.new { check_first.call }

    unrelated_calls = 0
    assert @store.authorize(second.id, interval: 60) { |token| unrelated_calls += 1; token == "second-token" }
    assert_equal 1, unrelated_calls

    release << true
    assert first_thread.value
    assert second_thread.value
    assert_equal 1, calls
  end
end
