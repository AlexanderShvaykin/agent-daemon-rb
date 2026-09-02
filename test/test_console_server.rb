# frozen_string_literal: true

require "test_helper"
require "net/http"
require "socket"
require "uri"

# AD-5 lazy-require isolation: console files are loaded explicitly here. This
# also pulls puma in (Puma::LogWriter is unloadable on its own).
require "agent_daemon/supervisor/console/server"
require "agent_daemon/supervisor/fleet"
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/activity_log"
require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/output_buffers"
require "agent_daemon/supervisor/output_pipeline"
require "agent_daemon/supervisor/redactor"
require "agent_daemon/supervisor/runner_identity"
require "agent_daemon/supervisor/master"

# Story 2.2 AC7 — the console really runs. AI-1: this boots a REAL Puma with
# the REAL middleware stack on an ephemeral port and speaks HTTP to it; the
# only double anywhere in the stack is the GitLab network seam, which is never
# reached by these requests.
class TestConsoleServer < Minitest::Test
  include LogStubbing

  Server = AgentDaemon::Supervisor::Console::Server

  CONSOLE_CONFIG = {
    "bind" => "127.0.0.1",
    "port" => 0, # ephemeral — the OS picks, #port reports what it picked
    "max_threads" => 4,
    "session_ttl" => 3_600,
    "secure_cookies" => true,
    "base_url" => "https://console.example.com",
    "auth" => {
      "gitlab_host" => "https://gitlab.example.com",
      "app_id" => "app-id",
      "app_secret" => "app-secret",
      "allowed_groups" => ["backoffice"]
    }
  }.freeze

  def setup
    stub_null_logger!
    @servers = []
    @state_registry = AgentDaemon::Supervisor::StateRegistry.new
    @event_bus = AgentDaemon::Supervisor::EventBus.new
    @fleet = AgentDaemon::Supervisor::Fleet.new(roster: [], state_registry: @state_registry)
    @activity_log = AgentDaemon::Supervisor::ActivityLog.new(event_bus: @event_bus)
    @output_buffers = AgentDaemon::Supervisor::OutputBuffers.new(capacity_bytes: 262_144)
  end

  def teardown
    @servers.each do |server|
      server.stop
    rescue StandardError
      nil
    end
    restore_logger!
  end

  def build_server(config = CONSOLE_CONFIG)
    Server.new(
      config,
      fleet: @fleet,
      activity_log: @activity_log,
      event_bus: @event_bus,
      state_registry: @state_registry,
      output_buffers: @output_buffers,
      log_writer: Puma::LogWriter.strings
    )
  end

  def start_server(config = CONSOLE_CONFIG)
    server = build_server(config)
    @servers << server
    server.start
    server
  end

  def get(server, path)
    uri = URI("http://127.0.0.1:#{server.port}#{path}")
    Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) do |http|
      http.request(Net::HTTP::Get.new(uri, "Cookie" => "irrelevant=1"))
    end
  end

  def authenticated_session(server)
    sessions = server.instance_variable_get(:@sessions)
    pending = sessions.create_pending(state: "integration")
    sessions.claim_pending(pending.id, "integration")
    sessions.promote(
      pending.id,
      state: "integration",
      username: "alice",
      access_token: "server-side-token"
    )
  end

  def open_event_stream(server, session_id)
    socket = TCPSocket.new("127.0.0.1", server.port)
    socket.write(
      "GET /events HTTP/1.1\r\n" \
      "Host: 127.0.0.1\r\n" \
      "Cookie: #{AgentDaemon::Supervisor::Console::Auth::COOKIE_NAME}=#{session_id}\r\n" \
      "Connection: close\r\n\r\n"
    )
    response = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until response.include?("event: refresh\n")
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "timed out waiting for SSE refresh" unless remaining.positive? && IO.select([socket], nil, nil, remaining)

      response << socket.read_nonblock(4096)
    end
    [socket, response]
  end

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      IO.select(nil, nil, nil, 0.01)
    end
  end

  def subscriber_count
    @event_bus.instance_variable_get(:@subscribers).size
  end

  def test_serves_the_public_health_probe
    server = start_server
    response = get(server, "/healthz")

    assert_equal "200", response.code
    assert_equal "ok", response.body
  end

  # The default-deny middleware is really in front of the app on the real
  # server, not just in the unit test's hand-built stack.
  def test_an_unauthenticated_request_is_redirected_to_login
    server = start_server
    response = get(server, "/")

    assert_equal "302", response.code
    assert_equal "/auth/login?return_to=%2F", response["location"]
  end

  def test_login_redirects_to_the_configured_gitlab_host
    server = start_server
    response = get(server, "/auth/login")

    assert_equal "302", response.code
    location = response["location"]
    assert location.start_with?("https://gitlab.example.com/oauth/authorize"), location

    params = URI.decode_www_form(URI.parse(location).query).to_h
    assert_equal "app-id", params["client_id"]
    assert_equal "read_api", params["scope"]
    # The redirect_uri is built from base_url and must be byte-identical to the
    # one the token exchange later sends.
    assert_equal "https://console.example.com/auth/callback", params["redirect_uri"]
    refute_empty params["state"].to_s
  end

  def test_reports_the_ephemeral_port_it_actually_bound
    server = start_server

    assert_operator server.port, :>, 0
    refute_equal 0, server.port
  end

  def test_stop_shuts_the_listener_and_the_thread_down
    server = start_server
    port = server.port
    assert_equal "200", get(server, "/healthz").code

    server.stop

    refute server.running?, "the server thread must be dead after stop"
    assert_raises(Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError) do
      Net::HTTP.start("127.0.0.1", port, open_timeout: 2, read_timeout: 2) do |http|
        http.request(Net::HTTP::Get.new("/healthz"))
      end
    end
  end

  def test_stop_is_idempotent
    server = start_server
    server.stop
    server.stop

    refute server.running?
  end

  def test_stop_before_start_is_a_no_op
    server = Server.new(CONSOLE_CONFIG, fleet: @fleet, activity_log: @activity_log,
                        event_bus: @event_bus, state_registry: @state_registry,
                        output_buffers: @output_buffers,
                        log_writer: Puma::LogWriter.strings)
    @servers << server

    server.stop

    refute server.running?
  end

  # AC7 names "bind in use" as the failure the master must survive; it surfaces
  # here, from the bind, so the master has something to rescue.
  def test_a_taken_port_raises_from_start
    running = start_server
    taken = CONSOLE_CONFIG.merge("port" => running.port)

    assert_raises(Errno::EADDRINUSE) { start_server(taken) }
  end

  # Load-bearing. Puma's #stop(true) joins its thread with NO timeout, and the
  # pool waits forever unless force_shutdown_after is set (it defaults to -1).
  # Without it a single wedged request makes Master#stop_console never return —
  # and the orphan sweep behind it never run. Master's rescue cannot help: it
  # catches exceptions, not hangs. This asserts the option is actually passed,
  # because the symptom only ever shows up as a hung shutdown in production.
  def test_the_server_bounds_its_own_shutdown
    server = start_server
    puma = server.instance_variable_get(:@server)

    assert_equal Server::STOP_TIMEOUT, puma.options[:force_shutdown_after]
  end

  def test_authenticated_sse_receives_refresh_and_disconnect_releases_cursor
    server = start_server
    session = authenticated_session(server)

    socket, response = open_event_stream(server, session.id)

    assert_includes response, "HTTP/1.1 200"
    assert_includes response.downcase, "content-type: text/event-stream; charset=utf-8"
    assert_includes response, "retry: 1000\n"
    assert_includes response, "event: refresh\n"
    assert_equal 1, subscriber_count

    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
    socket.close
    @event_bus.publish("integration", { type: :started })
    wait_until { subscriber_count.zero? }
  end

  def test_stop_remains_bounded_and_cleans_up_with_an_open_stream
    server = start_server
    session = authenticated_session(server)
    socket, = open_event_stream(server, session.id)
    assert_equal 1, subscriber_count

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    server.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<=, Server::STOP_TIMEOUT + 2
    wait_until(timeout: Server::STOP_TIMEOUT + 1) { subscriber_count.zero? }
  ensure
    socket&.close
  end

  # The listener is bound before the server thread exists, and Master records
  # the console only after #start returns — so a failure in between would leak
  # the socket for the life of the master with nothing able to close it.
  def test_a_failure_after_binding_does_not_leak_the_listener
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close

    failing = Class.new(Server) do
      def run_server(*)
        raise "boom after bind"
      end
    end

    server = failing.new(CONSOLE_CONFIG.merge("port" => port), fleet: @fleet, activity_log: @activity_log,
                          event_bus: @event_bus, state_registry: @state_registry,
                          output_buffers: @output_buffers,
                          log_writer: Puma::LogWriter.strings)
    assert_raises(RuntimeError) { server.start }

    # If the socket leaked, this bind fails with EADDRINUSE.
    reclaimed = TCPServer.new("127.0.0.1", port)
    assert_equal port, reclaimed.addr[1]
    reclaimed.close
  end

  # --- Story 3.5 DR1: the output_buffers wiring, proven end to end ----------

  # DR1 asks for a guard that the console reads the Master's OWN store rather
  # than a fresh empty one. The master-side test asserts the `start_console`
  # call site; these two close the remaining hops. Both are behavioral: they
  # populate a store, ask the running console for the runner's page over HTTP,
  # and require the output back. Replacing either forwarding expression with
  # `OutputBuffers.new(capacity_bytes: 1)` turns them red — nothing else in the
  # suite notices, because a mis-wired store fails by rendering the empty
  # state forever, which is indistinguishable from a runner that never ran.
  def runner_console(server_builder)
    id = AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "alpha")
    roster = [AgentDaemon::Supervisor::Fleet::Rostered.new(kind: :runner, workflow: "wf",
                                                            name: "alpha", entity_id: id)]
    @fleet = AgentDaemon::Supervisor::Fleet.new(roster: roster, state_registry: @state_registry)

    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([])
    )
    pipeline.subscribe(@output_buffers)
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: id, output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "wired-through-marker\n")

    server = server_builder.call
    @servers << server
    server.start
    server
  end

  def get_authenticated(server, path, session)
    uri = URI("http://127.0.0.1:#{server.port}#{path}")
    cookie = "#{AgentDaemon::Supervisor::Console::Auth::COOKIE_NAME}=#{session.id}"
    Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) do |http|
      http.request(Net::HTTP::Get.new(uri, "Cookie" => cookie))
    end
  end

  def test_the_server_forwards_its_own_output_buffers_to_the_app
    server = runner_console(-> { build_server(CONSOLE_CONFIG) })
    session = authenticated_session(server)

    response = get_authenticated(server, "/entity?id=runner%3Awf%3Aalpha", session)

    assert_equal "200", response.code
    assert_includes response.body, "wired-through-marker"
  end

  def test_the_server_forwards_restart_control_to_the_app
    restart_control = Object.new
    server = Server.new(
      CONSOLE_CONFIG,
      fleet: @fleet,
      activity_log: @activity_log,
      event_bus: @event_bus,
      state_registry: @state_registry,
      output_buffers: @output_buffers,
      restart_control: restart_control,
      log_writer: Puma::LogWriter.strings
    )

    stack = server.send(:build_app)
    app = stack.instance_variable_get(:@app)

    assert_same restart_control, app.instance_variable_get(:@restart_control)
  end

  # The same proof one hop further out: through the REAL default
  # Master::CONSOLE_FACTORY, so the positional-argument → kwarg mapping added
  # for this story is executed rather than replaced by a test lambda.
  def test_the_default_console_factory_maps_output_buffers_through_to_the_app
    factory = AgentDaemon::Supervisor::Master::CONSOLE_FACTORY
    server = runner_console(lambda {
      factory.call(CONSOLE_CONFIG, @fleet, @activity_log, @event_bus, @state_registry, @output_buffers)
    })
    session = authenticated_session(server)

    response = get_authenticated(server, "/entity?id=runner%3Awf%3Aalpha", session)

    assert_equal "200", response.code
    assert_includes response.body, "wired-through-marker"
  end

  # The two tests above prove output_buffers reaches the PAGE RENDER. The
  # stream is a separate hop — Server -> LiveUpdates.new(output_buffers:) —
  # and a fresh empty store would satisfy a naive "the console got an
  # output_buffers" assertion either way (3.5's wiring-guard hazard). This
  # drives the real socket and requires the Master's own instance, holding
  # the marker, to surface in an SSE output frame.
  def test_the_server_forwards_its_own_output_buffers_into_the_live_stream
    server = runner_console(-> { build_server(CONSOLE_CONFIG) })
    session = authenticated_session(server)

    frames = read_entity_stream(server, session, "/events?id=runner%3Awf%3Aalpha")

    assert_includes frames, "event: output_run\n"
    assert_includes frames, "wired-through-marker"
  end

  def read_entity_stream(server, session, path)
    socket = TCPSocket.new("127.0.0.1", server.port)
    socket.write(
      "GET #{path} HTTP/1.1\r\n" \
      "Host: 127.0.0.1\r\n" \
      "Cookie: #{AgentDaemon::Supervisor::Console::Auth::COOKIE_NAME}=#{session.id}\r\n" \
      "Connection: close\r\n\r\n"
    )
    response = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until response.include?("event: output_run\n")
      raise "timed out waiting for an output frame: #{response.inspect}" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      chunk = socket.read_nonblock(4096, exception: false)
      response << chunk if chunk.is_a?(String)
    end
    response
  ensure
    socket&.close
  end
end
