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
    assert_equal "abc", session.state
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
    @clock.advance(Store::PENDING_TTL)

    assert_nil @store.promote(pending.id, username: "alice")
    assert_equal 0, @store.size
  end

  # Refusing must also be non-destructive. Consuming the id here would make
  # #promote a way to revoke somebody else's live session by handing it their
  # id — the same forced-logout shape the middleware avoids on /auth/callback.
  def test_promote_refuses_an_already_authenticated_session_without_destroying_it
    pending = @store.create_pending(state: "abc")
    session = @store.promote(pending.id, username: "alice")

    assert_nil @store.promote(session.id, username: "mallory")

    survivor = @store.fetch(session.id)
    refute_nil survivor, "a refused promotion must not consume an authenticated session"
    assert_equal "alice", survivor.username
  end

  def test_authenticated_session_expires_after_the_configured_ttl
    pending = @store.create_pending(state: "abc")
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
end
