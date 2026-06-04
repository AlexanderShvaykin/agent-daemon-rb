# frozen_string_literal: true

require "test_helper"

class TestTransportFactory < Minitest::Test
  def test_default_type_is_webhook
    transport = AgentDaemon::Transport.for("webhook_url" => "https://example.com/h")
    assert_instance_of AgentDaemon::Transport::Webhook, transport
  end

  def test_explicit_mattermost_type
    transport = AgentDaemon::Transport.for(
      "type" => "mattermost",
      "base_url" => "https://mm.example.com",
      "token" => "t",
      "team" => "eng",
      "default_channel" => "alerts"
    )
    assert_instance_of AgentDaemon::Transport::Mattermost, transport
  end

  def test_unknown_type_raises_listing_valid_values
    err = assert_raises(ArgumentError) do
      AgentDaemon::Transport.for("type" => "carrier-pigeon")
    end
    assert_includes err.message, "webhook"
    assert_includes err.message, "mattermost"
  end
end
