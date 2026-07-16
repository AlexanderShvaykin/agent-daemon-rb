# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestShutdownFlag
  attr_writer :value

  def initialize
    @value = false
  end

  def value
    @value
  end
end

class TestableBackend < AgentDaemon::Backend::Base
  def call(cmd, timeout:)
    execute(cmd, timeout: timeout)
  end
end

# Records every output-sink append as an [entity_id, stream, chunk] tuple.
class RecordingOutputSink
  attr_reader :calls

  def initialize
    @calls = []
  end

  def append(entity_id, stream, chunk)
    @calls << [entity_id, stream, chunk]
  end
end

class TestBackendExecute < Minitest::Test
  def setup
    @shutdown = TestShutdownFlag.new
    Dir.mktmpdir do |dir|
      project_path = File.join(dir, "project")
      FileUtils.mkdir_p(project_path)
      @backend = TestableBackend.new(
        { "name" => "default", "timeout" => 10, "extra_flags" => "" },
        @shutdown,
        message_dir: File.join(project_path, "to_message"),
        project_path: project_path
      )
    end
  end

  def test_ok_command
    result = @backend.call("sleep 0.1; echo ok", timeout: 5)
    assert_equal :ok, result.reason
    assert result.success
    assert_includes result.stdout, "ok"
  end

  def test_failed_command
    result = @backend.call("exit 7", timeout: 5)
    assert_equal :failed, result.reason
    refute result.success
  end

  def test_timeout
    started = Time.now
    result = @backend.call("sleep 30", timeout: 1)
    elapsed = Time.now - started
    assert_equal :timeout, result.reason
    refute result.success
    assert elapsed < 5
  end

  def test_group_kill_terminates_children
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "child.pid")
      script = "sh -c 'sleep 60 & echo $! > #{pidfile}; wait'"

      result = @backend.call(script, timeout: 1)
      assert_equal :timeout, result.reason

      child_pid = nil
      30.times do
        if File.exist?(pidfile) && !File.read(pidfile).strip.empty?
          child_pid = File.read(pidfile).strip.to_i
          break
        end
        sleep(0.05)
      end
      refute_nil child_pid

      alive = true
      30.times do
        begin
          Process.kill(0, child_pid)
        rescue Errno::ESRCH
          alive = false
          break
        end
        sleep(0.1)
      end

      refute alive
    end
  end

  def test_shutdown_flag_kills_running_command
    thread = Thread.new do
      sleep(0.3)
      @shutdown.value = true
    end

    started = Time.now
    result = @backend.call("sleep 30", timeout: 60)
    elapsed = Time.now - started
    thread.join

    assert_equal :killed, result.reason
    assert elapsed < 5
  end

  def test_kill_already_dead_does_not_raise
    result = @backend.call("true", timeout: 5)
    assert_equal :ok, result.reason
    @backend.send(:kill_process_group, 999_999)
    pass
  end

  def test_incremental_output_through_sink
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))

    result = backend.call("echo one; sleep 0.7; echo two", timeout: 5)

    assert_equal :ok, result.reason
    stdout_appends = recorder.calls.select { |_id, stream, _chunk| stream == :stdout }
    assert_operator stdout_appends.size, :>=, 2
    assert_includes result.stdout, "one"
    assert_includes result.stdout, "two"
  end

  def test_stderr_chunk_arrives_tagged_stderr
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))

    result = backend.call("echo oops 1>&2", timeout: 5)

    assert_includes result.stderr, "oops"
    assert(recorder.calls.any? { |_id, stream, chunk| stream == :stderr && chunk.include?("oops") })
  end

  def test_drain_on_timeout_captures_late_output
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))

    result = backend.call(%(sh -c 'trap "echo dying; exit 0" TERM; sleep 30'), timeout: 1)

    assert_equal :timeout, result.reason
    assert_includes result.stdout, "dying"
    assert(recorder.calls.any? { |_id, stream, chunk| stream == :stdout && chunk.include?("dying") })
  end

  def test_drain_on_shutdown_kill_captures_late_output
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))
    thread = Thread.new do
      sleep(0.3)
      @shutdown.value = true
    end

    result = backend.call(%(sh -c 'trap "echo dying; exit 0" TERM; sleep 30'), timeout: 60)
    thread.join

    assert_equal :killed, result.reason
    assert_includes result.stdout, "dying"
    assert(recorder.calls.any? { |_id, stream, chunk| stream == :stdout && chunk.include?("dying") })
  end

  def test_cancel_flag_kills_running_command
    cancel = TestShutdownFlag.new
    backend = build_backend(cancel_flag: cancel)
    thread = Thread.new do
      sleep(0.3)
      cancel.value = true
    end

    started = Time.now
    result = backend.call("sleep 30", timeout: 60)
    elapsed = Time.now - started
    thread.join

    assert_equal :killed, result.reason
    assert elapsed < 5
    # A recycled pid owned by another user raises EPERM instead of ESRCH —
    # either way the original child is gone.
    assert_raises(Errno::ESRCH, Errno::EPERM) { Process.kill(0, result.pid) }
  end

  def test_ok_result_carries_timing_and_pid
    result = @backend.call("echo ok", timeout: 5)

    assert_equal :ok, result.reason
    assert_kind_of Time, result.started_at
    assert_kind_of Time, result.finished_at
    assert_operator result.finished_at, :>=, result.started_at
    assert_kind_of Integer, result.pid
    assert_operator result.pid, :>, 0
  end

  def test_timeout_result_carries_timing_and_pid
    result = @backend.call("sleep 30", timeout: 1)

    assert_equal :timeout, result.reason
    assert_kind_of Time, result.started_at
    assert_kind_of Time, result.finished_at
    assert_operator result.finished_at, :>=, result.started_at
    assert_kind_of Integer, result.pid
    assert_operator result.pid, :>, 0
  end

  def test_raising_output_sink_does_not_break_run
    raising = Object.new
    def raising.append(_entity_id, _stream, _chunk)
      raise "sink boom"
    end
    backend = build_backend(sinks: sink_bundle(raising))

    result = backend.call("echo ok", timeout: 5)

    assert_equal :ok, result.reason
    assert_includes result.stdout, "ok"
  end

  private

  # Same construction as setup, but with extra Backend::Base kwargs
  # (sinks:, cancel_flag:) for the seam tests.
  def build_backend(**opts)
    Dir.mktmpdir do |dir|
      project_path = File.join(dir, "project")
      FileUtils.mkdir_p(project_path)
      return TestableBackend.new(
        { "name" => "default", "timeout" => 10, "extra_flags" => "" },
        @shutdown,
        message_dir: File.join(project_path, "to_message"),
        project_path: project_path,
        **opts
      )
    end
  end

  def sink_bundle(output_sink)
    AgentDaemon::Sinks::Bundle.new(entity_id: "backend-test", output: output_sink)
  end
