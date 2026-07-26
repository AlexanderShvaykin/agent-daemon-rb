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
require "agent_daemon/supervisor/activity_log"
require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/runner_supervisor"

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
  ActivityLog = AgentDaemon::Supervisor::ActivityLog
  EventBus = AgentDaemon::Supervisor::EventBus
  GenerationStamp = AgentDaemon::Supervisor::GenerationStamp

  def setup
    @registry = StateRegistry.new
    @fleet = Fleet.new(roster: [], state_registry: @registry)
    @app = build_app(@fleet)
    @sessions = SessionStore.new(ttl: 3_600)
  end

  def build_app(fleet, activity_log: ActivityLog.new(event_bus: EventBus.new))
    Rack::MockRequest.new(Rack::Lint.new(App.new(fleet: fleet, activity_log: activity_log)))
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

    assert_includes wf_a, %(<td><a href="/entity?id=runner%3AwfA%3Aalpha">alpha</a></td>)
    assert_includes wf_a, %(<span class="liveness liveness-alive">alive</span>)
    refute_includes wf_a, "beta"
    assert_includes wf_b, %(<td><a href="/entity?id=runner%3AwfB%3Abeta">beta</a></td>)
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
                    "<tr><td><a href=\"/entity?id=runner%3Awf%3Aalpha\">alpha</a></td><td>runner</td>" \
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

    assert_includes wf_section, %(<td><a href="/entity?id=messenger%3Awf">messenger</a></td>)
    refute_includes wf_section, "mattermost_reactor"
    assert_includes fleet_wide_section, %(<td><a href="/entity?id=mattermost_reactor">mattermost_reactor</a></td>)
    refute_includes fleet_wide_section, ">messenger<"

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

  # --- Story 2.4: per-runner detail page -----------------------------------

  def test_a_waiting_runner_shows_liveness_and_activity_but_no_work_item_row
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/entity?id=runner%3Awf%3Aalpha").body

    assert_includes body, %(<span class="liveness liveness-alive">alive</span>)
    assert_includes body, "<tr><th>Activity</th><td>waiting</td></tr>"
    refute_includes body, "<th>Work item</th>"
    refute_includes body, "<th>Attempt</th>"
  end

  # AC7
  def test_an_in_progress_runner_shows_the_work_item_and_attempt_count
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :in_progress, work_item: "T-1", attempt: 2, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/entity?id=runner%3Awf%3Aalpha").body

    assert_includes body, "<tr><th>Work item</th><td>T-1</td></tr>"
    assert_includes body, "<tr><th>Attempt</th><td>2</td></tr>"
  end

  # AC4-carried-forward: work_item is the first genuinely agent-influenced
  # value to reach this renderer.
  def test_a_hostile_work_item_is_rendered_escaped
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :in_progress, work_item: "<script>alert(1)</script>", attempt: 1, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/entity?id=runner%3Awf%3Aalpha").body

    refute_includes body, "<script>alert(1)</script>"
    assert_includes body, "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  # AC6, rendered: the same-generation :crashed publish is a full overwrite,
  # so a crashed runner never renders a stale "working on X" row — this is
  # impossible by construction, so the render is checked against the AC6
  # sequence rather than guarded defensively.
  def test_a_crashed_runner_renders_restarting_its_generation_and_no_work_item_row
    id = RunnerIdentity.new(workflow: "wf", runner: "flaky")
    registry = StateRegistry.new
    registry.publish(id, { status: :in_progress, work_item: "T-1", attempt: 2, generation: 1 })
    registry.publish(id, { status: :crashed, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "flaky", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry, restart_delay: 60))

    body = get_on(app, "/entity?id=runner%3Awf%3Aflaky").body

    assert_includes body, %(<span class="liveness liveness-restarting">restarting</span>)
    assert_includes body, "<tr><th>Generation</th><td>1 (0 restart(s))</td></tr>"
    assert_match(%r{<tr><th>Restarting for</th><td>\d+s</td></tr>}, body)
    refute_includes body, "<th>Work item</th>"
    refute_includes body, "T-1"
  end

  # AC4: a healthy restart vs. a stuck crash-loop, driven by the injected
  # clock (no sleep).
  def test_a_crash_looping_entity_renders_the_stuck_flag_a_fresh_one_does_not
    id = RunnerIdentity.new(workflow: "wf", runner: "flaky")
    registry = StateRegistry.new
    registry.publish(id, { status: :crashed, generation: 1 })
    published_at = registry.snapshot(id).fetch(:observed_monotonic)
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "flaky", entity_id: id)]

    stuck_app = build_app(Fleet.new(roster: roster, state_registry: registry, restart_delay: 60,
                                     clock: -> { published_at + 66 }))
    fresh_app = build_app(Fleet.new(roster: roster, state_registry: registry, restart_delay: 60,
                                     clock: -> { published_at + 1 }))

    stuck_body = get_on(stuck_app, "/entity?id=runner%3Awf%3Aflaky").body
    fresh_body = get_on(fresh_app, "/entity?id=runner%3Awf%3Aflaky").body

    assert_includes stuck_body,
                    "<tr><th>Restarting for</th><td>66s — <strong>stuck: respawn is failing</strong></td></tr>"
    assert_includes fresh_body, "<tr><th>Restarting for</th><td>1s</td></tr>"
    refute_includes fresh_body, "stuck: respawn is failing"
  end

  # AC9: a messenger/reactor entity has no work-item/attempt semantics at all.
  def test_a_messenger_entity_shows_liveness_only
    registry = StateRegistry.new
    registry.publish("messenger:wf", { status: :running, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: "messenger:wf")]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/entity?id=messenger%3Awf").body

    assert_includes body, %(<span class="liveness liveness-alive">alive</span>)
    refute_includes body, "<th>Work item</th>"
    refute_includes body, "<th>Attempt</th>"
  end

  def test_a_reactor_entity_shows_liveness_only
    registry = StateRegistry.new
    registry.publish("mattermost_reactor", { status: :running, generation: 1 })
    roster = [
      Fleet::Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor", entity_id: "mattermost_reactor")
    ]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/entity?id=mattermost_reactor").body

    assert_includes body, %(<span class="liveness liveness-alive">alive</span>)
    # The reactor is fleet-wide, so its Workflow cell is the pinned em dash
    # rather than a blank cell.
    assert_includes body, "<tr><th>Workflow</th><td>—</td></tr>"
    refute_includes body, "<th>Work item</th>"
    refute_includes body, "<th>Attempt</th>"
  end

  # AC5
  def test_the_staleness_note_is_present
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    body = get_on(app, "/entity?id=runner%3Awf%3Aalpha").body

    # The literal, not App::STALENESS_NOTE: asserting the constant against
    # itself passes for any wording, and the Dev Notes pin this string.
    assert_includes body,
                    "<p class=\"staleness\">Liveness is observed on the supervisor's ~1 s supervision " \
                    "tick, so a crash can take up to ~1 s to appear here. This latency counts inside " \
                    "the ≤ 2 s freshness budget, not on top of it.</p>"
  end

  # Every not-found test below runs against this, never against an empty
  # roster: with roster: [] the lookup returns nil for any input, so the whole
  # batch would pass against an app with no id handling at all.
  def one_runner_app
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    build_app(Fleet.new(roster: roster, state_registry: registry))
  end

  # The positive control every not-found test needs: this app does render a
  # detail page, so a 404 below is the id being rejected, not the fleet being
  # empty.
  def assert_renders_alpha(app)
    response = get_on(app, "/entity?id=runner%3Awf%3Aalpha")

    assert_equal 200, response.status
    assert_includes response.body, "<h2>alpha</h2>"
  end

  # The Detail page contract's empty markers: "— is the empty marker … never a
  # blank cell, never nil.to_s: an empty cell reads as a rendering bug". An
  # entity that never published exercises every one of them at once, plus the
  # back-link and the three rows no other test asserts.
  def test_a_never_published_entity_renders_every_pinned_empty_marker
    id = RunnerIdentity.new(workflow: "wf", runner: "ghost")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "ghost", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: StateRegistry.new))

    body = get_on(app, "/entity?id=runner%3Awf%3Aghost").body

    assert_includes body, %(<p><a href="/">&larr; Fleet</a></p>)
    assert_includes body, "<h2>ghost</h2>"
    assert_includes body, "<tr><th>Workflow</th><td>wf</td></tr>"
    assert_includes body, "<tr><th>Kind</th><td>runner</td></tr>"
    assert_includes body, %(<span class="liveness liveness-unknown">unknown</span>)
    assert_includes body, "<tr><th>Activity</th><td>—</td></tr>"
    assert_includes body, "<tr><th>Generation</th><td>—</td></tr>"
    assert_includes body, "<tr><th>State published</th><td>never</td></tr>"
    assert_includes body, "<p>no state published — never started, or failed to start</p>"
  end

  # AC11: an unknown id is a plain 404 that echoes nothing.
  def test_get_entity_with_unknown_id_is_not_found_and_echoes_nothing
    app = one_runner_app
    assert_renders_alpha(app)

    response = get_on(app, "/entity?id=nope")

    assert_equal 404, response.status
    assert_equal "not found", response.body
  end

  def test_get_entity_with_a_hostile_id_is_not_found_and_echoes_nothing
    app = one_runner_app
    assert_renders_alpha(app)

    ["../../etc/passwd", "<script>alert(1)</script>"].each do |hostile|
      response = get_on(app, "/entity?id=#{Rack::Utils.escape(hostile)}")

      assert_equal 404, response.status
      assert_equal "not found", response.body
    end
  end

  # AC11's "malformed" half. Rack raises out of query parsing for a key that
  # mixes scalar and array forms or nests past its depth limit; PARAM_ERRORS
  # turns each into the same 404. Untested, that rescue is dead code to CI —
  # which is exactly how ParameterTypeError escaped the original list.
  def test_get_entity_with_a_malformed_query_string_is_not_found
    app = one_runner_app
    assert_renders_alpha(app)

    ["id=1&id[]=2", "id[]=1&id=2", "id#{"[a]" * 40}=1"].each do |query|
      response = get_on(app, "/entity?#{query}")

      assert_equal 404, response.status, "malformed query #{query.inspect} must be a 404, not a 500"
      assert_equal "not found", response.body
    end
  end

  # The Routing contract is one path and one *query* parameter. #params would
  # also merge a form-encoded body, so the id in the visible URL would not be
  # the id that renders.
  def test_a_form_encoded_body_cannot_override_the_query_string_id
    app = one_runner_app
    assert_renders_alpha(app)

    response = app.get("/entity?id=nope",
                       { Auth::SESSION_ENV_KEY => session_for("alice"),
                         :input => "id=runner%3Awf%3Aalpha",
                         "CONTENT_TYPE" => "application/x-www-form-urlencoded" })

    assert_equal 404, response.status
    assert_equal "not found", response.body
  end

  def test_post_entity_is_not_found
    assert_equal 404, @app.post("/entity").status
  end

  def test_get_entity_with_no_id_param_is_not_found
    app = one_runner_app
    assert_renders_alpha(app)

    assert_equal 404, get_on(app, "/entity").status
    assert_equal 404, get_on(app, "/entity?id=").status
  end

  # AC12: the detail page carries the same no-store header and CSRF logout
  # form as the list page.
  def test_the_detail_page_carries_no_store_and_the_csrf_logout_form
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))
    session = session_for("alice")

    response = app.get("/entity?id=runner%3Awf%3Aalpha", { Auth::SESSION_ENV_KEY => session })

    assert_equal "no-store", response.headers["cache-control"]
    assert_includes response.body, %(action="/auth/logout")
    assert_includes response.body, session.csrf_token
  end

  # AC10: following the list's link actually renders that entity's page, not
  # just the presence of an <a>.
  def test_the_lists_entity_link_round_trips_to_that_entitys_detail_page
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    list_body = get_on(app, "/").body
    href = list_body[%r{href="(/entity\?id=[^"]+)"}, 1]
    refute_nil href, "no entity link found on the list page"

    detail_body = get_on(app, href).body

    assert_includes detail_body, "<h2>alpha</h2>"
  end

  # --- Story 2.5: the activity log section ----------------------------------

  # Scoped to the activity section, not the whole body: body[/…/m] is nil on
  # no-match, so a layout regression surfaces as a readable failure here
  # rather than as a NoMethodError further down.
  def activity_section(body)
    found = body[%r{<h3>Recent activity \(up to \d+ events\)</h3>.*?<p class="activity-note">[^<]*</p>}m]
    refute_nil found, "no activity section found in the page"
    found
  end

  def build_activity_app(roster:, state_registry: StateRegistry.new, event_bus: EventBus.new)
    fleet = Fleet.new(roster: roster, state_registry: state_registry)
    build_app(fleet, activity_log: ActivityLog.new(event_bus: event_bus))
  end

  # The section's two remaining pinned strings, asserted literally rather than
  # against the constants that render them: the note is only ever located by
  # activity_section's `[^<]*` regex, which passes for any wording, and the
  # header row is only ever asserted in the negative by the empty-state test.
  # Column set and order are part of the contract.
  def test_the_pinned_note_and_table_header_render_verbatim
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    bus.publish(id, { type: :picked_up, work_item: "TASK-1", generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section,
                    "<tr><th>When</th><th>Gen</th><th>Event</th><th>Work item</th>" \
                    "<th>Attempt</th><th>Detail</th></tr>"
    assert_includes section,
                    "<p class=\"activity-note\">Recent activity only — the event buffer is bounded " \
                    "and does not survive a supervisor restart.</p>"
  end

  # The heading advertises the limit the injected log actually applies, not
  # ActivityLog::DEFAULT_LIMIT — otherwise a non-default limit renders a
  # truncated timeline under a promise of 50, the false negative the
  # bounded-buffer note exists to prevent.
  def test_the_heading_reports_the_injected_logs_own_limit
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    3.times { |i| bus.publish(id, { type: :picked_up, work_item: "item-#{i}", generation: 1 }) }
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: StateRegistry.new)
    app = build_app(fleet, activity_log: ActivityLog.new(event_bus: bus, limit: 2))

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "<h3>Recent activity (up to 2 events)</h3>"
    refute_includes section, "up to #{ActivityLog::DEFAULT_LIMIT} events"
    assert_equal 2, section.scan("<tr><td>").size
  end

  def test_a_full_work_item_cycle_renders_three_activity_rows
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    gen1 = GenerationStamp.new(1, bus)
    gen1.publish(id, { type: :picked_up, work_item: "T-1" })
    gen1.publish(id, { type: :started, work_item: "T-1", attempt: 1 })
    gen1.publish(id, { type: :finished, work_item: "T-1", attempt: 1, reason: :ok })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "<h3>Recent activity (up to 50 events)</h3>"
    assert_equal 3, section.scan("<tr><td>").size
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, section)
    assert_includes section, "<td>1</td><td>picked_up</td><td>T-1</td><td>—</td><td>—</td>"
    assert_includes section, "<td>1</td><td>started</td><td>T-1</td><td>1</td><td>—</td>"
    assert_includes section, "<td>1</td><td>finished</td><td>T-1</td><td>1</td><td>ok</td>"
  end

  def test_each_finished_reason_renders_verbatim_in_the_detail_cell
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    %i[ok failed timeout killed].each_with_index do |reason, i|
      bus.publish(id, { type: :finished, work_item: "T-#{i}", attempt: 1, reason: reason, generation: 1 })
    end
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    %w[ok failed timeout killed].each do |reason|
      assert_includes section, "<td>#{reason}</td></tr>", "reason #{reason.inspect} did not render verbatim"
    end
  end

  def test_a_restart_event_renders_its_actor_set_and_timestamp
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    bus.publish(id, { type: :restart, actor: [:crash_auto], generation: 2 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, section)
    assert_includes section, "<td>restart</td><td>—</td><td>—</td><td>actor: crash_auto</td>"
  end

  def test_a_multi_actor_restart_set_renders_joined
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    bus.publish(id, { type: :restart, actor: %i[crash_auto console_alice], generation: 2 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "actor: crash_auto, console_alice"
  end

  def test_a_restart_with_an_empty_actor_array_renders_the_em_dash
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    bus.publish(id, { type: :restart, actor: [], generation: 2 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "<td>restart</td><td>—</td><td>—</td><td>—</td>"
  end

  # AC4: two generations of the same restarted runner interleave, and each row
  # carries its own generation rather than the current one.
  def test_interleaved_generations_render_their_own_generation_per_row
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    GenerationStamp.new(1, bus).publish(id, { type: :picked_up, work_item: "T-1" })
    GenerationStamp.new(2, bus).publish(id, { type: :picked_up, work_item: "T-2" })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "<td>2</td><td>picked_up</td><td>T-2</td>"
    assert_includes section, "<td>1</td><td>picked_up</td><td>T-1</td>"
  end

  # AC4/Detail cell: a record shape this app does not know is rendered with
  # its type and timestamp and an em-dash Detail, never dropped and never
  # raised on.
  def test_an_unrecognised_event_type_renders_with_an_em_dash_detail
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    bus.publish(id, { type: :some_future_event, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "<td>some_future_event</td><td>—</td><td>—</td><td>—</td>"
  end

  def test_a_hostile_work_item_is_rendered_inert
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    malicious = "<script>alert(1)</script>"
    bus = EventBus.new
    bus.publish(id, { type: :picked_up, work_item: malicious, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute_includes section, malicious
  end

  def test_a_hostile_actor_is_rendered_inert
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    malicious = "<script>alert(1)</script>"
    bus = EventBus.new
    bus.publish(id, { type: :restart, actor: [malicious], generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute_includes section, malicious
  end

  # AC8: an entity with no events renders the pinned empty-state message and
  # no table inside the activity section — not the absence of the whole
  # section, and not merely the absence of the word "table".
  def test_an_entity_with_no_events_renders_the_pinned_empty_state
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, state_registry: registry)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "<p>No activity recorded.</p>"
    refute_includes section, "<tr><th>When</th><th>Gen</th><th>Event</th><th>Work item</th><th>Attempt</th><th>Detail</th></tr>"
  end

  # AC8: a messenger's timeline is restart-only, never absent — and 2.4's
  # AC9 guard (no Work item/Attempt rows for a non-runner) must still hold.
  def test_a_messenger_with_a_restart_event_renders_that_row_and_no_work_item_rows
    entity_id = "messenger:wf"
    bus = EventBus.new
    bus.publish(entity_id, { type: :restart, actor: [:crash_auto], generation: 1 })
    registry = StateRegistry.new
    registry.publish(entity_id, { status: :running, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: entity_id)]
    app = build_activity_app(roster: roster, state_registry: registry, event_bus: bus)

    body = get_on(app, "/entity?id=messenger%3Awf").body
    section = activity_section(body)

    assert_includes section, "actor: crash_auto"
    refute_includes body, "<tr><th>Work item</th><td>"
    refute_includes body, "<tr><th>Attempt</th><td>"
  end

  # More events than the limit -> exactly ActivityLog::DEFAULT_LIMIT rows, the
  # newest present and the oldest absent.
  def test_more_events_than_the_limit_renders_only_the_newest_default_limit_rows
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    (ActivityLog::DEFAULT_LIMIT + 10).times { |i| bus.publish(id, { type: :picked_up, work_item: "item-#{i}", generation: 1 }) }
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_equal ActivityLog::DEFAULT_LIMIT, section.scan("<tr><td>").size
    assert_includes section, "item-#{ActivityLog::DEFAULT_LIMIT + 9}"
    refute_includes section, "item-0<"
  end

  # AC7: a render fault costs the operator the whole page (a loud 500), never
  # a silently missing row — and never echoes the fault or the request path.
  def test_an_activity_log_that_raises_on_read_yields_a_500_with_no_echo_and_one_logged_error
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    fleet = Fleet.new(roster: roster, state_registry: StateRegistry.new)
    exploding_activity_log = Object.new.tap do |o|
      def o.recent(*) = raise "activity log boom, path /entity?id=runner:wf:alpha"
    end
    app = build_app(fleet, activity_log: exploding_activity_log)

    errors = capture_log_errors do
      @response = get_on(app, "/entity?id=runner%3Awf%3Aalpha")
    end

    assert_equal 500, @response.status
    assert_equal "internal error", @response.body
    refute_includes @response.body, "boom"
    refute_includes @response.body, "/entity"
    assert_equal 1, errors.size
    assert_match(/RuntimeError/, errors.first)
    # The other half of the contract: what the body must not carry, the log
    # must. Without this the rescue could log nothing useful and still pass.
    assert_includes errors.first, "activity log boom"
    assert_includes errors.first, "/entity"
  end

  # Same helper test_supervisor_master.rb uses (capture_log_errors): swap the
  # null logger this file's other tests never installed for a StringIO one,
  # for the duration of the block only. LogStubbing is deliberately not used
  # here — it installs a File::NULL logger, which cannot capture, and this
  # test asserts on what was logged. The restore mirrors LogStubbing's,
  # clear_context included.
  def capture_log_errors
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.level = ::Logger::ERROR
    prior = AgentDaemon::Log.instance_variable_get(:@logger)
    AgentDaemon::Log.use(logger)
    yield
    io.string.lines.map(&:chomp).reject(&:empty?)
  ensure
    AgentDaemon::Log.instance_variable_set(:@logger, prior)
    AgentDaemon::Log.clear_context
  end
end
