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
