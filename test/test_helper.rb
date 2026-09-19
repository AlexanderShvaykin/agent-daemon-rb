# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_daemon"
require "minitest/autorun"
require "stringio"
require "net/http"

# Minitest 6 dropped minitest/mock, so substitute Net::HTTP.new by hand for the
# duration of a block and restore the original afterwards.
module HttpStubbing
  def stub_net_http(fake)
    original = Net::HTTP.method(:new)
    silence_warnings { Net::HTTP.define_singleton_method(:new) { |*_args| fake } }
    yield
  ensure
    silence_warnings { Net::HTTP.define_singleton_method(:new, original) }
  end

  def silence_warnings
    saved = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = saved
  end
end

class Minitest::Test
  include HttpStubbing
end

# AI-3 (Epic 1 retro): save/restore AgentDaemon::Log's global logger AND
# clear its ambient per-thread context, so a test file doesn't leak its null
# logger to whichever file happens to run after it in the same Minitest
# process. Call stub_null_logger! from #setup and restore_logger! from
# #teardown.
#
# "Restore" means restore whatever was there — which in a fresh test process
# is nil, since neither `require "agent_daemon"` nor Log.use runs at load
# time. That is the correct restoration, not a leak: it is the same state the
# file inherited. Note that Log.logger's nil fallback allocates a fresh
# Logger.new($stdout) at DEBUG per call, so a test that wants quiet output
# must stub it rather than rely on the ambient default.
module LogStubbing
  def stub_null_logger!
    @__prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def restore_logger!
    AgentDaemon::Log.instance_variable_set(:@logger, @__prior_logger)
    AgentDaemon::Log.clear_context
  end

  # Returns whatever the block logged. The logger is a process-wide singleton,
  # so this swaps it and puts back what was there — including the null logger
  # stub_null_logger! installed, which is why the two compose.
  def capture_log
    prior = AgentDaemon::Log.instance_variable_get(:@logger)
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.level = ::Logger::INFO
    logger.formatter = proc { |_severity, _datetime, _progname, message| "#{message}\n" }
    AgentDaemon::Log.use(logger)
    yield
    io.string
  ensure
    AgentDaemon::Log.instance_variable_set(:@logger, prior)
  end
end

# Shared HTTP test doubles for transport specs. FakeHttp is substituted for the
# object Net::HTTP.new returns; the handler block maps each request to a fake
# response and every request is recorded for assertions.
class FakeHttp
  attr_accessor :use_ssl, :open_timeout, :read_timeout
  attr_reader :requests

  def initialize(&handler)
    @handler = handler
    @requests = []
  end

  def request(req)
    @requests << req
    @handler.call(req)
  end
end

class FakeSuccess < Net::HTTPSuccess
  def initialize(body = "ok")
    @fake_body = body
  end

  def code = "200"
  def body = @fake_body
end

class FakeServerError < Net::HTTPServerError
  def initialize = nil

  def code = "503"
  def body = "unavailable"
  # Net::HTTPResponse#[] reads a header hash these fakes never build, so a
  # transport that inspects one (Content-Type, Retry-After) would blow up on
  # the fixture rather than on its own logic.
  def [](_name) = nil
end

# Story 5.5: seeds a history store by plain SQL, so reader and console tests
# control every column (ties, NULLs, flags) without driving the writer. The
# including test provides #seed_db, a connection to a migrated store.
module HistorySeeding
  def seed_entity(key, kind: "runner", workflow: "wf", runner: "a")
    seed_db.execute("INSERT INTO supervised_entity (entity_key, kind, workflow, runner, first_seen_at) " \
                    "VALUES (?, ?, ?, ?, ?)", [key, kind, workflow, runner, "2026-09-19T09:00:00.000Z"])
    seed_db.last_insert_row_id
  end

  def seed_run(entity_row, started_at:, generation: 1, work_item: "TI-1", attempt: 1, finished_at: nil,
               reason: nil, incomplete: 0, output_truncated: 0, output_incomplete: 0, error_summary: nil)
    seed_db.execute("INSERT INTO run (entity_id, generation, work_item, attempt, started_at, finished_at, reason, " \
                    "incomplete, output_truncated, output_incomplete, error_summary) " \
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [entity_row, generation, work_item, attempt, started_at, finished_at, reason, incomplete,
                     output_truncated, output_incomplete, error_summary])
    seed_db.last_insert_row_id
  end

  def seed_event(run_id, seq, event, occurred_at, reason: nil)
    seed_db.execute("INSERT INTO run_event (run_id, seq, event, reason, occurred_at) VALUES (?, ?, ?, ?, ?)",
                    [run_id, seq, event, reason, occurred_at])
  end

  def seed_output(run_id, seq, stream, text)
    seed_db.execute("INSERT INTO run_output (run_id, seq, stream, text) VALUES (?, ?, ?, ?)",
                    [run_id, seq, stream, text])
  end

  def seed_restart(entity_row, requested_at:, actors: ["operator"], completed_at: nil, source: 1, target: 2)
    seed_db.execute("INSERT INTO restart_action (entity_id, source_generation, target_generation, actors, " \
                    "requested_at, completed_at) VALUES (?, ?, ?, ?, ?, ?)",
                    [entity_row, source, target, JSON.generate(actors), requested_at, completed_at])
  end

  # "2026-09-19T10:00:0N.000Z", the writer's iso8601(3) shape.
  def at(second)
    format("2026-09-19T10:%02d:%02d.000Z", second / 60, second % 60)
  end
end
