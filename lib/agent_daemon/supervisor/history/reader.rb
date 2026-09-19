# frozen_string_literal: true

module AgentDaemon
  module Supervisor
    module History
      # The console's only path into the history store (Story 5.5): a second,
      # query-only SQLite connection, separate from the writer's. WAL gives
      # this reader a snapshot without blocking the single writer (AD-6), and
      # sharing the writer's connection would put console reads inside the
      # writer's transactions. `PRAGMA query_only` makes "never writes"
      # enforced rather than stated.
      #
      # Construction does no IO. The connection opens on first use, under the
      # reader's own mutex, which every query also holds (Puma serves requests
      # on several threads). Any query failure closes and drops the
      # connection, so the next call reopens it, and re-raises to the caller.
      #
      # The file is opened READWRITE without CREATE: a missing store raises and
      # is never created here. READWRITE, not READONLY, because a WAL reader
      # needs the -shm file. The reader never migrates and never touches the
      # writer's Database.
      #
      # AD-5: `sqlite3` is required lazily in #connect, never at file top level.
      class Reader
        Page = Struct.new(:runs, :next_cursor)
        Entity = Struct.new(:entity_key, :kind, :workflow, :runner, :first_seen_at)
        RestartAction = Struct.new(:id, :source_generation, :target_generation, :actors, :requested_at,
                                   :completed_at)
        Run = Struct.new(:id, :entity_key, :kind, :workflow, :runner, :generation, :work_item, :attempt,
                         :started_at, :finished_at, :reason, :result, :output_truncated, :output_incomplete,
                         :error_summary, :events, :output)
        Event = Struct.new(:seq, :event, :reason, :occurred_at)
        # `stream` is a Symbol (:stdout/:stderr), the shape the console's
        # terminal line renderer reads.
        OutputLine = Struct.new(:seq, :stream, :text)

        RUN_COLUMNS = "r.id, e.entity_key, e.kind, e.workflow, e.runner, r.generation, r.work_item, r.attempt, " \
                      "r.started_at, r.finished_at, r.reason, r.incomplete, r.output_truncated, " \
                      "r.output_incomplete, r.error_summary"
        RUN_FROM = "FROM run r JOIN supervised_entity e ON e.id = r.entity_id"

        attr_reader :page_size

        def initialize(path:, busy_timeout_ms:, page_size:)
          @path = path
          @busy_timeout_ms = busy_timeout_ms
          @page_size = page_size
          @mutex = Mutex.new
          @db = nil
        end

        # Newest first, `(started_at DESC, id DESC)`. `cursor` is the last
        # shown `[started_at, id]` pair; the page holds the runs strictly
        # after it, so runs inserted since the previous page never repeat.
        # One extra row is read only to decide whether there is a next page.
        def runs(cursor: nil, entity_key: nil)
          conditions = []
          binds = []
          if entity_key
            conditions << "e.entity_key = ?"
            binds << entity_key
          end
          if cursor
            started_at, id = cursor
            conditions << "(r.started_at < ? OR (r.started_at = ? AND r.id < ?))"
            binds.push(started_at, started_at, id)
          end
          where = conditions.empty? ? "" : " WHERE #{conditions.join(' AND ')}"
          sql = "SELECT #{RUN_COLUMNS} #{RUN_FROM}#{where} ORDER BY r.started_at DESC, r.id DESC LIMIT ?"

          rows = query { |db| db.execute(sql, binds + [@page_size + 1]) }
          shown = rows.first(@page_size).map { |row| build_run(row) }
          next_cursor = rows.size > @page_size ? [shown.last.started_at, shown.last.id].freeze : nil
          Page.new(shown.freeze, next_cursor).freeze
        end

        def entity(entity_key)
          row = query do |db|
            db.execute("SELECT entity_key, kind, workflow, runner, first_seen_at FROM supervised_entity " \
                       "WHERE entity_key = ?", [entity_key]).first
          end
          row && Entity.new(*row).freeze
        end

        # The newest page_size actions, and whether older ones exist. `actors`
        # is the stored JSON array text, verbatim.
        def restart_actions(entity_key)
          rows = query do |db|
            db.execute("SELECT a.id, a.source_generation, a.target_generation, a.actors, a.requested_at, " \
                       "a.completed_at FROM restart_action a JOIN supervised_entity e ON e.id = a.entity_id " \
                       "WHERE e.entity_key = ? ORDER BY a.requested_at DESC, a.id DESC LIMIT ?",
                       [entity_key, @page_size + 1])
          end
          actions = rows.first(@page_size).map { |row| RestartAction.new(*row).freeze }
          [actions.freeze, rows.size > @page_size]
        end

        # One read transaction, so the run, its events and its output come
        # from the same snapshot.
        def run(id)
          query do |db|
            db.transaction(:deferred) do
              row = db.execute("SELECT #{RUN_COLUMNS} #{RUN_FROM} WHERE r.id = ?", [id]).first
              next nil unless row

              events = db.execute("SELECT seq, event, reason, occurred_at FROM run_event WHERE run_id = ? " \
                                  "ORDER BY occurred_at, id", [id]).map { |event| Event.new(*event).freeze }
              output = db.execute("SELECT seq, stream, text FROM run_output WHERE run_id = ? ORDER BY seq", [id])
                         .map { |seq, stream, text| OutputLine.new(seq, stream.to_sym, text).freeze }
              build_run(row, events: events.freeze, output: output.freeze)
            end
          end
        end

        def close
          @mutex.synchronize { drop }
        end

        private

        def query
          @mutex.synchronize do
            yield(@db ||= connect)
          rescue StandardError
            drop
            raise
          end
        end

        def connect
          require "sqlite3"
          db = SQLite3::Database.new(@path, flags: SQLite3::Constants::Open::READWRITE)
          begin
            # Never busy_timeout=: it sleeps holding the GVL (database.rb).
            db.busy_handler_timeout = @busy_timeout_ms
            db.execute("PRAGMA query_only = ON")
            db
          rescue Exception # close on ANY failure, then re-raise it untouched
            db.close unless db.closed?
            raise
          end
        end

        def drop
          db = @db
          @db = nil
          db.close if db && !db.closed?
        rescue StandardError
          nil
        end

        # `result` is derived here, once: the stored reason; else a run no
        # live writer will finish is "incomplete"; else the live writer still
        # holds it open, "running".
        def build_run(row, events: nil, output: nil)
          id, entity_key, kind, workflow, runner, generation, work_item, attempt, started_at, finished_at,
            reason, incomplete, truncated, output_incomplete, error_summary = row
          result = reason || (incomplete == 1 ? "incomplete" : "running")
          Run.new(id, entity_key, kind, workflow, runner, generation, work_item, attempt, started_at, finished_at,
                  reason, result, truncated == 1, output_incomplete == 1, error_summary, events, output).freeze
        end
      end
    end
  end
end
