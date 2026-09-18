# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "delegate"
require "json"

# AD-5 lazy-require isolation: loaded explicitly, never via `require "agent_daemon"`.
require "agent_daemon/supervisor/history/database"
require "agent_daemon/supervisor/history/writer"
require "agent_daemon/supervisor/event_bus"
require "agent_daemon/supervisor/runner_supervisor"
require "agent_daemon/supervisor/fleet"
require "sqlite3"

class TestSupervisorHistoryWriter < Minitest::Test
  include LogStubbing

  Database = AgentDaemon::Supervisor::History::Database
  Writer = AgentDaemon::Supervisor::History::Writer
  EventBus = AgentDaemon::Supervisor::EventBus
  GenerationStamp = AgentDaemon::Supervisor::GenerationStamp
  Rostered = AgentDaemon::Supervisor::Fleet::Rostered
  RunnerIdentity = AgentDaemon::Supervisor::RunnerIdentity

  TIMESTAMP = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
  RUNNER = RunnerIdentity.new(workflow: "wf", runner: "a")
  ROSTER = [
    Rostered.new(kind: :runner, workflow: "wf", name: "a", entity_id: RUNNER),
    Rostered.new(kind: :messenger, workflow: "wf", name: "messenger", entity_id: "messenger:wf"),
    Rostered.new(kind: :reactor, workflow: nil, name: "mattermost_reactor", entity_id: "mattermost_reactor")
  ].freeze

  # Wraps the real connection and raises on the Nth #execute, to fail a batch
  # part-way through, or on every #execute whose SQL matches a Regexp.
  class FailingDb < SimpleDelegator
    attr_accessor :fail_on

    def initialize(db, fail_on:)
      super(db)
      @fail_on = fail_on
      @calls = 0
    end

    def execute(*args)
      @calls += 1
      failing = @fail_on.is_a?(Regexp) ? @fail_on.match?(args.first) : @calls == @fail_on
      raise SQLite3::SQLException, "injected failure" if failing

      __getobj__.execute(*args)
    end
  end
  FakeStore = Struct.new(:db)

  def setup
    stub_null_logger!
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "history.sqlite3")
    @store = Database.open(path: @path, busy_timeout_ms: 5000)
    @source = EventBus.new
    @source_cursor = @source.subscribe
  end

  def teardown
    @writer&.stop(timeout: 5)
    @store.close
    FileUtils.remove_entry(@dir)
    restore_logger!
  end

  def writer(store = @store, bus: EventBus.new, **kwargs)
    @writer = Writer.new(database: store, event_bus: bus, roster: ROSTER, **kwargs)
  end

  # Publishes exactly as a supervised entity does: through GenerationStamp
  # onto a real EventBus.
  def publish(entity_id, generation, bus: @source, **event)
    GenerationStamp.new(generation, bus).publish(entity_id, event)
  end

  def records
    @source_cursor.read
  end

  def lifecycle(key, generation: 1, reason: :ok, attempt: 1, entity: RUNNER, bus: @source)
    publish(entity, generation, type: :picked_up, work_item: key, at: "2026-09-19T10:00:00Z", bus: bus)
    publish(entity, generation, type: :started, work_item: key, attempt: attempt, at: "2026-09-19T10:00:01Z", bus: bus)
    publish(entity, generation, type: :finished, work_item: key, reason: reason, attempt: attempt,
                                at: "2026-09-19T10:00:05Z", bus: bus)
  end

  # A sleeper that records the requested delays instead of sleeping.
  def recording_sleeper
    sleeps = []
    [sleeps, ->(seconds) { sleeps << seconds }]
  end

  def wait_until(timeout = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end

  # Ends the current session and opens the same DB again, as a restarted
  # master does: a fresh connection and a fresh bus whose seqs restart at 1.
  def reopen_session
    @writer&.stop(timeout: 5)
    @writer = nil
    @store.close
    @store = Database.open(path: @path, busy_timeout_ms: 5000)
    @source = EventBus.new
    @source_cursor = @source.subscribe
  end

  def rows(sql)
    @store.db.execute(sql)
  end

  def count(table)
    @store.db.get_first_value("SELECT COUNT(*) FROM #{table}")
  end

  # --- Correlation ----------------------------------------------------------

  def test_a_full_run_is_one_run_with_three_ordered_events
    lifecycle("K")
    batch = records

    assert writer.write(batch)

    runs = rows("SELECT generation, work_item, attempt, started_at, finished_at, reason FROM run")
    assert_equal [[1, "K", 1, "2026-09-19T10:00:00.000Z", "2026-09-19T10:00:05.000Z", "ok"]], runs
    events = rows("SELECT seq, event, reason, occurred_at FROM run_event ORDER BY seq")
    assert_equal batch.map { |r| r[:seq] }, events.map(&:first)
    assert_equal %w[picked_up started finished], events.map { |e| e[1] }
    assert_equal [nil, nil, "ok"], events.map { |e| e[2] }
    events.each { |e| assert_match TIMESTAMP, e[3] }
    entity = rows("SELECT entity_key, kind, workflow, runner, first_seen_at FROM supervised_entity")
    assert_equal [["runner:wf:a", "runner", "wf", "a", "2026-09-19T10:00:00.000Z"]], entity
  end

  def test_two_lifecycles_are_two_runs_of_one_entity
    lifecycle("K")
    lifecycle("L", reason: :failed, attempt: 2)

    assert writer.write(records)

    assert_equal [["K", 1, "ok"], ["L", 2, "failed"]], rows("SELECT work_item, attempt, reason FROM run ORDER BY id")
    assert_equal 6, count("run_event")
    assert_equal 1, count("supervised_entity")
  end

  def test_a_second_pickup_abandons_the_open_run_without_inventing_an_end
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 2, type: :picked_up, work_item: "K", at: "2026-09-19T10:01:00Z")

    assert writer.write(records)

    assert_equal [[1, nil, nil, 1], [2, nil, nil, 0]],
                 rows("SELECT generation, finished_at, reason, incomplete FROM run ORDER BY id")
    assert_equal 2, count("run_event")
  end

  def test_a_start_without_a_pickup_opens_a_run_from_what_was_seen
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:07Z")
    publish(RUNNER, 1, type: :finished, work_item: "K", reason: :timeout, attempt: 1, at: "2026-09-19T10:00:09Z")

    assert writer.write(records)

    assert_equal [["2026-09-19T10:00:07.000Z", "2026-09-19T10:00:09.000Z", "timeout", 1]],
                 rows("SELECT started_at, finished_at, reason, attempt FROM run")
    assert_equal %w[started finished], rows("SELECT event FROM run_event ORDER BY seq").flatten
  end

  def test_a_finish_for_another_generation_does_not_close_the_open_run
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 2, type: :finished, work_item: "K", reason: :killed, attempt: 1, at: "2026-09-19T10:00:09Z")
    w = writer

    assert w.write(records)

    assert_equal [[1, nil], [2, "killed"]], rows("SELECT generation, reason FROM run ORDER BY id")

    publish(RUNNER, 1, type: :finished, work_item: "K", reason: :ok, attempt: 1, at: "2026-09-19T10:00:10Z")
    assert w.write(records)

    assert_equal [[1, "ok"], [2, "killed"]], rows("SELECT generation, reason FROM run ORDER BY id")
  end

  def test_a_start_for_another_work_item_abandons_the_open_run_as_incomplete
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 1, type: :started, work_item: "L", attempt: 1, at: "2026-09-19T10:00:01Z")
    publish(RUNNER, 1, type: :finished, work_item: "L", reason: :ok, attempt: 1, at: "2026-09-19T10:00:02Z")

    assert writer.write(records)

    assert_equal [["K", nil, nil, 1], ["L", "2026-09-19T10:00:02.000Z", "ok", 0]],
                 rows("SELECT work_item, finished_at, reason, incomplete FROM run ORDER BY id")
  end

  def test_an_unknown_reason_is_null_in_both_run_and_run_event
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 1, type: :finished, work_item: "K", reason: :exploded, attempt: 1, at: "2026-09-19T10:00:02Z")

    assert writer.write(records)

    assert_equal [nil], rows("SELECT reason FROM run").flatten
    assert_equal [nil, nil], rows("SELECT reason FROM run_event ORDER BY seq").flatten
  end

  # --- Restart actions ------------------------------------------------------

  def test_a_messenger_restart_is_one_restart_action
    publish("messenger:wf", 2, type: :restart, actor: [:crash_auto], requested_at: "2026-09-19T10:00:00.123Z",
                               at: "2026-09-19T10:01:00Z")

    assert writer.write(records)

    assert_equal [["messenger:wf", "messenger", "wf", nil]],
                 rows("SELECT entity_key, kind, workflow, runner FROM supervised_entity")
    action = rows("SELECT source_generation, target_generation, actors, requested_at, completed_at FROM restart_action")
    assert_equal [[1, 2, '["crash_auto"]', "2026-09-19T10:00:00.123Z", "2026-09-19T10:01:00.000Z"]], action
    action.first.last(2).each { |t| assert_match TIMESTAMP, t }
  end

  def test_a_reactor_restart_has_no_workflow_or_runner
    publish("mattermost_reactor", 3, type: :restart, actor: [:crash_auto], requested_at: "2026-09-19T10:00:00.000Z",
                                     at: "2026-09-19T10:01:00Z")

    assert writer.write(records)

    assert_equal [["mattermost_reactor", "reactor", nil, nil]],
                 rows("SELECT entity_key, kind, workflow, runner FROM supervised_entity")
    assert_equal [[2, 3]], rows("SELECT source_generation, target_generation FROM restart_action")
  end

  def test_a_coalesced_restart_is_exactly_one_action_with_every_actor
    publish(RUNNER, 2, type: :restart, actor: [:crash_auto, "console:alice"],
                       requested_at: "2026-09-19T10:00:00.000Z", at: "2026-09-19T10:01:00Z")

    assert writer.write(records)

    assert_equal [['["crash_auto","console:alice"]']], rows("SELECT actors FROM restart_action")
  end

  # --- Idempotency and failure ----------------------------------------------

  def test_a_repeated_batch_writes_nothing_twice
    lifecycle("K")
    publish(RUNNER, 2, type: :restart, actor: [:crash_auto], requested_at: "2026-09-19T10:00:00.000Z",
                       at: "2026-09-19T10:01:00Z")
    batch = records
    w = writer

    assert w.write(batch)
    assert w.write(batch)

    assert_equal [1, 3, 1, 1], %w[run run_event restart_action supervised_entity].map { |t| count(t) }
  end

  def test_a_failed_batch_leaves_nothing_and_its_rewrite_is_complete
    lifecycle("K")
    batch = records
    failing = FailingDb.new(@store.db, fail_on: 3)
    w = writer(FakeStore.new(failing))

    log = capture_log { refute w.write(batch) }

    assert_equal [0, 0, 0], %w[run run_event supervised_entity].map { |t| count(t) }
    lines = log.lines.grep(/\[History\]/)
    assert_equal 1, lines.size, log
    assert_includes lines.first, "SQLite3::SQLException"
    assert_includes lines.first, "3 record(s)"
    refute_includes lines.first, "K"

    failing.fail_on = nil
    assert w.write(batch)

    assert_equal [[1, "K", "ok"]], rows("SELECT attempt, work_item, reason FROM run")
    assert_equal batch.map { |r| r[:seq] }, rows("SELECT seq FROM run_event ORDER BY id").flatten
  end

  # The failed batch opened a run in memory; the rollback must forget it, or
  # the next batch would attach events to a run id that was never committed.
  def test_a_failed_pickup_batch_leaves_no_open_run_behind
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    failing = FailingDb.new(@store.db, fail_on: 3) # entity insert, run insert, then the run_event insert
    w = writer(FakeStore.new(failing))
    refute w.write(records)
    failing.fail_on = nil

    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z")
    publish(RUNNER, 1, type: :finished, work_item: "K", reason: :ok, attempt: 1, at: "2026-09-19T10:00:02Z")
    assert w.write(records)

    assert_equal [["2026-09-19T10:00:01.000Z", "ok"]], rows("SELECT started_at, reason FROM run")
    assert_equal %w[started finished], rows("SELECT event FROM run_event ORDER BY seq").flatten
    assert_empty rows("PRAGMA foreign_key_check")
  end

  def test_a_failed_commit_is_rolled_back_and_the_next_batch_commits
    failed = false
    @store.db.singleton_class.prepend(Module.new do
      define_method(:commit) do
        next super() if failed

        failed = true
        raise SQLite3::BusyException, "injected commit failure"
      end
    end)
    lifecycle("K")
    w = writer

    refute w.write(records)
    refute @store.db.transaction_active?

    lifecycle("L")
    assert w.write(records)

    assert_equal ["L"], rows("SELECT work_item FROM run").flatten
    assert_equal 3, count("run_event")
  end

  def test_unknown_entities_and_bad_restarts_are_skipped_without_poisoning_the_batch
    publish("messenger:gone", 1, type: :picked_up, work_item: "X", at: "2026-09-19T10:00:00Z")
    publish("messenger:wf", 2, type: :restart, actor: [:crash_auto], at: "2026-09-19T10:01:00Z")
    lifecycle("K")

    log = capture_log { assert writer.write(records) }

    assert_equal 2, log.lines.grep(/\[History\].*skipped/).size, log
    assert_equal 1, count("run")
    assert_equal 0, count("restart_action")
    assert_equal ["runner:wf:a"], rows("SELECT entity_key FROM supervised_entity").flatten
  end

  # --- The thread -----------------------------------------------------------

  def test_one_named_thread_persists_events_published_before_start
    bus = EventBus.new
    w = writer(bus: bus, poll_interval: 0.05)
    lifecycle("K")
    records.each { |r| bus.publish(r[:entity_id], r.except(:seq, :entity_id)) }

    w.start
    assert_equal 1, Thread.list.count { |t| t.name == "history_writer" }
    publish(RUNNER, 1, type: :picked_up, work_item: "L", at: "2026-09-19T10:02:00Z", bus: bus)

    assert w.stop(timeout: 5)
    assert_equal 2, count("run")
    assert_equal 4, count("run_event")
    assert_equal 0, Thread.list.count { |t| t.name == "history_writer" && t.alive? }
  end

  def test_a_held_write_lock_never_stalls_publishers_or_other_threads
    bus = EventBus.new
    w = writer(bus: bus, poll_interval: 0.05)
    other = SQLite3::Database.new(@path)
    other.execute("BEGIN IMMEDIATE")
    publish(RUNNER, 1, type: :picked_up, work_item: "first", at: "2026-09-19T10:00:00Z", bus: bus)
    w.start
    sleep 0.2 # the writer is now waiting on the lock

    ticks = 0
    counter = Thread.new { loop { ticks += 1 } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    1000.times { |i| publish(RUNNER, 1, type: :picked_up, work_item: "k#{i}", at: "2026-09-19T10:00:00Z", bus: bus) }
    publishing = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    before = ticks
    sleep 0.2
    advanced = ticks - before
    counter.kill.join

    assert_operator publishing, :<, 1.0, "publishing 1,000 events must not wait on SQLite"
    assert_operator advanced, :>, 1000, "a Ruby thread must keep running while the writer waits"
    assert_equal 0, other.get_first_value("SELECT COUNT(*) FROM run"), "the writer was still waiting"

    other.execute("ROLLBACK")
    assert w.stop(timeout: 5)
    assert_equal 1001, count("run")
  ensure
    other&.close
  end

  def test_a_stop_that_times_out_returns_false_and_keeps_the_cursor
    bus = EventBus.new
    w = writer(bus: bus, poll_interval: 0.05)
    other = SQLite3::Database.new(@path)
    other.execute("BEGIN IMMEDIATE")
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z", bus: bus)
    w.start
    sleep 0.2 # the writer is now waiting on the lock

    refute w.stop(timeout: 0.1)
    assert_equal 0, bus.dropped(w.instance_variable_get(:@cursor)), "the cursor must stay subscribed"

    other.execute("ROLLBACK")
    assert w.stop(timeout: 5)
    assert_equal 1, count("run")
    assert_raises(KeyError) { bus.dropped(w.instance_variable_get(:@cursor)) }
  ensure
    other&.close
  end

  def test_the_final_drain_commits_what_was_published_while_the_writer_slept
    bus = EventBus.new
    w = writer(bus: bus, poll_interval: 0.5).start
    sleep 0.01 until w.thread.status == "sleep" # first (empty) drain done

    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z", bus: bus)
    assert w.stop(timeout: 5)
    assert_equal 1, count("run")
  end

  # --- Story 5.3: gaps --------------------------------------------------------

  def test_evicted_records_are_one_gap_line_and_only_the_retained_ones_persist
    bus = EventBus.new(capacity: 3)
    w = writer(bus: bus, poll_interval: 0.05)
    lifecycle("K", bus: bus)
    lifecycle("L", bus: bus)

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    gaps = log.lines.grep(/\[History\] gap:/)
    assert_equal 1, gaps.size, log
    assert_includes gaps.first, "3 bus record(s)"
    assert_equal ["L"], rows("SELECT work_item FROM run").flatten
    assert_equal 3, count("run_event")
    refute w.degraded?, "an eviction is logged but does not degrade the writer"
  end

  # --- Story 5.3: retry -------------------------------------------------------

  def test_a_transient_failure_is_retried_once_and_the_batch_commits_once
    bus = EventBus.new
    sleeps, sleeper = recording_sleeper
    failing = FailingDb.new(@store.db, fail_on: /\AINSERT/)
    w = writer(FakeStore.new(failing), bus: bus, poll_interval: 0.05,
                                       sleeper: lambda { |seconds|
                                         sleeper.call(seconds)
                                         failing.fail_on = nil # the retry succeeds
                                       })
    lifecycle("K", bus: bus)

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    assert_equal [0.1], sleeps
    assert_equal 1, count("run")
    assert_equal 3, count("run_event")
    assert_equal 1, log.lines.grep(/\[History\].*failed to write/).size, log
    assert_empty log.lines.grep(/gap:/)
    refute w.degraded?
  end

  def test_exhausted_retries_log_a_gap_degrade_and_later_batches_still_commit
    bus = EventBus.new
    sleeps, sleeper = recording_sleeper
    failing = FailingDb.new(@store.db, fail_on: /\AINSERT/)
    w = writer(FakeStore.new(failing), bus: bus, poll_interval: 0.05, retry_count: 3, backoff_ceiling_ms: 2000,
                                       sleeper: sleeper)
    lifecycle("K", bus: bus)

    log = capture_log do
      w.start
      wait_until { w.degraded? }
      failing.fail_on = nil
      lifecycle("L", bus: bus)
      assert w.stop(timeout: 5)
    end

    assert_equal [0.1, 0.2, 0.4], sleeps
    history_errors = log.lines.grep(/\[History\]/)
    assert_equal 4, history_errors.grep(/failed to write a batch of 3 record\(s\)/).size, log
    gaps = history_errors.grep(/gap:/)
    assert_equal 1, gaps.size, log
    assert_includes gaps.first, "3 record(s)"
    assert_includes gaps.first, "seq 1..3"
    assert_includes gaps.first, "3 retries"
    assert w.degraded?, "degraded is sticky"
    assert_equal ["L"], rows("SELECT work_item FROM run").flatten
  end

  def test_the_backoff_is_capped_by_the_ceiling
    bus = EventBus.new
    sleeps, sleeper = recording_sleeper
    w = writer(FakeStore.new(FailingDb.new(@store.db, fail_on: /\AINSERT/)), bus: bus, poll_interval: 0.05,
                                                                               retry_count: 5, backoff_ceiling_ms: 300,
                                                                               sleeper: sleeper)
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z", bus: bus)

    w.start
    assert w.stop(timeout: 5)

    assert_equal [0.1, 0.2, 0.3, 0.3, 0.3], sleeps
    assert w.degraded?
  end

  def test_no_retries_is_one_attempt_then_a_gap
    bus = EventBus.new
    sleeps, sleeper = recording_sleeper
    w = writer(FakeStore.new(FailingDb.new(@store.db, fail_on: /\AINSERT/)), bus: bus, poll_interval: 0.05,
                                                                               retry_count: 0, sleeper: sleeper)
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z", bus: bus)

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    assert_empty sleeps
    assert_equal 1, log.lines.grep(/failed to write/).size, log
    assert_equal 1, log.lines.grep(/gap:/).size, log
    assert w.degraded?
  end

  def test_a_failing_batch_never_logs_field_values
    sentinel = "SENTINEL-7f3a9c"
    @store.db.execute("CREATE TRIGGER boom BEFORE INSERT ON run BEGIN SELECT RAISE(ABORT, 'boom'); END")
    bus = EventBus.new
    _sleeps, sleeper = recording_sleeper
    w = writer(bus: bus, poll_interval: 0.05, sleeper: sleeper)
    publish(RUNNER, 1, type: :picked_up, work_item: sentinel, at: "2026-09-19T10:00:00Z", bus: bus)
    publish(RUNNER, 2, type: :restart, actor: [sentinel], requested_at: "2026-09-19T10:00:00.000Z",
                       at: "2026-09-19T10:01:00Z", bus: bus)

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    assert_includes log, "boom"
    assert_equal 1, log.lines.grep(/gap:/).size, log
    refute_includes log, sentinel
    assert w.degraded?
  end

  # --- Story 5.3: recovery across master restarts ---------------------------

  def test_a_recovery_that_exhausts_retries_logs_a_gap_degrades_and_later_batches_still_commit
    bus = EventBus.new
    sleeps, sleeper = recording_sleeper
    failing = FailingDb.new(@store.db, fail_on: /\AUPDATE run SET incomplete = 1 WHERE finished_at/)
    w = writer(FakeStore.new(failing), bus: bus, poll_interval: 0.05, sleeper: sleeper)
    lifecycle("K", bus: bus)

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    assert_equal [0.1, 0.2, 0.4], sleeps
    gaps = log.lines.grep(/\[History\] gap:/)
    assert_equal 1, gaps.size, log
    assert_includes gaps.first, "unmarked"
    assert w.degraded?
    assert_equal ["K"], rows("SELECT work_item FROM run").flatten
  end

  def test_a_run_left_open_by_a_crashed_master_is_marked_incomplete_and_never_finished_later
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z")
    assert writer.write(records)
    assert_equal [[nil, 0]], rows("SELECT finished_at, incomplete FROM run")

    reopen_session
    bus = EventBus.new
    w = writer(bus: bus, poll_interval: 0.05)
    log = capture_log do
      w.start
      wait_until { rows("SELECT incomplete FROM run WHERE id = 1").flatten == [1] }
      publish(RUNNER, 1, type: :finished, work_item: "K", reason: :ok, attempt: 1, at: "2026-09-19T11:00:00Z",
                         bus: bus)
      assert w.stop(timeout: 5)
    end

    assert_equal [[1, "K", nil, nil, 1], [2, "K", "2026-09-19T11:00:00.000Z", "ok", 0]],
                 rows("SELECT id, work_item, finished_at, reason, incomplete FROM run ORDER BY id")
    assert_equal 1, log.lines.grep(/\[History\] marked 1 run\(s\)/).size, log
  end

  def test_two_sessions_on_the_same_db_coexist
    lifecycle("K")
    assert writer.write(records)

    reopen_session
    lifecycle("K")
    assert writer.write(records)

    assert_equal [[1, "ok", 0], [1, "ok", 0]], rows("SELECT generation, reason, incomplete FROM run ORDER BY id")
    assert_equal 1, count("supervised_entity")
    assert_equal 6, count("run_event")
    assert_equal [1, 2, 3, 1, 2, 3], rows("SELECT seq FROM run_event ORDER BY id").flatten
  end

  # --- Story 5.3: bounded shutdown and death --------------------------------

  def test_a_missed_deadline_reports_the_unflushed_count
    bus = EventBus.new
    w = writer(bus: bus, poll_interval: 0.05)
    w.start
    sleep 0.01 until w.thread.status == "sleep" # recovery and the first (empty) drain are done
    other = SQLite3::Database.new(@path)
    other.execute("BEGIN IMMEDIATE")
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z", bus: bus)
    wait_until { w.instance_variable_get(:@inflight) } # the writer is now waiting on the lock mid-batch
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z", bus: bus)

    refute w.stop(timeout: 0.1)
    assert_equal 2, w.unflushed_count, "1 in flight + 1 on the bus past it"

    other.execute("ROLLBACK")
    assert w.stop(timeout: 5)
    assert_equal 0, w.unflushed_count
  ensure
    other&.close
  end

  def test_a_writer_thread_that_dies_unasked_is_degraded
    w = writer(poll_interval: 0.05).start
    refute w.degraded?

    w.thread.kill.join

    assert w.degraded?
  end
end
