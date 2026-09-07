# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Shapes below are copied from a live account, not invented: the notification
# is a real @-mention on a card, trimmed of the fields nothing reads. The values
# are placeholders.
class StubBasecampCLI
  attr_reader :read_ids, :list_calls

  def initialize(pages = [], read_error: nil)
    @pages = pages.dup
    @read_ids = []
    @list_calls = 0
    @read_error = read_error
  end

  def notifications
    @list_calls += 1
    @pages.shift || []
  end

  def mark_read(id)
    raise @read_error if @read_error

    @read_ids << id.to_s
    true
  end
end

class BasecampStubBackend
  attr_reader :prompts

  def initialize(message_dir: nil, writes: true)
    @prompts = []
    @message_dir = message_dir
    @writes = writes
    @written = 0
  end

  def run(prompt, images: [])
    @prompts << prompt
    if @writes && @message_dir
      @written += 1
      File.write(File.join(@message_dir, "reply-#{@written}.yml"), "message: ok\n")
    end
    AgentDaemon::Backend::Result.new(true, "stdout", "stderr", :ok)
  end
end

class BasecampStubShutdown
  def value = false
end

class TestRunnerBasecamp < Minitest::Test
  AUTHOR_ID   = 1_001
  AUTHOR_NAME = "Jane Doe"

  def setup
    @dir = Dir.mktmpdir
    @message_dir = File.join(@dir, "to_message")
    FileUtils.mkdir_p(@message_dir)
    @template_path = File.join(@dir, "prompt.txt")
    File.write(@template_path, "{{kind}} в {{project}} от {{summoned_by}}: {{request}} " \
                               "[{{bucket_id}}/{{recording_id}}]")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def notification(id: "5000", type: "Mention", project: "Проект",
    creator_id: AUTHOR_ID, creator_name: AUTHOR_NAME)
    {
      "id" => id.to_i,
      "type" => type,
      "bucket_name" => project,
      "title" => "@mentioned you in: Re: Карточка",
      "content_excerpt" => "Ты тут?",
      "app_url" => "https://app.basecamp.com/999/buckets/2000/card_tables/cards/3000",
      "subscription_url" =>
        "https://3.basecampapi.com/999/buckets/2000/recordings/3000/subscription.json",
      "created_at" => "2026-01-01T12:00:00.000Z",
      "creator" => { "id" => creator_id, "name" => creator_name }
    }
  end

  # Basecamp's own product announcements arrive in the same inbox as a
  # mention, from a "creator" that is the Basecamp bulletin account.
  def announcement
    {
      "id" => 5_001,
      "type" => "Bulletin",
      "bucket_name" => "Announcement",
      "content_excerpt" => "We've got a handful of Basecamp improvements to share",
      "subscription_url" => "",
      "creator" => { "id" => 1, "name" => "Basecamp" }
    }
  end

  def build_runner(client, trigger_overrides: {}, writes: true)
    trigger = { "type" => "basecamp", "interval" => 60 }.merge(trigger_overrides)
    config = {
      "name" => "tasks",
      "prompt_template_path" => @template_path,
      "timeout" => 60,
      "max_attempts" => 3,
      "trigger" => trigger
    }
    runner = AgentDaemon::Runner::Basecamp.new(config, @message_dir, @dir, BasecampStubShutdown.new)
    runner.instance_variable_set(:@client, client)
    runner.instance_variable_set(:@backend,
                                 BasecampStubBackend.new(message_dir: @message_dir, writes: writes))
    runner
  end

  def fetch(runner) = runner.send(:fetch_work_items)
  def backend(runner) = runner.instance_variable_get(:@backend)
  def attempts(runner) = runner.instance_variable_get(:@attempts)

  def capture_log
    io = StringIO.new
    previous = AgentDaemon::Log.instance_variable_get(:@logger)
    AgentDaemon::Log.instance_variable_set(:@logger, Logger.new(io))
    yield
    io.string
  ensure
    AgentDaemon::Log.instance_variable_set(:@logger, previous)
  end

  # --- the gates ------------------------------------------------------------

  def test_a_mention_from_an_allowed_author_is_work
    client = StubBasecampCLI.new([[notification]])
    runner = build_runner(client, trigger_overrides: { "allowed_users" => [AUTHOR_ID] })

    assert_equal 1, fetch(runner).size
    assert_empty client.read_ids, "работа подтверждается после прогона, а не при выборке"
  end

  def test_an_author_may_be_named_instead_of_numbered
    client = StubBasecampCLI.new([[notification]])
    runner = build_runner(client, trigger_overrides: { "allowed_users" => [AUTHOR_NAME] })

    assert_equal 1, fetch(runner).size
  end

  def test_an_unlisted_author_is_ignored_and_acknowledged
    client = StubBasecampCLI.new([[notification(creator_id: 999, creator_name: "Кто-то")]])
    runner = build_runner(client, trigger_overrides: { "allowed_users" => [AUTHOR_ID] })

    assert_empty fetch(runner)
    assert_equal %w[5000], client.read_ids
  end

  # Basecamp keeps returning unread items, so an announcement left alone would
  # be re-examined on every poll forever — and eventually push a real request
  # off the first page.
  def test_a_product_announcement_is_ignored_and_acknowledged
    client = StubBasecampCLI.new([[announcement]])
    runner = build_runner(client)

    assert_empty fetch(runner)
    assert_equal %w[5001], client.read_ids
  end

  def test_a_mention_in_an_unwatched_project_is_ignored
    client = StubBasecampCLI.new([[notification(project: "Другой")]])
    runner = build_runner(client, trigger_overrides: { "projects" => ["Проект"] })

    assert_empty fetch(runner)
    assert_equal %w[5000], client.read_ids
  end

  # Without an author the gate cannot be applied at all; acting anyway would
  # make the allowlist decorative.
  def test_an_unattributable_notification_is_not_acted_on
    item = notification
    item.delete("creator")
    client = StubBasecampCLI.new([[item]])
    runner = build_runner(client, trigger_overrides: { "allowed_users" => [AUTHOR_ID] })

    assert_empty fetch(runner)
  end

  # --- prompt ---------------------------------------------------------------

  # The ids live only inside subscription_url; app_url would need a different
  # pattern per recording type.
  def test_the_prompt_carries_the_request_and_both_ids
    client = StubBasecampCLI.new([[notification]])
    runner = build_runner(client)

    runner.send(:iterate)

    assert_equal "Mention в Проект от Jane Doe: Ты тут? [2000/3000]",
                 backend(runner).prompts.first
  end

  # --- acknowledgement ------------------------------------------------------

  def test_a_finished_run_marks_the_notification_read
    client = StubBasecampCLI.new([[notification]])
    runner = build_runner(client)

    runner.send(:iterate)

    assert_equal %w[5000], client.read_ids
  end

  # Exit 0 with nothing written is not an answer, and marking read here would
  # destroy the request — the case Runner::Base#expects_message_file? exists for.
  def test_a_run_that_wrote_nothing_is_not_acknowledged
    client = StubBasecampCLI.new([[notification]])
    runner = build_runner(client, writes: false)

    log = capture_log { runner.send(:iterate) }

    assert_empty client.read_ids, "просьба не должна исчезнуть из инбокса"
    assert_match(/exited 0 but wrote no message/, log)
    assert_equal 1, attempts(runner)["5000"]
  end

  # Until Basecamp agrees the notification is read it comes back in the next
  # listing, and acting on it twice would post the same answer twice.
  def test_a_failed_acknowledgement_is_retried_and_the_item_not_reprocessed
    failing = StubBasecampCLI.new([[notification], [notification]],
                                  read_error: AgentDaemon::Basecamp::CLI::Error.new("boom"))
    runner = build_runner(failing)

    log = capture_log { runner.send(:iterate) }
    assert_match(/could not mark 5000 read/, log)

    assert_empty fetch(runner), "повторно ту же просьбу брать нельзя"
    assert_equal 1, backend(runner).prompts.size
  end
end
