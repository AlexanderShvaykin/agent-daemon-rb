# frozen_string_literal: true

require "test_helper"
require "rack"

# AD-5 lazy-require isolation: console files are loaded explicitly here.
require "agent_daemon/supervisor/console/app"
require "agent_daemon/supervisor/console/auth"
require "agent_daemon/supervisor/console/session_store"
require "agent_daemon/supervisor/fleet"
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/runner_identity"

# Story 2.2 AC1/AC2 — the minimal authenticated surface. Story 2.3 adds the
# fleet list itself.
#
# Every request goes through Rack::Lint, so a spec violation fails here rather
# than under Puma.
class TestConsoleApp < Minitest::Test
  App = AgentDaemon::Supervisor::Console::App
  Auth = AgentDaemon::Supervisor::Console::Auth
  SessionStore = AgentDaemon::Supervisor::Console::SessionStore
  Fleet = AgentDaemon::Supervisor::Fleet
  StateRegistry = AgentDaemon::Supervisor::StateRegistry
  RunnerIdentity = AgentDaemon::Supervisor::RunnerIdentity

  def setup
    @registry = StateRegistry.new
    @fleet = Fleet.new(roster: [], state_registry: @registry)
    @app = build_app(@fleet)
    @sessions = SessionStore.new(ttl: 3_600)
  end

  def build_app(fleet)
    Rack::MockRequest.new(Rack::Lint.new(App.new(fleet: fleet)))
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

  # Like #get but against a caller-supplied app, so a fleet test can build its
  # own Fleet/StateRegistry without disturbing the shared empty-roster @app.
  def get_on(app, path, username: "alice")
    app.get(path, { Auth::SESSION_ENV_KEY => session_for(username) })
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

  # --- Story 2.3: the fleet list (AC1, AC2, AC3, AC4) ----------------------

  def test_root_shows_no_supervised_entities_when_roster_is_empty
    assert_includes get("/").body, "No supervised entities."
  end

  # Substring matches against the whole document prove nothing about which
  # table a row landed in, so every grouping assertion below is scoped to one
  # section. A missing section fails here with its own name rather than as a
  # NoMethodError on nil further down.
  def section(body, heading)
    found = body[/<h2>#{Regexp.escape(heading)}<\/h2>.*?<\/table>/m]
    refute_nil found, "no <h2>#{heading}</h2> section with a table in the page"
    found
  end

  def test_root_lists_every_workflow_with_its_runners
    id_a = RunnerIdentity.new(workflow: "wfA", runner: "alpha")
    id_b = RunnerIdentity.new(workflow: "wfB", runner: "beta")
    registry = StateRegistry.new
    registry.publish(id_a, { status: :waiting, generation: 1 })
    registry.publish(id_b, { status: :in_progress, generation: 1 })
    roster = [
      Fleet::Rostered.new(kind: :runner, workflow: "wfA", name: "alpha", entity_id: id_a),
      Fleet::Rostered.new(kind: :runner, workflow: "wfB", name: "beta", entity_id: id_b)
    ]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/").body
    wf_a = section(body, "wfA")
    wf_b = section(body, "wfB")

    assert_includes wf_a, "<td>alpha</td>"
    assert_includes wf_a, %(<span class="liveness liveness-alive">alive</span>)
    refute_includes wf_a, "beta"
    assert_includes wf_b, "<td>beta</td>"
    refute_includes wf_b, "alpha"
    assert_operator body.index("<h2>wfA</h2>"), :<, body.index("<h2>wfB</h2>"), "workflows must render in config order"
  end

  # The Page contract pins the column set and its order. Without this, a
  # silent reorder or a dropped header passes the whole suite.
  def test_the_entity_table_has_the_pinned_columns_in_the_pinned_order
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/").body

    assert_includes body, "<tr><th>Entity</th><th>Kind</th><th>Liveness</th><th>Note</th><th></th></tr>"
    assert_includes body,
                    "<tr><td>alpha</td><td>runner</td>" \
                    "<td><span class=\"liveness liveness-alive\">alive</span></td>" \
                    "<td></td><td><button type=\"button\" disabled>Restart</button></td></tr>"
  end

  # AC2: supervisor-owned entities are not just listed — each carries its own
  # liveness indicator and its own restart placeholder.
  def test_messenger_groups_under_its_workflow_and_the_reactor_is_fleet_wide
    roster = [
      Fleet::Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: "messenger:wf"),
      Fleet::Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor", entity_id: "mattermost_reactor")
    ]
    registry = StateRegistry.new
    registry.publish("messenger:wf", { status: :running, generation: 1 })
    registry.publish("mattermost_reactor", { status: :running, generation: 1 })
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/").body
    wf_section = section(body, "wf")
    fleet_wide_section = section(body, "Fleet-wide")

    assert_includes wf_section, "<td>messenger</td>"
    refute_includes wf_section, "mattermost_reactor"
    assert_includes fleet_wide_section, "<td>mattermost_reactor</td>"
    refute_includes fleet_wide_section, "<td>messenger</td>"

    [wf_section, fleet_wide_section].each do |sect|
      assert_includes sect, %(<span class="liveness liveness-alive">alive</span>)
      assert_includes sect, '<button type="button" disabled>Restart</button>'
    end
  end

  def test_a_runner_with_no_registry_entry_renders_the_not_started_note
    id = RunnerIdentity.new(workflow: "wf", runner: "ghost")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "ghost", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: StateRegistry.new))

    body = get_on(app, "/").body

    assert_includes body, "no state published — never started, or failed to start"
    assert_includes body, "liveness-unknown"
  end

  # AC3's FR3 boundary: a runner that exited without the crash flag must not
  # look auto-restarting.
  def test_an_exited_runner_renders_the_not_auto_restarted_note
    id = RunnerIdentity.new(workflow: "wf", runner: "done")
    registry = StateRegistry.new
    registry.publish(id, { status: :exited, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "done", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/").body

    assert_includes body, "exited cleanly — not auto-restarted"
    assert_includes body, "liveness-dead"
  end

  # The console keeps serving for the whole drain (stop_console runs in
  # Master#start's ensure, after wait_for_threads), so :stopped must not read
  # as an unexplained `dead` row.
  def test_a_stopped_runner_says_the_fleet_is_shutting_down
    id = RunnerIdentity.new(workflow: "wf", runner: "draining")
    registry = StateRegistry.new
    registry.publish(id, { status: :stopped, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "draining", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/").body

    assert_includes body, "stopped — fleet is shutting down"
    assert_includes body, "liveness-dead"
    refute_includes body, "exited cleanly — not auto-restarted"
  end

  def test_a_crashed_runner_renders_restarting
    id = RunnerIdentity.new(workflow: "wf", runner: "flaky")
    registry = StateRegistry.new
    registry.publish(id, { status: :crashed, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "flaky", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/").body

    assert_includes body, "liveness-restarting"
    assert_includes body, ">restarting<"
  end

  # AC4: a display value that originates from agent-influenced data (here, an
  # entity name) is rendered inert, never as HTML.
  def test_an_agent_influenced_entity_name_is_rendered_inert
    malicious = "<script>alert(1)</script>"
    id = RunnerIdentity.new(workflow: "wf", runner: malicious)
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: malicious, entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: StateRegistry.new))

    body = get_on(app, "/").body

    refute_includes body, "<script>"
    assert_includes body, "&lt;script&gt;"
  end

  # AC2/AD-13: the restart action exists for every kind, but Epic 4 owns the
  # endpoint — there must be no form here that could 404.
  def test_restart_placeholder_is_disabled_and_posts_nowhere
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: StateRegistry.new))

    body = get_on(app, "/").body

    assert_includes body, '<button type="button" disabled>Restart</button>'
    # "Posts nowhere" is only proved by there being no form to post through:
    # matching /restart/ inside a <form> open tag would miss any action path
    # spelled differently, and the button sits outside that tag anyway.
    assert_equal ['<form method="post" action="/auth/logout">'], body.scan(/<form[^>]*>/),
                 "the logout form must be the only <form> on the page until Epic 4 adds the restart endpoint"
  end
end
