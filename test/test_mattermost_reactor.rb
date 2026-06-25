# frozen_string_literal: true

require "test_helper"

class TestMattermostReactor < Minitest::Test
  def setup
    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(::File::NULL))
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, nil)
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
end
