# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class PachcaStubBackend
  attr_reader :prompts

  # A real agent leaves a reply YAML behind, and the runner now looks for it:
  # a run that exits 0 having written nothing is not a success.
  # `writes: false` is exactly that case — the CLI is happy, the answer is not there.
  def initialize(reasons = [], message_dir: nil, writes: true)
    @reasons = reasons.dup
    @prompts = []
    @message_dir = message_dir
    @writes = writes
    @written = 0
  end

  def run(prompt)
    @prompts << prompt
    reason = @reasons.shift || :ok

    if reason == :ok && @writes && @message_dir
      @written += 1
      File.write(File.join(@message_dir, "reply-#{@written}.yml"), "message: ok\n")
    end

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
  attr_reader :deleted, :fetches, :reactions

  def initialize(pages, delete_failures: [])
    @pages = pages.dup
    @delete_failures = delete_failures.dup
    @deleted = []
    @fetches = 0
    @reactions = []
  end

  def add_reaction(message_id, code:, name: nil)
    raise "нет такой реакции" if @reaction_failure

    @reactions << [:add, message_id, code, name]
    true
  end

  def remove_reaction(message_id, code:, name: nil)
    @reactions << [:remove, message_id, code, name]
    true
  end

  def fail_reactions!
    @reaction_failure = true
  end

  def events(limit: 50)
    @fetches += 1
    (@pages.shift || []).sort_by { |event| event["id"].to_s }
  end

  attr_writer :history, :history_error, :root, :root_error
  attr_reader :message_queries, :message_gets

  def messages(chat_id:, limit: 20)
    raise @history_error if @history_error

    (@message_queries ||= []) << [chat_id, limit]
    Array(@history)
  end

  def message(id)
    raise @root_error if @root_error

    (@message_gets ||= []) << id
    @root
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

  def build_runner(client, reasons: [], trigger_overrides: {}, writes: true)
    runner = AgentDaemon::Runner::Pachca.new(
      runner_config(trigger_overrides), @message_dir, @project_path, PachcaStubShutdown.new
    )
    runner.instance_variable_set(:@backend,
                                 PachcaStubBackend.new(reasons, message_dir: @message_dir, writes: writes))
    runner.instance_variable_set(:@client, client)
    runner
  end

  # `id` is the EVENT id (a ULID); `message_id` is the id of the message inside
  # the payload, which is what a reaction attaches to. Two different ids, and
  # keeping them apart here is the point.
  def event(id:, message_id: 555, user_id: 222, chat_id: CHAT, event_type: "message_new", content: "привет", **payload)
    {
      "id" => id,
      "event_type" => event_type,
      "payload" => { "id" => message_id, "user_id" => user_id, "chat_id" => chat_id, "content" => content }
        .merge(payload.transform_keys(&:to_s))
    }
  end

  def fetch(runner) = runner.send(:fetch_work_items)
  def backend(runner) = runner.instance_variable_get(:@backend)
  def settled(runner) = runner.instance_variable_get(:@settled)
  def attempts(runner) = runner.instance_variable_get(:@attempts)

  def capture_log
    prior = AgentDaemon::Log.instance_variable_get(:@logger)
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.level = ::Logger::INFO
    logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
    AgentDaemon::Log.use(logger)
    yield
    io.string
  ensure
    AgentDaemon::Log.instance_variable_set(:@logger, prior)
  end

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

  def test_messages_from_other_chats_are_skipped_when_chats_is_set
    runner = build_runner(StubPachcaClient.new([[event(id: "01A", chat_id: 999)]]))

    assert_empty fetch(runner)
  end

  # Without a chats list the runner answers wherever the bot was invited, and
  # that is what makes direct messages work at all: a DM gets its own chat id,
  # which cannot be listed in advance.
  def test_without_chats_every_received_chat_is_listened_to
    events = [event(id: "01A", chat_id: 999), event(id: "01B", chat_id: 12_345)]
    runner = build_runner(StubPachcaClient.new([events]), trigger_overrides: { "chats" => nil })

    assert_equal %w[01A 01B], fetch(runner).map { |e| e["id"] }
  end

  # The effective scope is stated on startup rather than left to be inferred
  # from the config: with neither list set, the right to command the agent is
  # exactly the right to talk to the bot.
  def test_the_effective_scope_is_logged_on_startup
    assert_match(/listening to every chat the bot receives, any author/,
                 capture_log { build_runner(StubPachcaClient.new([]), trigger_overrides: { "chats" => nil }) })
    assert_match(/listening to chats 900, authors 42/,
                 capture_log { build_runner(StubPachcaClient.new([]), trigger_overrides: { "allowed_users" => [42] }) })
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

  # Verbatim from a live message_new, which is where the two surprises below
  # come from: chat_id is the THREAD's chat, and the thread object carries no
  # id of its own.
  def threaded_event
    {
      "id" => "01M1RWHTDFM26GDFQQ8B8R1GDT",
      "event_type" => "message_new",
      "payload" => {
        "event" => "new", "type" => "message",
        "chat_id" => 43_358_443, "user_id" => 222, "id" => 1_067_135_135,
        "created_at" => "2026-09-05T13:36:27.000Z", "parent_message_id" => nil,
        "content" => "test", "entity_type" => "thread", "entity_id" => 33_177_699,
        "thread" => { "message_id" => 1_067_133_444, "message_chat_id" => 43_358_437 },
        "url" => "https://app.pachca.com/chats?thread_message_id=1067133444"
      }
    }
  end

  # An operator lists the chat id they can actually see, which for a threaded
  # message is thread.message_chat_id — chat_id belongs to the thread itself.
  # Matching only chat_id would silently drop every threaded message in a
  # chat the operator did list.
  def test_a_thread_matches_the_chat_it_hangs_in
    runner = build_runner(StubPachcaClient.new([[threaded_event]]), trigger_overrides: { "chats" => [43_358_437] })

    refute_empty fetch(runner)
  end

  def test_a_thread_also_matches_its_own_chat_id
    runner = build_runner(StubPachcaClient.new([[threaded_event]]), trigger_overrides: { "chats" => [43_358_443] })

    refute_empty fetch(runner)
  end

  def test_an_unrelated_chat_still_does_not_match
    runner = build_runner(StubPachcaClient.new([[threaded_event]]), trigger_overrides: { "chats" => [999] })

    assert_empty fetch(runner)
  end

  # Replying into the originating thread means echoing entity_type/entity_id
  # back to POST /messages; the thread object holds only the message it hangs
  # off of, and no id of its own.
  def test_a_threaded_event_exposes_the_real_reply_target
    runner = build_runner(StubPachcaClient.new([[threaded_event]]), trigger_overrides: { "chats" => nil })
    vars = runner.send(:event_variables, threaded_event)

    assert_equal "thread", vars["entity_type"]
    assert_equal 33_177_699, vars["entity_id"]
    assert_equal 1_067_133_444, vars["thread_message_id"]
    assert_equal 43_358_437, vars["thread_chat_id"]
    assert_equal "test", vars["message"]
    refute_nil vars["url"]
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

  # --- thread context ------------------------------------------------------

  def thread_event(message_id: 555, chat_id: 43_358_443, root_id: 1_067_133_444)
    event(id: "01A", message_id: message_id, chat_id: chat_id,
          entity_type: "thread", entity_id: 33_177_699, content: "а почему?",
          thread: { "message_id" => root_id, "message_chat_id" => 43_358_437 })
  end

  def history_of(*rows)
    rows.each_with_index.map { |(user_id, text), i| { "id" => 100 + i, "user_id" => user_id, "content" => text } }
  end

  # "а почему?" in a thread is unreadable without what came before it.
  def test_a_threaded_question_gets_the_thread_transcript
    client = StubPachcaClient.new([[thread_event]])
    client.history = history_of([222, "деплой сломался"], [BOT, "починил"])
    runner = build_runner(client, trigger_overrides: { "chats" => nil })

    context = runner.send(:thread_context, thread_event)

    assert_equal "222: деплой сломался\nbot: починил", context
  end

  # The message a thread hangs off lives in the parent chat, so listing the
  # thread returns every reply and not the question that started it. Observed
  # live: an agent following up inside a thread it had opened saw only its own
  # answer and said the context was incomplete.
  def test_the_message_the_thread_hangs_off_comes_first
    client = StubPachcaClient.new([[thread_event]])
    client.root = { "id" => 1_067_133_444, "user_id" => 222, "content" => "как успехи на сервере?" }
    client.history = history_of([BOT, "всё поднялось"])
    runner = build_runner(client, trigger_overrides: { "chats" => nil })

    context = runner.send(:thread_context, thread_event)

    assert_equal "222: как успехи на сервере?\nbot: всё поднялось", context
    assert_equal [1_067_133_444], client.message_gets
  end

  # A standalone thread hangs off nothing and reports message_id as nil.
  def test_a_standalone_thread_asks_for_no_root_message
    client = StubPachcaClient.new([[thread_event(root_id: nil)]])
    client.history = history_of([222, "первое"])
    runner = build_runner(client, trigger_overrides: { "chats" => nil })

    assert_equal "222: первое", runner.send(:thread_context, thread_event(root_id: nil))
    assert_nil client.message_gets
  end

  # A listing that happens to include the root must not show it twice.
  def test_the_root_message_is_not_repeated
    client = StubPachcaClient.new([[thread_event]])
    client.root = { "id" => 1_067_133_444, "user_id" => 222, "content" => "вопрос" }
    client.history = [{ "id" => 1_067_133_444, "user_id" => 222, "content" => "вопрос" },
                      { "id" => 900, "user_id" => BOT, "content" => "ответ" }]
    runner = build_runner(client, trigger_overrides: { "chats" => nil })

    assert_equal "222: вопрос\nbot: ответ", runner.send(:thread_context, thread_event)
  end

  # Losing the root is worth a warning, not the rest of the context.
  def test_a_failed_root_fetch_still_yields_the_thread
    client = StubPachcaClient.new([[thread_event]])
    client.root_error = "boom"
    client.history = history_of([BOT, "ответ"])
    runner = build_runner(client, trigger_overrides: { "chats" => nil })

    log = capture_log { assert_equal "bot: ответ", runner.send(:thread_context, thread_event) }

    assert_match(/could not read the message this thread hangs off/, log)
  end

  # The question is already in {{message}}; repeating it wastes tokens and
  # reads as if it were asked twice.
  def test_the_question_itself_is_left_out_of_the_transcript
    client = StubPachcaClient.new([[thread_event]])
    client.history = history_of([222, "раньше"]) + [{ "id" => 555, "user_id" => 222, "content" => "а почему?" }]
    runner = build_runner(client, trigger_overrides: { "chats" => nil })

    refute_includes runner.send(:thread_context, thread_event), "а почему?"
  end

  # A question asked in a channel carries its own context; the last N unrelated
  # channel messages would be noise, and a fetch that buys noise is not worth
  # making.
  def test_a_channel_question_pulls_no_context
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client)

    assert_equal "", runner.send(:thread_context, event(id: "01A"))
    assert_nil client.message_queries
  end

  def test_the_thread_chat_and_limit_are_what_gets_queried
    client = StubPachcaClient.new([[thread_event]])
    client.history = []
    runner = build_runner(client, trigger_overrides: { "chats" => nil, "context_messages" => 5 })

    runner.send(:thread_context, thread_event)

    assert_equal [[43_358_443, 5]], client.message_queries
  end

  def test_context_can_be_switched_off
    client = StubPachcaClient.new([[thread_event]])
    runner = build_runner(client, trigger_overrides: { "chats" => nil, "context_messages" => 0 })

    assert_equal "", runner.send(:thread_context, thread_event)
    assert_nil client.message_queries
  end

  # An answer written without the earlier messages is worse than one written
  # with them, and far better than no answer at all.
  def test_a_failed_context_fetch_warns_but_still_answers
    client = StubPachcaClient.new([[thread_event]])
    client.history_error = "boom"
    runner = build_runner(client, trigger_overrides: { "chats" => nil })

    log = capture_log { runner.send(:iterate) }

    assert_match(/could not read thread context/, log)
    assert_equal 1, backend(runner).prompts.size
  end

  def test_the_transcript_reaches_the_prompt
    File.write(@template_path, "было:\n{{thread_context}}\nспросили: {{message}}")
    client = StubPachcaClient.new([[thread_event]])
    client.history = history_of([222, "деплой сломался"])
    runner = build_runner(client, trigger_overrides: { "chats" => nil })

    runner.send(:iterate)

    assert_equal "было:\n222: деплой сломался\nспросили: а почему?", backend(runner).prompts.first
  end

  # --- a run that produced nothing -----------------------------------------

  # Exit code 0 is not the same as work done. An unauthenticated `claude -p`
  # prints "Not logged in" and exits 0; a sandbox that refused the write leaves
  # the agent politely explaining it could not save the file. Here the event is
  # acknowledged by DELETING it, so treating that as success destroys the
  # question — observed live with a message_dir the agent could not write to.
  def test_a_run_that_wrote_nothing_is_not_a_success
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client, writes: false)

    log = capture_log { runner.send(:iterate) }

    assert_empty client.deleted, "the question must not vanish from the history"
    assert_match(/exited 0 but wrote no message/, log)
    assert_equal 1, attempts(runner)["01A"], "the attempt must be counted"
  end

  def test_a_run_that_wrote_a_reply_is_a_success
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client)

    runner.send(:iterate)

    assert_equal %w[01A], client.deleted
  end

  # Retries are what make the check useful: the next cycle gets another go, and
  # only a genuinely exhausted item is dropped.
  # max_attempts is 3 here, and after_exhausted fires on the pass following
  # exhaustion — hence the fourth page.
  def test_a_silent_run_is_retried_and_then_exhausts
    events = [event(id: "01A")]
    client = StubPachcaClient.new([events, events, events, events])
    runner = build_runner(client, writes: false)

    4.times { runner.send(:iterate) }

    assert_equal 3, backend(runner).prompts.size, "three attempts, no more"
    assert_equal %w[01A], client.deleted, "an exhausted item is acknowledged"
  end

  # The Messenger polls the same directory and may move a reply to sent/ before
  # this check runs. Missing that would mean answering the same question twice.
  def test_a_reply_already_moved_to_sent_still_counts
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client, writes: false)
    sent = File.join(@message_dir, "sent")
    FileUtils.mkdir_p(sent)

    backend = runner.instance_variable_get(:@backend)
    backend.define_singleton_method(:run) do |prompt|
      @prompts << prompt
      File.write(File.join(sent, "already-delivered.yml"), "message: ok\n")
      AgentDaemon::Backend::Result.new(true, "stdout", "stderr", :ok)
    end

    runner.send(:iterate)

    assert_equal %w[01A], client.deleted
  end

  # Prompts name the reply after the work item ("write your answer to
  # <event id>.yml"), so a second run on the same item writes a name that is
  # already sitting in sent/ from the first. Comparing names alone called that
  # run silent and retried an answer the person had already received — observed
  # live on a GitHub review summoned twice on one pull request.
  def test_a_reply_reusing_a_delivered_filename_still_counts
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client, writes: false)
    sent = File.join(@message_dir, "sent")
    FileUtils.mkdir_p(sent)
    delivered = File.join(sent, "01A.yml")
    File.write(delivered, "message: first reply\n")
    # Explicitly in the past: on a filesystem with one-second granularity both
    # writes would share a timestamp and the test would flake.
    File.utime(Time.now - 60, Time.now - 60, delivered)

    backend = runner.instance_variable_get(:@backend)
    message_dir = @message_dir
    backend.define_singleton_method(:run) do |prompt|
      @prompts << prompt
      File.write(File.join(message_dir, "01A.yml"), "message: second reply\n")
      AgentDaemon::Backend::Result.new(true, "stdout", "stderr", :ok)
    end

    log = capture_log { runner.send(:iterate) }

    assert_equal %w[01A], client.deleted
    refute_match(/wrote no message/, log)
  end

  # --- acknowledging what is ignored ---------------------------------------

  # Every answer the agent posts comes back as an event authored by the bot.
  # The author gate drops it, and if nothing cleared it the history would only
  # grow — until `limit` of them push real questions off the page and the
  # runner goes deaf. Observed live: one such event was already sitting there.
  def test_the_bots_own_message_is_acknowledged_not_just_skipped
    client = StubPachcaClient.new([[event(id: "01A", user_id: BOT)]])
    runner = build_runner(client)

    assert_empty fetch(runner)
    assert_equal %w[01A], client.deleted
  end

  def test_an_event_of_an_unwatched_type_is_acknowledged
    client = StubPachcaClient.new([[event(id: "01A", event_type: "reaction_new")]])

    assert_empty fetch(build_runner(client))
    assert_equal %w[01A], client.deleted
  end

  def test_an_event_from_an_unlisted_chat_is_acknowledged
    client = StubPachcaClient.new([[event(id: "01A", chat_id: 999)]])

    assert_empty fetch(build_runner(client))
    assert_equal %w[01A], client.deleted
  end

  def test_an_event_from_an_unauthorized_author_is_acknowledged
    client = StubPachcaClient.new([[event(id: "01A", user_id: 333)]])
    runner = build_runner(client, trigger_overrides: { "allowed_users" => [222] })

    assert_empty fetch(runner)
    assert_equal %w[01A], client.deleted
  end

  # Acknowledging what is ignored must not touch what is not.
  def test_a_wanted_event_survives_a_page_full_of_ignored_ones
    events = [event(id: "01A", user_id: BOT), event(id: "01B"), event(id: "01C", event_type: "reaction_new")]
    client = StubPachcaClient.new([events])

    assert_equal %w[01B], fetch(build_runner(client)).map { |e| e["id"] }
    assert_equal %w[01A 01C], client.deleted.sort
  end

  # --- thinking indicator --------------------------------------------------

  # A run takes minutes. Without this the person who asked sees nothing at all
  # until the answer lands; Pachca renders a live timer for a reaction named
  # agent-thinking, which is the native version of that acknowledgement.
  def test_the_indicator_goes_on_before_the_run_and_off_after_it
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client)

    runner.send(:iterate)

    assert_equal %i[add remove], client.reactions.map(&:first)
    assert_equal %w[agent-thinking agent-thinking], client.reactions.first.last(2)
  end

  # Checked against the live API: colons around the name make Pachca resolve it
  # as a custom emoji id and answer 404, even though colons are exactly the form
  # it returns for stock shortcodes.
  def test_a_custom_reaction_is_named_bare_in_both_fields
    client = StubPachcaClient.new([[event(id: "01A")]])
    build_runner(client).send(:iterate)

    _, _, code, name = client.reactions.first
    assert_equal "agent-thinking", code
    assert_equal "agent-thinking", name
  end

  # A stock emoji is the glyph alone; the API fills the name in itself, and
  # sending one would be the same mistake in reverse.
  def test_a_stock_emoji_is_sent_as_the_glyph_without_a_name
    client = StubPachcaClient.new([[event(id: "01A")]])
    runner = build_runner(client, trigger_overrides: { "thinking_reaction" => "👀" })

    runner.send(:iterate)

    _, _, code, name = client.reactions.first
    assert_equal "👀", code
    assert_nil name
  end

  def test_the_indicator_is_attached_to_the_message_not_the_event
    client = StubPachcaClient.new([[event(id: "01A", message_id: 555)]])
    build_runner(client).send(:iterate)

    assert_equal [555, 555], client.reactions.map { |r| r[1] }
  end

  # Below max_attempts the question is still being worked on, so the indicator
  # stays up across the retry rather than flickering.
  def test_a_retry_keeps_the_indicator_up_and_does_not_re_add_it
    events = [event(id: "01A", message_id: 555)]
    client = StubPachcaClient.new([events, events])
    runner = build_runner(client, reasons: %i[failed ok])

    2.times { runner.send(:iterate) }

    assert_equal %i[add remove], client.reactions.map(&:first)
  end

  # Shutdown rolled the attempt back, so the question is unanswered — but the
  # timer must not sit there over a process that is gone.
  def test_a_killed_run_takes_the_indicator_down
    client = StubPachcaClient.new([[event(id: "01A", message_id: 555)]])
    runner = build_runner(client, reasons: [:killed])

    runner.send(:iterate)

    assert_equal %i[add remove], client.reactions.map(&:first)
  end

  # The custom reaction has to be created by hand in Pachca. When it is not,
  # one warning is worth more than one per message forever — and the run must
  # not fail over a courtesy.
  def test_a_missing_reaction_disables_the_indicator_once_and_never_fails_a_run
    events = [event(id: "01A", message_id: 555)]
    client = StubPachcaClient.new([events, [event(id: "01B", message_id: 556)]])
    client.fail_reactions!
    runner = build_runner(client)

    log = capture_log { 2.times { runner.send(:iterate) } }

    assert_equal 1, log.scan(/thinking indicator off/).size
    assert_match(/Create a custom reaction named "agent-thinking"/, log)
    assert_equal 2, backend(runner).prompts.size, "the runs must still happen"
    assert_equal %w[01A 01B], client.deleted
  end

  def test_the_indicator_can_be_turned_off_in_config
    client = StubPachcaClient.new([[event(id: "01A", message_id: 555)]])
    runner = build_runner(client, trigger_overrides: { "thinking_reaction" => nil })

    runner.send(:iterate)

    assert_empty client.reactions
  end
end
