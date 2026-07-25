# frozen_string_literal: true

require "test_helper"
require "rack"

# AD-5 lazy-require isolation: console files are loaded explicitly here.
require "agent_daemon/supervisor/console/app"
require "agent_daemon/supervisor/console/auth"
require "agent_daemon/supervisor/console/session_store"

# Story 2.2 AC1/AC2 — the minimal authenticated surface. The fleet view is
# Story 2.3; this page exists to prove the boundary works end to end.
#
# Every request goes through Rack::Lint, so a spec violation fails here rather
# than under Puma.
class TestConsoleApp < Minitest::Test
  App = AgentDaemon::Supervisor::Console::App
  Auth = AgentDaemon::Supervisor::Console::Auth
  SessionStore = AgentDaemon::Supervisor::Console::SessionStore

  def setup
    @app = Rack::MockRequest.new(Rack::Lint.new(App.new))
    @sessions = SessionStore.new(ttl: 3_600)
  end

  # A real, freshly promoted session — the same object the middleware puts in
  # env, not a hand-rolled stand-in (AI-1).
  def session_for(username)
    pending = @sessions.create_pending(state: "s")
    @sessions.promote(pending.id, username: username)
  end

  def get(path, username: "alice", session: :build)
    session = session_for(username) if session == :build
    env = session ? { Auth::SESSION_ENV_KEY => session } : {}
    @app.get(path, env)
  end

  # --- AC2: the health probe ----------------------------------------------

  def test_healthz_is_a_bare_liveness_response
    response = get("/healthz", session: nil)

    assert_equal 200, response.status
    assert_equal "text/plain; charset=utf-8", response.headers["content-type"]
    assert_equal "ok", response.body
  end

  # Security review F5: an unauthenticated probe must not leak fleet topology.
  # The response is a fixed two-byte string, so there is nothing to leak — this
  # test fails the moment someone "improves" it into a status summary.
  def test_healthz_leaks_no_fleet_topology
    body = get("/healthz", session: nil).body

    assert_equal "ok", body
    %w[workflow runner messenger reactor supervisor generation].each do |term|
      refute_match(/#{term}/i, body)
    end
  end

  # HEAD is how curl -I and most load balancers probe. RFC 9110 (and
  # Rack::Lint) require the response to carry no body.
  def test_healthz_answers_head_with_a_bodiless_200
    response = @app.request("HEAD", "/healthz")

    assert_equal 200, response.status
    assert_equal "text/plain; charset=utf-8", response.headers["content-type"]
    assert_empty response.body
  end

  # --- AC1: the authenticated page ----------------------------------------

  def test_root_renders_the_logged_in_username
    response = get("/")

    assert_equal 200, response.status
    assert_equal "text/html; charset=utf-8", response.headers["content-type"]
    assert_includes response.body, "alice"
  end

  # AD-7: every interpolated value is rendered inert. The username comes from
  # GitLab, so it is not ours to trust.
  def test_root_escapes_the_username
    response = get("/", username: "<script>alert(1)</script>")

    assert_equal 200, response.status
    refute_includes response.body, "<script>"
    assert_includes response.body, "&lt;script&gt;"
  end

  def test_root_renders_a_csrf_protected_logout_form
    session = session_for("alice")
    body = get("/", session: session).body

    assert_includes body, %(action="/auth/logout")
    assert_match(/<form[^>]+method="post"/, body)
    assert_includes body, %(name="_csrf")
    assert_includes body, session.csrf_token
  end

  def test_root_escapes_the_csrf_token_it_embeds
    session = session_for("alice")
    session.csrf_token = %(tok"><script>)

    body = get("/", session: session).body

    refute_includes body, "<script>"
    assert_includes body, "&lt;script&gt;"
  end

  # The app owns no auth logic whatsoever (security review F1) — it never reads
  # a cookie and never decides who may enter, so a missing session is a render
  # concern, not an access-control one.
  def test_root_renders_without_a_session_instead_of_raising
    response = get("/", session: nil)

    assert_equal 200, response.status
  end

  # --- routing -------------------------------------------------------------

  def test_unknown_paths_are_not_found
    response = get("/nope")

    assert_equal 404, response.status
    assert_equal "text/plain; charset=utf-8", response.headers["content-type"]
  end

  def test_non_get_requests_are_not_found
    assert_equal 404, @app.post("/").status
    assert_equal 404, @app.post("/healthz").status
  end

  # The page embeds the session's CSRF token and the username, so a shared
  # machine's Back button after logout — or any intermediary cache — must not
  # be able to serve either back.
  def test_the_authenticated_page_is_never_cached
    assert_equal "no-store", get("/").headers["cache-control"]
  end

  def test_not_found_never_echoes_the_requested_path
    body = get("/%3Cscript%3Ealert(1)%3C%2Fscript%3E").body

    assert_equal "not found", body
    refute_includes body, "script"
    refute_includes body, "%3C"
  end
end
