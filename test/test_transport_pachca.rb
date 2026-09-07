# frozen_string_literal: true

require "test_helper"
require "tmpdir"

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

  # --- files ---------------------------------------------------------------

  UPLOAD_SIGNATURE = {
    "policy" => "eyJleHBpcmF0aW9u", "x-amz-signature" => "cd7cec6b",
    "key" => "attaches/files/825566/dd9698fc/${filename}",
    "direct_url" => "https://pachca-prod-uploads.s3.storage.selcloud.ru"
  }.freeze

  # /uploads and /messages both live under the API path, so the leg is told
  # apart by the endpoint rather than by the host.
  def deliver_with_files(message_data)
    fake = FakeHttp.new do |req|
      case req.path
      when "/api/shared/v1/uploads" then FakeSuccess.new(JSON.generate(UPLOAD_SIGNATURE))
      when "/api/shared/v1/messages" then FakeSuccess.new(JSON.generate("data" => { "id" => 1 }))
      else FakeSuccess.new("")
      end
    end

    Dir.mktmpdir do |dir|
      path = File.join(dir, "chart.png")
      File.binwrite(path, "\x89PNG binary".b)
      stub_net_http(fake) { transport.deliver(message_data.call(path)) }
    end

    fake
  end

  def posted_message(fake)
    JSON.parse(fake.requests.find { |req| req.path == "/api/shared/v1/messages" }.body).fetch("message")
  end

  def test_a_file_path_is_uploaded_and_referenced_by_the_message
    fake = deliver_with_files(->(path) { { "message" => "график", "chat_id" => 900, "files" => [path] } })

    assert_equal ["/api/shared/v1/uploads", "/", "/api/shared/v1/messages"], fake.requests.map(&:path)
    assert_equal([{ "key" => "attaches/files/825566/dd9698fc/chart.png", "name" => "chart.png",
                    "file_type" => "image", "size" => 11 }], posted_message(fake)["files"])
    assert_equal "график", posted_message(fake)["content"]
  end

  # One file need not be written as a list, and the Hash form renames it.
  def test_a_single_hash_entry_carries_a_display_name_and_file_type
    fake = deliver_with_files(lambda do |path|
      { "message" => "лог", "chat_id" => 900,
        "files" => { "path" => path, "name" => "Отчёт за вчера.png", "file_type" => "file" } }
    end)

    assert_equal([{ "key" => "attaches/files/825566/dd9698fc/Отчёт за вчера.png",
                    "name" => "Отчёт за вчера.png", "file_type" => "file", "size" => 11 }],
                 posted_message(fake)["files"])
  end

  def test_a_message_without_files_posts_exactly_one_request_and_no_files_key
    fake = deliver("message" => "текст", "chat_id" => 900)

    assert_equal 1, fake.requests.size
    refute_includes created(fake), "files"
  end

  def test_an_unreadable_path_raises_rather_than_sending_the_text_alone
    fake = FakeHttp.new { |_req| FakeSuccess.new(JSON.generate("data" => { "id" => 1 })) }

    error = assert_raises(RuntimeError) do
      stub_net_http(fake) { transport.deliver("message" => "график", "chat_id" => 900, "files" => ["/nope/x.png"]) }
    end

    assert_match(%r{/nope/x\.png is not a readable file}, error.message)
    assert_empty fake.requests
  end

  def test_a_file_entry_without_a_path_raises
    fake = FakeHttp.new { |_req| FakeSuccess.new(JSON.generate("data" => { "id" => 1 })) }

    error = assert_raises(RuntimeError) do
      stub_net_http(fake) { transport.deliver("message" => "график", "chat_id" => 900, "files" => [{ "name" => "chart.png" }]) }
    end

    assert_match(/has no "path"/, error.message)
  end

  def test_the_factory_dispatches_on_the_type
    assert_instance_of AgentDaemon::Transport::Pachca, AgentDaemon::Transport.for(CONFIG)
    assert_includes AgentDaemon::Transport::VALID_TYPES, "pachca"
  end
end
