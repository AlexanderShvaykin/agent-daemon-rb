# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class StubBackendFile
  def initialize(reasons)
    @reasons = reasons.dup
  end

  def run(_prompt)
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

    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def build_runner(reasons)
    runner = AgentDaemon::Runner::File.new(
      @runner_config, @message_dir, @project_path, StubShutdownFile.new
    )
    runner.instance_variable_set(:@backend, StubBackendFile.new(reasons))
    runner
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
    runner = build_runner([:killed])
    runner.send(:process_item, path)

    assert File.exist?(path)
    refute File.exist?(File.join(@archive_dir, "TASK-1.yml"))
    refute File.exist?(File.join(@failed_dir, "TASK-1.yml"))
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
