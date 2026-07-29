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

class RateLimitedTracker
  def initialize(retry_after)
    @retry_after = retry_after
  end

  def search_issues(_query)
    raise AgentDaemon::Tracker::RateLimitError, @retry_after
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
    assert_equal true, payload["system_alert"]
    assert_equal "trigger_error", payload["error_type"]
    assert_includes payload["message"], "kaboom"

    # Counter resets after escalation
    assert_equal 0, runner.instance_variable_get(:@consecutive_errors)
  end

  def test_final_cli_failure_creates_one_system_alert
    runner = build_runner([:failed, :failed, :failed])

    3.times { runner.send(:process_item, { "key" => "TI-7" }) }

    alerts = Dir.glob(File.join(@message_dir, "error-default-*.yml"))
    assert_equal 1, alerts.size
    payload = YAML.safe_load_file(alerts.first)
    assert_equal true, payload["system_alert"]
    assert_equal "cli_failed", payload["error_type"]
    assert_equal "TI-7", payload["work_item"]
    assert_includes payload["message"], "work item TI-7"
  end

  def test_final_timeout_creates_one_system_alert
    runner = build_runner([:timeout, :timeout, :timeout])

    3.times { runner.send(:process_item, { "key" => "TI-8" }) }

    alerts = Dir.glob(File.join(@message_dir, "error-default-*.yml"))
    assert_equal 1, alerts.size
    payload = YAML.safe_load_file(alerts.first)
    assert_equal "timeout", payload["error_type"]
    assert_equal "TI-8", payload["work_item"]
  end

  def test_rate_limit_does_not_escalate_and_sets_backoff
    tracker = RateLimitedTracker.new(30)
    runner = build_runner([], tracker_stub: tracker)

    3.times { runner.send(:fetch_work_items_with_escalation) }

    error_files = Dir.glob(File.join(@message_dir, "error-*.yml"))
    assert_empty error_files
    assert_equal 0, runner.instance_variable_get(:@consecutive_errors)
    assert_equal 30, runner.instance_variable_get(:@backoff)
  end

  def test_rate_limit_backoff_drives_next_wait
    tracker = RateLimitedTracker.new(30)
    runner = build_runner([], tracker_stub: tracker)

    runner.send(:fetch_work_items_with_escalation)
    assert_equal 30, runner.send(:next_wait_seconds)
    # One-shot: backoff is consumed, next wait returns to the base interval.
    assert_equal 60, runner.send(:next_wait_seconds)
  end

  def test_jitter_zero_waits_exactly_interval
    runner = build_runner([])
    # Default runner_config has no jitter key → jitter 0.
    assert_equal 60, runner.send(:next_wait_seconds)
  end

  def test_jitter_stays_within_bound
    @runner_config["trigger"]["jitter"] = 5
    runner = build_runner([])
    20.times do
      wait = runner.send(:next_wait_seconds)
      assert_operator wait, :>=, 60
      assert_operator wait, :<, 65
    end
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
