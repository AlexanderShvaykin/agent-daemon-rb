# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestLog < Minitest::Test
  def setup
    @prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    @io = StringIO.new
    logger = ::Logger.new(@io)
    logger.level = ::Logger::DEBUG
    logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
    AgentDaemon::Log.use(logger)
  end

  def teardown
    AgentDaemon::Log.clear_context
    AgentDaemon::Log.instance_variable_set(:@logger, @prior_logger)
  end

  def output
    @io.string
  end

  # --- Absent context: byte-for-byte passthrough (AC4 regression) --------

  def test_absent_context_passes_through_unchanged
    AgentDaemon::Log.info("hello")

    assert_equal "hello\n", output
  end

  def test_absent_context_passthrough_for_every_severity
    AgentDaemon::Log.debug("d")
    AgentDaemon::Log.info("i")
    AgentDaemon::Log.warn("w")
    AgentDaemon::Log.error("e")

    assert_equal "d\ni\nw\ne\n", output
  end

  # --- Ambient tagging -----------------------------------------------------

  def test_ambient_context_prepends_tag_and_generation
    AgentDaemon::Log.bind_context(tag: "task-analyst:reviewer", generation: 2, level: nil)
    AgentDaemon::Log.info("polling")

    assert_equal "[task-analyst:reviewer gen2] polling\n", output
  end

  def test_messenger_tag_format
    AgentDaemon::Log.bind_context(tag: "messenger:task-analyst", generation: 1, level: nil)
    AgentDaemon::Log.info("delivered")

    assert_equal "[messenger:task-analyst gen1] delivered\n", output
  end

  def test_reactor_tag_format
    AgentDaemon::Log.bind_context(tag: "mattermost_reactor", generation: 1, level: nil)
    AgentDaemon::Log.info("connected")

    assert_equal "[mattermost_reactor gen1] connected\n", output
  end

  def test_clear_context_reverts_to_passthrough
    AgentDaemon::Log.bind_context(tag: "wf:r", generation: 1, level: nil)
    AgentDaemon::Log.clear_context
    AgentDaemon::Log.info("bare")

    assert_equal "bare\n", output
  end

  # --- Per-tag level gate (AC2) --------------------------------------------

  def test_level_gate_drops_below_threshold_and_passes_at_or_above
    AgentDaemon::Log.bind_context(tag: "wf:r", generation: 1, level: ::Logger::WARN)

    AgentDaemon::Log.debug("dropped")
    AgentDaemon::Log.info("dropped too")
    AgentDaemon::Log.warn("kept")
    AgentDaemon::Log.error("kept too")

    assert_equal "[wf:r gen1] kept\n[wf:r gen1] kept too\n", output
  end

  def test_nil_level_means_no_gate
    AgentDaemon::Log.bind_context(tag: "wf:r", generation: 1, level: nil)

    AgentDaemon::Log.debug("passes")

    assert_equal "[wf:r gen1] passes\n", output
  end

  # --- Ambient context is per-thread, not global ---------------------------

  def test_context_is_thread_local
    AgentDaemon::Log.bind_context(tag: "main-thread-tag", generation: 1, level: nil)

    other_thread_output = nil
    Thread.new do
      AgentDaemon::Log.info("from other thread")
      other_thread_output = output
    end.join

    assert_equal "from other thread\n", other_thread_output
  end

  # --- Shared prefix formatter ----------------------------------------------

  def test_tag_prefix_formats_tag_and_generation
    assert_equal "[wf:r gen3]", AgentDaemon::Log.tag_prefix("wf:r", 3)
  end
end
