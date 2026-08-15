# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"

class TestMessenger < Minitest::Test
  class ConfigStub
    attr_reader :messenger, :message_dir

    def initialize(messenger, message_dir)
      @messenger = messenger
      @message_dir = message_dir
    end
  end

  class ShutdownStub
    def value
      false
    end
  end

  class TransportStub
    attr_reader :messages

    def initialize
      @messages = []
    end

    def deliver(message)
      @messages << message
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @message_dir = File.join(@tmpdir, "to_message")
    FileUtils.mkdir_p(@message_dir)

    # These tests exercise Messenger#run, which logs a line per delivery.
    # AgentDaemon::Log's logger is a process-wide singleton, so silence it for
    # the duration of this file and hand back whatever was installed before.
    @prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, @prior_logger)
    FileUtils.remove_entry(@tmpdir)
  end

  def process(messenger_config, payload)
    config = ConfigStub.new(messenger_config, @message_dir)
    messenger = AgentDaemon::Messenger.new(config, ShutdownStub.new)
    transport = TransportStub.new
    messenger.instance_variable_set(:@transport, transport)
    path = File.join(@message_dir, "message.yml")
    File.write(path, payload.to_yaml)
    messenger.send(:process_file, path)
    transport.messages.first
  end

  def mattermost_config(alerts = nil)
    {
      "type" => "mattermost",
      "base_url" => "https://mm.example.com",
      "token" => "token",
      "team" => "eng",
      "default_channel" => "ops",
      "interval" => 1
    }.tap { |config| config["alerts"] = alerts if alerts }
  end

  def test_routes_system_alert_to_configured_user_as_separate_post
    delivered = process(
      mattermost_config("user" => "alexander.shvaykin"),
      "system_alert" => true,
      "task_key" => "SYSTEM:reviewer",
      "channel_id" => "source-channel",
      "root_id" => "source-root",
      "message" => "Runner reviewer failed"
    )

    assert_equal "alexander.shvaykin", delivered["user"]
    refute delivered.key?("channel_id")
    refute delivered.key?("root_id")
    refute delivered.key?("channel")
  end

  def test_routes_system_alert_to_configured_channel
    delivered = process(
      mattermost_config("channel" => "dev-alerts"),
      "system_alert" => true,
      "task_key" => "SYSTEM:reviewer",
      "message" => "Runner reviewer failed"
    )

    assert_equal "dev-alerts", delivered["channel"]
    refute delivered.key?("user")
    refute delivered.key?("root_id")
  end

  def test_system_alert_without_alerts_keeps_default_channel_fallback
    delivered = process(
      mattermost_config,
      "system_alert" => true,
      "task_key" => "SYSTEM:reviewer",
      "message" => "Runner reviewer failed"
    )

    refute delivered.key?("channel")
    refute delivered.key?("user")
  end
end
