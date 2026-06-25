# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

class StubShutdownMattermost
  def value
    false
  end
end

class TestRunnerMattermost < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    @message_dir = File.join(@project_path, "to_message")
    @input_dir   = File.join(@project_path, "mentions/mention-bot/inbox")
    @archive_dir = File.join(@project_path, "mentions/mention-bot/done")
    @failed_dir  = File.join(@project_path, "mentions/mention-bot/failed")
    FileUtils.mkdir_p(@message_dir)

    template_path = File.join(@tmpdir, "prompt.txt")
    File.write(template_path, <<~TPL)
      from {{sender}} in {{channel_name}} ({{channel_id}})
      post {{post_id}} root {{root_id}}
      says: {{message}}
    TPL

    @runner_config = {
      "name" => "mention-bot",
      "backend" => "claude",
      "agent" => "task-analyst",
      "extra_flags" => "",
      "timeout" => 1200,
      "max_attempts" => 3,
      "prompt_template" => "prompt.txt",
      "prompt_template_path" => template_path,
      "trigger" => {
        "type" => "mattermost",
        "base_url" => "https://mm.example.com",
        "token" => "bot-token",
        "team" => "engineering",
        "channels" => %w[general],
        "input_dir" => @input_dir,
        "archive_dir" => @archive_dir,
        "failed_dir" => @failed_dir,
        "interval" => 2
      }
    }

    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def build_runner
    AgentDaemon::Runner::Mattermost.new(
      @runner_config, @message_dir, @project_path, StubShutdownMattermost.new
    )
  end

  def test_render_prompt_exposes_work_item_fields
    item = {
      "message"      => "@bot please look",
      "channel_id"   => "chan123",
      "root_id"      => "root456",
      "sender"       => "alice",
      "channel_name" => "general",
      "post_id"      => "post789",
      "created_at"   => "2026-06-24T12:00:00Z"
    }
    runner = build_runner
    path = File.join(@input_dir, "post789.yml")
    File.write(path, item.to_yaml)

    prompt = runner.send(:render_prompt, path)

    assert_includes prompt, "@bot please look"
    assert_includes prompt, "chan123"
    assert_includes prompt, "root456"
    assert_includes prompt, "alice"
    assert_includes prompt, "general"
    assert_includes prompt, "post789"
  end
end