end

class TestBackendFactory < Minitest::Test
  def setup
    @shutdown = TestShutdownFlag.new
  end

  def test_factory_builds_claude_by_default
    backend = AgentDaemon::Backend.for(
      { "name" => "r", "backend" => "claude" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    assert_instance_of AgentDaemon::Backend::Claude, backend
  end

  def test_factory_builds_opencode
    backend = AgentDaemon::Backend.for(
      { "name" => "r", "backend" => "opencode" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    assert_instance_of AgentDaemon::Backend::OpenCode, backend
  end

  def test_factory_forwards_cancel_flag
    flag = TestShutdownFlag.new
    backend = AgentDaemon::Backend.for(
      { "name" => "r", "backend" => "claude" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj",
      cancel_flag: flag
    )
    assert_same flag, backend.instance_variable_get(:@cancel_flag)
  end

  def test_factory_rejects_unknown_backend
    err = assert_raises(ArgumentError) do
      AgentDaemon::Backend.for(
        { "name" => "r", "backend" => "magic" },
        @shutdown,
        message_dir: "/tmp/msg",
        project_path: "/tmp/proj"
      )
    end
    assert_includes err.message, "magic"
    assert_includes err.message, "\"r\""
  end

  def test_claude_command_includes_both_add_dirs
    backend = AgentDaemon::Backend::Claude.new(
      { "name" => "r", "agent" => "task-analyst", "extra_flags" => "", "output_dir" => "/tmp/out" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    cmd = backend.send(:build_command, "hello")
    assert_includes cmd, "--add-dir /tmp/msg"
    assert_includes cmd, "--add-dir /tmp/out"
  end

  def test_claude_command_deduplicates_add_dir
    backend = AgentDaemon::Backend::Claude.new(
      { "name" => "r", "agent" => "task-analyst", "extra_flags" => "", "output_dir" => "/tmp/msg" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    cmd = backend.send(:build_command, "hello")
    assert_equal 1, cmd.scan("--add-dir /tmp/msg").size
  end

  def test_claude_command_without_output_dir_adds_only_message_dir
    backend = AgentDaemon::Backend::Claude.new(
      { "name" => "r", "agent" => "task-analyst", "extra_flags" => "" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    cmd = backend.send(:build_command, "hello")
    assert_equal 1, cmd.scan("--add-dir").size
    assert_includes cmd, "--add-dir /tmp/msg"
  end
end
