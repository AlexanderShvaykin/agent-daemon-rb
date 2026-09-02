# frozen_string_literal: true

require "test_helper"

require "agent_daemon/supervisor/restart_control"
require "agent_daemon/supervisor/runner_supervisor"

class RestartControlRecordingSink
  attr_reader :calls

  def initialize
    @calls = []
  end

  def publish(entity_id, record)
    @calls << [entity_id, record]
  end
end

class RestartControlLoopingEntity
  def initialize(shutdown_flag)
    @shutdown_flag = shutdown_flag
  end

  def run
    Thread.pass until @shutdown_flag.value
  end
end

class TestRestartControl < Minitest::Test
  def setup
    @shutdown_flag = AgentDaemon::ShutdownFlag.new
    @entity_stop_flag = AgentDaemon::ShutdownFlag.new
    @state_sink = RestartControlRecordingSink.new
    sinks_factory = lambda do |generation|
      AgentDaemon::Sinks::Bundle.new(
        entity_id: "workflow:runner",
        state: AgentDaemon::Supervisor::GenerationStamp.new(generation, @state_sink)
      )
    end
    @supervisor = AgentDaemon::Supervisor::RunnerSupervisor.new(
      "workflow:runner",
      entity_factory: ->(_bundle, _cancel_token = nil) { RestartControlLoopingEntity.new(@entity_stop_flag) },
      shutdown_flag: @shutdown_flag,
      sinks_factory: sinks_factory
    )
    @control = AgentDaemon::Supervisor::RestartControl.new(
      supervisors: { "workflow:runner" => @supervisor },
      shutdown_flag: @shutdown_flag
    )
  end

  def teardown
    @entity_stop_flag.set!
    @shutdown_flag.set!
    @supervisor.thread&.join(1)
  end

  def test_unknown_id_returns_nil
    assert_nil @control.request_restart("unknown", actor: "console:alice")
  end

  def test_shutdown_refuses_without_queuing_an_intent
    assert @supervisor.spawn!
    @shutdown_flag.set!

    assert_equal :refused, @control.request_restart("workflow:runner", actor: "console:alice")
    @supervisor.tick

    assert_empty @state_sink.calls
    assert_equal :running, @supervisor.state
  end

  def test_accepted_restart_returns_the_next_generation
    assert @supervisor.spawn!

    assert_equal 2, @control.request_restart("workflow:runner", actor: "console:alice")
  end

  def test_coalesced_requests_return_the_same_target_generation
    assert @supervisor.spawn!

    first = @control.request_restart("workflow:runner", actor: "console:alice")
    second = @control.request_restart("workflow:runner", actor: "console:bob")

    assert_equal 2, first
    assert_equal first, second
  end
end
