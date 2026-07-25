# frozen_string_literal: true

require "test_helper"
require "rack"
require "uri"

# AD-5 lazy-require isolation: console files are loaded explicitly here.
require "agent_daemon/supervisor/console/auth"
require "agent_daemon/supervisor/console/session_store"

# Story 2.2 AC1-AC5 — the default-deny choke-point.
#
# AI-1 (Epic 1 retro): this drives the REAL middleware and the REAL
# SessionStore. The only double is GitlabOAuth, because it is the network
# boundary — and it is a collaborator fake, not a re-implementation of anything
# under test. The wrapped app is a probe so "the request never reached the app"
# is an assertion rather than an inference.
#
# The whole stack is wrapped in Rack::Lint, so a response that violates the Rack
# 3 spec (header casing, body shape) fails here rather than under Puma.
class TestConsoleAuth < Minitest::Test
  include LogStubbing

  Auth = AgentDaemon::Supervisor::Console::Auth
  SessionStore = AgentDaemon::Supervisor::Console::SessionStore
  GitlabOAuth = AgentDaemon::Supervisor::Console::GitlabOAuth
  COOKIE = Auth::COOKIE_NAME

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

  # Records what actually reached the app, so every "denied" case can assert the
  # request was stopped instead of merely assuming it.
  class ProbeApp
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(env)
      @calls << { path: env["PATH_INFO"], session: env["agent_daemon.session"] }
      # No body for HEAD — Rack::Lint enforces it, and the real App obeys the
      # same rule.
      body = env["REQUEST_METHOD"] == "HEAD" ? [] : ["app:#{env['PATH_INFO']}"]
      [200, { "content-type" => "text/plain" }, body]
    end
  end

  # Collaborator fake for the ONE network seam. `fail_at` makes any stage raise
  # the real GitlabOAuth::Error the production class raises.
  class FakeGitlab
    attr_accessor :username, :groups, :fail_at, :after_exchange
    attr_reader :codes, :states

    def initialize(username: "alice", groups: ["backoffice"])
      @username = username
      @groups = groups
      @codes = []
      @states = []
    end

    def authorize_url(state:)
      @states << state
      "https://gitlab.example.com/oauth/authorize?client_id=x&state=#{Rack::Utils.escape(state)}"
    end

    def exchange(code:)
      @codes << code
      boom(:exchange)
      @after_exchange&.call
      :access_token
    end

    def fetch_username(_token)
      boom(:fetch_username)
      @username
    end

    def member_group_paths(_token)
      boom(:member_group_paths)
      @groups
    end

    private

    def boom(stage)
      raise GitlabOAuth::Error, "#{stage} failed" if @fail_at == stage
    end
  end

  ALLOWED_GROUPS = ["backoffice", "platform/sre"].freeze
  TTL = 3_600

  def setup
    stub_null_logger!
    fresh_stack!
  end

  # The per-case state, without the logger stubbing. Cases that need a clean
  # slate per iteration call THIS, never #setup: stub_null_logger! captures the
  # logger it is replacing, so a second call inside one test would capture its
  # own null logger and #teardown would then install that null logger globally
  # for the rest of the process.
  def fresh_stack!
    @clock = FakeClock.new
    @sessions = SessionStore.new(ttl: TTL, clock: @clock)
    @gitlab = FakeGitlab.new
    @app = ProbeApp.new
    @stack = build_stack
  end

  def teardown
    restore_logger!
  end

  def build_stack(secure_cookies: true, app: @app)
    middleware = Auth.new(app,
                          sessions: @sessions,
                          gitlab: @gitlab,
                          allowed_groups: ALLOWED_GROUPS,
                          secure_cookies: secure_cookies)
    Rack::MockRequest.new(Rack::Lint.new(middleware))
  end

  # --- helpers -------------------------------------------------------------

  def with_cookie(id)
    { "HTTP_COOKIE" => "#{COOKIE}=#{id}" }
  end

  def cookie_id(response)
    value = response.cookie(COOKIE)&.value&.first.to_s
    value.empty? ? nil : value
  end

  def set_cookie_header(response)
    Array(response.headers["set-cookie"]).join("\n")
  end

  def expired_cookie?(response)
    set_cookie_header(response).include?("max-age=0")
  end

  def query_params(url)
    URI.decode_www_form(URI.parse(url).query.to_s).to_h
  end

  # Drives a full real login and returns the authenticated session cookie id.
  def login!
    started = @stack.get("/auth/login")
    pending_id = cookie_id(started)
    state = query_params(started.headers["location"])["state"]
    callback = @stack.get("/auth/callback?code=the-code&state=#{Rack::Utils.escape(state)}", with_cookie(pending_id))
    [callback, pending_id, cookie_id(callback)]
  end

  # --- AC1/AC2: the allowlist ---------------------------------------------

  def test_healthz_is_public_and_reaches_the_app_without_a_session
    response = @stack.get("/healthz")

    assert_equal 200, response.status
    assert_equal "app:/healthz", response.body
    assert_equal ["/healthz"], @app.calls.map { |c| c[:path] }
    assert_nil @app.calls.first[:session]
    assert_nil response.headers["set-cookie"], "the public probe must not touch cookies"
  end

  def test_healthz_ignores_a_garbage_session_cookie
    response = @stack.get("/healthz", with_cookie("not-a-real-session"))

    assert_equal 200, response.status
    assert_equal 1, @app.calls.size
  end

  def test_the_public_allowlist_is_exactly_healthz
    assert_equal ["/healthz"], Auth::PUBLIC_PATHS
  end

  # HEAD is how curl -I and most load balancers probe. It reaches the same
  # handler on the same public path, so it widens nothing.
  def test_healthz_is_public_for_head_as_well_as_get
    response = @stack.request("HEAD", "/healthz")

    assert_equal 200, response.status
    assert_equal ["/healthz"], @app.calls.map { |c| c[:path] }
  end

  def test_a_non_probe_method_on_healthz_is_not_public
    response = @stack.post("/healthz")

    assert_equal 302, response.status
    assert_empty @app.calls
  end

  # The login legs are browser navigations, so GET is the only verb that can
  # legitimately reach them; gating them keeps the pre-auth surface to one verb.
  def test_the_login_legs_answer_405_to_anything_but_get
    %w[POST PUT DELETE].each do |verb|
      assert_equal 405, @stack.request(verb, "/auth/login").status, "#{verb} /auth/login"
      assert_equal 405, @stack.request(verb, "/auth/callback").status, "#{verb} /auth/callback"
    end

    assert_equal 0, @sessions.size, "a rejected verb must not mint a pending session"
  end

  # /auth/login is reachable with no authentication at all, so an unbounded
  # store would let anyone grow the master's heap. Refusing is fail-closed.
  def test_login_is_refused_once_the_session_store_is_full
    SessionStore::MAX_SESSIONS.times { @sessions.create_pending(state: "s") }

    response = @stack.get("/auth/login")

    assert_equal 503, response.status
    assert_nil response.headers["set-cookie"]
    assert_equal SessionStore::MAX_SESSIONS, @sessions.size, "the flood must not grow the store further"
  end

  # The F1 property, asserted rather than assumed: a route this middleware has
  # never heard of — the shape Story 2.3 adds — is authenticated by default,
  # with zero action from whoever adds it.
  def test_a_route_added_later_is_authenticated_by_default
    future_app = ProbeApp.new
    stack = build_stack(app: future_app)

    response = stack.get("/fleet")

    assert_equal 302, response.status
    assert_equal "/auth/login", response.headers["location"]
    assert_empty future_app.calls, "an unauthenticated request must never reach the app"
  end

  def test_unauthenticated_request_redirects_to_login
    response = @stack.get("/")

    assert_equal 302, response.status
    assert_equal "/auth/login", response.headers["location"]
    assert_empty @app.calls
  end

  def test_an_unknown_session_cookie_is_not_a_session
    response = @stack.get("/", with_cookie("forged"))

    assert_equal 302, response.status
    assert_empty @app.calls
  end

  # AC1: the auth endpoints are handled inside the middleware, not exposed as
  # public allowlist entries and never passed down to the app.
  def test_auth_paths_never_reach_the_app
    @stack.get("/auth/login")
    @stack.get("/auth/callback?code=c&state=s")
    @stack.post("/auth/logout")

    assert_empty @app.calls
  end

  # --- AC3: login start ----------------------------------------------------

  def test_login_redirects_to_gitlab_with_a_state_bound_to_a_pending_session
    response = @stack.get("/auth/login")

    assert_equal 302, response.status
    location = response.headers["location"]
    assert location.start_with?("https://gitlab.example.com/oauth/authorize"), location

    state = query_params(location)["state"]
    refute_nil state
    assert_operator state.length, :>=, 32

    pending = @sessions.fetch(cookie_id(response))
    refute_nil pending, "the pending session must be retrievable by the cookie id"
    assert_equal :pending, pending.kind
    assert_equal state, pending.state
  end

  def test_each_login_mints_a_fresh_state
    3.times { @stack.get("/auth/login") }

    assert_equal 3, @gitlab.states.uniq.size
  end

  # AC4 cookie flags. SameSite=Lax is load-bearing: the OAuth callback is a
  # top-level cross-site navigation back from GitLab, and Strict would withhold
  # the cookie there and break login outright.
  def test_the_session_cookie_is_httponly_lax_and_secure
    header = set_cookie_header(@stack.get("/auth/login"))

    assert_includes header, "httponly"
    assert_includes header, "samesite=lax"
    assert_includes header, "secure"
    assert_includes header, "path=/"
    refute_includes header, "samesite=strict"
  end

  def test_secure_flag_is_configurable_for_plain_http_dev
    header = set_cookie_header(build_stack(secure_cookies: false).get("/auth/login"))

    assert_includes header, "httponly"
    refute_includes header, "secure"
  end

  # --- AC3/AC4: callback success ------------------------------------------

  def test_successful_callback_creates_a_session_and_rotates_the_id
    response, pending_id, session_id = login!

    assert_equal 302, response.status
    assert_equal "/", response.headers["location"]
    refute_nil session_id
    refute_equal pending_id, session_id, "AC4: the session id must rotate on login"

    assert_nil @sessions.fetch(pending_id), "the pending session must be consumed"
    session = @sessions.fetch(session_id)
    assert_equal :authenticated, session.kind
    assert_equal "alice", session.username
    assert_equal ["the-code"], @gitlab.codes
  end

  def test_an_authenticated_session_reaches_the_app_with_its_session_in_env
    _response, _pending_id, session_id = login!

    response = @stack.get("/", with_cookie(session_id))

    assert_equal 200, response.status
    assert_equal 1, @app.calls.size
    assert_equal "alice", @app.calls.first[:session].username
  end

  # --- AC3: state validation ----------------------------------------------

  def test_callback_with_a_mismatched_state_is_forbidden_and_consumes_the_pending
    started = @stack.get("/auth/login")
    pending_id = cookie_id(started)

    response = @stack.get("/auth/callback?code=c&state=wrong", with_cookie(pending_id))

    assert_equal 403, response.status
    assert_nil @sessions.fetch(pending_id), "a failed callback must consume the pending session"
    assert expired_cookie?(response), "a denied callback must clear the cookie"
    assert_empty @gitlab.codes, "the code must never be exchanged when state fails"
    assert_empty @app.calls
  end

  def test_callback_without_a_state_parameter_is_forbidden
    started = @stack.get("/auth/login")
    response = @stack.get("/auth/callback?code=c", with_cookie(cookie_id(started)))

    assert_equal 403, response.status
    assert_empty @gitlab.codes
  end

  # No redirect back to /auth/login: a loop would hide the real failure.
  def test_callback_without_a_pending_cookie_is_forbidden_not_redirected
    response = @stack.get("/auth/callback?code=c&state=s")

    assert_equal 403, response.status
    assert_empty @gitlab.codes
  end

  # A stray callback must be inert, not destructive. /auth/callback is an
  # unauthenticated GET and SameSite=Lax deliberately sends the cookie on
  # top-level cross-site navigation (the OAuth return leg needs it), so if this
  # revoked the session named by the cookie, any website could log an operator
  # out with a single link. Asserting only the 403 is what let that ship.
  def test_a_stray_callback_does_not_revoke_a_live_session
    _response, _pending_id, session_id = login!

    response = @stack.get("/auth/callback?code=c&state=s", with_cookie(session_id))

    assert_equal 403, response.status
    refute_nil @sessions.fetch(session_id), "a live session must survive a stray callback"
    assert_nil response.headers["set-cookie"], "the browser's cookie must be left alone too"

    # And it is still a working session, not merely a surviving record.
    assert_equal 200, @stack.get("/", with_cookie(session_id)).status
  end

  # The same guarantee one level down: handing an authenticated id to #promote
  # must not consume it either.
  def test_promote_cannot_be_used_to_revoke_an_authenticated_session
    _response, _pending_id, session_id = login!

    assert_nil @sessions.promote(session_id, username: "mallory")
    assert_equal "alice", @sessions.fetch(session_id).username
  end

  # Rack parses the query lazily, so a hostile query string raises out of the
  # middleware unless it is caught. A 500 there would also skip the denial path
  # that consumes the pending session, leaving its `state` replayable.
  def test_a_hostile_query_string_denies_instead_of_raising
    started = @stack.get("/auth/login")
    pending_id = cookie_id(started)

    flood = (1..5_000).map { |i| "p#{i}=1" }.join("&")
    response = @stack.get("/auth/callback?#{flood}", with_cookie(pending_id))

    assert_equal 403, response.status
    assert_nil @sessions.fetch(pending_id), "the pending state must still be consumed"
    assert_equal 0, @sessions.size
    assert_empty @app.calls
  end

  # The stored state is single-use, so a replayed callback URL cannot mint a
  # second session.
  def test_a_replayed_callback_is_forbidden
    started = @stack.get("/auth/login")
    pending_id = cookie_id(started)
    state = query_params(started.headers["location"])["state"]
    url = "/auth/callback?code=the-code&state=#{Rack::Utils.escape(state)}"

    assert_equal 302, @stack.get(url, with_cookie(pending_id)).status
    assert_equal 403, @stack.get(url, with_cookie(pending_id)).status
  end

  def test_callback_without_a_code_is_forbidden
    started = @stack.get("/auth/login")
    pending_id = cookie_id(started)
    state = query_params(started.headers["location"])["state"]

    response = @stack.get("/auth/callback?state=#{Rack::Utils.escape(state)}", with_cookie(pending_id))

    assert_equal 403, response.status
    assert_empty @gitlab.codes
  end

  def test_an_expired_pending_session_cannot_complete_a_login
    started = @stack.get("/auth/login")
    pending_id = cookie_id(started)
    state = query_params(started.headers["location"])["state"]
    @clock.advance(SessionStore::PENDING_TTL)

    response = @stack.get("/auth/callback?code=c&state=#{Rack::Utils.escape(state)}", with_cookie(pending_id))

    assert_equal 403, response.status
    assert_equal 0, @sessions.size
  end

  # Reachable in production: the OAuth round-trip is network-bound, so the
  # pending session can expire between the state check and the promotion.
  def test_a_pending_session_expiring_mid_flight_denies_the_login
    started = @stack.get("/auth/login")
    pending_id = cookie_id(started)
    state = query_params(started.headers["location"])["state"]
    @gitlab.after_exchange = -> { @clock.advance(SessionStore::PENDING_TTL) }

    response = @stack.get("/auth/callback?code=c&state=#{Rack::Utils.escape(state)}", with_cookie(pending_id))

    assert_equal 403, response.status
    assert_equal 0, @sessions.size, "no session may be minted from an expired login"
  end

  # --- AC3: fail-closed group check ---------------------------------------

  def test_every_gitlab_failure_stage_denies_the_login
    %i[exchange fetch_username member_group_paths].each do |stage|
      fresh_stack!
      @gitlab.fail_at = stage
      started = @stack.get("/auth/login")
      pending_id = cookie_id(started)
      state = query_params(started.headers["location"])["state"]

      response = @stack.get("/auth/callback?code=c&state=#{Rack::Utils.escape(state)}", with_cookie(pending_id))

      assert_equal 403, response.status, "#{stage} failure must deny"
      assert_nil @sessions.fetch(pending_id)
      assert_equal 0, @sessions.size, "#{stage} failure must not mint a session"
      assert_empty @app.calls
    end
  end

  def test_a_user_in_no_allowed_group_is_denied
    @gitlab.groups = ["some/other-group"]

    response, _pending_id, session_id = login!

    assert_equal 403, response.status
    assert_nil session_id
    assert_equal 0, @sessions.size
  end

  def test_an_empty_group_list_is_denied
    @gitlab.groups = []

    assert_equal 403, login!.first.status
  end

  def test_any_single_allowed_group_is_enough
    @gitlab.groups = ["unrelated", "platform/sre"]

    response, _pending_id, session_id = login!

    assert_equal 302, response.status
    refute_nil session_id
    assert_equal "alice", @sessions.fetch(session_id).username
  end

  # Pinned by the story: exact, case-sensitive full_path equality. GitLab
  # already expands inherited membership downward, so a member of an allowed
  # parent has the parent itself in the list; a user who only holds a
  # descendant is denied unless the operator lists it.
  def test_group_matching_is_exact_and_case_sensitive
    ["backoffice/subgroup", "BackOffice", "backoffic", "xbackoffice"].each do |group|
      fresh_stack!
      @gitlab.groups = [group]

      assert_equal 403, login!.first.status, "#{group} must not satisfy an allowed_groups entry"
    end
  end

  # --- AC5: logout and expiry ---------------------------------------------

  def test_logout_requires_a_csrf_token_and_revokes_the_session
    _response, _pending_id, session_id = login!
    csrf = @sessions.fetch(session_id).csrf_token

    response = @stack.post("/auth/logout", with_cookie(session_id).merge(params: { "_csrf" => csrf }))

    assert_equal 302, response.status
    assert_equal "/auth/login", response.headers["location"]
    assert expired_cookie?(response)
    assert_nil @sessions.fetch(session_id), "logout must revoke server-side"

    assert_equal 302, @stack.get("/", with_cookie(session_id)).status
    assert_empty @app.calls
  end

  def test_logout_accepts_the_csrf_token_from_a_header
    _response, _pending_id, session_id = login!
    csrf = @sessions.fetch(session_id).csrf_token

    response = @stack.post("/auth/logout", with_cookie(session_id).merge("HTTP_X_CSRF_TOKEN" => csrf))

    assert_equal 302, response.status
    assert_nil @sessions.fetch(session_id)
  end

  def test_logout_without_a_valid_csrf_token_is_forbidden_and_keeps_the_session
    _response, _pending_id, session_id = login!

    [{}, { params: { "_csrf" => "" } }, { params: { "_csrf" => "wrong" } }].each do |extra|
      response = @stack.post("/auth/logout", with_cookie(session_id).merge(extra))

      assert_equal 403, response.status
      refute_nil @sessions.fetch(session_id), "a rejected logout must not revoke the session"
    end
  end

  def test_logout_without_a_session_is_forbidden
    assert_equal 403, @stack.post("/auth/logout", params: { "_csrf" => "whatever" }).status
  end

  # Logout is a mutation, and AD-7 makes mutations CSRF-protected POSTs.
  def test_get_logout_is_method_not_allowed
    _response, _pending_id, session_id = login!

    response = @stack.get("/auth/logout", with_cookie(session_id))

    assert_equal 405, response.status
    refute_nil @sessions.fetch(session_id)
  end

  def test_an_expired_session_must_re_authenticate
    _response, _pending_id, session_id = login!
    assert_equal 200, @stack.get("/", with_cookie(session_id)).status

    @clock.advance(TTL)
    response = @stack.get("/", with_cookie(session_id))

    assert_equal 302, response.status
    assert_equal "/auth/login", response.headers["location"]
    assert_equal 1, @app.calls.size, "the expired request must not reach the app"
  end

  # --- responses -----------------------------------------------------------

  def test_denial_bodies_never_echo_user_input
    started = @stack.get("/auth/login")
    payload = "<script>alert(1)</script>"

    response = @stack.get("/auth/callback?code=#{Rack::Utils.escape(payload)}&state=#{Rack::Utils.escape(payload)}",
                          with_cookie(cookie_id(started)))

    assert_equal 403, response.status
    refute_includes response.body, "script"
    refute_includes response.body, payload
    assert_equal "text/plain; charset=utf-8", response.headers["content-type"]
  end
end
