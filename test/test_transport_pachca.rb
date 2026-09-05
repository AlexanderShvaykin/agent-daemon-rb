# frozen_string_literal: true

require "test_helper"

class TestTransportPachca < Minitest::Test
  CONFIG = { "type" => "pachca", "token" => "tok", "default_chat_id" => 500 }.freeze

  def transport(config = CONFIG)
    AgentDaemon::Transport::Pachca.new(config)
  end

  def created(fake)
    JSON.parse(fake.requests.first.body).fetch("message")
  end

  def deliver(message_data, config = CONFIG)
    fake = FakeHttp.new { |_req| FakeSuccess.new(JSON.generate("data" => { "id" => 1 })) }
    stub_net_http(fake) { transport(config).deliver(message_data) }
    fake
  end

  def test_the_body_is_nested_under_message_and_hits_the_shared_v1_path
    fake = deliver("message" => "привет", "chat_id" => 900)

    request = fake.requests.first
    assert_equal "POST", request.method
    assert_equal "/api/shared/v1/messages", request.path
    assert_equal "Bearer tok", request["Authorization"]
    assert_equal({ "entity_type" => "discussion", "entity_id" => 900, "content" => "привет" }, created(fake))
  end

  # The pair a threaded reply echoes straight back from the work item.
  def test_an_explicit_entity_pair_is_used_verbatim
    fake = deliver("message" => "ответ", "entity_type" => "thread", "entity_id" => 33_177_699,
                   "parent_message_id" => 1_067_135_135)

    assert_equal({ "entity_type" => "thread", "entity_id" => 33_177_699, "content" => "ответ",
                   "parent_message_id" => 1_067_135_135 }, created(fake))
  end

  def test_entity_id_alone_defaults_to_a_discussion
    fake = deliver("message" => "текст", "entity_id" => 900)

    assert_equal "discussion", created(fake)["entity_type"]
  end

  # Pachca opens the conversation on first contact, so a DM needs no channel
  # created first — unlike the mattermost transport's POST /channels/direct.
  def test_a_user_becomes_a_direct_message
    fake = deliver("message" => "в личку", "user" => 42)

    assert_equal({ "entity_type" => "user", "entity_id" => 42, "content" => "в личку" }, created(fake))
  end

  # SYSTEM:<runner> errors carry no routing fields at all.
  def test_a_message_without_routing_goes_to_the_default_chat
    fake = deliver("message" => "Ошибка runner qa")

    assert_equal 500, created(fake)["entity_id"]
  end

  def test_parent_message_id_is_omitted_when_absent
    fake = deliver("message" => "текст", "chat_id" => 900)

    refute_includes created(fake).keys, "parent_message_id"
  end

  # The ids come out of a YAML the agent wrote, where a number may well have
  # been quoted.
  def test_ids_written_as_strings_are_coerced
    fake = deliver("message" => "текст", "entity_id" => "900", "parent_message_id" => "77")

    assert_equal 900, created(fake)["entity_id"]
    assert_equal 77, created(fake)["parent_message_id"]
  end

  def test_a_nonsense_id_falls_through_to_the_default_chat
    fake = deliver("message" => "текст", "chat_id" => "не число")

    assert_equal 500, created(fake)["entity_id"]
  end

  def test_both_user_and_chat_id_is_refused_rather_than_guessed
    error = assert_raises(RuntimeError) { deliver("message" => "текст", "user" => 42, "chat_id" => 900) }
    assert_match(/refusing to guess a destination/, error.message)
  end

  # Most likely a reply whose entity_id never got substituted. Sending it to
  # the default chat would drop the answer in the wrong place rather than fail.
  def test_entity_type_without_entity_id_is_refused
    error = assert_raises(RuntimeError) { deliver("message" => "текст", "entity_type" => "thread") }
    assert_match(/without entity_id/, error.message)
  end

  # Messenger counts consecutive failures off a raise, so an API refusal must
  # not be swallowed.
  def test_an_api_error_propagates_to_the_caller
    fake = FakeHttp.new { |_req| FakeServerError.new }

    assert_raises(RuntimeError) { stub_net_http(fake) { transport.deliver("message" => "текст") } }
  end

  # A question asked in a channel has no thread of its own, so echoing its
  # entity pair back would answer beside it, not under it. Pachca creates the
  # thread on demand (idempotently) and the reply goes there.
  def test_a_channel_question_gets_its_thread_created_and_answered_in
    fake = FakeHttp.new do |req|
      if req.path.end_with?("/thread")
        FakeSuccess.new(JSON.generate("data" => { "id" => 33_177_699, "chat_id" => 43_358_443 }))
      else
        FakeSuccess.new(JSON.generate("data" => { "id" => 1 }))
      end
    end

    stub_net_http(fake) do
      transport.deliver("message" => "ответ", "entity_type" => "discussion",
                        "entity_id" => 43_358_437, "reply_to_message_id" => 1_067_146_413)
    end

    assert_equal "/api/shared/v1/messages/1067146413/thread", fake.requests.first.path
    posted = JSON.parse(fake.requests.last.body).fetch("message")
    assert_equal({ "entity_type" => "thread", "entity_id" => 33_177_699, "content" => "ответ" }, posted)
  end

  # Already inside a thread: no extra call, answer straight into it.
  def test_a_thread_question_needs_no_thread_creation
    fake = deliver("message" => "ответ", "entity_type" => "thread", "entity_id" => 33_177_699,
                   "reply_to_message_id" => 1_067_146_413)

    assert_equal 1, fake.requests.size
    assert_equal "/api/shared/v1/messages", fake.requests.first.path
    assert_equal "thread", created(fake)["entity_type"]
  end

  def test_the_factory_dispatches_on_the_type
    assert_instance_of AgentDaemon::Transport::Pachca, AgentDaemon::Transport.for(CONFIG)
    assert_includes AgentDaemon::Transport::VALID_TYPES, "pachca"
  end
end
