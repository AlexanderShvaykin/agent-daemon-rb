# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# AD-5 lazy-require isolation: loaded explicitly, never via `require "agent_daemon"`.
require "agent_daemon/supervisor/history/database"
require "sqlite3"

class TestSupervisorHistory < Minitest::Test
  include LogStubbing

  Database = AgentDaemon::Supervisor::History::Database
  Schema = AgentDaemon::Supervisor::History::Schema
  TABLES = %w[restart_action run run_event run_output supervised_entity].freeze

  def setup
    stub_null_logger!
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "history", "history.sqlite3")
  end

  def teardown
    @opened&.close
    locked = File.join(@dir, "locked")
    File.chmod(0o700, locked) if File.directory?(locked)
    FileUtils.remove_entry(@dir)
    restore_logger!
  end

  def open_store(path = @path, busy_timeout_ms: 1000, **kwargs)
    @opened = Database.open(path: path, busy_timeout_ms: busy_timeout_ms, **kwargs)
  end

  def mode(path) = File.stat(path).mode & 0o777

  def tables(db)
    db.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").flatten
  end

  def with_raw_db(path)
    db = SQLite3::Database.new(path)
    yield db
  ensure
    db&.close
  end

  # --- Default open ---------------------------------------------------------

  def test_open_creates_an_owner_only_store_at_the_latest_schema
    store = open_store

    assert_equal 0o700, mode(File.dirname(@path))
    assert_equal 0o600, mode(@path)
    %w[-wal -shm].each do |suffix|
      assert File.exist?("#{@path}#{suffix}"), "expected #{suffix} while the connection is open"
      assert_equal 0o600, mode("#{@path}#{suffix}")
    end
    assert_equal Schema::LATEST, store.schema_version
    assert_equal Schema::LATEST, store.db.get_first_value("PRAGMA user_version")
    assert_equal TABLES, tables(store.db)
    unique = store.db.execute("PRAGMA index_list(run_output)").select { |index| index[2] == 1 }
    assert_equal [%w[run_id seq]], unique.map { |index| store.db.execute("PRAGMA index_info(#{index[1]})").map { |c| c[2] } }
    assert_equal "wal", store.db.get_first_value("PRAGMA journal_mode")
    assert_equal 1000, store.busy_timeout_ms
    assert_equal 1, store.db.get_first_value("PRAGMA foreign_keys")
    assert_equal @path, store.path
  end

  def test_busy_timeout_follows_the_configured_value
    store = open_store(busy_timeout_ms: 2500)
    assert_equal 2500, store.busy_timeout_ms
  end

  # Behavioural: the handler really waits out a held lock (PRAGMA busy_timeout
  # reads 0 once busy_handler_timeout is set), and it releases the GVL while it
  # waits, so other Ruby threads keep running.
  def test_a_held_lock_is_waited_out_without_holding_the_gvl
    store = open_store(busy_timeout_ms: 300)
    with_raw_db(@path) do |other|
      other.execute("BEGIN IMMEDIATE")
      ticks = 0
      counter = Thread.new { loop { ticks += 1 } }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(SQLite3::BusyException) { store.db.execute("BEGIN IMMEDIATE") }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      counter.kill.join
      other.execute("ROLLBACK")

      assert_operator elapsed, :>=, 0.25
      assert_operator elapsed, :<, 1.5, "the configured 300 ms must bound the wait"
      assert_operator ticks, :>, 1000
    end
  end

  # --- Reopen ---------------------------------------------------------------

  def test_reopening_an_up_to_date_store_runs_no_ddl_and_keeps_rows
    store = open_store
    store.db.execute("INSERT INTO supervised_entity (entity_key, kind, first_seen_at) " \
                     "VALUES ('messenger:wf', 'messenger', '2026-09-19T00:00:00Z')")
    store.close

    # The same version with statements that would fail if executed: a reopen
    # that ran any DDL would raise here.
    poisoned = [[Schema::LATEST, ["THIS IS NOT SQL"]]]
    store = open_store(migrations: poisoned)

    assert_equal Schema::LATEST, store.schema_version
    assert_equal 1, store.db.get_first_value("SELECT COUNT(*) FROM supervised_entity")
  end

  # --- Existing files -------------------------------------------------------

  def test_a_broadly_readable_store_is_restricted_and_warned_about
    open_store.close
    File.chmod(0o644, @path)

    log = capture_log { open_store }

    assert_equal 0o600, mode(@path)
    assert_match(/\[History\].*#{Regexp.escape(@path)}.*0644/, log)
  end

  def test_a_read_only_store_is_made_writable_again
    open_store.close
    File.chmod(0o400, @path)

    log = capture_log { open_store }

    assert_equal 0o600, mode(@path)
    assert_match(/\[History\].*#{Regexp.escape(@path)}.*0400/, log)
  end

  def test_a_symlinked_store_is_refused
    target = File.join(@dir, "elsewhere.sqlite3")
    File.write(target, "")
    File.chmod(0o600, target)
    FileUtils.mkdir_p(File.dirname(@path))
    File.symlink(target, @path)

    error = assert_raises(Database::UnsafeStorageError) { open_store }
    assert_match(/not a regular file/, error.message)
    assert_equal 0, File.size(target), "the symlink target must not be touched"
  end

  def test_a_symlinked_sidecar_is_refused
    open_store.close
    File.symlink(File.join(@dir, "elsewhere"), "#{@path}-wal")

    assert_raises(Database::UnsafeStorageError) { open_store }
  end

  def test_a_store_owned_by_another_user_is_refused
    open_store.close
    original = File::Stat.instance_method(:uid)
    foreign = Process.euid + 1
    silence_warnings { File::Stat.define_method(:uid) { foreign } }
    begin
      error = assert_raises(Database::UnsafeStorageError) { open_store }
      assert_match(/owned by another user/, error.message)
    ensure
      silence_warnings { File::Stat.define_method(:uid, original) }
    end
  end

  # --- Schema versions ------------------------------------------------------

  def test_a_newer_schema_is_refused_and_never_downgraded
    FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
    with_raw_db(@path) { |db| db.execute("PRAGMA user_version = #{Schema::LATEST + 5}") }
    File.chmod(0o600, @path)

    assert_raises(Database::UnsupportedSchemaError) { open_store }
    with_raw_db(@path) do |db|
      assert_equal Schema::LATEST + 5, db.get_first_value("PRAGMA user_version")
      assert_empty tables(db)
    end
  end

  def test_a_failing_migration_leaves_version_and_tables_unchanged
    migrations = [
      [1, ["CREATE TABLE first_one (id INTEGER PRIMARY KEY)"]],
      [2, ["CREATE TABLE second_one (id INTEGER PRIMARY KEY)", "THIS IS NOT SQL"]]
    ]

    assert_raises(SQLite3::Exception) { open_store(migrations: migrations) }

    with_raw_db(@path) do |db|
      assert_equal 0, db.get_first_value("PRAGMA user_version")
      assert_empty tables(db)
    end
  end

  # Story 5.3: v2 adds run.incomplete; a v1 store's rows default to 0.
  def test_a_v1_store_migrates_to_v2_with_existing_runs_not_incomplete
    open_store(migrations: Schema::MIGRATIONS.first(1)).tap do |store|
      store.db.execute("INSERT INTO supervised_entity (entity_key, kind, first_seen_at) " \
                       "VALUES ('messenger:wf', 'messenger', '2026-09-19T00:00:00Z')")
      store.db.execute("INSERT INTO run (entity_id, generation) VALUES (1, 1)")
    end.close

    store = open_store(migrations: Schema::MIGRATIONS.first(2))

    assert_equal 2, store.schema_version
    assert_equal [0], store.db.execute("SELECT incomplete FROM run").flatten
    assert_raises(SQLite3::ConstraintException) { store.db.execute("UPDATE run SET incomplete = 2") }
  end

  # Story 5.4: v3 adds run_output and the run's output columns; a v2 store's
  # runs default to flags 0 and no summary, and reopening runs no DDL.
  def test_a_v2_store_migrates_to_v3_once
    open_store(migrations: Schema::MIGRATIONS.first(2)).tap do |store|
      store.db.execute("INSERT INTO supervised_entity (entity_key, kind, first_seen_at) " \
                       "VALUES ('messenger:wf', 'messenger', '2026-09-19T00:00:00Z')")
      store.db.execute("INSERT INTO run (entity_id, generation) VALUES (1, 1)")
    end.close

    store = open_store
    assert_equal 3, store.schema_version
    assert_equal [[0, 0, nil]], store.db.execute("SELECT output_truncated, output_incomplete, error_summary FROM run")
    store.db.execute("INSERT INTO run_output (run_id, seq, stream, text) VALUES (1, 1, 'stdout', 'x')")
    assert_raises(SQLite3::ConstraintException) do
      store.db.execute("INSERT INTO run_output (run_id, seq, stream, text) VALUES (1, 1, 'stderr', 'y')")
    end
    assert_raises(SQLite3::ConstraintException) do
      store.db.execute("INSERT INTO run_output (run_id, seq, stream, text) VALUES (1, 2, 'stdin', 'y')")
    end
    store.close

    store = open_store(migrations: Schema::MIGRATIONS.first(2) + [[3, ["THIS IS NOT SQL"]]])
    assert_equal 3, store.schema_version
    assert_equal 1, store.db.get_first_value("SELECT COUNT(*) FROM run_output")
  end

  def test_pending_migrations_apply_on_top_of_an_older_version
    open_store(migrations: [[1, ["CREATE TABLE first_one (id INTEGER PRIMARY KEY)"]]]).close

    store = open_store(migrations: [
      [1, ["THIS IS NOT SQL"]],
      [2, ["CREATE TABLE second_one (id INTEGER PRIMARY KEY)"]]
    ])

    assert_equal 2, store.schema_version
    assert_equal %w[first_one second_one], tables(store.db)
  end

  # --- Unopenable paths -----------------------------------------------------

  def test_a_directory_at_the_database_path_is_refused
    FileUtils.mkdir_p(@path)

    assert_raises(Database::UnsafeStorageError) { open_store }
  end

  def test_an_unwritable_parent_raises_a_system_call_error
    skip "root ignores directory permissions" if Process.euid.zero?

    locked = File.join(@dir, "locked")
    Dir.mkdir(locked, 0o500)

    assert_raises(SystemCallError) { open_store(File.join(locked, "history", "history.sqlite3")) }
  end

  def test_an_existing_directory_keeps_its_own_mode
    FileUtils.mkdir_p(File.dirname(@path))
    File.chmod(0o750, File.dirname(@path))

    open_store

    assert_equal 0o750, mode(File.dirname(@path))
    assert_equal 0o600, mode(@path)
  end
end
