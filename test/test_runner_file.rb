# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class StubBackendFile
  def initialize(reasons)
    @reasons = reasons.dup
  end

  def run(_prompt, images: [])
    reason = @reasons.shift || :ok
    AgentDaemon::Backend::Result.new(reason == :ok, "stdout", "stderr", reason)
  end
end

class StubShutdownFile
  def value
    false
  end
end

class TestRunnerFile < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    @message_dir = File.join(@project_path, "to_message")
    @input_dir   = File.join(@project_path, "review_inbox")
    @archive_dir = File.join(@project_path, "review_inbox/archive")
    @failed_dir  = File.join(@project_path, "review_inbox/failed")
    FileUtils.mkdir_p(@message_dir)
    FileUtils.mkdir_p(@input_dir)
    FileUtils.mkdir_p(@archive_dir)
    FileUtils.mkdir_p(@failed_dir)

    template_path = File.join(@tmpdir, "prompt.txt")
    File.write(template_path, "review {{input_file}}")

    @runner_config = {
      "name" => "reviewer",
      "backend" => "claude",
      "agent" => "task-analyst",
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
        "interval" => 10
      }
    }

    # AgentDaemon::Log's logger is a process-wide singleton and this suite runs
    # in one process — save it here and restore it in teardown so a swap made
    # by any test in this file cannot outlive the file.
    @prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, @prior_logger)
    FileUtils.remove_entry(@tmpdir)
  end

  def build_runner(reasons, cancel_flag: nil)
    options = {}
    options[:cancel_flag] = cancel_flag if cancel_flag
    runner = AgentDaemon::Runner::File.new(
      @runner_config, @message_dir, @project_path, StubShutdownFile.new,
      **options
    )
    runner.instance_variable_set(:@backend, StubBackendFile.new(reasons))
    runner
  end

  def test_forwards_cancel_flag_to_backend
    token = Struct.new(:value).new(false)
    runner = AgentDaemon::Runner::File.new(
      @runner_config, @message_dir, @project_path, StubShutdownFile.new,
      cancel_flag: token
    )

    assert_same token, runner.instance_variable_get(:@cancel_flag)
    assert_same token, runner.instance_variable_get(:@backend).instance_variable_get(:@cancel_flag)
  end

  # AC8 names Mattermost explicitly. Runner::Mattermost declares no
  # initialize and overrides only render_prompt, so its half of AC8 rests
  # entirely on inheriting File's signature — assert that rather than argue it.
  def test_mattermost_inherits_the_cancel_flag_forwarding
    token = Struct.new(:value).new(false)
    runner = AgentDaemon::Runner::Mattermost.new(
      @runner_config, @message_dir, @project_path, StubShutdownFile.new,
      cancel_flag: token
    )

    assert_same token, runner.instance_variable_get(:@cancel_flag)
    assert_same token, runner.instance_variable_get(:@backend).instance_variable_get(:@cancel_flag)
  end

  def test_run_returns_when_cancel_is_already_set
    shutdown = Struct.new(:value).new(false)
    token = Struct.new(:value).new(true)
    runner = AgentDaemon::Runner::File.new(
      @runner_config, @message_dir, @project_path, shutdown,
      cancel_flag: token
    )
    thread = Thread.new { runner.run }

    assert thread.join(0.2), "runner started polling with an already-cancelled generation"
    assert_empty runner.instance_variable_get(:@attempts)
  ensure
    shutdown.value = true if shutdown
    thread&.join(1.2)
  end

  def test_cancel_interrupts_wait_interval_within_the_poll_step
    shutdown = Struct.new(:value).new(false)
    token = Struct.new(:value).new(false)
    runner = AgentDaemon::Runner::File.new(
      @runner_config, @message_dir, @project_path, shutdown,
      cancel_flag: token
    )
    thread = Thread.new { runner.run }

    sleep(0.05)
    token.value = true

    assert thread.join(1.2), "runner did not observe cancellation within the 1s wait step"
  ensure
    shutdown.value = true if shutdown
    thread&.join(1.2)
  end

  def test_cancel_between_items_prevents_the_next_backend_run
    first = File.join(@input_dir, "TASK-1.yml")
    second = File.join(@input_dir, "TASK-2.yml")
    File.write(first, "body")
    File.write(second, "body")
    token = Struct.new(:value).new(false)
    runner = build_runner([], cancel_flag: token)
    calls = []
    backend = Object.new
    backend.define_singleton_method(:run) do |_prompt, images: []|
      calls << true
      token.value = true
      AgentDaemon::Backend::Result.new(true, "stdout", "", :ok)
    end
    runner.instance_variable_set(:@backend, backend)
    runner.define_singleton_method(:fetch_work_items) { [first, second] }

    runner.send(:iterate)

    assert_equal 1, calls.size
    assert File.exist?(second), "positive control: the second item must remain unprocessed"
  end

  def test_creates_missing_directories_on_startup
    FileUtils.rm_rf([@input_dir, @archive_dir, @failed_dir])
    build_runner([])
    assert Dir.exist?(@input_dir)
    assert Dir.exist?(@archive_dir)
    assert Dir.exist?(@failed_dir)
  end

  def test_picks_lexicographically_smallest_yml
    File.write(File.join(@input_dir, "TASK-3.yml"), "")
    File.write(File.join(@input_dir, "TASK-1.yml"), "")
    File.write(File.join(@input_dir, "TASK-2.yml"), "")

    runner = build_runner([])
    items = runner.send(:fetch_work_items)
    assert_equal 1, items.size
    assert_equal "TASK-1.yml", File.basename(items.first)
  end

  def test_ignores_non_yml_files
    File.write(File.join(@input_dir, "TASK-1.yml.tmp"), "")
    runner = build_runner([])
    assert_empty runner.send(:fetch_work_items)
  end

  def test_archives_on_success
    path = File.join(@input_dir, "TASK-1.yml")
    File.write(path, "body")
    runner = build_runner([:ok])
    runner.send(:process_item, path)

    assert File.exist?(File.join(@archive_dir, "TASK-1.yml"))
    refute File.exist?(path)
  end

  def test_moves_to_failed_dir_after_exhausted_attempts
    path = File.join(@input_dir, "TASK-1.yml")
    File.write(path, "body")
    runner = build_runner([:failed, :failed])

    runner.send(:process_item, path)
    assert File.exist?(path), "file should remain after first failure"

    runner.send(:process_item, path)
    refute File.exist?(path)
    assert File.exist?(File.join(@failed_dir, "TASK-1.yml"))
  end

  def test_leaves_file_on_killed
    path = File.join(@input_dir, "TASK-1.yml")
    File.write(path, "body")
    token = Struct.new(:value).new(true)
    runner = build_runner([:killed], cancel_flag: token)
    runner.send(:process_item, path)

    attempts = runner.instance_variable_get(:@attempts)
    assert attempts.key?("TASK-1.yml"), "positive control: the item must have been attempted"
    assert_equal 0, attempts["TASK-1.yml"]
    assert_operator attempts["TASK-1.yml"], :>=, 0
    assert File.exist?(path)
    refute File.exist?(File.join(@archive_dir, "TASK-1.yml"))
    refute File.exist?(File.join(@failed_dir, "TASK-1.yml"))
  end

  def test_killed_log_identifies_restart_cancellation
    path = File.join(@input_dir, "TASK-1.yml")
    File.write(path, "body")
    token = Struct.new(:value).new(true)
    output = StringIO.new
    logger = Logger.new(output)
    logger.level = Logger::INFO
    AgentDaemon::Log.instance_variable_set(:@logger, logger)
    runner = build_runner([:killed], cancel_flag: token)

    runner.send(:process_item, path)

    assert_includes output.string, "(restart), attempt rolled back"
  end

  def test_exhausted_counter_moves_file_to_failed
    path = File.join(@input_dir, "TASK-1.yml")
    File.write(path, "body")

    runner = build_runner([])
    runner.instance_variable_get(:@attempts)["TASK-1.yml"] = 2
    runner.send(:process_item, path)

    refute File.exist?(path)
    assert File.exist?(File.join(@failed_dir, "TASK-1.yml"))
  end
end
