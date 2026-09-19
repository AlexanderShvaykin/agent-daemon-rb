# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "uri"
require "rack"

# AD-5 lazy-require isolation: console files are loaded explicitly here.
require "agent_daemon/supervisor/console/history_authorization"
require "agent_daemon/supervisor/console/auth"
require "agent_daemon/supervisor/console/session_store"
require "agent_daemon/supervisor/console/app"
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

# Story 5.5: history pages carry no SSE stream, so the per-request membership
# recheck lives in HistoryAuthorization, between Auth and App.
class TestConsoleHistoryAuthorization < Minitest::Test
  include LogStubbing
  include HistorySeeding

  HistoryAuthorization = AgentDaemon::Supervisor::Console::HistoryAuthorization
  Auth = AgentDaemon::Supervisor::Console::Auth
  SessionStore = AgentDaemon::Supervisor::Console::SessionStore
  App = AgentDaemon::Supervisor::Console::App
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

  HISTORY_PATHS = ["/history", "/history/entity?id=runner%3Awf%3Aa", "/history/run?id=1"].freeze
  OTHER_PATHS = ["/", "/entity?id=runner%3Awf%3Aa", "/events", "/historyx", "/healthz"].freeze

  class ProbeApp
    attr_reader :paths

    def initialize = @paths = []

    def call(env)
      @paths << env["PATH_INFO"]
      body = env["REQUEST_METHOD"] == "HEAD" ? [] : ["app"]
      [200, { "content-type" => "text/plain" }, body]
    end
  end

  class FakeClock
    def initialize = @now = 1_000.0
    def call = @now
    def advance(seconds) = @now += seconds
  end

  # The one network seam; `groups` changes after login to model a revocation.
  class FakeGitlab
    attr_accessor :groups

    def initialize = @groups = ["backoffice"]
    def authorize_url(state:) = "https://gitlab.example.com/oauth/authorize?state=#{Rack::Utils.escape(state)}"
    def exchange(code:) = "token-#{code}"
    def fetch_username(_token) = "alice"
    def member_group_paths(_token) = @groups
  end

  def setup
    stub_null_logger!
    @probe = ProbeApp.new
    @stack = Rack::MockRequest.new(Rack::Lint.new(HistoryAuthorization.new(@probe)))
  end

  def teardown
    restore_logger!
  end

  def request(path, check)
    env = {}
    env[Auth::AUTHORIZATION_ENV_KEY] = check unless check == :missing
    @stack.get(path, env)
  end

  def assert_redirected_to_login(response, path)
    assert_equal 302, response.status, path
    assert_equal "/auth/login?return_to=#{Rack::Utils.escape(path)}", response.headers["location"], path
    assert_equal "", response.body, path
  end

  def test_a_history_path_whose_check_fails_is_redirected_and_never_reaches_the_app
    HISTORY_PATHS.each do |path|
      assert_redirected_to_login(request(path, -> { false }), path)
    end
    assert_empty @probe.paths
  end

  def test_a_check_that_raises_is_missing_or_not_literally_true_is_a_denial
    [-> { raise "gitlab down" }, :missing, "not callable", -> { nil }, -> { "yes" }].each do |check|
      HISTORY_PATHS.each do |path|
        assert_redirected_to_login(request(path, check), path)
      end
    end
    assert_empty @probe.paths
  end

  def test_a_history_path_whose_check_passes_reaches_the_app
    HISTORY_PATHS.each do |path|
      assert_equal 200, request(path, -> { true }).status, path
    end
    assert_equal ["/history", "/history/entity", "/history/run"], @probe.paths
  end

  def test_other_paths_never_call_the_check
    calls = 0
    check = lambda do
      calls += 1
      false
    end

    OTHER_PATHS.each do |path|
      assert_equal 200, request(path, check).status, path
    end
    assert_equal 0, calls
    assert_equal OTHER_PATHS.map { |path| path.split("?").first }, @probe.paths
  end

  # --- Through the real Auth + SessionStore -----------------------------------

  def seed_db = @store.db

  def test_a_revoked_membership_loses_history_once_the_recheck_is_due
    dir = Dir.mktmpdir
    path = File.join(dir, "history.sqlite3")
    @store = Database.open(path: path, busy_timeout_ms: 5000)
    reader = Reader.new(path: path, busy_timeout_ms: 5000, page_size: 50)
    id = seed_run(seed_entity("runner:wf:a"), started_at: at(1))
    seed_output(id, 1, "stdout", "persisted-secret-output")

    clock = FakeClock.new
    sessions = SessionStore.new(ttl: 3_600, clock: clock)
    gitlab = FakeGitlab.new
    fleet = Fleet.new(roster: [Fleet::Rostered.new(kind: :runner, workflow: "wf", name: "a",
                                                   entity_id: RunnerIdentity.new(workflow: "wf", runner: "a"))],
                      state_registry: StateRegistry.new)
    app = App.new(fleet: fleet, activity_log: ActivityLog.new(event_bus: EventBus.new),
                  live_updates: LiveUpdates.new(event_bus: EventBus.new, state_registry: StateRegistry.new),
                  output_buffers: OutputBuffers.new(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES),
                  history: reader)
    stack = Rack::MockRequest.new(Rack::Lint.new(
                                    Auth.new(HistoryAuthorization.new(app), sessions: sessions, gitlab: gitlab,
                                                                            allowed_groups: ["backoffice"],
                                                                            secure_cookies: true)
                                  ))

    started = stack.get("/auth/login")
    pending = started.cookie(Auth::PENDING_COOKIE_NAME).value.first
    state = URI.decode_www_form(URI.parse(started.headers["location"]).query).to_h["state"]
    callback = stack.get("/auth/callback?code=c&state=#{Rack::Utils.escape(state)}",
                         "HTTP_COOKIE" => "#{Auth::PENDING_COOKIE_NAME}=#{pending}")
    session_id = callback.cookie(Auth::COOKIE_NAME).value.first
    cookie = { "HTTP_COOKIE" => "#{Auth::COOKIE_NAME}=#{session_id}" }

    before = stack.get("/history/run?id=#{id}", cookie)
    assert_equal 200, before.status
    assert_includes before.body, "persisted-secret-output"

    gitlab.groups = []
    clock.advance(Auth::GROUP_RECHECK_INTERVAL)
    after = stack.get("/history/run?id=#{id}", cookie)

    assert_equal 302, after.status
    assert_equal "/auth/login?return_to=#{Rack::Utils.escape("/history/run?id=#{id}")}", after.headers["location"]
    refute_includes after.body, "persisted-secret-output"
    assert_nil sessions.fetch(session_id), "the failed recheck must delete the session"
  ensure
    reader&.close
    @store&.close
    FileUtils.remove_entry(dir) if dir
  end
end
