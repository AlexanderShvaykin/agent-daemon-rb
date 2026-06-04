# frozen_string_literal: true

require "test_helper"
require "json"

class TestTransportWebhook < Minitest::Test
  def setup
    null_logger = ::Logger.new(File::NULL)
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def build(http)
    transport = AgentDaemon::Transport::Webhook.new("webhook_url" => "https://example.com/hook")
    stub_net_http(http) { yield transport }
  end

  def test_posts_text_payload
    http = FakeHttp.new { FakeSuccess.new }
    build(http) { |t| t.deliver("message" => "Done") }

    req = http.requests.first
    assert_equal "/hook", req.path
    assert_equal({ "text" => "Done" }, JSON.parse(req.body))
  end

  def test_ignores_channel_and_user_fields
    http = FakeHttp.new { FakeSuccess.new }
    build(http) { |t| t.deliver("message" => "Done", "channel" => "dev", "user" => "ivan") }

    assert_equal 1, http.requests.size
    assert_equal({ "text" => "Done" }, JSON.parse(http.requests.first.body))
  end

  def test_non_2xx_raises
    http = FakeHttp.new { FakeServerError.new }
    err = assert_raises(RuntimeError) do
      build(http) { |t| t.deliver("message" => "Done") }
    end
    assert_includes err.message, "503"
  end
end
