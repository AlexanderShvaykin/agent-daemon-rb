# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

class TestDaemon < Minitest::Test
  def setup
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)

    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    FileUtils.mkdir_p(@project_path)
    template = File.join(@tmpdir, "p.txt")
    File.write(template, "x")
    @template = template
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def make_config(runners)
    path = File.join(@tmpdir, "config.yml")
    data = {
      "project_path" => @project_path,
      "tracker" => { "token" => "t", "org_id" => "o" },
      "runners" => runners,
      "messenger" => { "webhook_url" => "https://example.com/h" }
    }
    File.write(path, data.to_yaml)
    AgentDaemon::Config.new(path)
  end

  def tracker_runner(name)
    {
      "name" => name,
      "prompt_template" => File.basename(@template),
      "trigger" => { "type" => "tracker", "query" => "Queue: TI" }
    }
  end

  def file_runner(name)
    {
      "name" => name,
      "prompt_template" => File.basename(@template),
      "trigger" => {
        "type" => "file",
        "input_dir" => "inbox/",
        "archive_dir" => "inbox/archive/",
        "failed_dir" => "inbox/failed/"
      }
    }
  end

  def test_daemon_builds_factory_per_runner
    config = make_config([tracker_runner("a"), file_runner("b")])
    daemon = AgentDaemon::Daemon.new(config)
    daemon.send(:build_runner_factories)

    factories = daemon.instance_variable_get(:@runner_factories)
    assert_equal 3, factories.size
    assert factories.key?(:"runner:a")
    assert factories.key?(:"runner:b")
    assert factories.key?(:messenger)
  end

  def test_runner_factory_for_tracker_returns_tracker_runner
    config = make_config([tracker_runner("a")])
    daemon = AgentDaemon::Daemon.new(config)
    factory = daemon.send(:runner_factory_for, config.runners.first)
    instance = factory.call
    assert_instance_of AgentDaemon::Runner::Tracker, instance
  end

  def test_runner_factory_for_file_returns_file_runner
    config = make_config([file_runner("b")])
    daemon = AgentDaemon::Daemon.new(config)
    factory = daemon.send(:runner_factory_for, config.runners.first)
    instance = factory.call
    assert_instance_of AgentDaemon::Runner::File, instance
  end
end
