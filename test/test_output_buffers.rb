# frozen_string_literal: true

require "test_helper"

# AD-5 lazy-require isolation: the supervisor files are loaded explicitly here
# and are NOT part of the core `require "agent_daemon"` graph.
require "agent_daemon/supervisor/output_buffers"
require "agent_daemon/supervisor/output_pipeline"
require "agent_daemon/supervisor/redactor"

class TestOutputBuffers < Minitest::Test
  # A real OutputPipeline + real Redactor drive every test about the seam
  # (retro AI-1: no reimplemented internals). Only the DR7/DR8 tests that are
  # about the store's OWN write-path arithmetic construct a Record directly.
  def build(capacity_bytes: 1_000_000, secrets: [])
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(
      redactor: AgentDaemon::Supervisor::Redactor.new(secrets)
    )
    buffers = AgentDaemon::Supervisor::OutputBuffers.new(capacity_bytes: capacity_bytes)
    pipeline.subscribe(buffers)
    [pipeline, buffers]
  end

  def raw_record(entity_id:, run_id:, seq: 1, generation: nil, text: "stray")
    AgentDaemon::Supervisor::OutputPipeline::Record.new(
      entity_id: entity_id, generation: generation, run_id: run_id, stream: :stdout,
      seq: seq, at: Time.now.utc.iso8601, text: text
    ).freeze
  end

  # --- AC7: empty is a state, not a failure ----------------------------------

  def test_an_entity_that_never_published_returns_an_explicit_empty_snapshot
    _, buffers = build

    snap = buffers.snapshot("ent")

    refute_nil snap
    assert_equal :empty, snap.status
    assert_equal [], snap.records
    assert_nil snap.run_id
    assert_equal "ent", snap.entity_id
  end

  def test_an_unknown_entity_id_returns_empty_even_when_another_entity_has_output
    pipeline, buffers = build
    pipeline.begin_run("known", 1)
    pipeline.append("known", :stdout, "line\n")

    snap = buffers.snapshot("unknown")

    assert_equal :empty, snap.status
    assert_equal [], snap.records
  end

  # --- AC4/AC5: in-progress and last-completed selection ---------------------

  def test_an_in_progress_run_is_selected_and_reports_unfinished
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "line\n")

    snap = buffers.snapshot("ent")

    assert_equal :retained, snap.status
    assert_equal 1, snap.run_id
    refute snap.finished
    assert_nil snap.reason
  end

  def test_after_run_finished_the_same_run_stays_selected_with_the_reason
    %i[ok failed timeout killed].each do |reason|
      pipeline, buffers = build
      pipeline.begin_run("ent", 1)
      pipeline.append("ent", :stdout, "line\n")
      pipeline.end_run("ent", 1, reason)

      snap = buffers.snapshot("ent")
      assert_equal 1, snap.run_id
      assert snap.finished
      assert_equal reason, snap.reason
    end
  end

  # Sinks::Bundle#end_output_run passes reason: nil when the backend body
  # raised before a terminal reason was assigned (sinks.rb:70-73) — finished
  # must still flip true so reason.nil? cannot be read as "still running".
  def test_run_finished_with_a_nil_reason_still_marks_the_run_finished
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.end_run("ent", 1, nil)

    snap = buffers.snapshot("ent")
    assert snap.finished
    assert_nil snap.reason
  end

  # --- AC6: a new run replaces the selection, without bleed -----------------

  def test_a_second_run_started_selects_it_and_drops_the_first_runs_records
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "first\n")
    pipeline.end_run("ent", 1, :ok)

    pipeline.begin_run("ent", 2)
    pipeline.append("ent", :stdout, "second\n")

    snap = buffers.snapshot("ent")
    assert_equal 2, snap.run_id
    assert_equal ["second"], snap.records.map(&:text)
  end

  # --- AC1: bounded retention with oldest-first eviction ----------------------

  def test_appending_past_capacity_evicts_oldest_first_and_sets_truncated
    pipeline, buffers = build(capacity_bytes: 10)
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "aaaaa\n")
    pipeline.append("ent", :stdout, "bbbbb\n")
    pipeline.append("ent", :stdout, "ccccc\n")

    snap = buffers.snapshot("ent")
    assert_equal %w[bbbbb ccccc], snap.records.map(&:text)
    assert snap.truncated
    assert_operator snap.records.sum { |r| r.text.bytesize }, :<=, 10
  end

  def test_head_seq_advances_as_records_are_evicted
    pipeline, buffers = build(capacity_bytes: 5)
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\n")
    pipeline.append("ent", :stdout, "b\n")
    pipeline.append("ent", :stdout, "c\n")
    pipeline.append("ent", :stdout, "d\n")
    pipeline.append("ent", :stdout, "e\n")
    pipeline.append("ent", :stdout, "f\n")

    snap = buffers.snapshot("ent")
    assert_equal snap.records.first.seq, snap.head_seq
    assert_equal snap.records.last.seq, snap.tail_seq
  end

  # A preceding small record must be evicted to make room, then the huge one
  # is retained alone: truncated is true because the small one WAS dropped.
  def test_a_record_larger_than_capacity_evicts_priors_and_is_retained_alone_truncated
    pipeline, buffers = build(capacity_bytes: 5)
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "small\n")
    pipeline.append("ent", :stdout, "#{'a' * 20}\n")

    snap = buffers.snapshot("ent")
    assert_equal 1, snap.records.size
    assert_equal 20, snap.records.first.text.bytesize
    assert snap.truncated
  end

  # --- AC2: the snapshot is a copy that describes its own window -------------

  def test_records_are_ascending_by_seq
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\nb\nc\n")

    snap = buffers.snapshot("ent")
    assert_equal [1, 2, 3], snap.records.map(&:seq)
  end

  def test_two_snapshots_return_independent_array_objects
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\n")

    snap1 = buffers.snapshot("ent")
    snap2 = buffers.snapshot("ent")

    refute_same snap1.records, snap2.records
    assert_equal snap1.records.map(&:text), snap2.records.map(&:text)
  end

  def test_the_snapshot_and_its_records_array_are_frozen
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\n")

    snap = buffers.snapshot("ent")
    assert_predicate snap, :frozen?
    assert_predicate snap.records, :frozen?
  end

  def test_snapshot_fields_read_correctly
    pipeline, buffers = build
    ingress = pipeline.ingress(9)
    ingress.begin_run("ent", 5)
    ingress.append("ent", :stdout, "a\nb\n")

    snap = buffers.snapshot("ent")
    assert_equal "ent", snap.entity_id
    assert_equal 9, snap.generation
    assert_equal 5, snap.run_id
    assert_equal 1, snap.head_seq
    assert_equal 2, snap.tail_seq
    refute snap.truncated
    refute snap.finished
    assert_nil snap.reason
  end

  # --- AC3 / DR6: cursor resolution rule table --------------------------------

  def test_no_cursor_returns_the_full_window_not_lagged
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\nb\n")

    snap = buffers.snapshot("ent")
    assert_equal %w[a b], snap.records.map(&:text)
    refute snap.lagged
  end

  def test_cursor_at_tail_seq_yields_empty_not_lagged
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\nb\n")

    snap = buffers.snapshot("ent", after_run_id: 1, after_seq: 2)
    assert_equal [], snap.records
    refute snap.lagged
  end

  def test_cursor_mid_window_returns_only_newer_records_not_lagged
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\nb\nc\n")

    snap = buffers.snapshot("ent", after_run_id: 1, after_seq: 1)
    assert_equal %w[b c], snap.records.map(&:text)
    refute snap.lagged
  end

  def test_cursor_below_the_retained_head_reports_lagged_with_the_full_window
    pipeline, buffers = build(capacity_bytes: 4)
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "aa\n")
    pipeline.append("ent", :stdout, "bb\n")
    pipeline.append("ent", :stdout, "cc\n")
    pipeline.append("ent", :stdout, "dd\n")

    snap = buffers.snapshot("ent", after_run_id: 1, after_seq: 1)
    assert snap.lagged
    assert_equal %w[cc dd], snap.records.map(&:text)
  end

  def test_cursor_from_a_different_run_id_returns_the_full_window_not_lagged
    pipeline, buffers = build
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "a\n")
    pipeline.end_run("ent", 1, :ok)
    pipeline.begin_run("ent", 2)
    pipeline.append("ent", :stdout, "b\n")

    snap = buffers.snapshot("ent", after_run_id: 1, after_seq: 1)
    assert_equal ["b"], snap.records.map(&:text)
    refute snap.lagged
  end

  def test_exactly_one_cursor_kwarg_raises_argument_error
    _, buffers = build
    buffers.run_started("ent", 1, nil)

    assert_raises(ArgumentError) { buffers.snapshot("ent", after_run_id: 1) }
    assert_raises(ArgumentError) { buffers.snapshot("ent", after_seq: 1) }
  end

  # The obvious Story 3.5 caller bug — an uncoerced HTTP query param — must
  # fail with the contract's deliberate ArgumentError, not an opaque
  # comparison TypeError from inside the mutex on a Puma thread.
  def test_a_non_integer_after_seq_raises_argument_error
    _, buffers = build
    buffers.run_started("ent", 1, nil)

    error = assert_raises(ArgumentError) { buffers.snapshot("ent", after_run_id: 1, after_seq: "5") }
    assert_includes error.message, "after_seq must be an Integer"
  end

  def test_truncated_true_with_lagged_false_for_a_fresh_reader
    pipeline, buffers = build(capacity_bytes: 4)
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "aa\n")
    pipeline.append("ent", :stdout, "bb\n")
    pipeline.append("ent", :stdout, "cc\n")

    snap = buffers.snapshot("ent")
    assert snap.truncated
    refute snap.lagged
  end

  def test_truncated_true_with_lagged_true_for_a_lagging_cursor
    pipeline, buffers = build(capacity_bytes: 4)
    pipeline.begin_run("ent", 1)
    pipeline.append("ent", :stdout, "aa\n")
    pipeline.append("ent", :stdout, "bb\n")
    pipeline.append("ent", :stdout, "cc\n")
    pipeline.append("ent", :stdout, "dd\n")

    snap = buffers.snapshot("ent", after_run_id: 1, after_seq: 1)
    assert snap.truncated
    assert snap.lagged
  end

  # --- DR7: generation compare-and-set on every write path -------------------

  def test_an_older_generation_run_started_is_dropped
    _, buffers = build
    buffers.run_started("ent", 1, 5)
    buffers.run_started("ent", 2, 3)

    snap = buffers.snapshot("ent")
    assert_equal 1, snap.run_id
    assert_equal 5, snap.generation
  end

  def test_an_equal_generation_run_started_is_accepted
    _, buffers = build
    buffers.run_started("ent", 1, 5)
    buffers.run_started("ent", 2, 5)

    assert_equal 2, buffers.snapshot("ent").run_id
  end

  def test_a_nil_generation_does_not_raise_and_compares_as_zero
    _, buffers = build

    buffers.run_started("ent", 1, nil)

    assert_equal :retained, buffers.snapshot("ent").status
  end

  def test_a_call_whose_run_id_does_not_match_the_selection_is_dropped
    _, buffers = build
    buffers.run_started("ent", 1, nil)

    buffers.call(raw_record(entity_id: "ent", run_id: 999))

    assert_equal [], buffers.snapshot("ent").records
  end

  def test_a_record_arriving_with_no_selected_run_is_dropped_without_raising
    _, buffers = build

    buffers.call(raw_record(entity_id: "ent", run_id: 1))

    assert_equal :empty, buffers.snapshot("ent").status
  end

  def test_an_older_generation_call_is_dropped
    _, buffers = build
    buffers.run_started("ent", 1, 5)

    buffers.call(raw_record(entity_id: "ent", run_id: 1, generation: 3, text: "old-gen"))

    assert_equal [], buffers.snapshot("ent").records
  end

  def test_an_older_generation_run_finished_is_dropped
    _, buffers = build
    buffers.run_started("ent", 1, 5)

    buffers.run_finished("ent", 1, :ok, 3)

    refute buffers.snapshot("ent").finished
  end

  def test_a_run_finished_for_a_non_selected_run_id_is_dropped
    _, buffers = build
    buffers.run_started("ent", 1, nil)

    buffers.run_finished("ent", 999, :ok, nil)

    refute buffers.snapshot("ent").finished
  end

  # --- DR8: thread safety / copy-on-read isolation between entities ----------

  def test_two_entities_never_see_each_others_records
    pipeline, buffers = build
    pipeline.begin_run("a", 1)
    pipeline.begin_run("b", 1)
    pipeline.append("a", :stdout, "a-line\n")
    pipeline.append("b", :stdout, "b-line\n")

    assert_equal ["a-line"], buffers.snapshot("a").records.map(&:text)
    assert_equal ["b-line"], buffers.snapshot("b").records.map(&:text)
  end

  # --- protocol -----------------------------------------------------------

  def test_the_store_implements_the_call_only_output_observer_protocol
    _, buffers = build
    assert_respond_to buffers, :call
  end
end
