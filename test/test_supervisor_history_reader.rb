# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"

# AD-5 lazy-require isolation: loaded explicitly, never via `require "agent_daemon"`.
require "agent_daemon/supervisor/history/database"
require "agent_daemon/supervisor/history/reader"
require "sqlite3"

# Story 5.5: the console's query-only history reader, against a real store
# seeded by SQL.
class TestSupervisorHistoryReader < Minitest::Test
  include LogStubbing
  include HistorySeeding

  Database = AgentDaemon::Supervisor::History::Database
  Reader = AgentDaemon::Supervisor::History::Reader

  def setup
    stub_null_logger!
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "history.sqlite3")
    @store = Database.open(path: @path, busy_timeout_ms: 5000)
    @readers = []
  end

  def teardown
    @readers.each(&:close)
    @store.close
    FileUtils.remove_entry(@dir)
    restore_logger!
  end

  def seed_db = @store.db

  def reader(page_size: 50, path: @path)
    @readers << Reader.new(path: path, busy_timeout_ms: 5000, page_size: page_size)
    @readers.last
  end

  def walk(reader, **kwargs)
    pages = []
    cursor = nil
    loop do
      page = reader.runs(cursor: cursor, **kwargs)
      pages << page.runs.map(&:id)
      cursor = page.next_cursor
      break unless cursor
    end
    pages
  end

  # --- Ordering and paging ----------------------------------------------------

  def test_runs_are_newest_first_with_ties_broken_by_id_descending
    entity = seed_entity("runner:wf:a")
    oldest = seed_run(entity, started_at: at(1))
    tie_low = seed_run(entity, started_at: at(5))
    tie_high = seed_run(entity, started_at: at(5))

    page = reader.runs

    assert_equal [tie_high, tie_low, oldest], page.runs.map(&:id)
    assert_nil page.next_cursor
  end

  def test_runs_carry_every_field_joined_to_their_entity
    entity = seed_entity("runner:wf:a")
    id = seed_run(entity, started_at: at(1), generation: 3, work_item: "TI-9", attempt: 2, finished_at: at(2),
                          reason: "failed", output_truncated: 1, error_summary: '{"reason":"failed"}')

    run = reader.runs.runs.first

    assert_equal [id, "runner:wf:a", "runner", "wf", "a", 3, "TI-9", 2, at(1), at(2), "failed", "failed", true, false,
                  '{"reason":"failed"}'],
                 [run.id, run.entity_key, run.kind, run.workflow, run.runner, run.generation, run.work_item,
                  run.attempt, run.started_at, run.finished_at, run.reason, run.result, run.output_truncated,
                  run.output_incomplete, run.error_summary]
    assert run.frozen?
  end

  def test_seek_paging_walks_every_run_exactly_once
    entity = seed_entity("runner:wf:a")
    ids = (1..5).map { |second| seed_run(entity, started_at: at(second)) }

    pages = walk(reader(page_size: 2))

    assert_equal [[ids[4], ids[3]], [ids[2], ids[1]], [ids[0]]], pages
  end

  def test_a_page_exactly_full_has_no_next_cursor
    entity = seed_entity("runner:wf:a")
    2.times { |second| seed_run(entity, started_at: at(second)) }

    assert_nil reader(page_size: 2).runs.next_cursor
  end

  def test_the_cursor_is_the_last_shown_pair_and_paging_is_exclusive_across_ties
    entity = seed_entity("runner:wf:a")
    ids = 4.times.map { seed_run(entity, started_at: at(7)) }
    r = reader(page_size: 3)

    first = r.runs
    assert_equal [at(7), ids[1]], first.next_cursor
    assert_equal [ids[0]], r.runs(cursor: first.next_cursor).runs.map(&:id)
  end

  def test_runs_inserted_after_page_one_never_repeat_on_the_next_page
    entity = seed_entity("runner:wf:a")
    old = (1..3).map { |second| seed_run(entity, started_at: at(second)) }
    r = reader(page_size: 2)

    first = r.runs
    3.times { |n| seed_run(entity, started_at: at(10 + n)) }
    second = r.runs(cursor: first.next_cursor)

    assert_equal [old[2], old[1]], first.runs.map(&:id)
    assert_equal [old[0]], second.runs.map(&:id)
    assert_nil second.next_cursor
  end

  def test_runs_from_a_previous_master_and_the_current_one_form_one_sequence
    entity = seed_entity("runner:wf:a")
    before = seed_run(entity, started_at: at(1), generation: 1, incomplete: 1)
    after = seed_run(entity, started_at: at(2), generation: 1, finished_at: at(3), reason: "ok")

    runs = reader.runs.runs

    assert_equal [[after, "ok"], [before, "incomplete"]], runs.map { |run| [run.id, run.result] }
  end

  # --- Entity scoping and restart actions -----------------------------------

  def test_runs_scoped_to_an_entity_exclude_every_other_entity
    a = seed_entity("runner:wf:a")
    b = seed_entity("runner:wf:b", runner: "b")
    mine = seed_run(a, started_at: at(1))
    seed_run(b, started_at: at(2))

    assert_equal [mine], reader.runs(entity_key: "runner:wf:a").runs.map(&:id)
    assert_empty reader.runs(entity_key: "runner:wf:nope").runs
  end

  def test_scoped_paging_walks_only_that_entity
    a = seed_entity("runner:wf:a")
    b = seed_entity("runner:wf:b", runner: "b")
    mine = (1..3).map { |second| seed_run(a, started_at: at(second * 2)) }
    (1..3).each { |second| seed_run(b, started_at: at((second * 2) + 1)) }

    assert_equal [[mine[2], mine[1]], [mine[0]]], walk(reader(page_size: 2), entity_key: "runner:wf:a")
  end

  def test_entity_returns_the_persisted_row_or_nil
    seed_entity("messenger:wf", kind: "messenger", runner: nil)

    entity = reader.entity("messenger:wf")

    assert_equal ["messenger:wf", "messenger", "wf", nil], [entity.entity_key, entity.kind, entity.workflow,
                                                             entity.runner]
    assert entity.frozen?
    assert_nil reader.entity("runner:wf:nope")
  end

  def test_restart_actions_are_newest_first_limited_to_a_page_with_a_more_flag
    a = seed_entity("runner:wf:a")
    b = seed_entity("runner:wf:b", runner: "b")
    seed_restart(a, requested_at: at(1), actors: %w[x])
    seed_restart(a, requested_at: at(3), actors: %w[a b], completed_at: at(4))
    seed_restart(a, requested_at: at(2), actors: %w[y])
    seed_restart(b, requested_at: at(9), actors: %w[other])

    actions, more = reader(page_size: 2).restart_actions("runner:wf:a")

    assert_equal [%w[a b], %w[y]], actions.map { |action| JSON.parse(action.actors) }
    assert_equal [1, 2, at(4)], [actions.first.source_generation, actions.first.target_generation,
                                 actions.first.completed_at]
    assert more
    _all, more = reader.restart_actions("runner:wf:a")
    refute more
  end

  # --- Run detail -----------------------------------------------------------

  def test_run_detail_carries_events_in_time_order_and_output_in_seq_order
    entity = seed_entity("runner:wf:a")
    id = seed_run(entity, started_at: at(1), finished_at: at(5), reason: "failed")
    seed_event(id, 3, "finished", at(5), reason: "failed")
    seed_event(id, 1, "picked_up", at(1))
    seed_event(id, 2, "started", at(2))
    seed_output(id, 2, "stderr", "boom")
    seed_output(id, 1, "stdout", "hello")

    run = reader.run(id)

    assert_equal [%w[picked_up] + [nil], %w[started] + [nil], %w[finished failed]],
                 run.events.map { |event| [event.event, event.reason] }
    assert_equal [[:stdout, "hello"], [:stderr, "boom"]], run.output.map { |line| [line.stream, line.text] }
    assert run.events.frozen?
    assert run.output.frozen?
  end

  def test_run_returns_nil_for_an_unknown_id
    assert_nil reader.run(99_999)
  end

  def test_result_is_the_reason_else_incomplete_else_running
    entity = seed_entity("runner:wf:a")
    finished = seed_run(entity, started_at: at(1), finished_at: at(2), reason: "timeout")
    crashed = seed_run(entity, started_at: at(3), incomplete: 1)
    open = seed_run(entity, started_at: at(4))

    assert_equal %w[timeout incomplete running], [finished, crashed, open].map { |id| reader.run(id).result }
  end

  # --- Connection -----------------------------------------------------------

  def test_the_connection_is_query_only
    r = reader
    r.runs

    assert_raises(SQLite3::ReadOnlyException) do
      r.send(:query) { |db| db.execute("DELETE FROM run") }
    end
  end

  def test_construction_does_no_io_and_a_missing_store_raises_and_is_not_created
    missing = File.join(@dir, "nope", "missing.sqlite3")
    r = reader(path: missing)

    refute File.exist?(File.dirname(missing))
    assert_raises(SQLite3::CantOpenException) { r.runs }
    refute File.exist?(missing)
  end

  def test_a_failed_query_drops_the_connection_and_the_next_call_reopens_it
    entity = seed_entity("runner:wf:a")
    seed_run(entity, started_at: at(1))
    r = reader
    r.runs
    first = r.instance_variable_get(:@db)

    assert_raises(SQLite3::SQLException) { r.send(:query) { |db| db.execute("SELECT nope FROM nowhere") } }
    assert first.closed?
    assert_nil r.instance_variable_get(:@db)

    assert_equal 1, r.runs.runs.size
    refute_same first, r.instance_variable_get(:@db)
  end

  def test_close_is_idempotent
    r = reader
    r.runs
    r.close
    r.close

    assert_nil r.instance_variable_get(:@db)
  end

  def test_the_reader_sees_the_writers_later_commits
    entity = seed_entity("runner:wf:a")
    r = reader
    assert_empty r.runs.runs

    seed_run(entity, started_at: at(1))

    assert_equal 1, r.runs.runs.size
  end

  # --- Story 5.6: status ------------------------------------------------------

  def test_status_is_the_callables_value_and_never_opens_the_store
    snapshot = Object.new
    r = Reader.new(path: File.join(@dir, "missing.sqlite3"), busy_timeout_ms: 5000, page_size: 50,
                   status: -> { snapshot })
    @readers << r

    assert_same snapshot, r.status
    assert_nil r.instance_variable_get(:@db)
  end

  def test_status_is_nil_without_a_callable
    assert_nil reader.status
  end
end
