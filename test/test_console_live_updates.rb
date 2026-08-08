# frozen_string_literal: true

require "test_helper"
require "stringio"
require "json"

require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/state_registry"
require "agent_daemon/supervisor/console/live_updates"
require "agent_daemon/supervisor/output_pipeline"
require "agent_daemon/supervisor/output_buffers"
require "agent_daemon/supervisor/redactor"

class TestConsoleLiveUpdates < Minitest::Test
  include LogStubbing

  EventBus = AgentDaemon::Supervisor::EventBus
  StateRegistry = AgentDaemon::Supervisor::StateRegistry
  LiveUpdates = AgentDaemon::Supervisor::Console::LiveUpdates
  OutputPipeline = AgentDaemon::Supervisor::OutputPipeline
  OutputBuffers = AgentDaemon::Supervisor::OutputBuffers
  Redactor = AgentDaemon::Supervisor::Redactor

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

  # --- Story 3.6: output multiplexed onto the same stream --------------------
  #
  # Retro AI-1: a real OutputPipeline + real Redactor + real OutputBuffers,
  # never a reimplementation of the store under test.

  def build_output_buffers(capacity_bytes: OutputPipeline::DEFAULT_MAX_LINE_BYTES)
    buffers = OutputBuffers.new(capacity_bytes: capacity_bytes)
    pipeline = OutputPipeline.new(redactor: Redactor.new([]))
    pipeline.subscribe(buffers)
    [buffers, pipeline]
  end

  def build_with_output(output_buffers:, clock: -> { 0.0 }, wait: ->(_seconds) {})
    LiveUpdates.new(event_bus: @bus, state_registry: @registry, output_buffers: output_buffers,
                     clock: clock, wait: wait)
  end

  def output_frames(output, event)
    output.scan(/event: #{event}\nid: ([^\n]+)\ndata: (.+)\n\n/).map { |id, data| [id, JSON.parse(data)] }
  end

  def state_frames(output)
    output.scan(/event: output_state\ndata: (.+)\n\n/).map { |match| JSON.parse(match[0]) }
  end

  # AC3/AC1: mid-run continuation rides the plain `output` event, in seq
  # order, JSON-encoded — and carries the `id:` line AC10's reconnect needs.
  def test_output_records_emit_in_seq_order_json_encoded_with_a_reconnect_id
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)

    checks = 0
    authorized = lambda do
      checks += 1
      if checks == 1
        bundle.append_output(:stdout, "first\n")
        bundle.append_output(:stderr, "second\n")
      end
      checks < 2
    end
    io = StreamIO.new

    build_with_output(output_buffers: buffers).stream(io, authorized: authorized, entity_id: "alpha",
                                                        after_run_id: 1, after_seq: 0)

    events = output_frames(io.output, "output")
    assert_equal 1, events.size
    id, payload = events.first
    # generation:run:seq — generation is part of the cursor because run ids
    # restart at 1 in every respawned Backend.
    assert_equal "1:1:2", id
    assert_equal 1, payload["generation"]
    assert_equal 1, payload["run"]
    assert_equal(
      [{ "seq" => 1, "stream" => "stdout", "text" => "first" },
       { "seq" => 2, "stream" => "stderr", "text" => "second" }],
      payload["records"]
    )
    assert_empty output_frames(io.output, "output_run")
  end

  # AC2: the bootstrap cursor is "after the last sequence rendered in the
  # snapshot" — records at or below it never reach the wire again.
  def test_output_cursor_bootstrap_skips_records_already_rendered_by_the_page
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "already shown\n")
    bundle.append_output(:stdout, "new line\n")

    checks = 0
    io = StreamIO.new
    build_with_output(output_buffers: buffers).stream(io, authorized: -> { checks += 1; checks < 2 },
                                                        entity_id: "alpha", after_run_id: 1, after_seq: 1)

    events = output_frames(io.output, "output")
    assert_equal 1, events.size
    _id, payload = events.first
    assert_equal [{ "seq" => 2, "stream" => "stdout", "text" => "new line" }], payload["records"]
    refute_includes io.output, "already shown"
  end

  # Task 1: after_seq == tail_seq is "nothing new", not a lag — no output
  # frame at all that tick.
  def test_after_seq_at_the_tail_emits_no_output_frame
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "line\n")

    checks = 0
    io = StreamIO.new
    build_with_output(output_buffers: buffers).stream(io, authorized: -> { checks += 1; checks < 2 },
                                                        entity_id: "alpha", after_run_id: 1, after_seq: 1)

    assert_empty output_frames(io.output, "output")
    assert_empty output_frames(io.output, "output_run")
    assert_empty output_frames(io.output, "output_lagged")
  end

  # AC8: a new run_id is a run change, not a lag — full window, cursor reset.
  def test_a_new_run_emits_output_run_with_the_full_window
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "old run\n")
    bundle.end_output_run(1, :ok)

    checks = 0
    authorized = lambda do
      checks += 1
      if checks == 1
        bundle.begin_output_run(2)
        bundle.append_output(:stdout, "new run\n")
      end
      checks < 2
    end
    io = StreamIO.new

    build_with_output(output_buffers: buffers).stream(io, authorized: authorized, entity_id: "alpha",
                                                        after_run_id: 1, after_seq: 1)

    events = output_frames(io.output, "output_run")
    assert_equal 1, events.size
    _id, payload = events.first
    assert_equal 2, payload["run"]
    assert_equal [{ "seq" => 1, "stream" => "stdout", "text" => "new run" }], payload["records"]
    refute_includes io.output, "old run"
  end

  # AC9: a cursor whose seq has been evicted gets the full retained window,
  # explicitly flagged as lagged rather than a silent gap.
  def test_an_evicted_cursor_emits_output_lagged_with_the_retained_window
    buffers, pipeline = build_output_buffers(capacity_bytes: 16)
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "#{'a' * 20}\n")
    bundle.append_output(:stdout, "#{'b' * 20}\n")
    bundle.append_output(:stdout, "#{'c' * 20}\n")

    checks = 0
    io = StreamIO.new
    build_with_output(output_buffers: buffers).stream(io, authorized: -> { checks += 1; checks < 2 },
                                                        entity_id: "alpha", after_run_id: 1, after_seq: 1)

    events = output_frames(io.output, "output_lagged")
    assert_equal 1, events.size
    _id, payload = events.first
    assert_equal [{ "seq" => 3, "stream" => "stdout", "text" => 'c' * 20 }], payload["records"]
  end

  # AC7: finished/reason transitions emit output_state, including the legal
  # finished:true/reason:nil combination (DR4: reason.nil? is never "still
  # running" — finished carries that).
  def test_output_state_reports_finished_transitions_including_a_nil_reason
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)

    checks = 0
    authorized = lambda do
      checks += 1
      bundle.end_output_run(1, nil) if checks == 2
      checks < 3
    end
    io = StreamIO.new

    build_with_output(output_buffers: buffers).stream(io, authorized: authorized, entity_id: "alpha",
                                                        after_run_id: 1, after_seq: 0)

    states = state_frames(io.output)
    assert_equal 2, states.size
    assert_equal({ "finished" => false, "reason" => nil, "truncated" => false }, states[0])
    assert_equal({ "finished" => true, "reason" => nil, "truncated" => false }, states[1])
  end

  # DR2: the store is keyed by the raw entity_id, so one entity's stream must
  # never carry another's records.
  def test_output_from_other_entities_never_appears_in_frames
    buffers, pipeline = build_output_buffers
    alpha = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    beta = AgentDaemon::Sinks::Bundle.new(entity_id: "beta", output: pipeline.ingress(1))
    alpha.begin_output_run(1)
    beta.begin_output_run(1)
    beta.append_output(:stdout, "beta secret\n")

    # Positive control FIRST: alpha has output of its own, and the same call
    # must deliver it. Without this the negative assertion below holds even
    # if #emit_output were deleted outright.
    alpha.append_output(:stdout, "alpha visible\n")

    checks = 0
    io = StreamIO.new
    build_with_output(output_buffers: buffers).stream(io, authorized: -> { checks += 1; checks < 2 },
                                                        entity_id: "alpha", after_run_id: 1, after_seq: 0)

    assert_includes io.output, "alpha visible"
    refute_includes io.output, "beta secret"
  end

  # AC13: the merged stream's auth recheck is the same one — output
  # multiplexing must not create a second, unchecked path.
  def test_output_stream_still_terminates_on_auth_revocation_and_unsubscribes
    buffers, _pipeline = build_output_buffers
    checks = 0
    io = StreamIO.new

    # Positive control: the cursor must actually be registered while the
    # stream is live, otherwise "0 subscribers afterwards" proves nothing.
    observed = nil
    authorized = lambda do
      checks += 1
      observed ||= subscriber_count
      checks < 2
    end

    build_with_output(output_buffers: buffers).stream(io, authorized: authorized, entity_id: "alpha")

    assert_equal 1, observed, "the stream must hold an EventBus cursor while it is live"
    assert_includes io.output, "authorization_lost"
    assert io.closed?
    assert_equal 0, subscriber_count
  end

  # The cleanup contract covers the exception path too, not only the ordinary
  # return above — a stream dropped mid-write must not leak its cursor.
  def test_an_output_stream_dropped_mid_write_still_unsubscribes_and_closes
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "line\n")

    # Fail on the OUTPUT frame, not on the opening retry/refresh pair, so the
    # stream is genuinely mid-flight (and subscribed) when the peer vanishes.
    writes = 0
    observed = nil
    io = StreamIO.new(on_write: ->(_value) { writes += 1; raise Errno::EPIPE if writes > 2 })

    build_with_output(output_buffers: buffers).stream(
      io, authorized: -> { observed ||= subscriber_count; true },
      entity_id: "alpha", after_generation: 1, after_run_id: 1, after_seq: 0
    )

    assert_equal 1, observed
    assert io.closed?
    assert_equal 0, subscriber_count
  end

  # The cursor is (generation, run_id, seq), not (run_id, seq): every respawn
  # builds a fresh Backend whose @run_seq restarts at 0, so generation 2's
  # first run is run_id 1 exactly like generation 1's was. Comparing run ids
  # alone, a client holding the previous generation's cursor reads the
  # restarted run as "same run, nothing newer" and silently loses its output
  # — on the one screen that exists to diagnose a crash.
  def test_a_respawned_generation_reusing_run_id_1_emits_a_full_output_run
    buffers, pipeline = build_output_buffers
    first = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    first.begin_output_run(1)
    3.times { |i| first.append_output(:stdout, "gen1 line #{i}\n") }

    # The runner crashes and is respawned: generation 2, run id back to 1.
    second = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(2))
    second.begin_output_run(1)
    second.append_output(:stdout, "gen2 first line\n")

    checks = 0
    io = StreamIO.new
    build_with_output(output_buffers: buffers).stream(
      io, authorized: -> { checks += 1; checks < 2 },
      entity_id: "alpha", after_generation: 1, after_run_id: 1, after_seq: 3
    )

    runs = output_frames(io.output, "output_run")
    assert_equal 1, runs.size, "a respawn must announce a run change, not resume the old cursor"
    id, payload = runs.first
    assert_equal 2, payload["generation"]
    assert_equal "2:1:1", id
    assert_equal ["gen2 first line"], payload["records"].map { |record| record["text"] }
    refute_includes io.output, "gen1 line"
  end

  # The same generation must NOT trigger the respawn path — otherwise every
  # ordinary tick would replay the whole window.
  def test_an_unchanged_generation_resumes_incrementally_without_a_run_change
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "already shown\n")

    checks = 0
    authorized = lambda do
      checks += 1
      bundle.append_output(:stdout, "brand new\n") if checks == 1
      checks < 2
    end
    io = StreamIO.new
    build_with_output(output_buffers: buffers).stream(
      io, authorized: authorized,
      entity_id: "alpha", after_generation: 1, after_run_id: 1, after_seq: 1
    )

    assert_empty output_frames(io.output, "output_run")
    records = output_frames(io.output, "output").flat_map { |_id, payload| payload["records"] }
    assert_equal ["brand new"], records.map { |record| record["text"] }
  end

  # AC11: the pre-existing lifecycle/state refresh frame keeps interleaving
  # with output frames on the same connection.
  def test_refresh_frames_still_interleave_with_output_frames
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    bundle.begin_output_run(1)

    checks = 0
    authorized = lambda do
      checks += 1
      if checks == 1
        @registry.publish("alpha", { status: :running })
        bundle.append_output(:stdout, "line\n")
      end
      checks < 2
    end
    io = StreamIO.new

    build_with_output(output_buffers: buffers).stream(io, authorized: authorized, entity_id: "alpha",
                                                        after_run_id: 1, after_seq: 0)

    assert_equal 2, io.output.scan("event: refresh\n").size
    assert_equal 1, output_frames(io.output, "output").size
  end

  # AD-7: record text is attacker-influenceable. It must reach the wire only
  # inside one JSON-encoded data: line, never interpolated raw.
  def test_attacker_influenced_text_reaches_the_wire_only_json_encoded
    buffers, pipeline = build_output_buffers
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "alpha", output: pipeline.ingress(1))
    hostile = "</pre><script>alert(1)</script>"
    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "#{hostile}\n")

    checks = 0
    io = StreamIO.new
    build_with_output(output_buffers: buffers).stream(io, authorized: -> { checks += 1; checks < 2 },
                                                        entity_id: "alpha", after_run_id: 1, after_seq: 0)

    _id, payload = output_frames(io.output, "output").first
    assert_equal hostile, payload["records"].first["text"]
    # One `data:` line — JSON.generate never emits a literal newline — so the
    # SSE frame boundary cannot be split by attacker-controlled text.
    assert_equal 1, io.output.scan("event: output\n").size
  end
end
