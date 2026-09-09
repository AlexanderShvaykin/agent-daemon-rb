# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"

class TestMessenger < Minitest::Test
  include LogStubbing

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

  # Trips the generation cancel token on its first delivery, so a Messenger
  # holding a backlog has to observe the token *inside* the per-file loop to
  # stop. Without that, the only cancel-aware test writes zero files and never
  # enters the loop at all.
  class CancellingTransportStub < TransportStub
    def initialize(cancel_flag)
      super()
      @cancel_flag = cancel_flag
    end

    def deliver(message)
      super
      @cancel_flag.set!
    end
  end

  class StateSink
    attr_reader :records, :published

    def initialize
      @records = []
      @published = Thread::Queue.new
    end

    def publish(_entity_id, record)
      @records << record
      @published << record
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @message_dir = File.join(@tmpdir, "to_message")
    FileUtils.mkdir_p(@message_dir)

    # These tests exercise Messenger#run, which logs a line per delivery.
    # AgentDaemon::Log's logger is a process-wide singleton, so silence it for
    # the duration of this file and hand back whatever was installed before.
    stub_null_logger!
  end

  def teardown
    restore_logger!
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

  def test_iterate_processes_yml_and_yaml_in_global_filename_order
    files = {
      "post-2-result.yml" => "post-2-result.yml",
      "post-1-ack.yaml" => "post-1-ack.yaml",
      "reply.yml" => "reply.yml",
      "reply.yaml" => "reply.yaml"
    }
    files.each do |filename, task_key|
      File.write(
        File.join(@message_dir, filename),
        { "task_key" => task_key, "message" => task_key }.to_yaml
      )
    end
    ignored_path = File.join(@message_dir, "post-3.yaml.tmp")
    File.write(ignored_path, { "task_key" => "ignored" }.to_yaml)

    config = ConfigStub.new(mattermost_config, @message_dir)
    messenger = AgentDaemon::Messenger.new(config, ShutdownStub.new)
    transport = TransportStub.new
    messenger.instance_variable_set(:@transport, transport)

    messenger.send(:iterate)

    expected_order = files.keys.sort
    assert_equal expected_order, transport.messages.map { |message| message["task_key"] }
    assert_equal expected_order, Dir.children(File.join(@message_dir, "sent")).sort
    files.each_key { |filename| refute_path_exists File.join(@message_dir, filename) }
    assert_path_exists ignored_path
  end

  # An agent that decides it has nothing to add still has to leave a file: a
  # trigger with expects_message_file? set reads a missing one as a failed run
  # and retries it. So silence is stated, not implied — and archiving the file
  # acks the work item, because the decision is final rather than deferred.
  def test_a_skipped_message_is_archived_without_being_sent
    File.write(File.join(@message_dir, "quiet.yml"),
               { "task_key" => "quiet", "skip" => true, "reason" => "not addressed to me" }.to_yaml)
    File.write(File.join(@message_dir, "loud.yml"),
               { "task_key" => "loud", "message" => "答" }.to_yaml)

    config = ConfigStub.new(mattermost_config, @message_dir)
    messenger = AgentDaemon::Messenger.new(config, ShutdownStub.new)
    transport = TransportStub.new
    messenger.instance_variable_set(:@transport, transport)

    messenger.send(:iterate)

    assert_equal %w[loud], transport.messages.map { |m| m["task_key"] }
    assert_equal %w[loud.yml quiet.yml], Dir.children(File.join(@message_dir, "sent")).sort
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

  def test_generation_cancel_stops_the_messenger_without_publishing_stopped
    config = ConfigStub.new(mattermost_config.merge("interval" => 60), @message_dir)
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    cancel_flag = AgentDaemon::ShutdownFlag.new
    state_sink = StateSink.new
    sinks = AgentDaemon::Sinks::Bundle.new(entity_id: "messenger:wf", state: state_sink)
    messenger = AgentDaemon::Messenger.new(
      config, shutdown_flag, sinks: sinks, cancel_flag: cancel_flag
    )

    thread = Thread.new { messenger.run }
    assert_equal({ status: :running }, state_sink.published.pop)
    cancel_flag.set!

    assert thread.join(2), "cancelled Messenger did not return within its existing tick bound"
    assert_equal [{ status: :running }], state_sink.records
  ensure
    shutdown_flag&.set!
    thread&.join(2)
  end

  # `iterate`'s per-file gate is `break if stopping?`, not `break if
  # @shutdown_flag.value`. Revert that one line and a manually restarted
  # Messenger drains its whole queue to the webhook before returning, which is
  # exactly the turnover window the restart is waiting on.
  def test_generation_cancel_stops_the_messenger_mid_backlog
    3.times do |i|
      File.write(File.join(@message_dir, "m#{i}.yml"), { "text" => "n#{i}" }.to_yaml)
    end
    config = ConfigStub.new(mattermost_config.merge("interval" => 60), @message_dir)
    shutdown_flag = AgentDaemon::ShutdownFlag.new
    cancel_flag = AgentDaemon::ShutdownFlag.new
    transport = CancellingTransportStub.new(cancel_flag)
    messenger = AgentDaemon::Messenger.new(config, shutdown_flag, cancel_flag: cancel_flag)
    messenger.instance_variable_set(:@transport, transport)

    thread = Thread.new { messenger.run }

    assert thread.join(2), "cancelled Messenger did not return within its existing tick bound"
    assert_equal 1, transport.messages.size,
                 "a cancelled Messenger must stop mid-backlog, not drain the queue"
    assert_equal 2, Dir.glob(File.join(@message_dir, "*.yml")).size,
                 "the undelivered messages must stay in message_dir for the next generation"
  ensure
    shutdown_flag&.set!
    thread&.join(2)
  end
end
