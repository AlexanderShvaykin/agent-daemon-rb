# frozen_string_literal: true

require "test_helper"
require "stringio"

# AD-5 lazy-require isolation: the supervisor files are loaded explicitly here
# and are NOT part of the core `require "agent_daemon"` graph.
require "agent_daemon/supervisor/output_pipeline"
require "agent_daemon/supervisor/redactor"
require "agent_daemon/supervisor/runner_identity"
require "agent_daemon/supervisor/event_bus"

# The only fake in this file: a real Redactor and a real OutputPipeline are
# always used (retro AI-1).
class RecordingObserver
  attr_reader :records

  def initialize
    @records = []
  end

  def call(record)
    @records << record
  end
end

class RaisingObserver
  attr_reader :calls

  def initialize(error = RuntimeError.new("observer boom"))
    @error = error
    @calls = 0
  end

  def call(_record)
    @calls += 1
    raise @error
  end
end

# A distinct fixture from RecordingObserver (which implements #call only, and
# must stay that way — it is the regression guard for DR3's respond_to? guard).
class LifecycleObserver
  attr_reader :records, :started, :finished

  def initialize
    @records = []
    @started = []
    @finished = []
  end

  def call(record)
    @records << record
  end

  def run_started(entity_id, run_id, generation)
    @started << [entity_id, run_id, generation]
  end

  def run_finished(entity_id, run_id, reason, generation)
    @finished << [entity_id, run_id, reason, generation]
  end
end

class RaisingLifecycleObserver
  attr_reader :started_calls, :finished_calls

  def initialize
    @started_calls = 0
    @finished_calls = 0
  end

  def call(_record); end

  def run_started(*)
    @started_calls += 1
    raise "run_started boom"
  end

  def run_finished(*)
    @finished_calls += 1
    raise "run_finished boom"
  end
end

