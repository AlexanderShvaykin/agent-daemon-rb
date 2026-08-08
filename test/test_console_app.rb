# frozen_string_literal: true

require "test_helper"
require "delegate"
require "rack"

# AD-5 lazy-require isolation: console files are loaded explicitly here.
require "agent_daemon/supervisor/console/app"
require "agent_daemon/supervisor/console/auth"
require "agent_daemon/supervisor/console/session_store"
require "agent_daemon/supervisor/console/live_updates"
require "agent_daemon/supervisor/fleet"
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/runner_identity"
require "agent_daemon/supervisor/activity_log"
require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/runner_supervisor"
require "agent_daemon/supervisor/output_buffers"
require "agent_daemon/supervisor/output_pipeline"
require "agent_daemon/supervisor/redactor"

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
  LiveUpdates = AgentDaemon::Supervisor::Console::LiveUpdates
  OutputBuffers = AgentDaemon::Supervisor::OutputBuffers
  OutputPipeline = AgentDaemon::Supervisor::OutputPipeline
  Redactor = AgentDaemon::Supervisor::Redactor

  class CountingFleet < SimpleDelegator
    attr_reader :entries_calls

    def initialize(fleet)
      super
      @entries_calls = 0
    end

    def entries
      @entries_calls += 1
      __getobj__.entries
    end
  end

  def setup
    @registry = StateRegistry.new
    @fleet = Fleet.new(roster: [], state_registry: @registry)
    @app = build_app(@fleet)
    @sessions = SessionStore.new(ttl: 3_600)
  end

  def build_app(fleet, activity_log: ActivityLog.new(event_bus: EventBus.new),
                live_updates: LiveUpdates.new(event_bus: EventBus.new, state_registry: StateRegistry.new),
                output_buffers: OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES))
    Rack::MockRequest.new(Rack::Lint.new(App.new(fleet: fleet, activity_log: activity_log, live_updates: live_updates,
                                                  output_buffers: output_buffers)))
  end

  # The bare App, unwrapped — /events tests drive `#call` directly with a
  # hand-built hijack env (Auth::AUTHORIZATION_ENV_KEY, rack.hijack?,
  # HTTP_LAST_EVENT_ID), matching test_events_uses_partial_hijack_with_exact_
  # headers_and_fixed_frames's existing pattern; Rack::MockRequest cannot
  # express a hijack request.
  def build_raw_app(fleet, output_buffers: OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES))
    bus = EventBus.new
    registry = StateRegistry.new
    live_updates = LiveUpdates.new(event_bus: bus, state_registry: registry, output_buffers: output_buffers,
                                    wait: ->(_seconds) {})
    App.new(fleet: fleet, activity_log: ActivityLog.new(event_bus: bus), live_updates: live_updates,
            output_buffers: output_buffers)
  end

  # A real, freshly promoted session — the same object the middleware puts in
  # env, not a hand-rolled stand-in (AI-1).
  def session_for(username)
    pending = @sessions.create_pending(state: "s")
    @sessions.claim_pending(pending.id, "s")
    @sessions.promote(pending.id, username: username)
  end

  # The page carries exactly one intentional <script>: the static live-update
  # constant. Strip that one known-static block and NOTHING may reintroduce a
  # script token — the class-level guard that predates the SSE work, restored
  # rather than narrowed to whichever payload a test happens to inject.
  def inert_body(body)
    stripped = body.sub(App::LIVE_SCRIPT, "")
    refute_includes stripped, "<script", "the live-update script must be the page's only <script> block"
    stripped
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

  # The favicon is inlined rather than served from /favicon.ico, which the
  # default-deny middleware would answer with a login redirect.
  def test_root_inlines_the_favicon_as_a_data_uri
    body = get("/").body

    assert_includes body, %(<link rel="icon" href="data:image/svg+xml,)
    refute_includes App::FAVICON, "#", "'#' must be percent-encoded inside a data URI"
  end

  # AD-7: every interpolated value is rendered inert. The username comes from
  # GitLab, so it is not ours to trust.
  def test_root_escapes_the_username
    response = get("/", username: "<script>alert(1)</script>")

    assert_equal 200, response.status
    refute_includes inert_body(response.body), "<script"
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

    refute_includes inert_body(body), "<script"
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

  def test_authenticated_pages_have_a_stable_live_content_region_and_static_refresh_script
    body = get("/").body

    assert_equal 1, body.scan('<main id="console-content">').size
    # Story 3.6: the fleet page has no terminal panel, so buildEventsUrl()
    # falls through to the bare "/events" string at runtime — the literal
    # `new EventSource(...)` call site is static text, built once.
    assert_equal 1, body.scan("new EventSource(buildEventsUrl())").size
    assert_includes body, 'return "/events";'
    assert_includes body, 'source.addEventListener("open", refreshContent)'
    assert_includes body, 'source.addEventListener("refresh", refreshContent)'
    assert_includes body, 'source.addEventListener("authorization_lost"'
    assert_includes body, 'fetch(window.location.href, { credentials: "same-origin" })'
    assert_includes body, 'response.headers.get("content-type")'
    assert_includes body, 'document.querySelector("#console-content")'
    assert_includes body, "current.replaceWith(replacement)"
    assert_includes body, "dirty = true"
    assert_includes body, "source.close()"
    refute_includes body, "innerHTML"

    # A CLOSED EventSource is fatal per the SSE specification — the browser
    # will not reconnect — so the page must leave for login rather than sit on
    # state that stopped updating while still looking live.
    assert_includes body, 'source.addEventListener("error"'
    assert_includes body, "EventSource.CLOSED"

    # pagehide also fires into the back/forward cache. A one-shot listener plus
    # no pageshow is how Back restores a page whose stream is closed forever.
    assert_includes body, 'window.addEventListener("pageshow"'
    assert_includes body, "event.persisted"
    refute_includes body, "{ once: true }"
  end

  def test_authenticated_pages_emit_one_frozen_static_stylesheet_outside_live_content
    body = get("/").body

    assert App::STYLESHEET.frozen?
    assert_equal 1, body.scan("<style>").size
    assert_equal 1, body.scan("</style>").size
    assert_operator body.index("</style>"), :<, body.index('<main id="console-content">')
    assert_includes body, App::STYLESHEET
  end

  def test_live_content_region_contains_the_complete_replaceable_fleet_view
    roster = [
      Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha",
                          entity_id: RunnerIdentity.new(workflow: "wf", runner: "alpha")),
      Fleet::Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor",
                          entity_id: "mattermost_reactor")
    ]
    body = get_on(build_app(Fleet.new(roster: roster, state_registry: StateRegistry.new)), "/").body
    content = body[/<main id="console-content">(.*?)<\/main>/m, 1]

    refute_nil content
    assert_includes content, "Fleet summary"
    assert_includes content, ">wf</h2>"
    assert_includes content, ">Fleet-wide</h2>"
    assert_includes content, "alpha"
    assert_includes content, "mattermost_reactor"
    refute_includes content, "<style>"
    refute_includes content, "console-header"
  end

  def test_live_content_region_contains_complete_detail_sections_but_not_chrome_or_css
    body = get_on(one_runner_app, "/entity?id=runner%3Awf%3Aalpha").body
    content = body[/<main id="console-content">(.*?)<\/main>/m, 1]

    refute_nil content
    assert_includes content, 'aria-labelledby="entity-diagnostics-heading"'
    assert_includes content, 'aria-labelledby="activity-heading"'
    assert_includes content, "alpha"
    assert_includes content, "Recent activity"
    refute_includes content, "<style>"
    refute_includes content, "console-header"
    # Anchored on the element, not the bare class name: `console-header` also
    # appears as a CSS rule inside the <head> <style>, so indexing on the
    # substring alone would pass even with the header element deleted.
    assert_includes body, '<header class="console-header">'
    assert_operator body.index("</style>"), :<, body.index('<main id="console-content">')
    assert_operator body.index('<header class="console-header">'), :<,
                    body.index('<main id="console-content">')
  end

  def test_stylesheet_provides_responsive_reflow_and_keyboard_focus_contracts
    stylesheet = App::STYLESHEET

    assert_includes stylesheet, "grid-template-columns"
    assert_includes stylesheet, "@media"
    assert_includes stylesheet, ":focus-visible"
    assert_includes stylesheet, "overflow-wrap"
  end

  def test_head_for_authenticated_pages_is_bodiless
    session = session_for("alice")
    env = { Auth::SESSION_ENV_KEY => session }

    root = @app.request("HEAD", "/", env)
    assert_equal 200, root.status
    assert_empty root.body

    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: StateRegistry.new))
    detail = app.request("HEAD", "/entity?id=runner%3Awf%3Aalpha", env)
    assert_equal 200, detail.status
    assert_empty detail.body
  end

  def test_events_uses_partial_hijack_with_exact_headers_and_fixed_frames
    bus = EventBus.new
    registry = StateRegistry.new
    live_updates = LiveUpdates.new(event_bus: bus, state_registry: registry, wait: ->(_seconds) {})
    raw_app = App.new(fleet: @fleet, activity_log: ActivityLog.new(event_bus: bus), live_updates: live_updates,
                       output_buffers: OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES))
    env = Rack::MockRequest.env_for(
      "/events",
      "rack.hijack?" => true,
      Auth::AUTHORIZATION_ENV_KEY => -> { false }
    )

    status, headers, body = raw_app.call(env)

    assert_equal 200, status
    assert_equal "text/event-stream; charset=utf-8", headers["content-type"]
    assert_equal "no-cache, no-store", headers["cache-control"]
    assert_equal "no", headers["x-accel-buffering"]
    assert_respond_to headers["rack.hijack"], :call
    assert_empty body

    io = StringIO.new
    headers["rack.hijack"].call(io)
    assert_includes io.string, "event: refresh\n"
    assert_includes io.string, "event: authorization_lost\n"
  end

  # Story 3.6 AC1/AC2: a valid runner id resolves to that entity's raw
  # entity_id and hijacks normally; with no bootstrap cursor the first tick
  # is a run change (AC8's own mechanism, not a special case).
  def test_events_with_a_valid_runner_id_hijacks_and_streams_that_entitys_output
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    output_buffers = OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES)
    pipeline = OutputPipeline.new(redactor: Redactor.new([]))
    pipeline.subscribe(output_buffers)
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "hello\n")

    app = build_raw_app(Fleet.new(roster: roster, state_registry: StateRegistry.new), output_buffers: output_buffers)
    checks = 0
    env = Rack::MockRequest.env_for(
      "/events?id=runner%3Awf%3Aalpha",
      "rack.hijack?" => true,
      Auth::AUTHORIZATION_ENV_KEY => -> { checks += 1; checks < 2 }
    )

    status, headers, body = app.call(env)

    assert_equal 200, status
    assert_empty body

    io = StringIO.new
    headers["rack.hijack"].call(io)
    assert_includes io.string, "event: output_run\n"
    assert_includes io.string, %("text":"hello")
  end

  # AC14: malformed, unknown, and known-but-non-runner ids all return the
  # existing fixed non-disclosing 404, and never reach the authorized
  # callback — proof the hijack never happens.
  def test_events_with_a_malformed_unknown_or_non_runner_id_is_not_found_and_does_not_hijack
    alpha = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: alpha),
              Fleet::Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: "messenger:wf")]
    app = build_raw_app(Fleet.new(roster: roster, state_registry: StateRegistry.new))

    ["id=%3Cscript%3E", "id=runner%3Awf%3Aghost", "id=messenger%3Awf"].each do |query|
      env = Rack::MockRequest.env_for(
        "/events?#{query}",
        "rack.hijack?" => true,
        Auth::AUTHORIZATION_ENV_KEY => -> { flunk("a 404 id must never reach the authorized callback") }
      )

      status, _headers, body = app.call(env)

      assert_equal 404, status
      assert_equal ["not found"], body
    end
  end

  # AC14 names FOUR rejects and only "missing" may fall through to the
  # fleet-wide stream. A query string Rack refuses to parse is malformed, not
  # missing — /entity already 404s it, and /events used to answer 200 with a
  # cursor-less stream that could never emit output.
  def test_events_with_an_unparseable_query_string_is_not_found_rather_than_a_fleet_stream
    alpha = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app = build_raw_app(Fleet.new(roster: runner_roster(alpha), state_registry: StateRegistry.new))

    # Positive control: an id-less /events IS a legitimate fleet stream, so
    # the 404 below is about malformedness, not about the absence of an id.
    bare = Rack::MockRequest.env_for("/events", "rack.hijack?" => true,
                                                Auth::AUTHORIZATION_ENV_KEY => -> { true })
    bare_status, = app.call(bare)

    assert_equal 200, bare_status

    env = Rack::MockRequest.env_for(
      "/events?id=1&id[]=2", "rack.hijack?" => true,
      Auth::AUTHORIZATION_ENV_KEY => -> { flunk("a malformed query must never reach the authorized callback") }
    )
    status, _headers, body = app.call(env)

    assert_equal 404, status
    assert_equal ["not found"], body
  end

  # Integer() accepts a leading sign, 0x/0 radix prefixes and _ separators.
  # `seq=-1` is the one that bites: OutputBuffers reads any seq below
  # head_seq - 1 as a lagged cursor, making a full-window replay available on
  # demand to any authenticated client. Every hostile cursor must degrade to
  # "no cursor", which is itself a full window — so the assertion is that the
  # stream stays UP and non-500, and the negative case is proven by the
  # matching-cursor control that emits nothing.
  def test_hostile_cursor_values_degrade_to_no_cursor_without_raising
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    output_buffers = OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES)
    pipeline = OutputPipeline.new(redactor: Redactor.new([]))
    pipeline.subscribe(output_buffers)
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "one\n")

    app = build_raw_app(Fleet.new(roster: runner_roster(id), state_registry: StateRegistry.new),
                        output_buffers: output_buffers)

    # Control: an exact, well-formed cursor resumes silently.
    assert_empty stream_events(app, "gen=1&run=1&seq=1"), "a matching cursor must emit no output frame"

    ["gen=1&run=1&seq=-1", "gen=1&run=1&seq=0x1f", "gen=1&run=1&seq=#{'9' * 40}",
     "gen=1&run=1", "gen=1&run=1&seq=", "gen=1&run=1&seq=abc"].each do |query|
      assert_includes stream_events(app, query), "event: output_run\n",
                      "#{query} must degrade to a cursor-less full window"
    end
  end

  def stream_events(app, query)
    checks = 0
    env = Rack::MockRequest.env_for(
      "/events?id=runner%3Awf%3Aalpha&#{query}", "rack.hijack?" => true,
      Auth::AUTHORIZATION_ENV_KEY => -> { checks += 1; checks < 2 }
    )
    status, headers, = app.call(env)

    assert_equal 200, status
    io = StringIO.new
    headers["rack.hijack"].call(io)
    io.string.scan(/event: output(?:_run|_lagged)?\n/).join
  end

  # AC10: a reconnect's Last-Event-ID wins over query params and resumes
  # exactly (no output frame when nothing is new); a malformed one degrades
  # to no cursor rather than a 500 from OutputBuffers' ArgumentError.
  def test_last_event_id_resumes_the_cursor_and_a_malformed_one_degrades_to_the_full_window
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    output_buffers = OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES)
    pipeline = OutputPipeline.new(redactor: Redactor.new([]))
    pipeline.subscribe(output_buffers)
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "one\n")

    app = build_raw_app(Fleet.new(roster: runner_roster(id), state_registry: StateRegistry.new),
                         output_buffers: output_buffers)

    # Positive control for the assertions below: with NO cursor at all this
    # same request does emit a full window, so a later "no output frame" is
    # evidence the cursor was honoured, not evidence that nothing streams.
    bare_checks = 0
    bare_env = Rack::MockRequest.env_for(
      "/events?id=runner%3Awf%3Aalpha", "rack.hijack?" => true,
      Auth::AUTHORIZATION_ENV_KEY => -> { bare_checks += 1; bare_checks < 2 }
    )
    _bare_status, bare_headers, = app.call(bare_env)
    bare_io = StringIO.new
    bare_headers["rack.hijack"].call(bare_io)
    assert_includes bare_io.string, "event: output_run\n"

    # The header carries the up-to-date cursor and the query params carry a
    # stale one that WOULD look like a run change. The header must win, so
    # the stream resumes silently instead of replaying a window.
    resumed_checks = 0
    resumed_env = Rack::MockRequest.env_for(
      "/events?id=runner%3Awf%3Aalpha&gen=1&run=9&seq=0", "rack.hijack?" => true,
      "HTTP_LAST_EVENT_ID" => "1:1:1",
      Auth::AUTHORIZATION_ENV_KEY => -> { resumed_checks += 1; resumed_checks < 2 }
    )
    _status, resumed_headers, = app.call(resumed_env)
    resumed_io = StringIO.new
    resumed_headers["rack.hijack"].call(resumed_io)
    refute_includes resumed_io.string, "event: output\n"
    refute_includes resumed_io.string, "event: output_run\n"

    # A pre-3.6-shaped two-field id has no generation; it must degrade to no
    # cursor rather than raise ArgumentError on the Puma thread.
    short_checks = 0
    short_env = Rack::MockRequest.env_for(
      "/events?id=runner%3Awf%3Aalpha", "rack.hijack?" => true,
      "HTTP_LAST_EVENT_ID" => "1:1",
      Auth::AUTHORIZATION_ENV_KEY => -> { short_checks += 1; short_checks < 2 }
    )
    _short_status, short_headers, = app.call(short_env)
    short_io = StringIO.new
    short_headers["rack.hijack"].call(short_io)
    assert_includes short_io.string, "event: output_run\n"

    malformed_checks = 0
    malformed_env = Rack::MockRequest.env_for(
      "/events?id=runner%3Awf%3Aalpha", "rack.hijack?" => true,
      "HTTP_LAST_EVENT_ID" => "garbage",
      Auth::AUTHORIZATION_ENV_KEY => -> { malformed_checks += 1; malformed_checks < 2 }
    )
    _status2, malformed_headers, = app.call(malformed_env)
    malformed_io = StringIO.new
    malformed_headers["rack.hijack"].call(malformed_io)
    assert_includes malformed_io.string, "event: output_run\n"
  end

  def test_events_fails_closed_without_partial_hijack_and_rejects_other_verbs
    unavailable = get("/events")
    assert_equal 503, unavailable.status
    assert_equal "streaming unavailable", unavailable.body

    response = @app.post("/events")
    assert_equal 405, response.status
    assert_equal "method not allowed", response.body

    # Rack::Lint fails the request if a HEAD response carries a body, which is
    # the same RFC 9110 rule / and /entity already honour.
    head = @app.request("HEAD", "/events")
    assert_equal 405, head.status
    assert_empty head.body
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
    body = get("/").body

    assert_includes body, "Fleet summary"
    assert_includes body, "No supervised entities."
    refute_includes section(body, "Supervised entities"), "<ul"
  end

  # Substring matches against the whole document prove nothing about which
  # group a card landed in, so every grouping assertion below is scoped to one
  # section. A missing section fails here with its own name rather than as a
  # NoMethodError on nil further down.
  def section(body, heading)
    found = body[/<section[^>]*>\s*<h2[^>]*>#{Regexp.escape(heading)}<\/h2>.*?<\/section>/m]
    refute_nil found, "no labelled <h2>#{heading}</h2> section in the page"
    found
  end

  def test_root_reads_the_real_fleet_snapshot_exactly_once
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    fleet = CountingFleet.new(Fleet.new(roster: roster, state_registry: StateRegistry.new))

    response = get_on(build_app(fleet), "/")

    assert_equal 200, response.status
    assert_includes response.body, "alpha"
    assert_equal 1, fleet.entries_calls
  end

  def test_root_renders_a_truthful_summary_before_groups_from_the_same_fleet
    registry = StateRegistry.new
    roster = {
      "waiting" => :waiting,
      "working" => :in_progress,
      "flaky" => :crashed,
      "done" => :exited,
      "ghost" => nil
    }.map do |name, status|
      id = RunnerIdentity.new(workflow: "wf", runner: name)
      registry.publish(id, { status: status, generation: 1 }) if status
      Fleet::Rostered.new(kind: :runner, workflow: "wf", name: name, entity_id: id)
    end
    body = get_on(build_app(Fleet.new(roster: roster, state_registry: registry)), "/").body
    summary = section(body, "Fleet summary")

    { "Total" => 5, "Alive" => 2, "Restarting" => 1, "Dead" => 1, "Unknown" => 1 }.each do |label, count|
      assert_includes summary, "<dt>#{label}</dt><dd>#{count}</dd>"
    end
    assert_operator body.index("Fleet summary"), :<, body.index(">wf</h2>"), "summary must precede entity groups"
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

    assert_includes wf_a, %(<a href="/entity?id=runner%3AwfA%3Aalpha">alpha</a>)
    assert_includes wf_a, %(<span class="liveness liveness-alive">alive</span>)
    refute_includes wf_a, "beta"
    assert_includes wf_b, %(<a href="/entity?id=runner%3AwfB%3Abeta">beta</a>)
    refute_includes wf_b, "alpha"
    assert_operator body.index(">wfA</h2>"), :<, body.index(">wfB</h2>"), "workflows must render in config order"
  end

  # The Page contract pins the field set and its order. The exact-match
  # assertion on the whole <dl> is the point: without it a silent reorder or
  # a dropped field passes the whole suite.
  def test_each_entity_card_has_a_semantic_link_and_complete_labelled_values
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    group = section(get_on(app, "/").body, "wf")

    assert_includes group, '<ul aria-label="Entities in workflow wf" role="list">'
    assert_includes group, '<h3><a href="/entity?id=runner%3Awf%3Aalpha">alpha</a></h3>'
    assert_includes group, <<~HTML.chomp
      <dl>
      <div><dt>Kind</dt><dd>runner</dd></div>
      <div><dt>Liveness</dt><dd><span class="liveness liveness-alive">alive</span></dd></div>
      <div><dt>Note</dt><dd>—</dd></div>
      </dl>
    HTML
    assert_includes group, '<button type="button" disabled>Restart</button>'
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

    assert_includes wf_section, %(<a href="/entity?id=messenger%3Awf">messenger</a>)
    refute_includes wf_section, "mattermost_reactor"
    assert_includes fleet_wide_section, %(<a href="/entity?id=mattermost_reactor">mattermost_reactor</a>)
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

    refute_includes inert_body(body), "<script"
    assert_includes body, "&lt;script&gt;"
  end

  def test_a_hostile_workflow_name_is_rendered_inert_in_heading_and_label
    malicious = %(<script>alert("workflow")</script>)
    id = RunnerIdentity.new(workflow: malicious, runner: "alpha")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: malicious, name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: StateRegistry.new))

    body = get_on(app, "/").body

    refute_includes inert_body(body), malicious
    assert_includes body, '&lt;script&gt;alert(&quot;workflow&quot;)&lt;/script&gt;'
    assert_includes body, 'aria-label="Entities in workflow &lt;script&gt;alert(&quot;workflow&quot;)&lt;/script&gt;"'
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

  def diagnostic_section(body)
    found = body[%r{<section aria-labelledby="entity-diagnostics-heading">.*?</section>}m]
    refute_nil found, "no labelled diagnostics section in the page"
    found
  end

  def test_a_waiting_runner_shows_liveness_and_activity_but_no_work_item_row
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    diagnostics = diagnostic_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes diagnostics, %(<span class="liveness liveness-alive">alive</span>)
    assert_includes diagnostics, "<div><dt>Activity</dt><dd>waiting</dd></div>"
    refute_includes diagnostics, "<dt>Work item</dt>"
    refute_includes diagnostics, "<dt>Attempt</dt>"
  end

  # AC7
  def test_an_in_progress_runner_shows_the_work_item_and_attempt_count
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :in_progress, work_item: "T-1", attempt: 2, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    diagnostics = diagnostic_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    expected_fields = <<~HTML.chomp
      <div><dt>Workflow</dt><dd>wf</dd></div>
      <div><dt>Kind</dt><dd>runner</dd></div>
      <div><dt>Liveness</dt><dd><span class="liveness liveness-alive">alive</span></dd></div>
      <div><dt>Activity</dt><dd>in_progress</dd></div>
      <div><dt>Work item</dt><dd>T-1</dd></div>
      <div><dt>Attempt</dt><dd>2</dd></div>
      <div><dt>Generation</dt><dd>1 (0 restart(s))</dd></div>
    HTML
    assert_includes diagnostics, expected_fields
    assert_operator diagnostics.index("<dt>Work item</dt>"), :<, diagnostics.index("<dt>Generation</dt>")
    assert_operator diagnostics.index("<dt>Attempt</dt>"), :<, diagnostics.index("<dt>State published</dt>")
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

  def test_detail_page_escapes_hostile_entity_workflow_and_session_values
    malicious_name = %(<script>alert("entity")</script>)
    malicious_workflow = %(<img src=x onerror="workflow">)
    id = RunnerIdentity.new(workflow: malicious_workflow, runner: malicious_name)
    registry = StateRegistry.new
    registry.publish(id, { status: :waiting, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: malicious_workflow,
                                  name: malicious_name, entity_id: id)]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))
    session = session_for(%(<svg onload="username">))
    session.csrf_token = %("><script>csrf</script>)

    entity_id = RunnerIdentity.key_for(id)
    response = app.get("/entity?id=#{Rack::Utils.escape(entity_id)}", { Auth::SESSION_ENV_KEY => session })
    assert_equal 200, response.status
    body = response.body
    diagnostics = diagnostic_section(body)

    assert_includes diagnostics, '&lt;script&gt;alert(&quot;entity&quot;)&lt;/script&gt;'
    assert_includes diagnostics, '&lt;img src=x onerror=&quot;workflow&quot;&gt;'
    assert_includes body, '&lt;svg onload=&quot;username&quot;&gt;'
    assert_includes body, '&quot;&gt;&lt;script&gt;csrf&lt;/script&gt;'
    refute_includes inert_body(body), malicious_name
    refute_includes diagnostics, malicious_workflow
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

    diagnostics = diagnostic_section(get_on(app, "/entity?id=runner%3Awf%3Aflaky").body)

    assert_includes diagnostics, %(<span class="liveness liveness-restarting">restarting</span>)
    # DR2 item 8: the order guard built from an :in_progress runner cannot
    # cover "Restarting for", which only renders in this state. Pinned here
    # against the two fields it must precede.
    assert_match(
      %r{<div><dt>Restarting\ for</dt><dd>\d+s</dd></div>\n
         <div><dt>Generation</dt><dd>1\ \(0\ restart\(s\)\)</dd></div>\n
         <div><dt>State\ published</dt>}x,
      diagnostics
    )
    refute_includes diagnostics, "<dt>Work item</dt>"
    refute_includes diagnostics, "<dt>Attempt</dt>"
    refute_includes diagnostics, "T-1"
  end

  def test_terminal_runner_states_omit_stale_work_and_keep_their_exact_adjacent_notes
    {
      exited: "exited cleanly — not auto-restarted",
      stopped: "stopped — fleet is shutting down"
    }.each do |status, note|
      id = RunnerIdentity.new(workflow: "wf", runner: status.to_s)
      registry = StateRegistry.new
      registry.publish(id, { status: :in_progress, work_item: "STALE", attempt: 3, generation: 1 })
      registry.publish(id, { status: status, generation: 2 })
      roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: status.to_s, entity_id: id)]
      app = build_app(Fleet.new(roster: roster, state_registry: registry))

      entity_id = RunnerIdentity.key_for(id)
      diagnostics = diagnostic_section(get_on(app, "/entity?id=#{Rack::Utils.escape(entity_id)}").body)

      assert_includes diagnostics,
                      "<div><dt>Activity</dt><dd>#{status}<p class=\"status-note\">#{note}</p></dd></div>"
      assert_includes diagnostics, "<div><dt>Generation</dt><dd>2 (1 restart(s))</dd></div>"
      refute_includes diagnostics, "<dt>Work item</dt>"
      refute_includes diagnostics, "<dt>Attempt</dt>"
      refute_includes diagnostics, "STALE"
    end
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

    stuck = diagnostic_section(get_on(stuck_app, "/entity?id=runner%3Awf%3Aflaky").body)
    fresh = diagnostic_section(get_on(fresh_app, "/entity?id=runner%3Awf%3Aflaky").body)

    assert_includes stuck, "<div><dt>Restarting for</dt><dd>66s</dd></div>"
    assert_includes stuck, "<strong>Restart delayed</strong> — respawn is failing"
    assert_operator stuck.index("Restart delayed"), :<, stuck.index("<button"),
                    "the delayed warning must precede the restart control"
    assert_includes fresh, "<div><dt>Restarting for</dt><dd>1s</dd></div>"
    refute_includes fresh, "Restart delayed"
  end

  # AC9: a messenger/reactor entity has no work-item/attempt semantics at all.
  def test_a_messenger_entity_shows_liveness_only
    registry = StateRegistry.new
    registry.publish("messenger:wf", { status: :running, generation: 1 })
    roster = [Fleet::Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: "messenger:wf")]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    diagnostics = diagnostic_section(get_on(app, "/entity?id=messenger%3Awf").body)

    assert_includes diagnostics, %(<span class="liveness liveness-alive">alive</span>)
    assert_includes diagnostics, "<div><dt>Activity</dt><dd>running</dd></div>"
    assert_includes diagnostics, "<div><dt>Generation</dt><dd>1 (0 restart(s))</dd></div>"
    refute_includes diagnostics, "<dt>Work item</dt>"
    refute_includes diagnostics, "<dt>Attempt</dt>"
  end

  def test_a_reactor_entity_shows_liveness_only
    registry = StateRegistry.new
    registry.publish("mattermost_reactor", { status: :running, generation: 1 })
    roster = [
      Fleet::Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor", entity_id: "mattermost_reactor")
    ]
    app = build_app(Fleet.new(roster: roster, state_registry: registry))

    diagnostics = diagnostic_section(get_on(app, "/entity?id=mattermost_reactor").body)

    assert_includes diagnostics, %(<span class="liveness liveness-alive">alive</span>)
    # The reactor is fleet-wide, so its Workflow cell is the pinned em dash
    # rather than a blank cell.
    assert_includes diagnostics, "<div><dt>Workflow</dt><dd>—</dd></div>"
    assert_includes diagnostics, "<div><dt>Activity</dt><dd>running</dd></div>"
    assert_includes diagnostics, "<div><dt>Generation</dt><dd>1 (0 restart(s))</dd></div>"
    refute_includes diagnostics, "<dt>Work item</dt>"
    refute_includes diagnostics, "<dt>Attempt</dt>"
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
    assert_includes response.body, '<h2 id="entity-diagnostics-heading">alpha</h2>'
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
    diagnostics = diagnostic_section(body)

    # The Fleet link is page-level navigation, so it sits ahead of the named
    # diagnostics region rather than being announced as content of it.
    assert_includes body, %(<p><a href="/">&larr; Fleet</a></p>)
    refute_includes diagnostics, %(<a href="/">&larr; Fleet</a>)
    assert_operator body.index(%(<a href="/">&larr; Fleet</a>)), :<,
                    body.index('<section aria-labelledby="entity-diagnostics-heading">')
    assert_includes diagnostics, '<h2 id="entity-diagnostics-heading">ghost</h2>'
    assert_includes diagnostics, "<div><dt>Workflow</dt><dd>wf</dd></div>"
    assert_includes diagnostics, "<div><dt>Kind</dt><dd>runner</dd></div>"
    assert_includes diagnostics, %(<span class="liveness liveness-unknown">unknown</span>)
    assert_includes diagnostics,
                    '<div><dt>Activity</dt><dd>—<p class="status-note">' \
                    'no state published — never started, or failed to start</p></dd></div>'
    assert_includes diagnostics, "<div><dt>Generation</dt><dd>—</dd></div>"
    assert_includes diagnostics, "<div><dt>State published</dt><dd>never</dd></div>"
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

    assert_includes detail_body, '<h2 id="entity-diagnostics-heading">alpha</h2>'
  end

  # --- Story 2.5: the activity log section ----------------------------------

  # Scoped to the activity section, not the whole body: body[/…/m] is nil on
  # no-match, so a layout regression surfaces as a readable failure here
  # rather than as a NoMethodError further down.
  def activity_section(body)
    found = body[%r{<section aria-labelledby="activity-heading">.*?<p class="activity-note">[^<]*</p>\s*</section>}m]
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
  # field labels are otherwise only asserted piecemeal by event-specific tests.
  # Field set AND order are part of the contract: this is the one
  # order-sensitive assertion over the timeline, replacing the header row the
  # table used to pin. An order-insensitive loop of `assert_includes` cannot
  # fail on a reorder, a dropped field, or a field migrating into another <dl>
  # — the exact regression Story 3.1's review had to undo once already.
  def test_the_pinned_note_and_timeline_fields_render_verbatim_and_in_order
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    bus.publish(id, { type: :picked_up, work_item: "TASK-1", generation: 1 })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_match(/<ol[^>]* role="list"[^>]*>/, section)
    assert_match(
      %r{<dl>\n
         <div><dt>When</dt><dd>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z</dd></div>\n
         <div><dt>Generation</dt><dd>1</dd></div>\n
         <div><dt>Event</dt><dd>picked_up</dd></div>\n
         <div><dt>Work\ item</dt><dd>TASK-1</dd></div>\n
         <div><dt>Attempt</dt><dd>—</dd></div>\n
         <div><dt>Detail</dt><dd>—</dd></div>\n
         </dl>}x,
      section
    )
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

    assert_includes section, '<h2 id="activity-heading">Recent activity (up to 2 events)</h2>'
    refute_includes section, "up to #{ActivityLog::DEFAULT_LIMIT} events"
    assert_equal 2, section.scan("<li>").size
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

    assert_includes section, '<h2 id="activity-heading">Recent activity (up to 50 events)</h2>'
    assert_equal 3, section.scan("<li>").size
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, section)
    assert_includes section, "<dt>Generation</dt><dd>1</dd>"
    assert_includes section, "<dt>Work item</dt><dd>T-1</dd>"
    assert_includes section, "<dt>Attempt</dt><dd>1</dd>"
    assert_includes section, %(<dt>Detail</dt><dd><span class="outcome outcome-ok">ok</span></dd>)
    assert_operator section.index("<dd>finished</dd>"), :<, section.index("<dd>started</dd>")
    assert_operator section.index("<dd>started</dd>"), :<, section.index("<dd>picked_up</dd>")
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
      assert_includes section, %(<span class="outcome outcome-#{reason}">#{reason}</span>),
                      "reason #{reason.inspect} did not render as a text-labelled outcome"
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
    assert_includes section, "<dt>Generation</dt><dd>2</dd>"
    assert_includes section, "<dt>Event</dt><dd>restart</dd>"
    assert_includes section, "<dt>Detail</dt><dd>actor: crash_auto</dd>"
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

    assert_includes section, "<dt>Event</dt><dd>restart</dd>"
    assert_includes section, "<dt>Detail</dt><dd>—</dd>"
  end

  # A boundary marker claims "a restart happened between these two events". An
  # event published through an unstamped bundle carries no generation, which is
  # a gap in the record, not a transition — the positive control above it is the
  # real boundary between generations 2 and 1.
  def test_an_event_without_a_generation_does_not_manufacture_a_boundary
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    bus = EventBus.new
    bus.publish(id, { type: :picked_up, work_item: "T-0" })
    GenerationStamp.new(1, bus).publish(id, { type: :picked_up, work_item: "T-1" })
    GenerationStamp.new(2, bus).publish(id, { type: :picked_up, work_item: "T-2" })
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
    app = build_activity_app(roster: roster, event_bus: bus)

    section = activity_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "<dt>Generation</dt><dd>—</dd>"
    assert_equal 1, section.scan('<p class="generation-boundary">').size
    assert_includes section, '<p class="generation-boundary">Generation boundary: 1</p>'
    refute_includes section, "Generation boundary: —"
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

    assert_operator section.index("<dt>Generation</dt><dd>2</dd>"), :<,
                    section.index("<dt>Generation</dt><dd>1</dd>"), "events must remain newest first"
    assert_includes section, "<dt>Work item</dt><dd>T-2</dd>"
    assert_includes section, "<dt>Work item</dt><dd>T-1</dd>"
    assert_includes section, '<p class="generation-boundary">Generation boundary: 1</p>'
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

    assert_includes section, "<dt>Event</dt><dd>some_future_event</dd>"
    assert_includes section, "<dt>Detail</dt><dd>—</dd>"
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
    refute_match(/<ol[^>]* role="list">/, section)
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
    diagnostics = diagnostic_section(body)
    refute_includes diagnostics, "<dt>Work item</dt>"
    refute_includes diagnostics, "<dt>Attempt</dt>"
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

    assert_equal ActivityLog::DEFAULT_LIMIT, section.scan("<li>").size
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

  # --- Story 3.5: the terminal / run-output panel ---------------------------

  # Scoped to the terminal section, not the whole body — the same rule
  # activity_section/diagnostic_section follow above. The wrapper is the page's
  # only unnamed <section> (the name lives on the inner scroll region, so the
  # two do not become duplicate nested landmarks), so anchoring on the heading
  # that follows it keeps the match unambiguous.
  def terminal_section(body)
    found = body[%r{<section>\s*<h2 id="terminal-heading">.*?</section>}m]
    refute_nil found, "no terminal section found in the page"
    found
  end

  # Retro AI-1: a real OutputPipeline + real Redactor + real OutputBuffers,
  # never a reimplementation of the store under test. The only double in this
  # section is the raising one in the DR7 fault-isolation test below.
  def build_terminal_app(roster:, capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES,
                          state_registry: StateRegistry.new)
    output_buffers = OutputBuffers.new(capacity_bytes: capacity_bytes)
    pipeline = OutputPipeline.new(redactor: Redactor.new([]))
    pipeline.subscribe(output_buffers)
    fleet = Fleet.new(roster: roster, state_registry: state_registry)
    app = build_app(fleet, output_buffers: output_buffers)
    [app, pipeline]
  end

  def runner_roster(id)
    [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: id)]
  end

  # AC1: an in-progress run's lines render in seq order, each carrying a
  # visible (not aria-label-only) stream label — Story 3.2's review proved a
  # bare <span aria-label> is dropped by browsers.
  def test_an_in_progress_run_renders_its_lines_in_seq_order_with_stream_labels
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "first line\n")
    bundle.append_output(:stderr, "second line\n")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, %(<span class="terminal-stream terminal-stream-stdout">out</span>first line)
    assert_includes section, %(<span class="terminal-stream terminal-stream-stderr">err</span>second line)
    assert_includes section, '<p class="terminal-state">Running</p>'
    assert_operator section.index("first line"), :<, section.index("second line"),
                    "records must render in ascending seq order"
  end

  # AC8/DR6: the scrollable region must be keyboard-reachable (WCAG 2.4.7 /
  # 2.4.11) — a semantic-attribute assertion, not a CSS/palette one.
  def test_the_scrollable_panel_is_a_labelled_keyboard_reachable_region
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "hello\n")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, '<h2 id="terminal-heading">Run output</h2>'
    assert_match(
      /<div class="terminal-panel" id="terminal-panel" tabindex="0" role="region" aria-labelledby="terminal-heading"\n */,
      section
    )
    # Exactly ONE thing may carry the "Run output" accessible name. A <section>
    # with an accessible name is itself a region landmark, so naming the
    # wrapper too would announce "Run output, region" twice, nested.
    assert_equal 1, section.scan('aria-labelledby="terminal-heading"').size,
                 "the scroll container is the only element that may be named by the heading"
    refute_includes section, '<section aria-labelledby="terminal-heading">'
  end

  # AC2: a completed run stays visible with its final reason, rendered
  # through the same outcome vocabulary activity_detail_html uses.
  def test_a_completed_run_keeps_its_output_and_shows_the_finished_outcome
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "done\n")
    bundle.end_output_run(1, :failed)

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, "done"
    assert_includes section, %(Finished — <span class="outcome outcome-failed">failed</span>)
    refute_includes section, '<p class="terminal-state">Running</p>'
  end

  def test_a_successfully_completed_run_shows_the_ok_outcome
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.end_output_run(1, :ok)

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, %(Finished — <span class="outcome outcome-ok">ok</span>)
  end

  # DR4's fourth row: reason.nil? must never be read as "still running".
  def test_a_finished_run_with_no_recorded_reason_states_that_explicitly
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.end_output_run(1, nil)

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    # The literal, not App::TERMINAL_NO_REASON_LABEL: asserting the constant
    # against itself passes for any wording, including "Running".
    assert_includes section, "Finished — run ended without a recorded reason"
    refute_includes section, '<p class="terminal-state">Running</p>'
  end

  # DR4's outcome vocabulary is a four-symbol whitelist; :ok and :failed are
  # covered above. These pin the other two plus the whitelist-miss branch,
  # where the CLASS is clamped to outcome-unknown while the TEXT is the
  # escaped reason verbatim — the sink protocol declares `reason` opaque
  # (sinks.rb:70-73), so both halves need pinning.
  def test_the_remaining_whitelisted_reasons_render_their_own_outcome_class
    %i[timeout killed].each do |reason|
      id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
      app, pipeline = build_terminal_app(roster: runner_roster(id))
      bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
      bundle.begin_output_run(1)
      bundle.end_output_run(1, reason)

      section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

      assert_includes section, %(Finished — <span class="outcome outcome-#{reason}">#{reason}</span>)
    end
  end

  def test_a_reason_outside_the_whitelist_is_clamped_to_the_unknown_class_but_shown_verbatim
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.end_output_run(1, :"weird<reason>")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, %(<span class="outcome outcome-unknown">)
    # The reason reaches an attribute-adjacent context, so it must be escaped
    # even though it can only come from core today.
    assert_includes section, "weird&lt;reason&gt;"
    refute_includes section, "weird<reason>"
  end

  # DR2's whole point: the panel joins on the RAW entity_id, so one runner's
  # page must never show another's output. Every other terminal test uses a
  # single-runner roster and would pass against a store keyed by anything.
  def test_the_panel_shows_only_the_requested_runners_output
    alpha = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    beta = RunnerIdentity.new(workflow: "wf", runner: "beta")
    roster = [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "alpha", entity_id: alpha),
              Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "beta", entity_id: beta)]
    output_buffers = OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES)
    pipeline = OutputPipeline.new(redactor: Redactor.new([]))
    pipeline.subscribe(output_buffers)
    app = build_app(Fleet.new(roster: roster, state_registry: StateRegistry.new),
                    output_buffers: output_buffers)

    AgentDaemon::Sinks::Bundle.new(entity_id: alpha, output: pipeline.ingress(1)).tap do |bundle|
      bundle.begin_output_run(1)
      bundle.append_output(:stdout, "alpha secret text\n")
    end
    AgentDaemon::Sinks::Bundle.new(entity_id: beta, output: pipeline.ingress(1)).tap do |bundle|
      bundle.begin_output_run(1)
      bundle.append_output(:stdout, "beta secret text\n")
    end

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Abeta").body)

    assert_includes section, "beta secret text"
    refute_includes section, "alpha secret text"
  end

  # AC3: the store holds at most one buffer per entity, so the next render
  # after a new run_started shows only the new run's content by construction.
  def test_a_new_run_replaces_the_panels_content
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "first run text\n")
    bundle.end_output_run(1, :ok)

    bundle.begin_output_run(2)
    bundle.append_output(:stdout, "second run text\n")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    refute_includes section, "first run text"
    assert_includes section, "second run text"
  end

  # AC4: no run has ever been selected for this entity.
  def test_a_runner_with_no_runs_renders_the_pinned_empty_state
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, _pipeline = build_terminal_app(roster: runner_roster(id))

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    # The literal, not the constant — see the no-recorded-reason test above.
    # The class is load-bearing: it is how the client retracts this note once
    # a run actually starts streaming.
    assert_includes section, '<p class="terminal-empty">No run output captured.</p>'
    # A scroll region with nothing to scroll must not collect a tab stop or
    # announce itself as "Run output" (Story 3.5 rendered no panel at all).
    refute_includes section, 'tabindex="0"'
    refute_includes section, 'role="region"'
    # ...but the element itself must survive, because it is the only carrier
    # of data-entity-id for a page that loads before the first run.
    assert_includes section, 'data-entity-id="runner:wf:alpha"'
  end

  # DR4: :retained + records: [] is Running with distinct no-output-yet
  # wording — an operator must be able to tell "no run selected" from "run
  # running silently".
  def test_a_started_run_with_no_output_yet_is_distinct_from_the_empty_state
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, '<p class="terminal-state">Running</p>'
    # Literals, so the two states cannot be silently rewritten into each other.
    assert_includes section, "(no output yet)"
    refute_includes section, "<p>No run output captured.</p>"
  end

  # Story 3.6 Task 3: the only bridge between this server-rendered snapshot
  # and the client's live cursor.
  def test_the_terminal_panel_carries_escaped_cursor_and_entity_id_attributes
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "hi\n")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, 'data-entity-id="runner:wf:alpha"'
    assert_includes section, 'data-run="1"'
    assert_includes section, 'data-seq="1"'
  end

  # A started run with zero output has no tail_seq — the placeholder "0"
  # keeps the cursor a valid Integer pair rather than omitting one half.
  def test_a_started_run_with_no_output_yet_gets_a_zero_seq_cursor
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, 'data-run="1"'
    assert_includes section, 'data-seq="0"'
  end

  # Task 3: an entity with no run at all omits the cursor attributes
  # entirely (the client starts cursor-less) but still carries the id the
  # EventSource URL needs to connect at all.
  def test_a_runner_with_no_runs_omits_cursor_attributes_but_keeps_the_entity_id
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, _pipeline = build_terminal_app(roster: runner_roster(id))

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, 'data-entity-id="runner:wf:alpha"'
    refute_includes section, "data-run="
    refute_includes section, "data-seq="
  end

  # Story 3.3 review deferred item, folded into 3.6 Task 6: a dead entity
  # whose runner thread never reached the backend's ensure must not render a
  # bare "Running" three rows below a "Liveness: dead" the operator just read.
  def test_a_dead_entity_with_an_unfinished_run_does_not_render_a_bare_running_state
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :exited })
    app, pipeline = build_terminal_app(roster: runner_roster(id), state_registry: registry)
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "still going?\n")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    refute_includes section, '<p class="terminal-state">Running</p>'
    assert_includes section, "Not running"
    # The client re-renders this line on the first output_state frame and has
    # no liveness input of its own, so the reconciled wording has to travel to
    # it as data. Without this the panel reverts to a bare "Running" one
    # 250 ms tick after load and the fix above is invisible in a browser.
    assert_includes section, 'data-running-label="Not running'
  end

  # The control for the above: a live entity's label stays "Running", so the
  # attribute is carrying the reconciliation rather than a constant.
  def test_a_live_entity_with_an_unfinished_run_carries_the_running_label
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    registry = StateRegistry.new
    registry.publish(id, { status: :running })
    app, pipeline = build_terminal_app(roster: runner_roster(id), state_registry: registry)
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "going\n")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    assert_includes section, '<p class="terminal-state">Running</p>'
    assert_includes section, 'data-running-label="Running"'
  end

  # AC5: eviction is stated, not hidden.
  # Task 9 manual QA, 2026-08-08: the hanging indent that keeps wrapped
  # continuation lines out of the gutter column is `text-indent: -2.7rem` on
  # .terminal-line — and text-indent INHERITS, with an inline-block applying it
  # to its own first line box. So the .terminal-stream span's "out"/"err"
  # glyphs painted 2.7rem to the left of the span, clean outside the scroll
  # container, while its box, hit-testing and getBoundingClientRect all stayed
  # correct. Every DOM- and HTML-level assertion passed; only the pixels were
  # wrong, leaving stdout and stderr distinguishable by colour alone (AC4,
  # WCAG 1.4.1). A stylesheet assertion is a poor substitute for a rendering
  # test, but it is what this suite can hold: it fails if the reset is dropped
  # or the hanging indent is reintroduced without one.
  def test_the_stream_label_resets_the_inherited_hanging_indent
    stream_rule = App::STYLESHEET[/\.terminal-stream \{[^}]*\}/m]

    refute_nil stream_rule, "the .terminal-stream rule must exist"
    assert_includes stream_rule, "text-indent: 0",
                    "the gutter label must reset .terminal-line's inherited negative text-indent"

    line_rule = App::STYLESHEET[/\.terminal-line \{[^}]*\}/m]

    assert_includes line_rule, "text-indent: -", "the wrapped-line hanging indent must still be present"
  end

  def test_overflowing_the_buffer_states_that_earlier_output_was_discarded
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id), capacity_bytes: 16)
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "#{'a' * 20}\n")
    bundle.append_output(:stdout, "#{'b' * 20}\n")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    # The literal, not the constant — see the no-recorded-reason test above.
    assert_includes section, '<p class="terminal-note">Earlier output was discarded — ' \
                              "the per-run output buffer is bounded.</p>"
  end

  def test_the_truncation_notice_is_absent_when_nothing_was_evicted
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "short\n")

    section = terminal_section(get_on(app, "/entity?id=runner%3Awf%3Aalpha").body)

    # Refuting the constant is vacuous the same way asserting it is: reword the
    # notice and this passes no matter what the page says. Refute the class the
    # notice is rendered with, plus its literal opening words.
    refute_includes section, '<p class="terminal-note">'
    refute_includes section, "Earlier output was discarded"
  end

  # AC6: only runners get a panel. Scoped to #console-content so the CSS
  # class names inside <style> (.terminal-panel etc.) cannot satisfy the
  # refutation — 3.2 review lesson.
  def console_content(body)
    found = body[%r{<main id="console-content">.*?</main>}m]
    refute_nil found, "no #console-content region found in the page"
    found
  end

  def test_a_messenger_entity_has_no_terminal_panel
    roster = [Fleet::Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: "messenger:wf")]
    app, _pipeline = build_terminal_app(roster: roster)

    content = console_content(get_on(app, "/entity?id=messenger%3Awf").body)

    refute_includes content, "terminal-heading"
  end

  def test_a_reactor_entity_has_no_terminal_panel
    roster = [Fleet::Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor",
                                  entity_id: "mattermost_reactor")]
    app, _pipeline = build_terminal_app(roster: roster)

    content = console_content(get_on(app, "/entity?id=mattermost_reactor").body)

    refute_includes content, "terminal-heading"
  end

  # AC7: captured output is inert — escaped and displayed as text, never
  # interpreted as markup, even a payload attempting to break out of the
  # surrounding <pre>. Positive control first, then the negative (inert_body).
  def test_captured_output_containing_html_is_rendered_escaped_and_inert
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    app, pipeline = build_terminal_app(roster: runner_roster(id))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    malicious = "</pre><script>alert(1)</script>"
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "#{malicious}\n")

    body = get_on(app, "/entity?id=runner%3Awf%3Aalpha").body
    section = terminal_section(body)

    assert_includes section, Rack::Utils.escape_html(malicious)
    inert_body(body)
  end

  # DR7: a raising store degrades to the same 500/no-echo/one-log behavior as
  # the raising ActivityLog test above — the one legitimate double in this
  # section.
  def test_an_output_buffers_store_that_raises_on_snapshot_yields_a_500_with_no_echo_and_one_logged_error
    id = RunnerIdentity.new(workflow: "wf", runner: "alpha")
    fleet = Fleet.new(roster: runner_roster(id), state_registry: StateRegistry.new)
    exploding_output_buffers = Object.new.tap do |o|
      def o.snapshot(*) = raise "output buffers boom, path /entity?id=runner:wf:alpha"
    end
    app = build_app(fleet, output_buffers: exploding_output_buffers)

    errors = capture_log_errors do
      @response = get_on(app, "/entity?id=runner%3Awf%3Aalpha")
    end

    assert_equal 500, @response.status
    assert_equal "internal error", @response.body
    refute_includes @response.body, "boom"
    refute_includes @response.body, "/entity"
    assert_equal 1, errors.size
    assert_match(/RuntimeError/, errors.first)
    assert_includes errors.first, "output buffers boom"
    assert_includes errors.first, "/entity"
  end
end
