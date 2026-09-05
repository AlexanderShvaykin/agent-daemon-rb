# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class PachcaStubBackend
  attr_reader :prompts

  def initialize(reasons = [])
    @reasons = reasons.dup
    @prompts = []
  end

  def run(prompt)
    @prompts << prompt
    reason = @reasons.shift || :ok
    AgentDaemon::Backend::Result.new(reason == :ok, "stdout", "stderr", reason)
  end
end

class PachcaStubShutdown
  def value = false
end

# Records every call so a test can assert what was fetched and acknowledged.
# `delete_failures` names ids whose first delete attempt raises, so the retry
# path is exercised without any timing.
class StubPachcaClient
  attr_reader :deleted, :fetches

  def initialize(pages, delete_failures: [])
    @pages = pages.dup
    @delete_failures = delete_failures.dup
    @deleted = []
    @fetches = 0
  end

  def events(limit: 50)
    @fetches += 1
    (@pages.shift || []).sort_by { |event| event["id"].to_s }
  end

  def delete_event(id)
    if @delete_failures.delete(id)
      raise "boom"
    end

    @deleted << id
    true
  end
end

class TestRunnerPachca < Minitest::Test
  BOT = 111
  CHAT = 900

  def setup
    @prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    @message_dir = File.join(@project_path, "to_message")
    FileUtils.mkdir_p(@message_dir)

    @template_path = File.join(@tmpdir, "prompt.txt")
    File.write(@template_path, "chat {{chat_id}} from {{sender_id}}: {{message}} (root {{parent_message_id}})")

    null_logger = ::Logger.new(File::NULL)
    null_logger.level = ::Logger::FATAL
    AgentDaemon::Log.instance_variable_set(:@logger, null_logger)
  end

  def teardown
    AgentDaemon::Log.instance_variable_set(:@logger, @prior_logger)
    AgentDaemon::Log.clear_context
    FileUtils.remove_entry(@tmpdir)
  end

  def runner_config(trigger_overrides = {})
    {
      "name" => "qa",
      "backend" => "claude",
      "max_attempts" => 3,
      "prompt_template_path" => @template_path,
      "trigger" => {
        "type" => "pachca",
        "token" => "tok",
        "bot_user_id" => BOT,
        "chats" => [CHAT],
        "interval" => 5,
        "jitter" => 0
      }.merge(trigger_overrides)
    }
  end

  def build_runner(client, reasons: [], trigger_overrides: {})
    runner = AgentDaemon::Runner::Pachca.new(
      runner_config(trigger_overrides), @message_dir, @project_path, PachcaStubShutdown.new
    )
    runner.instance_variable_set(:@backend, PachcaStubBackend.new(reasons))
    runner.instance_variable_set(:@client, client)
    runner
  end

  def event(id:, user_id: 222, chat_id: CHAT, event_type: "message_new", content: "привет", **payload)
    {
      "id" => id,
      "event_type" => event_type,
      "payload" => { "user_id" => user_id, "chat_id" => chat_id, "content" => content }
        .merge(payload.transform_keys(&:to_s))
    }
  end

  def fetch(runner) = runner.send(:fetch_work_items)
  def backend(runner) = runner.instance_variable_get(:@backend)
  def settled(runner) = runner.instance_variable_get(:@settled)

  # --- filtering -----------------------------------------------------------

  def test_a_qualifying_event_is_picked_up
    runner = build_runner(StubPachcaClient.new([[event(id: "01A")]]))

    assert_equal %w[01A], fetch(runner).map { |e| e["id"] }
  end

  # The agent replies into the same chat it reads. Without this gate every
  # answer is re-ingested as a new question and the runner loops on itself.
  def test_the_bots_own_messages_are_skipped
    runner = build_runner(StubPachcaClient.new([[event(id: "01A", user_id: BOT)]]))

    assert_empty fetch(runner)
  end

  def test_messages_from_other_chats_are_skipped
    runner = build_runner(StubPachcaClient.new([[event(id: "01A", chat_id: 999)]]))

    assert_empty fetch(runner)
  end

  def test_other_event_types_are_skipped
    runner = build_runner(StubPachcaClient.new([[event(id: "01A", event_type: "reaction_new")]]))

    assert_empty fetch(runner)
  end

  def test_event_types_are_configurable
    runner = build_runner(
      StubPachcaClient.new([[event(id: "01A", event_type: "button_click")]]),
      trigger_overrides: { "event_types" => %w[button_click] }
    )

    assert_equal %w[01A], fetch(runner).map { |e| e["id"] }
  end

  def test_allowed_users_gates_the_author_when_configured
    events = [event(id: "01A", user_id: 222), event(id: "01B", user_id: 333)]
    runner = build_runner(StubPachcaClient.new([events]), trigger_overrides: { "allowed_users" => [333] })

    assert_equal %w[01B], fetch(runner).map { |e| e["id"] }
  end

  def test_without_allowed_users_any_chat_member_may_trigger
    events = [event(id: "01A", user_id: 222), event(id: "01B", user_id: 333)]
    runner = build_runner(StubPachcaClient.new([events]))

    assert_equal %w[01A 01B], fetch(runner).map { |e| e["id"] }
  end

  def test_a_payloadless_event_is_skipped_rather_than_raising
    runner = build_runner(StubPachcaClient.new([[{ "id" => "01A", "event_type" => "message_new" }]]))

    assert_empty fetch(runner)
  end

  # --- prompt --------------------------------------------------------------

  def test_the_prompt_gets_the_payload_fields
    runner = build_runner(StubPachcaClient.new([[event(id: "01A", parent_message_id: 77)]]))

    prompt = runner.send(:render_prompt, fetch(runner).first)

    assert_equal "chat 900 from 222: привет (root 77)", prompt
  end

  # A root message carries no parent_message_id; the key is present with a nil
  # value, so it renders empty instead of leaking a literal {{...}}.
  def test_a_nil_payload_field_renders_empty_not_as_a_placeholder
    runner = build_runner(StubPachcaClient.new([[event(id: "01A")]]))

    prompt = runner.send(:render_prompt, fetch(runner).first)

    assert_equal "chat 900 from 222: привет (root )", prompt
    refute_includes prompt, "{{"
  end

  # --- acknowledgement -----------------------------------------------------

  def test_a_processed_event_is_deleted_from_the_history
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client)

    runner.send(:iterate)

    assert_equal %w[01A], client.deleted
    assert_equal 1, backend(runner).prompts.size
  end

  # Below max_attempts a failed run leaves the event in place, so the next poll
  # retries it — the same contract as Runner::File leaving the file in inbox.
  def test_a_failed_run_does_not_acknowledge_the_event
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client, reasons: [:failed])

    runner.send(:iterate)

    assert_empty client.deleted
  end

  def test_an_exhausted_event_is_acknowledged_and_dropped
    events = [event(id: "01A")]
    client = StubPachcaClient.new([events, events, events, events])
    runner = build_runner(client, reasons: %i[failed failed failed])

    4.times { runner.send(:iterate) }

    assert_equal %w[01A], client.deleted
    assert_equal 3, backend(runner).prompts.size
  end

  # A delete that failed must not let the event be answered twice: it stays in
  # @settled, is filtered out of the next fetch, and the delete is retried.
  def test_a_failed_delete_is_retried_and_never_reprocessed
    events = [event(id: "01A")]
    client = StubPachcaClient.new([events, events], delete_failures: %w[01A])
    runner = build_runner(client)

    runner.send(:iterate)
    assert_empty client.deleted
    assert_includes settled(runner), "01A"

    runner.send(:iterate)

    assert_equal %w[01A], client.deleted
    assert_empty settled(runner)
    assert_equal 1, backend(runner).prompts.size, "the event must be answered exactly once"
  end

  # --- rate limiting -------------------------------------------------------

  def test_a_throttle_backs_off_without_counting_as_a_trigger_error
    client = Object.new
    def client.events(limit: 50) = raise(AgentDaemon::RateLimitError.new(17))

    runner = build_runner(client)
    runner.send(:iterate)

    assert_equal 17, runner.instance_variable_get(:@backoff)
    assert_equal 0, runner.instance_variable_get(:@consecutive_errors)
  end
end