class TestOutputPipeline < Minitest::Test
  ISO8601_UTC_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  def setup
    @prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, @prior_logger)
  end

  def build(secrets: [])
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new(secrets)
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)
    [pipeline, observer]
  end

  # --- line assembly (AC2, DR3) --------------------------------------------

  def test_a_chunk_without_a_newline_emits_nothing
    pipeline, observer = build

    pipeline.append("ent", :stdout, "partial")

    assert_empty observer.records
  end

  def test_the_completing_chunk_emits_exactly_one_record
    pipeline, observer = build

    pipeline.append("ent", :stdout, "par")
    pipeline.append("ent", :stdout, "tial\n")

    assert_equal ["partial"], observer.records.map(&:text)
  end

  def test_one_chunk_with_three_newlines_emits_three_records_in_order
    pipeline, observer = build

    pipeline.append("ent", :stdout, "a\nb\nc\n")

    assert_equal %w[a b c], observer.records.map(&:text)
    assert_equal [1, 2, 3], observer.records.map(&:seq)
  end

  def test_a_lone_newline_emits_one_empty_text_record
    pipeline, observer = build

    pipeline.append("ent", :stdout, "\n")

    assert_equal [""], observer.records.map(&:text)
  end

  # Pinned behavior: \r is agent output, and stripping it is a rendering
  # decision, not an ingress one.
  def test_crlf_keeps_the_carriage_return_in_text
    pipeline, observer = build

    pipeline.append("ent", :stdout, "a\r\n")

    assert_equal ["a\r"], observer.records.map(&:text)
  end

  def test_stdout_and_stderr_keep_separate_partial_buffers
    pipeline, observer = build

    pipeline.append("ent", :stdout, "out-half ")
    pipeline.append("ent", :stderr, "err-half ")
    pipeline.append("ent", :stdout, "out-rest\n")
    pipeline.append("ent", :stderr, "err-rest\n")

    assert_equal [[:stdout, "out-half out-rest"], [:stderr, "err-half err-rest"]],
                 observer.records.map { |r| [r.stream, r.text] }
  end

  def test_two_entities_keep_separate_partial_buffers
    pipeline, observer = build

    pipeline.append("a", :stdout, "aaa")
    pipeline.append("b", :stdout, "bbb")
    pipeline.append("a", :stdout, "-end\n")
    pipeline.append("b", :stdout, "-end\n")

    assert_equal [["a", "aaa-end"], ["b", "bbb-end"]],
                 observer.records.map { |r| [r.entity_id, r.text] }
  end

  # --- redaction (AC3, AC4) -------------------------------------------------

  def test_a_complete_line_is_redacted_before_the_observer_sees_it
    pipeline, observer = build(secrets: ["sekret-value-1"])

    pipeline.append("ent", :stdout, "token=sekret-value-1 done\n")

    assert_equal ["token=[REDACTED] done"], observer.records.map(&:text)
  end

  # AC4: split across chunk boundaries, the reconstructed value is still caught.
  def test_a_secret_split_across_three_chunks_is_still_redacted
    pipeline, observer = build(secrets: ["sekret-value-1"])

    pipeline.append("ent", :stdout, "token=sekr")
    pipeline.append("ent", :stdout, "et-val")
    pipeline.append("ent", :stdout, "ue-1 done\n")

    assert_equal ["token=[REDACTED] done"], observer.records.map(&:text)
  end

  def test_a_line_with_no_known_secret_is_passed_through_unchanged
    pipeline, observer = build(secrets: ["sekret-value-1"])

    pipeline.append("ent", :stdout, "nothing to hide\n")
    pipeline.append("ent", :stdout, "sekret-value-1\n")

    assert_equal ["nothing to hide", "[REDACTED]"], observer.records.map(&:text)
  end

  # --- record identity (AC6, DR5) -------------------------------------------

  def test_a_record_carries_the_full_identity_tuple
    pipeline, observer = build
    identity = AgentDaemon::Supervisor::RunnerIdentity.new(workflow: "wf", runner: "r")
    ingress = pipeline.ingress(7)

    ingress.begin_run(identity, 3)
    ingress.append(identity, :stderr, "line\n")

    record = observer.records.fetch(0)
    assert_same identity, record.entity_id
    assert_equal 7, record.generation
    assert_equal 3, record.run_id
    assert_equal :stderr, record.stream
    assert_equal 1, record.seq
    assert_equal "line", record.text
    assert_match ISO8601_UTC_RE, record.at
  end

  def test_a_record_is_frozen
    pipeline, observer = build

    pipeline.append("ent", :stdout, "line\n")

    record = observer.records.fetch(0)
    assert_predicate record, :frozen?
    assert_raises(FrozenError) { record.text = "mutated" }
  end

  def test_seq_is_monotonic_within_a_run_and_restarts_on_the_next_run
    pipeline, observer = build

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\nb\n")
    pipeline.append("ent", :stderr, "c\n")
    pipeline.end_run("ent", 1, :ok)
    pipeline.begin_run("ent", 2)
    pipeline.append("ent", :stdout, "d\n")

    assert_equal [[1, 1, "a"], [1, 2, "b"], [1, 3, "c"], [2, 1, "d"]],
                 observer.records.map { |r| [r.run_id, r.seq, r.text] }
  end

  # --- end_run flush (AC2, AC7, DR4) ----------------------------------------

  def test_end_run_flushes_a_newlineless_residue_on_both_streams
    pipeline, observer = build

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "out-tail")
    pipeline.append("ent", :stderr, "err-tail")
    pipeline.end_run("ent", 1, :failed)

    assert_equal [[:stdout, "out-tail"], [:stderr, "err-tail"]],
                 observer.records.map { |r| [r.stream, r.text] }
  end

  def test_end_run_flushes_the_residue_redacted
    pipeline, observer = build(secrets: ["sekret-value-1"])

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "tail sekret-value-1")
    pipeline.end_run("ent", 1, :timeout)

    assert_equal ["tail [REDACTED]"], observer.records.map(&:text)
  end

  def test_end_run_emits_nothing_when_no_residue_remains
    pipeline, observer = build

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "complete\n")
    pipeline.end_run("ent", 1, :ok)

    assert_equal ["complete"], observer.records.map(&:text)
  end

  def test_a_second_run_never_inherits_the_previous_runs_fragment
    pipeline, observer = build

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "orphan-fragment")
    pipeline.end_run("ent", 1, :killed)
    pipeline.begin_run("ent", 2)
    pipeline.append("ent", :stdout, "fresh\n")

    assert_equal [[1, "orphan-fragment"], [2, "fresh"]],
                 observer.records.map { |r| [r.run_id, r.text] }
  end

  def test_end_run_clears_only_the_named_entitys_buffers
    pipeline, observer = build

    pipeline.append("a", :stdout, "a-tail")
    pipeline.append("b", :stdout, "b-tail")
    pipeline.end_run("a", 1, :ok)
    pipeline.append("b", :stdout, "-kept\n")

    assert_equal [["a", "a-tail"], ["b", "b-tail-kept"]],
                 observer.records.map { |r| [r.entity_id, r.text] }
  end

  # --- encoding seam (DR3 steps 1 and 3) ------------------------------------

  def test_a_multibyte_character_torn_across_two_chunks_is_healed
    pipeline, observer = build
    bytes = "привет".dup.force_encoding(Encoding::BINARY)
    head = bytes[0, 5]
    tail = bytes[5..]

    pipeline.append("ent", :stdout, head)
    pipeline.append("ent", :stdout, "#{tail}\n".b)

    record = observer.records.fetch(0)
    assert_equal "привет", record.text
    assert_equal Encoding::UTF_8, record.text.encoding
    assert_predicate record.text, :valid_encoding?
  end

  def test_genuinely_invalid_bytes_neither_raise_nor_produce_invalid_utf8
    pipeline, observer = build

    pipeline.append("ent", :stdout, "ok-\xC3\x28-bad\n".b)

    record = observer.records.fetch(0)
    assert_predicate record.text, :valid_encoding?
    assert_includes record.text, "ok-"
    assert_includes record.text, "-bad"
  end

  def test_a_utf8_tagged_chunk_is_accepted_alongside_a_binary_one
    pipeline, observer = build

    pipeline.append("ent", :stdout, "привет ")
    pipeline.append("ent", :stdout, "мир\n".b)

    assert_equal ["привет мир"], observer.records.map(&:text)
  end

  # --- observer isolation (AC8, DR8) ----------------------------------------

  def test_a_raising_observer_is_logged_and_does_not_reach_the_caller
    log_io = StringIO.new
    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(log_io))
    pipeline, = build
    pipeline.subscribe(RaisingObserver.new)

    pipeline.append("ent", :stdout, "line\n")

    assert_includes log_io.string, "observer boom"
  end

  def test_a_raising_observer_does_not_starve_the_others
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([])
    )
    first = RecordingObserver.new
    raiser = RaisingObserver.new
    last = RecordingObserver.new
    pipeline.subscribe(first)
    pipeline.subscribe(raiser)
    pipeline.subscribe(last)

    pipeline.append("ent", :stdout, "one\n")
    pipeline.append("ent", :stdout, "two\n")

    assert_equal %w[one two], first.records.map(&:text)
    assert_equal %w[one two], last.records.map(&:text)
    assert_equal 2, raiser.calls, "the broken observer keeps being offered later records"
  end

  def test_a_raising_observer_does_not_break_end_run_flush
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([])
    )
    observer = RecordingObserver.new
    pipeline.subscribe(RaisingObserver.new)
    pipeline.subscribe(observer)

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "tail")
    pipeline.end_run("ent", 1, :ok)

    assert_equal ["tail"], observer.records.map(&:text)
  end

  # StandardError only — a signal must still reach the runner.
  def test_a_signal_exception_from_an_observer_propagates
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([])
    )
    pipeline.subscribe(RaisingObserver.new(SignalException.new("TERM")))

    assert_raises(SignalException) { pipeline.append("ent", :stdout, "line\n") }
  end

  def test_a_pipeline_with_no_observers_accepts_output
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([])
    )

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "line\n")
    pipeline.end_run("ent", 1, :ok)

    # The observer-less records are gone, but the pipeline is intact: a later
    # subscriber sees the next run from a clean state.
    observer = RecordingObserver.new
    pipeline.subscribe(observer)
    pipeline.begin_run("ent", 2)
    pipeline.append("ent", :stdout, "next\n")

    assert_equal [["next", 2, 1]], observer.records.map { |r| [r.text, r.run_id, r.seq] }
  end

  # Production always brackets appends with begin_run/end_run; this pins what
  # a consumer sees if output ever arrives outside a run (DR5's `run_id` is
  # "the backend's per-run integer" — absent a run, it is nil, not 0).
  def test_output_outside_any_run_carries_a_nil_run_id
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([])
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)

    pipeline.append("ent", :stdout, "stray\n")

    record = observer.records.fetch(0)
    assert_equal "stray", record.text
    assert_nil record.run_id
    assert_equal 1, record.seq
  end

  # --- protocol + DR7 -------------------------------------------------------

  def test_the_pipeline_implements_the_three_arg_output_sink_protocol
    pipeline, observer = build

    AgentDaemon::Sinks::Bundle.new(entity_id: "ent", output: pipeline)
                              .append_output(:stdout, "via-bundle\n")

    assert_equal [["ent", "via-bundle"]], observer.records.map { |r| [r.entity_id, r.text] }
  end

  def test_the_ingress_forwards_all_three_lifecycle_methods_with_the_generation
    pipeline, observer = build
    ingress = pipeline.ingress(4)

    ingress.begin_run("ent", 9)
    ingress.append("ent", :stdout, "tail")
    ingress.end_run("ent", 9, :ok)

    record = observer.records.fetch(0)
    assert_equal 4, record.generation
    assert_equal 9, record.run_id
    assert_equal "tail", record.text
  end

  def test_two_ingresses_stamp_their_own_generations
    pipeline, observer = build

    pipeline.ingress(1).append("ent", :stdout, "gen-one\n")
    pipeline.ingress(2).append("ent", :stdout, "gen-two\n")

    assert_equal [[1, "gen-one"], [2, "gen-two"]],
                 observer.records.map { |r| [r.generation, r.text] }
  end

  # DR7 by construction: output must never reach the lifecycle EventBus.
  def test_the_pipeline_holds_no_event_bus_reference
    pipeline, = build

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "line\n")

    held = pipeline.instance_variables.map { |ivar| pipeline.instance_variable_get(ivar) }
    refute(held.any? { |v| v.is_a?(AgentDaemon::Supervisor::EventBus) })
    refute_respond_to pipeline, :publish
  end

  # --- lifecycle fanout (Story 3.4 DR3) --------------------------------------

  def test_run_started_is_notified_on_begin_run_with_entity_run_and_generation
    pipeline, = build
    observer = LifecycleObserver.new
    pipeline.subscribe(observer)

    pipeline.ingress(7).begin_run("ent", 3)

    assert_equal [["ent", 3, 7]], observer.started
  end

  def test_run_finished_is_notified_on_end_run_with_reason_and_generation
    pipeline, = build
    observer = LifecycleObserver.new
    pipeline.subscribe(observer)

    ingress = pipeline.ingress(7)
    ingress.begin_run("ent", 3)
    ingress.end_run("ent", 3, :ok)

    assert_equal [["ent", 3, :ok, 7]], observer.finished
  end

  def test_run_finished_carries_a_nil_reason_when_the_backend_aborted
    pipeline, = build
    observer = LifecycleObserver.new
    pipeline.subscribe(observer)

    ingress = pipeline.ingress(1)
    ingress.begin_run("ent", 1)
    ingress.end_run("ent", 1, nil)

    assert_equal [["ent", 1, nil, 1]], observer.finished
  end

  # The existing #call-only fixture must keep working unedited — that is the
  # regression guard for the respond_to? guard this story adds.
  def test_a_call_only_observer_is_unaffected_by_lifecycle_notifications
    pipeline, observer = build

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "line\n")
    pipeline.end_run("ent", 1, :ok)

    assert_equal ["line"], observer.records.map(&:text)
  end

  # A residual newline-less line must be inside the buffer before the run is
  # marked terminal (DR3's ordering contract), or the last line of a crashed
  # agent is lost to the very consumer that exists to show it.
  def test_a_residual_line_record_arrives_before_run_finished
    pipeline, = build
    observer = LifecycleObserver.new
    pipeline.subscribe(observer)
    order = []
    observer.define_singleton_method(:call) { |record| order << [:call, record.text] }
    observer.define_singleton_method(:run_finished) { |*args| order << [:run_finished, args] }

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "tail-no-newline")
    pipeline.end_run("ent", 1, :failed)

    assert_equal :call, order.first.first
    assert_equal "tail-no-newline", order.first.last
    assert_equal :run_finished, order.last.first
  end

  def test_a_raising_run_started_is_logged_isolated_and_does_not_reach_the_caller
    log_io = StringIO.new
    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(log_io))
    pipeline, = build
    observer = RaisingLifecycleObserver.new

    pipeline.subscribe(observer)
    pipeline.begin_run("ent", 1)

    assert_equal 1, observer.started_calls
    assert_includes log_io.string, "run_started boom"
  end

  def test_a_raising_run_finished_is_logged_isolated_and_does_not_starve_other_observers
    log_io = StringIO.new
    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(log_io))
    pipeline, = build
    raiser = RaisingLifecycleObserver.new
    healthy = LifecycleObserver.new
    pipeline.subscribe(raiser)
    pipeline.subscribe(healthy)

    pipeline.begin_run("ent", 1)
    pipeline.end_run("ent", 1, :ok)

    assert_equal 1, raiser.finished_calls
    assert_includes log_io.string, "run_finished boom"
    assert_equal [["ent", 1, :ok, nil]], healthy.finished
  end

  # --- bounded partial-line cap (Story 3.4 DR9) ------------------------------

  def test_a_newline_free_chunk_past_max_line_bytes_is_force_emitted_before_end_run
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([]), max_line_bytes: 16
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)

    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a" * 20)

    refute_empty observer.records, "a record must be force-emitted before end_run"
  end

  def test_the_retained_buffer_plus_the_forced_record_account_for_every_byte
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([]), max_line_bytes: 16
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)

    payload = ("a".."z").to_a.join * 3 # 78 newline-free bytes
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, payload)
    pipeline.end_run("ent", 1, :ok)

    reconstructed = observer.records.map(&:text).join
    assert_equal payload, reconstructed
  end

  def test_a_secret_placed_exactly_across_the_forced_cut_boundary_is_still_redacted
    secret = "sekret-value-1"
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([secret]), max_line_bytes: 32
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)

    filler = "x" * 30
    pipeline.begin_run("ent", 1)
    # The chunk crosses max_line_bytes right where `secret` sits at the tail,
    # so a naive positional cut would split it and neither half would match
    # on its own.
    pipeline.append("ent", :stdout, filler + secret)
    pipeline.end_run("ent", 1, :ok)

    reconstructed = observer.records.map(&:text).join
    refute_includes reconstructed, secret
    assert_includes reconstructed, "[REDACTED]"
  end

  def test_max_line_bytes_defaults_so_existing_redactor_only_construction_still_compiles
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([])
    )

    assert_instance_of AgentDaemon::Supervisor::OutputPipeline, pipeline
  end

  def test_a_forced_cut_landing_mid_multibyte_character_emits_valid_utf8_and_loses_no_bytes
    # The secret makes hold_back 1, which lands the byte-offset cut inside
    # one of the two-byte "é" characters unless the cut is boundary-aligned.
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new(["ab"]), max_line_bytes: 16
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)

    payload = "é" * 12 # 24 bytes, newline-free
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, payload)
    pipeline.end_run("ent", 1, :ok)

    observer.records.each do |record|
      assert_predicate record.text, :valid_encoding?,
                       "forced record text must stay valid UTF-8"
    end
    assert_equal payload, observer.records.map(&:text).join
  end

  def test_a_multibyte_secret_torn_at_the_cap_boundary_is_still_redacted
    secret = "café-sekret"
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([secret]), max_line_bytes: 16
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)

    secret_bytes = secret.b
    pipeline.begin_run("ent", 1)
    # The chunk boundary tears the two-byte "é" exactly when the cap trips;
    # scrubbing the torn lead byte here would mangle the secret forever.
    pipeline.append("ent", :stdout, ("x" * 15).b + secret_bytes.byteslice(0, 4))
    pipeline.append("ent", :stdout, secret_bytes.byteslice(4, secret_bytes.bytesize - 4) + "\n")
    pipeline.end_run("ent", 1, :ok)

    reconstructed = observer.records.map(&:text).join
    refute_includes reconstructed, "sekret"
    assert_includes reconstructed, "[REDACTED]"
  end

  def test_an_incomplete_secret_at_the_forced_cut_is_completed_and_redacted_later
    secret = "sekret-value-1"
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([secret]), max_line_bytes: 32
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)

    pipeline.begin_run("ent", 1)
    # The cap trips while only a prefix of the secret has arrived — the
    # hold-back must keep that prefix in the buffer so the completed value
    # matches on the next emission.
    pipeline.append("ent", :stdout, "x" * 25 + "sekret-v")
    pipeline.append("ent", :stdout, "alue-1\n")
    pipeline.end_run("ent", 1, :ok)

    reconstructed = observer.records.map(&:text).join
    refute_includes reconstructed, secret
    assert_includes reconstructed, "[REDACTED]"
  end

  def test_an_over_cap_buffer_that_redacts_below_the_hold_back_is_still_shrunk
    secret = "s" * 40
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new([secret]), max_line_bytes: 32
    )
    observer = RecordingObserver.new
    pipeline.subscribe(observer)

    pipeline.begin_run("ent", 1)
    # 40 raw bytes collapse to a 10-byte "[REDACTED]" — below the 16-byte
    # hold-back, so nothing can be emitted. The buffer must still be replaced
    # with the redacted form or it grows raw forever, re-redacted per append.
    pipeline.append("ent", :stdout, secret)

    buffer = pipeline.instance_variable_get(:@entities).dig("ent", :buffers, :stdout)
    assert_operator buffer.bytesize, :<=, 32,
                    "the partial-line buffer must not stay over max_line_bytes"

    pipeline.end_run("ent", 1, :ok)
    reconstructed = observer.records.map(&:text).join
    refute_includes reconstructed, secret
    assert_includes reconstructed, "[REDACTED]"
  end
end
