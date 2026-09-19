# frozen_string_literal: true

module AgentDaemon
  module Supervisor
    module History
      # Versioned history schema (Story 5.1). Each entry is [version, [sql, ...]]
      # in ascending order; PRAGMA user_version records the last one applied.
      # Append new versions, never edit a shipped one. Timestamps are ISO-8601
      # UTC TEXT.
      module Schema
        MIGRATIONS = [
          [1, [
            <<~SQL,
              CREATE TABLE supervised_entity (id INTEGER PRIMARY KEY, entity_key TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL CHECK (kind IN ('runner','messenger','reactor')), workflow TEXT, runner TEXT,
                first_seen_at TEXT NOT NULL)
            SQL
            <<~SQL,
              CREATE TABLE run (id INTEGER PRIMARY KEY, entity_id INTEGER NOT NULL REFERENCES supervised_entity(id),
                generation INTEGER NOT NULL, work_item TEXT, attempt INTEGER, started_at TEXT, finished_at TEXT,
                reason TEXT CHECK (reason IS NULL OR reason IN ('ok','failed','timeout','killed')))
            SQL
            "CREATE INDEX run_by_start ON run (started_at DESC, id DESC)",
            "CREATE INDEX run_by_entity ON run (entity_id, started_at DESC, id DESC)",
            <<~SQL,
              CREATE TABLE run_event (id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL REFERENCES run(id) ON DELETE CASCADE,
                seq INTEGER NOT NULL, event TEXT NOT NULL, reason TEXT, occurred_at TEXT NOT NULL, UNIQUE (run_id, seq))
            SQL
            <<~SQL
              CREATE TABLE restart_action (id INTEGER PRIMARY KEY, entity_id INTEGER NOT NULL REFERENCES supervised_entity(id),
                source_generation INTEGER, target_generation INTEGER, actors TEXT NOT NULL,
                requested_at TEXT NOT NULL, completed_at TEXT)
            SQL
          ].freeze],
          # Story 5.3: a run no live writer will ever finish (left open by a
          # crashed master, or displaced by a newer run of its entity).
          [2, [
            "ALTER TABLE run ADD COLUMN incomplete INTEGER NOT NULL DEFAULT 0 CHECK (incomplete IN (0,1))"
          ].freeze],
          # Story 5.4: bounded redacted output per run, the flags for a
          # dropped beginning (truncated) and a capture hole (incomplete), and
          # the JSON error summary of a failed run.
          [3, [
            <<~SQL,
              CREATE TABLE run_output (id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL REFERENCES run(id) ON DELETE CASCADE,
                seq INTEGER NOT NULL, stream TEXT NOT NULL CHECK (stream IN ('stdout','stderr')), text TEXT NOT NULL,
                UNIQUE (run_id, seq))
            SQL
            "ALTER TABLE run ADD COLUMN output_truncated INTEGER NOT NULL DEFAULT 0 CHECK (output_truncated IN (0,1))",
            "ALTER TABLE run ADD COLUMN output_incomplete INTEGER NOT NULL DEFAULT 0 CHECK (output_incomplete IN (0,1))",
            "ALTER TABLE run ADD COLUMN error_summary TEXT"
          ].freeze]
        ].freeze

        LATEST = MIGRATIONS.last.first
      end
    end
  end
end
