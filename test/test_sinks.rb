# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# Records every sink call in order. Implements both the state/event protocol
# (#publish) and the output protocol (#append), so one instance can serve as
# all three sinks and its `calls` array captures the global publish order.
class RecordingSink
  attr_reader :calls

  def initialize
    @calls = []
  end

  def publish(entity_id, payload)
    @calls << [entity_id, payload]
  end

  def append(entity_id, stream, chunk)
    @calls << [entity_id, stream, chunk]
  end
end

# The Story 3.3 output protocol in full: #append plus the run lifecycle.
# RecordingSink deliberately stays one-method (the legacy shape) so both
# shapes keep being exercised.
class RecordingLifecycleOutputSink
  attr_reader :calls

  def initialize
    @calls = []
  end

  def append(entity_id, stream, chunk)
    @calls << [:append, entity_id, stream, chunk]
  end

  def begin_run(entity_id, run_id)
    @calls << [:begin_run, entity_id, run_id]
  end

  def end_run(entity_id, run_id, reason)
    @calls << [:end_run, entity_id, run_id, reason]
  end
end

# A sink whose every protocol method raises the given exception.
class RaisingSink
  def initialize(error = RuntimeError.new("sink boom"))
    @error = error
  end

  def publish(_entity_id, _payload)
    raise @error
  end

  def append(_entity_id, _stream, _chunk)
    raise @error
  end

  def begin_run(_entity_id, _run_id)
    raise @error
  end

  def end_run(_entity_id, _run_id, _reason)
    raise @error
  end
end

class SinksStubBackend
  def initialize(reasons)
    @reasons = reasons.dup
  end

  def run(_prompt)
    reason = @reasons.shift || :ok
    AgentDaemon::Backend::Result.new(reason == :ok, "stdout", "stderr", reason)
  end
end

# Shutdown flag driven by a predicate, so a runner's #run loop can stop as
# soon as an observable condition holds (e.g. the input file was consumed)
# without real sleeps.
class SinksPredicateShutdown
  def initialize(&predicate)
    @predicate = predicate
  end

  def value
    @predicate.call
  end
end

ISO8601_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

