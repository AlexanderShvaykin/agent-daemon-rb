# frozen_string_literal: true

require "test_helper"

require "agent_daemon/supervisor/history/output_queue"
require "agent_daemon/supervisor/output_pipeline"

class TestOutputQueue < Minitest::Test
  OutputQueue = AgentDaemon::Supervisor::History::OutputQueue
  Record = AgentDaemon::Supervisor::OutputPipeline::Record

  def line(text, entity: "e", generation: 1, run_id: 1, stream: :stdout, seq: 1)
    Record.new(entity_id: entity, generation: generation, run_id: run_id, stream: stream, seq: seq,
               at: "2026-09-19T10:00:00Z", text: text).freeze
  end

  def kinds(entries) = entries.map { |entry| entry[:kind] }

  def test_entries_keep_arrival_order_with_their_fields
    queue = OutputQueue.new(budget_bytes: 100)
    queue.run_started("e", 7, 2)
    queue.call(line("out", generation: 2, run_id: 7, seq: 1))
    queue.call(line("err", generation: 2, run_id: 7, stream: :stderr, seq: 2))
    queue.run_finished("e", 7, :ok, 2)

    entries = queue.drain

    assert_equal %i[run_started output output run_finished], kinds(entries)
    assert(entries.all? { |entry| entry[:entity_id] == "e" && entry[:generation] == 2 && entry[:run_id] == 7 })
    assert_equal [[:stdout, 1, "out"], [:stderr, 2, "err"]],
                 entries[1, 2].map { |entry| entry.values_at(:stream, :seq, :text) }
    assert entries.frozen?
    assert entries.all?(&:frozen?)
  end

  def test_drain_empties_the_queue_and_size_counts_entries
    queue = OutputQueue.new(budget_bytes: 100)
    queue.run_started("e", 1, 1)
    queue.call(line("a"))
    assert_equal 2, queue.size

    assert_equal 2, queue.drain.size
    assert_equal 0, queue.size
    assert_empty queue.drain
  end

  def test_over_budget_the_oldest_lines_become_one_lost_marker
    queue = OutputQueue.new(budget_bytes: 10)
    queue.run_started("e", 1, 1)
    5.times { |i| queue.call(line("abcd", seq: i + 1)) } # 20 bytes, budget 10
    queue.run_finished("e", 1, :ok, 1)

    assert_equal 5, queue.size
    entries = queue.drain

    assert_equal %i[run_started lost output output run_finished], kinds(entries)
    assert_equal [4, 5], entries.select { |entry| entry[:kind] == :output }.map { |entry| entry[:seq] }
    assert_equal ["e", 1, 1], entries[1].values_at(:entity_id, :generation, :run_id)
  end

  def test_lifecycle_markers_are_never_evicted
    queue = OutputQueue.new(budget_bytes: 4)
    3.times do |run|
      queue.run_started("e", run, 1)
      queue.call(line("abcd", run_id: run))
      queue.run_finished("e", run, :ok, 1)
    end
    queue.call(line("abcd", run_id: 9))

    entries = queue.drain

    assert_equal %i[run_started lost run_finished] * 3 + %i[output], kinds(entries)
  end

  def test_markers_are_per_run_key_and_never_merged_across_runs
    queue = OutputQueue.new(budget_bytes: 2)
    queue.call(line("ab", entity: "a"))
    queue.call(line("ab", entity: "b"))
    queue.call(line("ab", entity: "a", seq: 2))
    queue.call(line("ab", entity: "b", seq: 2))

    entries = queue.drain

    assert_equal %i[lost lost output], kinds(entries)
    assert_equal %w[a b], entries.first(2).map { |entry| entry[:entity_id] }
  end

  def test_a_long_eviction_stays_bounded_and_correct
    queue = OutputQueue.new(budget_bytes: 10)
    queue.run_started("e", 1, 1)
    1000.times { |i| queue.call(line("x" * 5, seq: i + 1)) }

    assert_equal 4, queue.size
    entries = queue.drain
    assert_equal %i[run_started lost output output], kinds(entries)
    assert_equal [999, 1000], entries.last(2).map { |entry| entry[:seq] }
  end

  def test_the_queue_is_an_output_pipeline_observer
    require "agent_daemon/supervisor/redactor"
    pipeline = AgentDaemon::Supervisor::OutputPipeline.new(redactor: AgentDaemon::Supervisor::Redactor.new([]))
    queue = OutputQueue.new(budget_bytes: 100)
    pipeline.subscribe(queue)

    pipeline.begin_run("e", 3, 2)
    pipeline.append("e", :stdout, "hello\n", 2)
    pipeline.end_run("e", 3, :ok, 2)

    entries = queue.drain
    assert_equal %i[run_started output run_finished], kinds(entries)
    assert_equal ["hello", 3, 2], entries[1].values_at(:text, :run_id, :generation)
  end

  def test_compaction_after_many_coalesced_holes_keeps_order_and_contents
    queue = OutputQueue.new(budget_bytes: 4)
    queue.run_started("e", 1, 1)
    100.times { |i| queue.call(line("ab", seq: i + 1)) } # 98 evicted: 1 marker, 97 holes
    queue.run_finished("e", 1, :ok, 1)
    queue.run_started("e", 2, 1)
    queue.call(line("ab", run_id: 2, seq: 1))

    assert_equal 6, queue.size # run 2's line evicted run 1's seq 99 into the same marker
    assert_operator queue.instance_variable_get(:@entries).size, :<, 50, "104 slots without compaction"
    entries = queue.drain
    assert_equal %i[run_started lost output run_finished run_started output], kinds(entries)
    assert_equal [[1, 100], [2, 1]],
                 entries.select { |entry| entry[:kind] == :output }.map { |entry| entry.values_at(:run_id, :seq) }
  end
end
