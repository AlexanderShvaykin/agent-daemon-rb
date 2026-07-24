# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_daemon"
require "minitest/autorun"
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
end