class TestSinks < Minitest::Test
  def setup
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, nil)
  end

  def test_null_sinks_accept_protocol_calls_and_return_nothing
    assert_nil AgentDaemon::Sinks::NullState.new.publish("e", { status: :waiting })
    assert_nil AgentDaemon::Sinks::NullEvent.new.publish("e", { type: :started })
    assert_nil AgentDaemon::Sinks::NullOutput.new.append("e", :stdout, "chunk")
  end

  def test_bundle_null_wires_null_sinks
    bundle = AgentDaemon::Sinks::Bundle.null("runner-1")

    assert_instance_of AgentDaemon::Sinks::NullState, bundle.instance_variable_get(:@state)
    assert_instance_of AgentDaemon::Sinks::NullEvent, bundle.instance_variable_get(:@event)
    assert_instance_of AgentDaemon::Sinks::NullOutput, bundle.instance_variable_get(:@output)
  end

  def test_bundle_null_defaults_entity_id_to_nil
    bundle = AgentDaemon::Sinks::Bundle.null

    assert_nil bundle.instance_variable_get(:@entity_id)
  end

  def test_publish_state_stamps_entity_id
    recorder = RecordingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", state: recorder)

    bundle.publish_state(status: :waiting)

    assert_equal [["ent", { status: :waiting }]], recorder.calls
  end

  def test_publish_event_stamps_entity_id
    recorder = RecordingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", event: recorder)

    bundle.publish_event(type: :started, work_item: "k")

    assert_equal [["ent", { type: :started, work_item: "k" }]], recorder.calls
  end

  def test_append_output_stamps_entity_id
    recorder = RecordingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", output: recorder)

    bundle.append_output(:stdout, "chunk")

    assert_equal [["ent", :stdout, "chunk"]], recorder.calls
  end

  def test_standard_error_from_sink_is_swallowed_and_logged
    log_io = StringIO.new
    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(log_io))
    raising = RaisingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", state: raising, event: raising, output: raising)

    bundle.publish_state(status: :waiting)
    bundle.publish_event(type: :started)
    bundle.append_output(:stdout, "chunk")

    assert_includes log_io.string, "sink error isolated: RuntimeError: sink boom"
  end

  def test_signal_exception_from_sink_is_not_swallowed
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", state: RaisingSink.new(SignalException.new("TERM")))

    assert_raises(SignalException) { bundle.publish_state(status: :waiting) }
  end

  # --- Story 3.3 / DR4: the output run lifecycle ---------------------------

  def test_null_output_accepts_the_run_lifecycle_and_returns_nothing
    null = AgentDaemon::Sinks::NullOutput.new

    assert_nil null.begin_run("e", 1)
    assert_nil null.end_run("e", 1, :ok)
  end

  def test_begin_output_run_stamps_entity_id
    recorder = RecordingLifecycleOutputSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", output: recorder)

    bundle.begin_output_run(7)

    assert_equal [[:begin_run, "ent", 7]], recorder.calls
  end

  def test_end_output_run_stamps_entity_id_and_carries_the_reason
    recorder = RecordingLifecycleOutputSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", output: recorder)

    bundle.end_output_run(7, :timeout)

    assert_equal [[:end_run, "ent", 7, :timeout]], recorder.calls
  end

  def test_standard_error_from_the_run_lifecycle_is_swallowed_and_logged
    log_io = StringIO.new
    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(log_io))
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", output: RaisingSink.new)

    bundle.begin_output_run(1)
    bundle.end_output_run(1, :ok)

    assert_equal 2, log_io.string.scan("sink error isolated: RuntimeError: sink boom").size
  end

  def test_signal_exception_from_the_run_lifecycle_is_not_swallowed
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", output: RaisingSink.new(SignalException.new("TERM")))

    assert_raises(SignalException) { bundle.begin_output_run(1) }
    assert_raises(SignalException) { bundle.end_output_run(1, :ok) }
  end

  # A minimal one-method output sink (the pre-3.3 shape) must keep working:
  # letting guard swallow a NoMethodError would turn every run into two
  # spurious WARN lines.
  def test_a_legacy_one_method_output_sink_still_works_and_logs_nothing
    log_io = StringIO.new
    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(log_io))
    recorder = RecordingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent", output: recorder)

    bundle.begin_output_run(1)
    bundle.append_output(:stdout, "chunk")
    bundle.end_output_run(1, :ok)

    assert_equal [["ent", :stdout, "chunk"]], recorder.calls, "positive control: #append still reached the sink"
    refute_includes log_io.string, "sink error isolated"
  end

  def test_the_bundle_default_output_sink_accepts_the_run_lifecycle
    bundle = AgentDaemon::Sinks::Bundle.null("ent")

    assert_nil bundle.begin_output_run(1)
    assert_nil bundle.end_output_run(1, :ok)
  end
end

