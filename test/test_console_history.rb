# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "uri"
require "rack"

# AD-5 lazy-require isolation: loaded explicitly here. The console never
# requires history/*; this test wires a real Reader in, as the master does.
require "agent_daemon/supervisor/console/app"
require "agent_daemon/supervisor/console/auth"
require "agent_daemon/supervisor/console/history_authorization"
require "agent_daemon/supervisor/console/session_store"
require "agent_daemon/supervisor/console/live_updates"
require "agent_daemon/supervisor/fleet"
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/runner_identity"
require "agent_daemon/supervisor/activity_log"
require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/output_buffers"
require "agent_daemon/supervisor/output_pipeline"
require "agent_daemon/supervisor/history/database"
require "agent_daemon/supervisor/history/reader"
require "sqlite3"

# Story 5.5: the persisted-history routes, through Rack::Lint, reading a real
# Reader over a temp store seeded by SQL.
class TestConsoleHistory < Minitest::Test
  include LogStubbing
  include HistorySeeding

  App = AgentDaemon::Supervisor::Console::App
  Auth = AgentDaemon::Supervisor::Console::Auth
  HistoryAuthorization = AgentDaemon::Supervisor::Console::HistoryAuthorization
  SessionStore = AgentDaemon::Supervisor::Console::SessionStore
  LiveUpdates = AgentDaemon::Supervisor::Console::LiveUpdates
  Fleet = AgentDaemon::Supervisor::Fleet
  StateRegistry = AgentDaemon::Supervisor::StateRegistry
  RunnerIdentity = AgentDaemon::Supervisor::RunnerIdentity
  ActivityLog = AgentDaemon::Supervisor::ActivityLog
  EventBus = AgentDaemon::Supervisor::EventBus
  OutputBuffers = AgentDaemon::Supervisor::OutputBuffers
  OutputPipeline = AgentDaemon::Supervisor::OutputPipeline
  Database = AgentDaemon::Supervisor::History::Database
  Reader = AgentDaemon::Supervisor::History::Reader

  RUNNER_KEY = "runner:wf:a"
  HOSTILE = "<script>alert(1)</script>\e[31m"

  class RaisingHistory
    def initialize(error) = @error = error
    def runs(**) = raise(@error)
    def entity(_key) = raise(@error)
    def restart_actions(_key) = raise(@error)
    def run(_id) = raise(@error)
  end

  class FakeClock
    def initialize = @now = 1_000.0
    def call = @now
    def advance(seconds) = @now += seconds
  end

  # The one network seam of the auth stack.
  class FakeGitlab
    def authorize_url(state:) = "https://gitlab.example.com/oauth/authorize?state=#{Rack::Utils.escape(state)}"
    def exchange(code:) = "token-#{code}"
    def fetch_username(_token) = "alice"
    def member_group_paths(_token) = ["backoffice"]
  end

  def setup
    stub_null_logger!
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "history.sqlite3")
    @store = Database.open(path: @path, busy_timeout_ms: 5000)
    @reader = Reader.new(path: @path, busy_timeout_ms: 5000, page_size: 50)
    @sessions = SessionStore.new(ttl: 3_600)
    @fleet = Fleet.new(roster: [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "a",
                                                    entity_id: RunnerIdentity.new(workflow: "wf", runner: "a"))],
                       state_registry: StateRegistry.new)
  end

  def teardown
    @reader.close
    @store.close
    FileUtils.remove_entry(@dir)
    restore_logger!
  end

  def seed_db = @store.db

  def use_page_size(page_size)
    @reader.close
    @reader = Reader.new(path: @path, busy_timeout_ms: 5000, page_size: page_size)
  end

  def app_with(history: @reader)
    Rack::MockRequest.new(Rack::Lint.new(raw_app(history)))
  end

  def raw_app(history)
    App.new(fleet: @fleet, activity_log: ActivityLog.new(event_bus: EventBus.new),
            live_updates: LiveUpdates.new(event_bus: EventBus.new, state_registry: StateRegistry.new),
            output_buffers: OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES),
            history: history)
  end

  def session
    pending = @sessions.create_pending(state: "s")
    @sessions.claim_pending(pending.id, "s")
    @sessions.promote(pending.id, username: "alice")
  end

  def get(path, history: @reader, method: :get)
    app_with(history: history).request(method.to_s.upcase, path, Auth::SESSION_ENV_KEY => session)
  end

  def get_ok(path)
    response = get(path)
    assert_equal 200, response.status, "#{path}: #{response.body[0, 200]}"
    response.body
  end

  def run_ids(body)
    body.scan(%r{<h3><a href="/history/run\?id=(\d+)">}).flatten.map(&:to_i)
  end

  def next_href(body)
    href = body[/<a rel="next" href="([^"]+)">Older runs<\/a>/, 1]
    href&.gsub("&amp;", "&")
  end

  # --- List -------------------------------------------------------------------

  def test_the_list_is_newest_first_with_ties_by_id_and_shows_every_field
    entity = seed_entity(RUNNER_KEY)
    oldest = seed_run(entity, started_at: at(1), work_item: "TI-1", attempt: 1, generation: 1,
                              finished_at: at(2), reason: "ok")
    tie_low = seed_run(entity, started_at: at(5), work_item: "TI-2", attempt: 2, generation: 2)
    tie_high = seed_run(entity, started_at: at(5), work_item: "TI-3", attempt: 3, generation: 4,
                                finished_at: at(6), reason: "timeout")

    body = get_ok("/history")

    assert_equal [tie_high, tie_low, oldest], run_ids(body)
    card = body[/<li><article>\s*<h3><a href="\/history\/run\?id=#{tie_high}">.*?<\/article><\/li>/m]
    assert_includes card, "<div><dt>Workflow</dt><dd>wf</dd></div>"
    assert_includes card, %(<a href="/history/entity?id=runner%3Awf%3Aa">a</a>)
    assert_includes card, "<div><dt>Work item</dt><dd>TI-3</dd></div>"
    assert_includes card, "<div><dt>Attempt</dt><dd>3</dd></div>"
    assert_includes card, "<div><dt>Generation</dt><dd>4</dd></div>"
    assert_includes card, %(<time datetime="#{at(5)}">#{at(5)}</time>)
    assert_includes card, %(<span class="outcome outcome-timeout">timeout</span>)
    refute_includes card, "absent from current fleet"
    assert_includes body, '<ol class="history-runs" role="list">'
    refute_includes body, "<table"
  end

  def test_an_empty_store_renders_an_empty_state_without_pagination
    body = get_ok("/history")

    assert_includes body, "No runs recorded."
    refute_includes body, 'aria-label="History pages"'
  end

  def test_following_the_older_links_walks_every_run_once
    use_page_size(2)
    entity = seed_entity(RUNNER_KEY)
    ids = (1..5).map { |second| seed_run(entity, started_at: at(second)) }

    pages = []
    path = "/history"
    bodies = []
    while path
      body = get_ok(path)
      bodies << body
      pages << run_ids(body)
      path = next_href(body)
    end

    assert_equal [[ids[4], ids[3]], [ids[2], ids[1]], [ids[0]]], pages
    assert_includes bodies[0], '<nav class="history-pages" aria-label="History pages">'
    refute_includes bodies[0], ">Newest runs</a>"
    assert_includes bodies[1], %(<a href="/history">Newest runs</a>)
    assert_includes bodies[2], %(<a href="/history">Newest runs</a>)
    refute_includes bodies[2], 'rel="next"'
  end

  def test_runs_inserted_after_page_one_never_repeat_when_its_cursor_is_followed
    use_page_size(2)
    entity = seed_entity(RUNNER_KEY)
    old = (1..3).map { |second| seed_run(entity, started_at: at(second)) }

    first = get_ok("/history")
    3.times { |n| seed_run(entity, started_at: at(10 + n)) }
    second = get_ok(next_href(first))

    assert_equal [old[2], old[1]], run_ids(first)
    assert_equal [old[0]], run_ids(second)
    assert_nil next_href(second)
  end

  def test_an_entity_absent_from_the_current_fleet_is_listed_with_a_badge
    gone = seed_entity("runner:old:gone", workflow: "old", runner: "gone")
    seed_run(gone, started_at: at(1))

    body = get_ok("/history")

    assert_includes body, '<span class="history-absent">absent from current fleet</span>'
    assert_includes body, "<div><dt>Workflow</dt><dd>old</dd></div>"
  end

  def test_a_messenger_run_is_labelled_by_its_kind
    messenger = seed_entity("messenger:wf", kind: "messenger", runner: nil)
    seed_run(messenger, started_at: at(1))

    assert_includes get_ok("/history"), %(<a href="/history/entity?id=messenger%3Awf">messenger</a>)
  end

  def test_runs_from_before_and_after_a_master_restart_form_one_sequence
    entity = seed_entity(RUNNER_KEY)
    before = seed_run(entity, started_at: at(1), generation: 1, incomplete: 1)
    after = seed_run(entity, started_at: at(2), generation: 1, finished_at: at(3), reason: "ok")

    body = get_ok("/history")

    assert_equal [after, before], run_ids(body)
    assert_includes body, %(<span class="outcome outcome-incomplete">incomplete</span>)
    assert_includes body, %(<span class="outcome outcome-ok">ok</span>)
  end

  def test_an_open_run_is_labelled_running
    seed_run(seed_entity(RUNNER_KEY), started_at: at(1))

    assert_includes get_ok("/history"), %(<span class="outcome outcome-running">running</span>)
  end

  # --- Entity history -------------------------------------------------------

  def test_entity_history_shows_only_its_runs_and_its_restart_actions
    mine = seed_entity(RUNNER_KEY)
    other = seed_entity("runner:wf:b", runner: "b")
    my_run = seed_run(mine, started_at: at(1))
    seed_run(other, started_at: at(2))
    seed_restart(mine, requested_at: at(3), completed_at: at(4), actors: %w[a b], source: 2, target: 3)
    seed_restart(other, requested_at: at(5), actors: %w[elsewhere])

    body = get_ok("/history/entity?id=runner%3Awf%3Aa")

    assert_equal [my_run], run_ids(body)
    restarts = body[%r{<ol class="history-restarts" role="list">.*?</ol>}m]
    assert_equal 1, restarts.scan("<li>").size
    assert_includes restarts, "<div><dt>Actors</dt><dd>a, b</dd></div>"
    assert_includes restarts, %(<time datetime="#{at(3)}">)
    assert_includes restarts, %(<time datetime="#{at(4)}">)
    assert_includes restarts, "<div><dt>Generation</dt><dd>2 → 3</dd></div>"
    refute_includes body, "elsewhere"
    assert_includes body, "<div><dt>Workflow</dt><dd>wf</dd></div>"
    assert_includes body, "<div><dt>Kind</dt><dd>runner</dd></div>"
    assert_includes body, %(<a href="/entity?id=runner%3Awf%3Aa">Current fleet entry</a>)
    refute_includes body, "Only the newest"
  end

  def test_restart_actions_beyond_a_page_carry_a_note
    use_page_size(2)
    mine = seed_entity(RUNNER_KEY)
    3.times { |n| seed_restart(mine, requested_at: at(n)) }

    body = get_ok("/history/entity?id=runner%3Awf%3Aa")

    assert_includes body, "Only the newest 2 restart actions are shown."
    assert_includes body, "<div><dt>Completed</dt><dd>—</dd></div>"
  end

  def test_entity_history_pages_within_the_entity
    use_page_size(2)
    mine = seed_entity(RUNNER_KEY)
    other = seed_entity("runner:wf:b", runner: "b")
    ids = (1..3).map { |n| seed_run(mine, started_at: at(n * 2)) }
    (1..3).each { |n| seed_run(other, started_at: at((n * 2) + 1)) }

    first = get_ok("/history/entity?id=runner%3Awf%3Aa")
    href = next_href(first)
    second = get_ok(href)

    assert_match %r{\A/history/entity\?id=runner%3Awf%3Aa&cursor=}, href
    assert_equal [ids[2], ids[1]], run_ids(first)
    assert_equal [ids[0]], run_ids(second)
    assert_includes second, %(<a href="/history/entity?id=runner%3Awf%3Aa">Newest runs</a>)
  end

  def test_a_current_entity_with_no_rows_renders_an_empty_state
    body = get_ok("/history/entity?id=runner%3Awf%3Aa")

    assert_includes body, '<h2 id="history-entity-heading">a</h2>'
    assert_includes body, "No runs recorded."
    assert_includes body, "No restart actions recorded."
    assert_includes body, "<div><dt>Workflow</dt><dd>wf</dd></div>"
    assert_includes body, "<div><dt>Kind</dt><dd>runner</dd></div>"
  end

  def test_a_persisted_entity_absent_from_the_fleet_renders_with_the_badge
    seed_entity("runner:old:gone", workflow: "old", runner: "gone")

    body = get_ok("/history/entity?id=runner%3Aold%3Agone")

    assert_includes body, '<h2 id="history-entity-heading">gone</h2>'
    assert_includes body, "absent from current fleet"
  end

  # --- Run detail -----------------------------------------------------------

  def test_run_detail_shows_identity_transitions_and_links
    entity = seed_entity(RUNNER_KEY)
    id = seed_run(entity, started_at: at(1), finished_at: at(5), reason: "ok", generation: 2, work_item: "TI-7",
                          attempt: 3)
    seed_event(id, 1, "picked_up", at(1))
    seed_event(id, 2, "finished", at(5), reason: "ok")

    body = get_ok("/history/run?id=#{id}")

    assert_includes body, %(<h2 id="history-run-heading">Run #{id}</h2>)
    ["<div><dt>Workflow</dt><dd>wf</dd></div>", "<div><dt>Kind</dt><dd>runner</dd></div>",
     "<div><dt>Generation</dt><dd>2</dd></div>", "<div><dt>Work item</dt><dd>TI-7</dd></div>",
     "<div><dt>Attempt</dt><dd>3</dd></div>", %(<time datetime="#{at(5)}">),
     %(<span class="outcome outcome-ok">ok</span>)].each { |fragment| assert_includes body, fragment }
    transitions = body[%r{<ol class="history-transitions" role="list">.*?</ol>}m]
    assert_operator transitions.index("picked_up"), :<, transitions.index("finished")
    assert_includes transitions, "<div><dt>Reason</dt><dd>—</dd></div>"
    assert_includes transitions, "<div><dt>Reason</dt><dd>ok</dd></div>"
    assert_includes body, %(<a href="/history/entity?id=runner%3Awf%3Aa">Entity history</a>)
    assert_includes body, %(<a href="/history">All runs</a>)
    refute_includes body, "Error summary"
  end

  def test_run_detail_badges_an_entity_absent_from_the_current_fleet
    gone = seed_run(seed_entity("runner:old:gone", workflow: "old", runner: "gone"), started_at: at(1))
    current = seed_run(seed_entity(RUNNER_KEY), started_at: at(2))

    assert_includes get_ok("/history/run?id=#{gone}"), "absent from current fleet"
    refute_includes get_ok("/history/run?id=#{current}"), "absent from current fleet"
  end

  def test_an_incomplete_run_is_labelled_incomplete_and_never_a_failure
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1), incomplete: 1)

    body = get_ok("/history/run?id=#{id}")

    assert_includes body, %(<span class="outcome outcome-incomplete">incomplete</span>)
    assert_includes body, "<div><dt>Finished</dt><dd>—</dd></div>"
    %w[failed timeout killed].each { |reason| refute_includes body, %(class="outcome outcome-#{reason}") }
  end

  def test_output_flags_render_both_notices_and_lines_in_seq_order_with_text_labels
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1), output_truncated: 1, output_incomplete: 1)
    seed_output(id, 2, "stderr", "second line")
    seed_output(id, 1, "stdout", "first line")

    body = get_ok("/history/run?id=#{id}")

    assert_includes body, "Only the retained tail is shown — earlier output exceeded the per-run limit and was discarded."
    assert_includes body, "Captured output is incomplete — the history writer lost some lines, so this is not a " \
                          "complete transcript."
    assert_equal 2, body.scan('<p class="terminal-note">').size
    panel = body[%r{<div class="terminal-panel" tabindex="0" role="region" aria-labelledby="history-output-heading">.*?</div>\s*</section>}m]
    refute_nil panel
    assert_operator panel.index("first line"), :<, panel.index("second line")
    assert_includes panel, %(<span class="terminal-stream terminal-stream-stdout">out</span>first line)
    assert_includes panel, %(<span class="terminal-stream terminal-stream-stderr">err</span>second line)
  end

  def test_a_run_with_no_output_says_so_without_a_scroll_region
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1))

    body = get_ok("/history/run?id=#{id}")

    assert_includes body, '<p class="terminal-note">No output was captured for this run.</p>'
    refute_includes body, 'class="terminal-panel"'
    refute_includes body, 'tabindex="0"'
  end

  def test_a_failed_run_shows_its_error_summary
    summary = JSON.generate({ "reason" => "failed", "attempt" => 2, "last_stderr" => "boom" })
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1), finished_at: at(2), reason: "failed",
                                           error_summary: summary)

    body = get_ok("/history/run?id=#{id}")
    section = body[%r{<section aria-labelledby="history-error-heading">.*?</section>}m]

    assert_includes section, "<div><dt>Reason</dt><dd>failed</dd></div>"
    assert_includes section, "<div><dt>Attempt</dt><dd>2</dd></div>"
    assert_includes section, %(<dd class="history-stderr">boom</dd>)
  end

  def test_a_null_last_stderr_renders_a_dash_and_unparseable_json_says_unreadable
    entity = seed_entity(RUNNER_KEY)
    nulls = seed_run(entity, started_at: at(1), reason: "failed",
                             error_summary: '{"reason":"failed","attempt":1,"last_stderr":null}')
    broken = seed_run(entity, started_at: at(2), reason: "failed", error_summary: "{not json")

    assert_includes get_ok("/history/run?id=#{nulls}"), %(<dd class="history-stderr">—</dd>)
    assert_includes get_ok("/history/run?id=#{broken}"), "Error summary unreadable"
  end

  def test_hostile_text_is_escaped_everywhere_it_appears
    entity = seed_entity(RUNNER_KEY)
    id = seed_run(entity, started_at: at(1), work_item: HOSTILE, reason: "failed",
                          error_summary: JSON.generate({ "reason" => "failed", "attempt" => 1, "last_stderr" => HOSTILE }))
    seed_output(id, 1, "stdout", HOSTILE)

    [get_ok("/history"), get_ok("/history/entity?id=runner%3Awf%3Aa"), get_ok("/history/run?id=#{id}")].each do |body|
      refute_includes body, "<script"
      assert_includes body, "&lt;script&gt;alert(1)"
    end
  end

  # --- Bad ids ----------------------------------------------------------------

  def test_malformed_or_unknown_ids_are_a_non_disclosing_404
    seed_run(seed_entity(RUNNER_KEY), started_at: at(1))
    paths = ["/history/run?id=abc", "/history/run?id=0", "/history/run?id=-1", "/history/run?id=99999",
             "/history/run", "/history/run?id[]=1", "/history/run?id=1&id[]=2", "/history/run?id=01",
             "/history?cursor=x%7C1", "/history?cursor=", "/history?cursor[]=1",
             "/history?cursor=2026-09-19T10%3A00%3A00Z%7C1",
             "/history/entity?id=nope", "/history/entity", "/history/entity?id=",
             "/history/entity?id[]=1", "/history/entity?id=runner%3Awf%3Aa&cursor=x%7C1"]

    log = capture_log do
      paths.each do |path|
        response = get(path)
        assert_equal 404, response.status, path
        assert_equal "not found", response.body, path
      end
    end

    %w[abc 99999 nope x|1].each { |value| refute_includes log, value }
  end

  def test_other_verbs_are_404_and_head_has_no_body
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1))

    ["/history", "/history/entity?id=runner%3Awf%3Aa", "/history/run?id=#{id}"].each do |path|
      assert_equal 404, get(path, method: :post).status, path
      head = get(path, method: :head)
      assert_equal 200, head.status, path
      assert_equal "", head.body, path
    end
  end

  # --- Unavailable ----------------------------------------------------------

  def test_a_raising_reader_renders_503_and_logs_the_class_only
    history = RaisingHistory.new(SQLite3::BusyException.new("database is locked: SELECT secret"))
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1))

    ["/history", "/history/entity?id=runner%3Awf%3Aa", "/history/run?id=#{id}"].each do |path|
      response = nil
      log = capture_log { response = get(path, history: history) }

      assert_equal 503, response.status, path
      assert_includes response.body, '<h2 id="history-unavailable-heading">History unavailable</h2>'
      assert_includes response.body, "cannot be read right now"
      assert_includes response.body, "fleet is unaffected"
      assert_equal ["[Console] history read failed: SQLite3::BusyException"], log.lines.map(&:chomp), path
    end
  end

  def test_history_disabled_renders_503
    ["/history", "/history/entity?id=runner%3Awf%3Aa", "/history/run?id=1"].each do |path|
      response = nil
      log = capture_log { response = get(path, history: nil) }

      assert_equal ["[Console] history read failed: no history reader"], log.lines.map(&:chomp), path
      assert_equal 503, response.status, path
      assert_includes response.body, "History unavailable"
      refute_includes response.body, "EventSource"
    end
  end

  def test_head_while_unavailable_answers_503_with_an_empty_body
    history = RaisingHistory.new(SQLite3::BusyException.new("database is locked"))
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1))

    [nil, history].each do |unavailable|
      ["/history", "/history/entity?id=runner%3Awf%3Aa", "/history/run?id=#{id}"].each do |path|
        response = nil
        capture_log { response = get(path, history: unavailable, method: :head) }

        assert_equal 503, response.status, path
        assert_equal "", response.body, path
      end
    end
  end

  def test_syntax_is_checked_before_the_reader_is_present
    assert_equal 404, get("/history/run?id=abc", history: nil).status
    assert_equal 404, get("/history?cursor=bad", history: nil).status
  end

  def test_a_failed_read_reopens_the_connection_on_the_next_request
    seed_run(seed_entity(RUNNER_KEY), started_at: at(1))
    app = app_with
    env = -> { { Auth::SESSION_ENV_KEY => session } }
    assert_equal 200, app.get("/history", env.call).status

    # Break the open connection behind the reader's back.
    @reader.instance_variable_get(:@db).close
    log = capture_log { assert_equal 503, app.get("/history", env.call).status }
    assert_match(/\A\[Console\] history read failed: \S+\n\z/, log)

    assert_equal 200, app.get("/history", env.call).status
  end

  # --- Layout and navigation ------------------------------------------------

  def test_every_page_carries_the_primary_nav_with_the_current_link_marked
    fleet = get_ok("/")
    history = get_ok("/history")

    assert_includes fleet, %(<nav class="console-nav" aria-label="Primary">)
    assert_includes fleet, %(<a href="/" aria-current="page">Fleet</a>)
    assert_includes fleet, %(<a href="/history">History</a>)
    assert_includes history, %(<a href="/">Fleet</a>)
    assert_includes history, %(<a href="/history" aria-current="page">History</a>)
  end

  def test_history_pages_are_static_and_the_live_pages_keep_their_script
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1))

    ["/history", "/history/entity?id=runner%3Awf%3Aa", "/history/run?id=#{id}"].each do |path|
      body = get_ok(path)
      refute_includes body, "EventSource", path
      refute_includes body, "<script", path
    end
    assert_includes get_ok("/"), App::LIVE_SCRIPT
    assert_includes get_ok("/entity?id=runner%3Awf%3Aa"), App::LIVE_SCRIPT
  end

  def test_the_entity_page_links_to_its_persisted_history
    body = get_ok("/entity?id=runner%3Awf%3Aa")

    assert_includes body, %(<a href="/history/entity?id=runner%3Awf%3Aa">Persisted history</a>)
  end

  def test_the_stylesheet_contract_for_history
    css = App::STYLESHEET
    history_rules = css.scan(/^\s*\.history-[^{]*\{[^}]*\}/m).join

    refute_empty history_rules
    refute_includes history_rules, "overflow-x"
    assert_match(/\.history-fields dd \{[^}]*overflow-wrap: anywhere;/, css)
    assert_match(/\.outcome-incomplete \{/, css)
    assert_match(/\.outcome-running \{/, css)
    media = css[/@media \(max-width: 40rem\) \{.*?\n\}/m]
    assert_match(/\.history-fields > div \{ grid-template-columns: 1fr;/, media)
  end

  # --- Behind the real auth middleware --------------------------------------

  def test_every_history_route_is_denied_without_a_live_session
    id = seed_run(seed_entity(RUNNER_KEY), started_at: at(1))
    seed_output(id, 1, "stdout", "secret-output-line")
    clock = FakeClock.new
    sessions = SessionStore.new(ttl: 3_600, clock: clock)
    stack = Rack::MockRequest.new(Rack::Lint.new(
                                    Auth.new(HistoryAuthorization.new(raw_app(@reader)),
                                             sessions: sessions, gitlab: FakeGitlab.new,
                                             allowed_groups: ["backoffice"], secure_cookies: true)
                                  ))
    paths = ["/history", "/history/entity?id=runner%3Awf%3Aa", "/history/run?id=#{id}"]
    cookie = ->(value) { { "HTTP_COOKIE" => "#{Auth::COOKIE_NAME}=#{value}" } }

    login = lambda do
      started = stack.get("/auth/login")
      pending = started.cookie(Auth::PENDING_COOKIE_NAME).value.first
      state = URI.decode_www_form(URI.parse(started.headers["location"]).query).to_h["state"]
      callback = stack.get("/auth/callback?code=c&state=#{Rack::Utils.escape(state)}",
                           "HTTP_COOKIE" => "#{Auth::PENDING_COOKIE_NAME}=#{pending}")
      callback.cookie(Auth::COOKIE_NAME).value.first
    end

    live = login.call
    assert_equal 200, stack.get("/history/run?id=#{id}", cookie.call(live)).status

    expired = login.call
    revoked = login.call
    sessions.destroy(revoked)
    clock.advance(3_600)
    denied = [{}, cookie.call("forged"), cookie.call(expired), cookie.call(revoked)]

    paths.product(denied).each do |path, env|
      response = stack.get(path, env)
      refute_equal 200, response.status, path
      refute_includes response.body, "secret-output-line", path
    end
  end
end
