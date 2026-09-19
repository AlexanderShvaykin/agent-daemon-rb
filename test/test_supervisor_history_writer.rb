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
require "agent_daemon/supervisor/output_pipeline"
require "agent_daemon/supervisor/redactor"
require "sqlite3"

class TestSupervisorHistoryWriter < Minitest::Test
  include LogStubbing

  Database = AgentDaemon::Supervisor::History::Database
  Writer = AgentDaemon::Supervisor::History::Writer
  EventBus = AgentDaemon::Supervisor::EventBus
  GenerationStamp = AgentDaemon::Supervisor::GenerationStamp
  Rostered = AgentDaemon::Supervisor::Fleet::Rostered
  RunnerIdentity = AgentDaemon::Supervisor::RunnerIdentity
  OutputPipeline = AgentDaemon::Supervisor::OutputPipeline
  Redactor = AgentDaemon::Supervisor::Redactor

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

  # Story 5.6: the clock is pinned, so the startup prune never deletes the
  # 2026-09-19T10:… fixtures however far the real date moves on.
  NOW = Time.utc(2026, 9, 19, 12)

  def writer(store = @store, bus: EventBus.new, clock: -> { NOW }, **kwargs)
    @writer = Writer.new(database: store, event_bus: bus, roster: ROSTER, clock: clock, **kwargs)
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

  def test_a_lost_batch_reports_writer_degraded_in_status_but_not_prune_degraded
    bus = EventBus.new
    _sleeps, sleeper = recording_sleeper
    failing = FailingDb.new(@store.db, fail_on: /\AINSERT/)
    w = writer(FakeStore.new(failing), bus: bus, poll_interval: 0.05, retry_count: 1, sleeper: sleeper)
    lifecycle("K", bus: bus)

    capture_log do
      w.start
      wait_until { w.degraded? }
      assert w.stop(timeout: 5)
    end

    assert w.status.writer_degraded
    refute w.status.prune_degraded
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

  # --- Story 5.4: output and error summaries --------------------------------

  def pipeline(secrets = [])
    @pipeline = OutputPipeline.new(redactor: Redactor.new(secrets))
  end

  def output_writer(store = @store, **kwargs)
    writer(store, output_pipeline: @pipeline || pipeline, **kwargs)
  end

  def queued(writer)
    writer.instance_variable_get(:@output_queue).drain
  end

  def say(text, stream: :stdout, generation: 1)
    @pipeline.append(RUNNER, stream, "#{text}\n", generation)
  end

  # Producer order: started (bus), begin_run, lines, end_run, finished (bus).
  def output_run(key, lines, reason: :ok, attempt: 1, run_id: 1, generation: 1, bus: @source)
    publish(RUNNER, generation, type: :picked_up, work_item: key, at: "2026-09-19T10:00:00Z", bus: bus)
    publish(RUNNER, generation, type: :started, work_item: key, attempt: attempt, at: "2026-09-19T10:00:01Z", bus: bus)
    @pipeline.begin_run(RUNNER, run_id, generation)
    lines.each { |stream, text| say(text, stream: stream, generation: generation) }
    @pipeline.end_run(RUNNER, run_id, reason, generation)
    publish(RUNNER, generation, type: :finished, work_item: key, reason: reason, attempt: attempt,
                                at: "2026-09-19T10:00:05Z", bus: bus)
  end

  def output_rows
    rows("SELECT seq, stream, text FROM run_output ORDER BY run_id, seq")
  end

  def output_flags
    rows("SELECT output_truncated, output_incomplete, error_summary FROM run ORDER BY id")
  end

  def test_schema_v3_adds_run_output_and_the_run_output_columns
    run_columns = rows("PRAGMA table_info(run)").map { |column| column[1] }
    assert_equal %w[output_truncated output_incomplete error_summary], run_columns.last(3)
    assert_equal %w[id run_id seq stream text], rows("PRAGMA table_info(run_output)").map { |column| column[1] }
  end

  def test_a_run_with_output_stores_its_lines_in_order
    w = output_writer
    output_run("K", [[:stdout, "out1"], [:stderr, "err1"], [:stdout, "out2"]])

    assert w.write(records, queued(w))

    assert_equal [[1, "stdout", "out1"], [2, "stderr", "err1"], [3, "stdout", "out2"]], output_rows
    assert_equal [[0, 0, nil]], output_flags
  end

  def test_output_is_persisted_incrementally_while_the_run_is_open
    w = output_writer
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z")
    @pipeline.begin_run(RUNNER, 1, 1)
    say("one")
    say("two")

    assert w.write(records, queued(w))

    reader = SQLite3::Database.new(@path)
    assert_equal [%w[one], %w[two]], reader.execute("SELECT text FROM run_output ORDER BY seq")
    assert_equal [nil], reader.execute("SELECT finished_at FROM run").flatten

    @pipeline.end_run(RUNNER, 1, :ok, 1)
    publish(RUNNER, 1, type: :finished, work_item: "K", reason: :ok, attempt: 1, at: "2026-09-19T10:00:05Z")
    assert w.write(records, queued(w))
    assert_equal 2, reader.get_first_value("SELECT COUNT(*) FROM run_output")
  ensure
    reader&.close
  end

  def test_a_failed_run_gets_a_json_error_summary
    w = output_writer
    output_run("K", [[:stdout, "out1"], [:stderr, "err1"], [:stdout, "out2"]], reason: :failed, attempt: 2)

    assert w.write(records, queued(w))

    summary = rows("SELECT error_summary FROM run").flatten.first
    assert_equal({ "reason" => "failed", "attempt" => 2, "last_stderr" => "err1" }, JSON.parse(summary))
    assert_includes output_rows, [2, "stderr", "err1"]
  end

  def test_a_failed_run_without_stderr_has_a_null_last_stderr
    w = output_writer
    output_run("K", [[:stdout, "out1"]], reason: :failed)

    assert w.write(records, queued(w))

    assert_equal({ "reason" => "failed", "attempt" => 1, "last_stderr" => nil },
                 JSON.parse(rows("SELECT error_summary FROM run").flatten.first))
  end

  def test_terminal_drain_lines_commit_with_the_completion_never_after
    failing = FailingDb.new(@store.db, fail_on: nil)
    w = output_writer(FakeStore.new(failing))
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z")
    @pipeline.begin_run(RUNNER, 1, 1)
    say("first")
    assert w.write(records, queued(w))

    @pipeline.append(RUNNER, :stdout, "last words", 1) # no newline: end_run drains it
    @pipeline.end_run(RUNNER, 1, :timeout, 1)
    publish(RUNNER, 1, type: :finished, work_item: "K", reason: :timeout, attempt: 1, at: "2026-09-19T10:00:05Z")
    batch = records
    output = queued(w)
    failing.fail_on = /\AUPDATE run SET finished_at/
    refute w.write(batch, output)
    assert_equal %w[first], rows("SELECT text FROM run_output").flatten, "the line must not commit without finished"

    failing.fail_on = nil
    assert w.write(batch, output)
    assert_equal %w[first last\ words], rows("SELECT text FROM run_output ORDER BY seq").flatten
    assert_equal [["timeout", nil]], rows("SELECT reason, error_summary FROM run")
  end

  def test_a_run_without_output_stores_no_rows
    w = output_writer
    output_run("K", [])

    assert w.write(records, queued(w))

    assert_equal 0, count("run_output")
    assert_equal [[0, 0, nil]], output_flags
  end

  def test_a_known_secret_never_reaches_the_database_files
    pipeline(["s3cr3t"])
    w = output_writer
    output_run("K", [[:stdout, "token=s3cr3t"]])

    assert w.write(records, queued(w))

    assert_equal ["token=[REDACTED]"], rows("SELECT text FROM run_output").flatten
    ["", "-wal", "-shm"].each do |suffix|
      path = "#{@path}#{suffix}"
      refute_includes File.binread(path), "s3cr3t" if File.exist?(path)
    end
  end

  def test_a_run_over_the_cap_keeps_its_newest_rows_and_is_truncated
    w = output_writer(output_buffer_bytes: 20)
    output_run("K", (1..4).map { |i| [:stdout, "line-00#{i}"] }) # 8 bytes each

    assert w.write(records, queued(w))

    assert_equal [3, 4], rows("SELECT seq FROM run_output ORDER BY seq").flatten
    assert_equal [[1, 0, nil]], output_flags
  end

  def test_one_line_over_the_cap_is_kept_whole
    w = output_writer(output_buffer_bytes: 20)
    output_run("K", [[:stdout, "x" * 50]])

    assert w.write(records, queued(w))

    assert_equal ["x" * 50], rows("SELECT text FROM run_output").flatten
    assert_equal [[0, 0, nil]], output_flags
  end

  def test_lines_evicted_from_the_queue_mark_the_capture_incomplete
    w = output_writer(output_buffer_bytes: 20) # queue budget 60 with the 3-entity roster
    output_run("K", (1..10).map { |i| [:stdout, format("line%04d", i)] }) # 8 bytes each

    assert w.write(records, queued(w))

    assert_equal [9, 10], rows("SELECT seq FROM run_output ORDER BY seq").flatten
    assert_equal [[1, 1, nil]], output_flags
  end

  def test_a_retried_output_batch_stores_each_line_once
    bus = EventBus.new
    failing = FailingDb.new(@store.db, fail_on: /\AINSERT OR IGNORE INTO run_output/)
    w = output_writer(FakeStore.new(failing), bus: bus, poll_interval: 0.05,
                                              sleeper: ->(_seconds) { failing.fail_on = nil })
    output_run("K", [[:stdout, "a"], [:stderr, "b"], [:stdout, "c"]], bus: bus)

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    assert_equal [1, 2, 3], rows("SELECT seq FROM run_output ORDER BY seq").flatten
    assert_equal 1, log.lines.grep(/\[History\].*failed to write/).size, log
    assert_empty log.lines.grep(/gap:/)
  end

  def test_output_that_arrives_before_its_started_is_read_waits_one_batch
    w = output_writer
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    first = records
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z")
    @pipeline.begin_run(RUNNER, 1, 1)
    say("early")

    assert w.write(first, queued(w))
    assert_equal 0, count("run_output")

    assert w.write(records, queued(w))
    assert_equal ["early"], rows("SELECT text FROM run_output").flatten
  end

  def test_output_of_a_run_whose_start_was_evicted_is_stored_on_the_run_finished_opened
    bus = EventBus.new(capacity: 1)
    w = output_writer(bus: bus, poll_interval: 0.05)
    output_run("K", [[:stdout, "out1"], [:stderr, "err1"]], reason: :failed, bus: bus)

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    assert_equal [["2026-09-19T10:00:05.000Z", "failed"]], rows("SELECT started_at, reason FROM run")
    assert_equal [[1, "stdout", "out1"], [2, "stderr", "err1"]], output_rows
    assert_equal({ "reason" => "failed", "attempt" => 1, "last_stderr" => "err1" },
                 JSON.parse(rows("SELECT error_summary FROM run").flatten.first))
    gaps = log.lines.grep(/\[History\] gap:/)
    assert_equal 1, gaps.size, log
    assert_includes gaps.first, "bus record(s) evicted"
  end

  def test_an_orphan_run_start_is_dropped_after_two_batches_and_a_later_run_binds_its_own
    w = output_writer
    log = capture_log do
      @pipeline.begin_run(RUNNER, 1, 1)
      say("nobody's")
      assert w.write([], queued(w))
      assert w.write([], queued(w))

      output_run("L", [[:stdout, "mine"]], run_id: 2)
      assert w.write(records, queued(w))
    end

    assert_equal [%w[L mine]], rows("SELECT work_item, text FROM run JOIN run_output ON run_output.run_id = run.id")
    gaps = log.lines.grep(/\[History\] gap:/)
    assert_equal 1, gaps.size, log
    assert_includes gaps.first, "1 output line(s)"
    refute_includes log, "nobody"
  end

  def test_a_writer_waiting_on_the_lock_never_makes_the_pipeline_wait
    bus = EventBus.new
    w = output_writer(bus: bus, poll_interval: 0.05)
    other = SQLite3::Database.new(@path)
    other.execute("BEGIN IMMEDIATE")
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z", bus: bus)
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z", bus: bus)
    @pipeline.begin_run(RUNNER, 1, 1)
    w.start
    sleep 0.2 # the writer is now waiting on the lock

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    1000.times { |i| say("line #{i}") }
    appending = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator appending, :<, 1.0, "appending 1,000 lines must not wait on SQLite"
    assert_equal 0, other.get_first_value("SELECT COUNT(*) FROM run_output"), "the writer was still waiting"
    other.execute("ROLLBACK")
    assert w.stop(timeout: 5)
    assert_equal 1000, count("run_output")
  ensure
    other&.close
  end

  def test_failing_output_writes_degrade_history_and_the_live_tail_keeps_its_lines
    bus = EventBus.new
    tail = []
    pipeline.subscribe(->(record) { tail << record.text })
    w = output_writer(FakeStore.new(FailingDb.new(@store.db, fail_on: /\AINSERT OR IGNORE INTO run_output/)),
                      bus: bus, poll_interval: 0.05, retry_count: 0)
    output_run("K", [[:stdout, "a"], [:stdout, "b"]], bus: bus)

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    assert_equal %w[a b], tail
    assert w.degraded?
    gaps = log.lines.grep(/\[History\] gap:/)
    assert_equal 1, gaps.size, log
    assert_includes gaps.first, "output entr(ies)"
    assert_equal 0, w.unflushed_count
  end

  def test_unflushed_count_includes_pending_and_queued_output
    w = output_writer
    @pipeline.begin_run(RUNNER, 1, 1)
    say("waiting")
    assert w.write([], queued(w)) # run_started cannot bind yet: 2 entries stay pending
    say("queued")

    assert_equal 3, w.unflushed_count
  end

  def test_a_lost_batch_marks_the_bound_run_incomplete_once_a_later_batch_commits
    failing = FailingDb.new(@store.db, fail_on: nil)
    w = output_writer(FakeStore.new(failing), retry_count: 0)
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z")
    @pipeline.begin_run(RUNNER, 1, 1)
    say("one")
    assert w.write(records, queued(w))

    say("two")
    failing.fail_on = /\AINSERT OR IGNORE INTO run_output/
    output = queued(w)
    refute w.write([], output)
    w.send(:lose_batch, [], output)
    failing.fail_on = nil

    say("three")
    @pipeline.end_run(RUNNER, 1, :ok, 1)
    publish(RUNNER, 1, type: :finished, work_item: "K", reason: :ok, attempt: 1, at: "2026-09-19T10:00:05Z")
    capture_log { assert w.write(records, queued(w)) }

    assert_equal [1, 3], rows("SELECT seq FROM run_output ORDER BY seq").flatten
    assert_equal [[0, 1, nil]], output_flags
  end

  def test_output_still_pending_at_a_stop_is_one_gap_line
    bus = EventBus.new
    w = output_writer(bus: bus, poll_interval: 0.05)
    @pipeline.begin_run(RUNNER, 1, 1) # its started never arrives
    say("unclaimed")

    log = capture_log do
      w.start
      assert w.stop(timeout: 5)
    end

    gaps = log.lines.grep(/\[History\] gap:.*at stop/)
    assert_equal 1, gaps.size, log
    assert_includes gaps.first, "2 pending output entr(ies)"
    refute_includes log, "unclaimed"
  end

  def test_two_generations_reusing_pipeline_run_one_keep_their_own_lines
    w = output_writer
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: "2026-09-19T10:00:00Z")
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: "2026-09-19T10:00:01Z")
    @pipeline.begin_run(RUNNER, 1, 1)
    say("gen one", generation: 1)
    @pipeline.end_run(RUNNER, 1, :killed, 1) # crashed: no finished on the bus

    output_run("K", [[:stdout, "gen two"]], run_id: 1, generation: 2)
    assert w.write(records, queued(w))

    assert_equal [[1, "gen one"], [2, "gen two"]],
                 rows("SELECT generation, text FROM run JOIN run_output ON run_output.run_id = run.id ORDER BY run.id")
  end

  # --- Story 5.6: retention ---------------------------------------------------

  def days_ago(days, from: NOW)
    (from - (days * 86_400)).iso8601(3)
  end

  def seed_entity(key = "runner:wf:a")
    kind = key.split(":").first
    @store.db.execute("INSERT INTO supervised_entity (entity_key, kind, first_seen_at) VALUES (?, ?, ?)",
                      [key, kind, days_ago(100)])
    @store.db.last_insert_row_id
  end

  def seed_run(entity_id, started_at:, finished_at: nil, incomplete: 0, events: 0, output: 0)
    @store.db.execute("INSERT INTO run (entity_id, generation, started_at, finished_at, reason, incomplete) " \
                      "VALUES (?, 1, ?, ?, ?, ?)", [entity_id, started_at, finished_at, finished_at && "ok", incomplete])
    id = @store.db.last_insert_row_id
    seed_children(id, events: events, output: output)
    id
  end

  def seed_children(run_id, events: 0, output: 0)
    events.times do |n|
      @store.db.execute("INSERT INTO run_event (run_id, seq, event, occurred_at) VALUES (?, ?, 'started', ?)",
                        [run_id, n + 1, days_ago(40)])
    end
    output.times do |n|
      @store.db.execute("INSERT INTO run_output (run_id, seq, stream, text) VALUES (?, ?, 'stdout', ?)",
                        [run_id, n + 1, "line #{n}"])
    end
  end

  def seed_action(entity_id, requested_at)
    @store.db.execute("INSERT INTO restart_action (entity_id, actors, requested_at) VALUES (?, '[]', ?)",
                      [entity_id, requested_at])
    @store.db.last_insert_row_id
  end

  # One run_loop iteration without the thread: drain, then one prune step.
  def iterate(w)
    w.send(:drain)
    w.send(:prune_step)
  end

  # Steps until the cycle in progress (or the one that is due) ends.
  def prune_cycle(w)
    loop do
      w.send(:prune_step)
      break if w.instance_variable_get(:@prune).nil?
    end
  end

  def ids(table)
    rows("SELECT id FROM #{table} ORDER BY id").flatten
  end

  def run_children(run_id)
    [@store.db.get_first_value("SELECT COUNT(*) FROM run_event WHERE run_id = ?", [run_id]),
     @store.db.get_first_value("SELECT COUNT(*) FROM run_output WHERE run_id = ?", [run_id])]
  end

  def test_an_expired_run_goes_with_its_events_and_output_and_the_boundary_is_strict
    entity = seed_entity
    expired = seed_run(entity, started_at: days_ago(31), finished_at: days_ago(31), events: 2, output: 3)
    boundary = seed_run(entity, started_at: days_ago(31), finished_at: days_ago(30), events: 1, output: 1)
    recent = seed_run(entity, started_at: days_ago(29), finished_at: days_ago(29), events: 1)

    log = capture_log { prune_cycle(writer) }

    assert_equal [boundary, recent], ids("run")
    assert_equal [0, 0], run_children(expired)
    assert_equal [1, 1], run_children(boundary)
    assert_equal 1, log.lines.grep(/\[History\] pruned 1 run\(s\), 0 restart action\(s\), 0 entit\(ies\) older than #{Regexp.escape(days_ago(30))}/).size, log
  end

  def test_a_crash_incomplete_run_is_pruned_by_its_start
    entity = seed_entity
    seed_run(entity, started_at: days_ago(40), incomplete: 1, output: 1)
    kept = seed_run(entity, started_at: days_ago(10), incomplete: 1)

    prune_cycle(writer)

    assert_equal [kept], ids("run")
    assert_equal 0, count("run_output")
  end

  def test_the_writers_active_open_run_is_kept_however_old
    w = writer
    publish(RUNNER, 1, type: :picked_up, work_item: "K", at: days_ago(40))
    publish(RUNNER, 1, type: :started, work_item: "K", attempt: 1, at: days_ago(40))
    assert w.write(records)
    open_run = ids("run").first
    seed_children(open_run, output: 2)

    prune_cycle(w)

    assert_equal [open_run], ids("run")
    assert_equal [2, 2], run_children(open_run)
  end

  def test_restart_actions_are_pruned_per_row_by_request_time
    entity = seed_entity
    seed_action(entity, days_ago(40))
    newer = seed_action(entity, days_ago(1))

    prune_cycle(writer)

    assert_equal [newer], ids("restart_action")
  end

  def test_an_orphaned_entity_goes_only_when_the_roster_does_not_name_it
    rostered = seed_entity("runner:wf:a")
    seed_entity("runner:wf:gone")
    referenced = seed_entity("runner:wf:old")
    seed_action(referenced, days_ago(1))
    with_run = seed_entity("runner:wf:older")
    seed_run(with_run, started_at: days_ago(1), finished_at: days_ago(1))

    prune_cycle(writer)

    assert_equal [rostered, referenced, with_run], ids("supervised_entity")
  end

  def test_an_entity_whose_last_run_expires_goes_in_the_same_cycle
    gone = seed_entity("runner:wf:gone")
    seed_run(gone, started_at: days_ago(40), finished_at: days_ago(40))
    seed_action(gone, days_ago(40))

    prune_cycle(writer)

    assert_equal [0, 0, 0], [count("run"), count("restart_action"), count("supervised_entity")]
  end

  def test_each_batch_is_one_transaction_and_drains_commit_between_them
    entity = seed_entity
    7.times { seed_run(entity, started_at: days_ago(40), finished_at: days_ago(40)) }
    bus = EventBus.new
    w = writer(bus: bus, prune_batch_size: 3)
    begins = []
    @store.db.trace { |sql| begins << sql if sql.match?(/\Abegin/i) }

    iterate(w)
    assert_equal 4, count("run")
    lifecycle("fresh", bus: bus)
    iterate(w)
    assert_equal 5 - 3, count("run"), "the drain committed the fresh run, then one batch of 3 went"
    assert_equal ["fresh"], rows("SELECT work_item FROM run WHERE work_item IS NOT NULL").flatten
    iterate(w)
    assert_equal ["fresh"], rows("SELECT work_item FROM run").flatten
    2.times { iterate(w) } # restart actions, then entities
    assert_nil w.instance_variable_get(:@prune)
    assert_equal 6, begins.size, "3 run batches + 1 drain + 1 per remaining phase"
  ensure
    @store.db.trace(nil)
  end

  def test_a_failed_batch_rolls_back_whole_degrades_prune_and_a_later_cycle_recovers
    entity = seed_entity
    runs = Array.new(4) { seed_run(entity, started_at: days_ago(40), finished_at: days_ago(40), events: 1, output: 1) }
    failing = FailingDb.new(@store.db, fail_on: nil)
    w = writer(FakeStore.new(failing), prune_batch_size: 2, prune_interval_seconds: 0)

    log = capture_log do
      w.send(:prune_step)
      failing.fail_on = /\ADELETE FROM run WHERE/
      w.send(:prune_step)
    end

    assert_equal runs.last(2), ids("run")
    runs.last(2).each { |run| assert_equal [1, 1], run_children(run) }
    assert_equal 2, count("run_event")
    failures = log.lines.grep(/\[History\] prune failed:/)
    assert_equal ["[History] prune failed: SQLite3::SQLException: injected failure\n"], failures
    assert w.status.prune_degraded
    refute w.status.writer_degraded, "a prune failure is not a lost write batch"
    assert_nil w.status.last_pruned_at
    refute @store.db.transaction_active?

    failing.fail_on = nil
    prune_cycle(w)

    assert_empty ids("run")
    assert_equal 0, count("run_event")
    refute w.status.prune_degraded
    assert_equal NOW.iso8601(3), w.status.last_pruned_at
  end

  def test_the_cutoff_is_captured_once_per_cycle
    entity = seed_entity
    7.times { seed_run(entity, started_at: days_ago(35), finished_at: days_ago(35)) }
    kept = seed_run(entity, started_at: days_ago(25), finished_at: days_ago(25))
    calls = 0
    clock = lambda do
      calls += 1
      NOW + ((calls - 1) * 10 * 86_400)
    end

    prune_cycle(writer(clock: clock, prune_batch_size: 3))

    assert_equal 1, calls
    assert_equal [kept], ids("run")
  end

  def test_a_second_cycle_runs_on_schedule_without_a_restart
    entity = seed_entity
    seed_run(entity, started_at: days_ago(15), finished_at: days_ago(15))
    later = NOW + (20 * 86_400)
    calls = 0
    clock = lambda do
      calls += 1
      calls == 1 ? NOW : later
    end
    w = writer(clock: clock, poll_interval: 0.02, prune_interval_seconds: 0.2).start

    wait_until { w.status.last_pruned_at == later.iso8601(3) }
    assert w.stop(timeout: 5)

    assert_equal 0, count("run")
  end

  def test_a_stop_ends_a_cycle_between_batches
    entity = seed_entity
    5.times { seed_run(entity, started_at: days_ago(40), finished_at: days_ago(40)) }
    w = writer(prune_batch_size: 2)
    w.send(:prune_step)
    assert_equal 3, count("run")

    assert w.stop(timeout: 1)
    w.send(:prune_step)

    assert_equal 3, count("run")
    assert_nil w.status.last_pruned_at
    refute w.status.prune_degraded
  end

  def test_a_writer_mid_cycle_stops_within_its_timeout
    entity = seed_entity
    30.times { seed_run(entity, started_at: days_ago(40), finished_at: days_ago(40)) }
    w = writer(poll_interval: 0.05, prune_batch_size: 1).start
    wait_until { prune_running?(w) }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert w.stop(timeout: 5)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    assert_nil w.status.last_pruned_at, "an abandoned cycle is not a success"
    refute w.status.prune_degraded, "nor a failure"
  end

  def prune_running?(writer)
    !writer.instance_variable_get(:@prune).nil?
  end

  def test_a_cycle_never_vacuums
    entity = seed_entity
    3.times { seed_run(entity, started_at: days_ago(40), finished_at: days_ago(40), events: 1, output: 1) }
    statements = []
    @store.db.trace { |sql| statements << sql }

    prune_cycle(writer)

    refute_empty statements.grep(/\ADELETE/)
    assert_empty statements.grep(/vacuum/i)
  ensure
    @store.db.trace(nil)
  end

  def test_status_before_and_after_a_cycle
    w = writer(retention_days: 12)
    before = w.status

    assert_predicate before, :frozen?
    assert_equal [12, nil, false, false], before.to_a

    prune_cycle(w)

    assert_equal [12, NOW.iso8601(3), false, false], w.status.to_a
  end

  def test_a_cycle_that_deletes_nothing_logs_nothing
    log = capture_log { prune_cycle(writer) }

    assert_empty log
  end
end
