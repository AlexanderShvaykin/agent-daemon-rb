# frozen_string_literal: true

require "test_helper"

class TestMattermostReactor < Minitest::Test
  include LogStubbing

  def setup
    stub_null_logger!
  end

  def teardown
    restore_logger!
  end

  # A fake listener whose #prepare either succeeds (returning self, as the real
  # listener does) or raises, and which records whether #start was called.
  class FakeListener
    attr_reader :started

    def initialize(name, raise_on_prepare: false)
      @name = name
      @raise_on_prepare = raise_on_prepare
      @started = false
    end

    def prepare
      raise "boom (#{@name})" if @raise_on_prepare

      self
    end

    def start
      @started = true
    end
  end

  class StateSink
    attr_reader :records, :published

    def initialize
      @records = []
      @published = Thread::Queue.new
    end

    def publish(_entity_id, record)
      @records << record
      @published << record
    end
  end

  def test_prepare_listeners_skips_failures_and_keeps_others
    ok = FakeListener.new("ok")
    bad = FakeListener.new("bad", raise_on_prepare: true)
    reactor = AgentDaemon::Mattermost::Reactor.new([bad, ok], AgentDaemon::ShutdownFlag.new)

    prepared = reactor.prepare_listeners

    assert_equal [ok], prepared, "failed listener must be dropped, the succeeding one kept"
  end

  def test_prepare_listeners_returns_all_when_none_fail
    a = FakeListener.new("a")
    b = FakeListener.new("b")
    reactor = AgentDaemon::Mattermost::Reactor.new([a, b], AgentDaemon::ShutdownFlag.new)

    assert_equal [a, b], reactor.prepare_listeners
  end

  def test_generation_cancel_stops_the_reactor_without_publishing_stopped
    listener = FakeListener.new("ok")
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    cancel_flag = AgentDaemon::ShutdownFlag.new
    state_sink = StateSink.new
    sinks = AgentDaemon::Sinks::Bundle.new(entity_id: "mattermost_reactor", state: state_sink)
    reactor = AgentDaemon::Mattermost::Reactor.new(
      [listener], shutdown_flag, sinks: sinks, cancel_flag: cancel_flag
    )

    thread = Thread.new { reactor.run }
    assert_equal({ status: :running }, state_sink.published.pop)
    cancel_flag.set!

    assert thread.join(2), "cancelled reactor did not return within its existing timer bound"
    assert listener.started
    assert_equal [{ status: :running }], state_sink.records
  ensure
    shutdown_flag&.set!
    thread&.join(2)
  end
end