class TestSinksRunnerIntegration < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    @message_dir = File.join(@project_path, "to_message")
    @input_dir   = File.join(@project_path, "review_inbox")
    @archive_dir = File.join(@project_path, "review_inbox/archive")
    @failed_dir  = File.join(@project_path, "review_inbox/failed")
    FileUtils.mkdir_p(@message_dir)

    template_path = File.join(@tmpdir, "prompt.txt")
    File.write(template_path, "review {{input_file}}")

    @runner_config = {
      "name" => "reviewer",
      "backend" => "claude",
      "extra_flags" => "",
      "timeout" => 1200,
      "max_attempts" => 2,
      "prompt_template" => "prompt.txt",
      "prompt_template_path" => template_path,
      "trigger" => {
        "type" => "file",
        "input_dir" => @input_dir,
        "archive_dir" => @archive_dir,
        "failed_dir" => @failed_dir,
        "interval" => 0
      }
    }

    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, nil)
    FileUtils.remove_entry(@tmpdir)
  end

  def build_runner(reasons, sinks: nil, shutdown: nil)
    shutdown ||= SinksPredicateShutdown.new { false }
    runner = if sinks
      AgentDaemon::Runner::File.new(@runner_config, @message_dir, @project_path, shutdown, sinks: sinks)
    else
      AgentDaemon::Runner::File.new(@runner_config, @message_dir, @project_path, shutdown)
    end
    runner.instance_variable_set(:@backend, SinksStubBackend.new(reasons))
    runner
  end

  def write_work_item(name = "TASK-1.yml")
    FileUtils.mkdir_p(@input_dir)
    path = File.join(@input_dir, name)
    File.write(path, "body")
    path
  end

  def test_run_publishes_frozen_state_and_event_sequence_with_entity_id
    path = write_work_item
    recorder = RecordingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent-1", state: recorder, event: recorder)
    shutdown = SinksPredicateShutdown.new { !File.exist?(path) }
    runner = build_runner([:ok], sinks: bundle, shutdown: shutdown)

    runner.run

    assert(recorder.calls.all? { |entity_id, _| entity_id == "ent-1" })

    payloads = recorder.calls.map(&:last)
    timestamps = payloads.filter_map { |p| p.delete(:at) }
    assert_equal 3, timestamps.size, "picked_up/started/finished must carry :at"
    timestamps.each { |at| assert_match ISO8601_RE, at }

    assert_equal [
      { status: :waiting },
      { type: :picked_up, work_item: "TASK-1.yml" },
      { type: :started, work_item: "TASK-1.yml", attempt: 1 },
      { status: :in_progress, work_item: "TASK-1.yml", attempt: 1 },
      { type: :finished, work_item: "TASK-1.yml", reason: :ok, attempt: 1 },
      { status: :waiting },
      { status: :stopped }
    ], payloads
  end

  def test_non_string_entity_id_round_trips_untouched
    path = write_work_item
    identity = Struct.new(:workflow, :runner).new("wf", "rn")
    recorder = RecordingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: identity, state: recorder, event: recorder)
    runner = build_runner([:ok], sinks: bundle)

    runner.send(:process_item, path)

    refute_empty recorder.calls
    recorder.calls.each { |entity_id, _| assert_same identity, entity_id }
  end

  def test_raising_sinks_never_break_item_processing
    path = write_work_item
    raising = RaisingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "ent-1", state: raising, event: raising)
    runner = build_runner([:ok], sinks: bundle)

    runner.send(:process_item, path)

    assert File.exist?(File.join(@archive_dir, "TASK-1.yml")), "item must complete despite raising sinks"
    refute File.exist?(path)
  end

  def test_default_constructed_runner_processes_item_without_sinks_kwarg
    path = write_work_item
    runner = build_runner([:ok])

    runner.send(:process_item, path)

    assert File.exist?(File.join(@archive_dir, "TASK-1.yml"))
    refute File.exist?(path)
  end
end

class TestSinksLivenessIntegration < Minitest::Test
  FakeConfig = Struct.new(:messenger, :message_dir)

  def setup
    AgentDaemon::Log.instance_variable_set(:@logger, ::Logger.new(File::NULL))
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, nil)
  end

  def already_shutdown
    SinksPredicateShutdown.new { true }
  end

  def test_messenger_publishes_running_then_stopped
    Dir.mktmpdir do |dir|
      config = FakeConfig.new({ "type" => "webhook", "webhook_url" => "http://example.test", "interval" => 1 }, dir)
      recorder = RecordingSink.new
      bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "messenger", state: recorder)

      AgentDaemon::Messenger.new(config, already_shutdown, sinks: bundle).run

      assert_equal [
        ["messenger", { status: :running }],
        ["messenger", { status: :stopped }]
      ], recorder.calls
    end
  end

  def test_reactor_publishes_running_then_stopped_on_empty_listeners_path
    recorder = RecordingSink.new
    bundle = AgentDaemon::Sinks::Bundle.new(entity_id: "mattermost_reactor", state: recorder)

    AgentDaemon::Mattermost::Reactor.new([], already_shutdown, sinks: bundle).run

    assert_equal [
      ["mattermost_reactor", { status: :running }],
      ["mattermost_reactor", { status: :stopped }]
    ], recorder.calls
  end
end
