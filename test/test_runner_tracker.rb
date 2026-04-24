# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

class StubBackend
  attr_reader :calls

  def initialize(reasons)
    @reasons = reasons.dup
    @calls = 0
  end

  def run(_prompt)
    @calls += 1
    reason = @reasons.shift || :ok
    AgentDaemon::Backend::Result.new(reason == :ok, "stdout", "stderr", reason)
  end
end

class StubShutdown
  def value
    false
  end
end

class FailingTracker
  def initialize(error_message)
    @error_message = error_message
  end

  def search_issues(_query)
    raise @error_message
  end
end

class TestRunnerTracker < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    @message_dir = File.join(@project_path, "to_message")
    FileUtils.mkdir_p(@message_dir)

    template_path = File.join(@tmpdir, "prompt.txt")
    File.write(template_path, "task {{task_key}}")

    @runner_config = {
      "name" => "default",
      "backend" => "claude",
      "agent" => "task-analyst",
      "extra_flags" => "",
      "timeout" => 1200,
      "max_attempts" => 3,
      "prompt_template" => "prompt.txt",
      "prompt_template_path" => template_path,
      "trigger" => { "type" => "tracker", "query" => "Queue: TI", "interval" => 60 }
    }

    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def build_runner(reasons, tracker_stub: nil)
    runner = AgentDaemon::Runner::Tracker.new(
      @runner_config, @message_dir, @project_path, StubShutdown.new,
      { "token" => "t", "org_id" => "o" }
    )
    runner.instance_variable_set(:@backend, StubBackend.new(reasons))
    runner.instance_variable_set(:@tracker, tracker_stub) if tracker_stub
    runner
  end

  def attempts(runner)
    runner.instance_variable_get(:@attempts)
  end

  def test_first_attempt_increments_and_runs
    runner = build_runner([:ok])
    backend = runner.instance_variable_get(:@backend)
    runner.send(:process_item, { "key" => "TI-1" })
    assert_equal 1, backend.calls
  end

  def test_ok_removes_counter
    runner = build_runner([:ok])
    runner.send(:process_item, { "key" => "TI-2" })
    refute attempts(runner).key?("TI-2")
  end

  def test_failed_keeps_counter
    runner = build_runner([:failed])
    runner.send(:process_item, { "key" => "TI-3" })
    assert_equal 1, attempts(runner)["TI-3"]
  end

  def test_killed_rolls_back_counter
    runner = build_runner([:killed])
    runner.send(:process_item, { "key" => "TI-5" })
    assert_equal 0, attempts(runner)["TI-5"]
  end

  def test_exhausted_skips_backend
    runner = build_runner([:ok])
    backend = runner.instance_variable_get(:@backend)
    attempts(runner)["TI-6"] = 3
    runner.send(:process_item, { "key" => "TI-6" })
    assert_equal 0, backend.calls
  end

  def test_three_trigger_failures_escalate
    tracker = FailingTracker.new("kaboom")
    runner = build_runner([], tracker_stub: tracker)

    3.times { runner.send(:fetch_work_items_with_escalation) }

    error_files = Dir.glob(File.join(@message_dir, "error-default-*.yml"))
    assert_equal 1, error_files.size

    payload = YAML.safe_load_file(error_files.first)
    assert_equal "SYSTEM:default", payload["task_key"]
    assert_includes payload["message"], "kaboom"

    # Counter resets after escalation
    assert_equal 0, runner.instance_variable_get(:@consecutive_errors)
  end

  def test_intermittent_failure_does_not_escalate
    tracker = Object.new
    counter = [0]
    tracker.define_singleton_method(:search_issues) do |_q|
      counter[0] += 1
      raise "fail" if counter[0].odd?
      []
    end

    runner = build_runner([], tracker_stub: tracker)
    runner.send(:fetch_work_items_with_escalation)  # fail
    runner.send(:fetch_work_items_with_escalation)  # ok
    runner.send(:fetch_work_items_with_escalation)  # fail

    error_files = Dir.glob(File.join(@message_dir, "error-*.yml"))
    assert_empty error_files
    assert_equal 1, runner.instance_variable_get(:@consecutive_errors)
  end
end
