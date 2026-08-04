# frozen_string_literal: true

require "test_helper"
require "stringio"

require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/console/live_updates"

class TestConsoleLiveUpdates < Minitest::Test
  include LogStubbing

  EventBus = AgentDaemon::Supervisor::EventBus
  StateRegistry = AgentDaemon::Supervisor::StateRegistry
  LiveUpdates = AgentDaemon::Supervisor::Console::LiveUpdates

  class StreamIO
    attr_reader :writes

    def initialize(on_write: nil, fail_with: nil)
      @on_write = on_write
      @fail_with = fail_with
      @writes = []
      @closed = false
    end

    def write(value)
      @on_write&.call(value)
      raise @fail_with if @fail_with

      @writes << value
      value.bytesize
    end

    def close
      @closed = true
    end

    def closed? = @closed

    def output = @writes.join
  end

  # A socket whose peer has stopped reading: the send buffer never drains, so
  # every write_nonblock reports :wait_writable and writability never arrives.
  class StalledSocket
    attr_reader :waits

    def initialize(on_wait: nil)
      @on_wait = on_wait
      @waits = 0
      @closed = false
    end

    def write_nonblock(_value, exception: true) = :wait_writable

    def wait_writable(_timeout)
      @waits += 1
      @on_wait&.call
      nil
    end

    def close = @closed = true

    def closed? = @closed
  end

  def setup
    stub_null_logger!
    @bus = EventBus.new(capacity: 2)
    @registry = StateRegistry.new
  end

  def teardown
    restore_logger!
  end

  def build(clock: -> { 0.0 }, wait: ->(_seconds) {})
    LiveUpdates.new(event_bus: @bus, state_registry: @registry, clock: clock, wait: wait)
  end

  def subscriber_count
    @bus.instance_variable_get(:@subscribers).size
  end

  def test_initial_refresh_is_fixed_contains_no_read_model_payload_and_cleans_up
    @bus.publish("secret-entity", { type: :started, work_item: "<script>secret</script>" })
    @registry.publish("secret-entity", { status: :in_progress, work_item: "TOKEN" })
    subscribed_during_write = false
    io = StreamIO.new(on_write: ->(_value) { subscribed_during_write = subscriber_count == 1 })

    build.stream(io, authorized: -> { false })

    assert subscribed_during_write, "the stream must subscribe before its first write"
    assert_includes io.output, "retry: 1000\n"
    assert_equal 1, io.output.scan("event: refresh\n").size
    assert_includes io.output, "event: authorization_lost\n"
    refute_includes io.output, "secret-entity"
    refute_includes io.output, "TOKEN"
    refute_includes io.output, "<script>"
    assert io.closed?
    assert_equal 0, subscriber_count
  end

  def test_event_and_state_changes_coalesce_into_one_refresh
    checks = 0
    authorized = lambda do
      checks += 1
      if checks == 1
        @bus.publish("ent", { type: :started, detail: "must not leak" })
        @registry.publish("ent", { status: :running, generation: 1 })
      end
      checks < 2
    end
    io = StreamIO.new

    build.stream(io, authorized: authorized)

    assert_equal 2, io.output.scan("event: refresh\n").size,
                 "initial plus one coalesced refresh for simultaneous bus and registry changes"
    refute_includes io.output, "must not leak"
    assert_equal 0, subscriber_count
  end

  def test_state_only_change_emits_refresh
    checks = 0
    authorized = lambda do
      checks += 1
      @registry.publish("ent", { status: :running, generation: 1 }) if checks == 1
      checks < 2
    end
    io = StreamIO.new

    build.stream(io, authorized: authorized)

    assert_equal 2, io.output.scan("event: refresh\n").size
  end

  def test_event_only_change_emits_refresh
    checks = 0
    authorized = lambda do
      checks += 1
      @bus.publish("ent", { type: :started }) if checks == 1
      checks < 2
    end
    io = StreamIO.new

    build.stream(io, authorized: authorized)

    assert_equal 2, io.output.scan("event: refresh\n").size
  end

  def test_cursor_loss_emits_refresh
    checks = 0
    authorized = lambda do
      checks += 1
      if checks == 1
        3.times { |index| @bus.publish("ent", { type: :event, index: index }) }
      end
      checks < 2
    end
    io = StreamIO.new

    build.stream(io, authorized: authorized)

    assert_equal 2, io.output.scan("event: refresh\n").size
    assert_operator @bus.events_dropped_total, :>, 0
  end

  def test_heartbeat_uses_injected_clock_without_sleep
    now = 0.0
    waits = 0
    wait = lambda do |seconds|
      assert_equal 0.25, seconds
      waits += 1
      now = 15.0
    end
    checks = 0
    io = StreamIO.new

    build(clock: -> { now }, wait: wait).stream(io, authorized: -> { checks += 1; checks < 3 })

    assert_operator waits, :>=, 1
    assert_includes io.output, ": heartbeat\n\n"
  end

  def test_disconnect_is_normal_cleanup
    subscribed = false
    io = StreamIO.new(
      on_write: ->(_value) { subscribed = subscriber_count == 1 },
      fail_with: Errno::EPIPE.new
    )

    build.stream(io, authorized: -> { true })

    assert subscribed, "disconnect cleanup must be tested after a real subscription"
    assert io.closed?
    assert_equal 0, subscriber_count
  end

  def test_unexpected_error_is_logged_without_exception_message_and_cleans_up
    restore_logger!
    log_io = StringIO.new
    @__prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    logger = Logger.new(log_io)
    AgentDaemon::Log.use(logger)
    subscribed = false
    io = StreamIO.new(on_write: ->(_value) { subscribed = subscriber_count == 1 })

    build.stream(io, authorized: -> { raise RuntimeError, "oauth-token-secret" })

    assert_includes log_io.string, "RuntimeError"
    refute_includes log_io.string, "oauth-token-secret"
    assert subscribed, "unexpected-error cleanup must be tested after a real subscription"
    assert io.closed?
    assert_equal 0, subscriber_count
  end

  # DR3's server-shutdown terminal path. Server#stop latches the loop before it
  # stops Puma, so the latch must end the stream on its first iteration and
  # still run the ordinary close/unsubscribe cleanup.
  def test_shutdown_latch_ends_the_stream_and_unsubscribes
    @registry.publish("ent", { status: :running, generation: 1 })
    @bus.publish("ent", { type: :started })
    subscribed = false
    io = StreamIO.new(on_write: ->(_value) { subscribed = subscriber_count == 1 })
    live = build
    live.stop!

    live.stream(io, authorized: -> { flunk("a latched stream must not re-check authorization") })

    assert subscribed, "shutdown cleanup must be tested after a real subscription"
    assert_equal 1, io.output.scan("event: refresh\n").size, "only the initial refresh is written"
    refute_includes io.output, "authorization_lost"
    assert io.closed?
    assert_equal 0, subscriber_count
  end

  # Server#start is re-enterable, so the drain latch must not outlive the drain.
  def test_resume_lets_a_restarted_server_serve_streams_again
    checks = 0
    io = StreamIO.new
    live = build
    live.stop!
    live.resume!

    live.stream(io, authorized: lambda {
      checks += 1
      false
    })

    assert_equal 1, checks, "a resumed stream must reach its authorization check"
    assert_includes io.output, "event: authorization_lost\n"
    assert_equal 0, subscriber_count
  end

  # AC5: a stream occupies one Puma thread, so a client that stops reading must
  # cost one dropped stream — the browser reconnects — rather than a thread
  # parked forever inside a blocking write, where the #stopping check is
  # unreachable and the cursor stays registered.
  def test_a_client_that_stops_reading_is_dropped_instead_of_parking_the_thread
    subscribed = false
    socket = StalledSocket.new(on_wait: -> { subscribed = subscriber_count == 1 })

    build.stream(socket, authorized: -> { flunk("a stalled write must not reach the poll loop") })

    assert_equal 1, socket.waits, "the write waits on writability once, then gives up"
    assert subscribed, "the stalled-write path must be tested after a real subscription"
    assert socket.closed?
    assert_equal 0, subscriber_count
  end
end
