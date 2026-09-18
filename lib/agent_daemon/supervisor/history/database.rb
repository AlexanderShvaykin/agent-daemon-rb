# frozen_string_literal: true

require "fileutils"

require_relative "../../log"
require_relative "schema"

module AgentDaemon
  module Supervisor
    module History
      # The history store's SQLite connection (Story 5.1): owner-only storage,
      # WAL mode, busy_timeout, and transactional versioned migrations.
      #
      # AD-5: `sqlite3` is required lazily inside .open, so loading this file
      # never pulls the gem in, and the core `require "agent_daemon"` graph
      # never reaches this file at all.
      #
      # The process umask is never touched (it is process-global and shared
      # with every other thread). Owner-only modes come from creating the file
      # with an explicit 0600 before SQLite sees it; SQLite's unix VFS gives the
      # -wal/-shm sidecars the main file's mode, and the post-open check is the
      # backstop.
      class Database
        class Error < StandardError; end
        # A file on the history path that must not be used: not a regular file
        # (a symlink included), owned by another user, or with permissions that
        # could not be tightened.
        class UnsafeStorageError < Error; end
        # The DB carries a newer schema than this code knows. Never downgraded.
        class UnsupportedSchemaError < Error; end

        DIR_MODE = 0o700
        FILE_MODE = 0o600
        SIDECAR_SUFFIXES = %w[-wal -shm].freeze

        attr_reader :db, :path, :schema_version

        def self.open(path:, busy_timeout_ms:, migrations: Schema::MIGRATIONS)
          # First, so a missing gem leaves nothing behind on disk.
          require "sqlite3"
          secure_directory(File.dirname(path))
          secure_or_create_main_file(path)
          secure_sidecars(path)

          db = SQLite3::Database.new(path)
          begin
            configure(db, busy_timeout_ms)
            version = migrate(db, migrations)
            secure_sidecars(path)
            new(db, path, version)
          rescue Exception # close on ANY failure, then re-raise it untouched
            db.close unless db.closed?
            raise
          end
        end

        def initialize(db, path, schema_version)
          @db = db
          @path = path
          @schema_version = schema_version
        end

        def close
          @db.close unless @db.closed?
        end

        class << self
          private

          # Only a directory this call creates is forced to 0700; an existing
          # one belongs to the operator.
          def secure_directory(dir)
            return if File.directory?(dir)

            FileUtils.mkdir_p(dir, mode: DIR_MODE)
            File.chmod(DIR_MODE, dir)
          end

          # O_EXCL creates the file at 0600 before SQLite touches it, so there is
          # never a window with umask permissions. The chmod after it only makes
          # the mode exact (a umask can remove bits, never add them). O_EXCL also
          # refuses to follow a symlink, so an existing link lands in the
          # EEXIST branch and is refused there.
          def secure_or_create_main_file(path)
            File.open(path, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) { |f| f.chmod(FILE_MODE) }
          rescue Errno::EEXIST
            secure_existing(path)
          end

          # A sidecar may vanish at any moment (another connection closing
          # checkpoints and removes it), so absence is not an error.
          def secure_sidecars(path)
            SIDECAR_SUFFIXES.each do |suffix|
              secure_existing("#{path}#{suffix}")
            rescue Errno::ENOENT
              next
            end
          end

          # lstat, not stat: a symlink is judged as itself and refused.
          def secure_existing(path)
            stat = File.lstat(path)
            raise UnsafeStorageError, "#{path} is not a regular file" unless stat.file?
            raise UnsafeStorageError, "#{path} is owned by another user" unless stat.uid == Process.euid

            mode = stat.mode & 0o777
            return if (mode & 0o077).zero?

            begin
              File.chmod(FILE_MODE, path)
            rescue SystemCallError => e
              raise UnsafeStorageError, "#{path} has mode #{format('%04o', mode)} and could not be restricted: #{e.class}"
            end
            Log.warn("[History] #{path} had mode #{format('%04o', mode)}; restricted it to #{format('%04o', FILE_MODE)}")
          end

          # busy_timeout first: switching the journal mode takes a lock that a
          # concurrent connection may briefly hold.
          def configure(db, busy_timeout_ms)
            db.busy_timeout = busy_timeout_ms
            mode = db.get_first_value("PRAGMA journal_mode=WAL")
            raise Error, "journal_mode is #{mode.inspect}, expected \"wal\"" unless mode.to_s.downcase == "wal"

            db.execute("PRAGMA foreign_keys=ON")
          end

          # All pending migrations and the new user_version commit together or
          # not at all. The version is re-read inside BEGIN IMMEDIATE so a
          # concurrent opener cannot make us apply a migration twice. An
          # up-to-date DB returns before any transaction starts.
          def migrate(db, migrations)
            latest = migrations.empty? ? 0 : migrations.last.first
            current = user_version(db)
            check_supported!(current, latest)
            return current if current == latest

            db.transaction(:immediate) do
              current = user_version(db)
              check_supported!(current, latest)
              migrations.each do |version, statements|
                next if version <= current

                statements.each { |sql| db.execute(sql) }
              end
              db.execute("PRAGMA user_version = #{Integer(latest)}")
            end
            user_version(db)
          end

          def user_version(db)
            db.get_first_value("PRAGMA user_version")
          end

          def check_supported!(current, latest)
            return if current <= latest

            raise UnsupportedSchemaError, "schema version #{current} is newer than the latest known (#{latest})"
          end
        end
      end
    end
  end
end
