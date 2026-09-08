# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class GitHubStubBackend
  attr_reader :prompts

  # A real agent posts the review and writes a short report into message_dir;
  # the runner treats a missing report as "nothing happened". `writes: false`
  # is that case — the CLI is happy, no review was posted.
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
      File.write(File.join(@message_dir, "review-#{@written}.yml"), "message: reviewed\n")
    end

    AgentDaemon::Backend::Result.new(reason == :ok, "stdout", "stderr", reason)
  end
end

class GitHubStubShutdown
  def value = false
end

class StubGitHubClient
  attr_reader :read, :comment_urls

  attr_writer :login

  def login
    @login ||= "bot"
  end

  def initialize(pages, comments: {}, mark_failures: [])
    @pages = pages.dup
    @comments = comments
    @mark_failures = mark_failures.dup
    @read = []
    @comment_urls = []
  end

  def notifications
    (@pages.shift || []).sort_by { |n| n["updated_at"].to_s }
  end

  def comment(url)
    return nil if url.nil? || url.empty?

    @comment_urls << url
    @comments[url]
  end

  def mark_read(id)
    raise "boom" if @mark_failures.delete(id)

    @read << id
    true
  end
end

class TestRunnerGitHub < Minitest::Test
  REPO = "art/app"

  def setup
    @prior_logger = AgentDaemon::Log.instance_variable_get(:@logger)
    @tmpdir = Dir.mktmpdir
    @project_path = File.join(@tmpdir, "project")
    @message_dir = File.join(@project_path, "to_message")
    FileUtils.mkdir_p(@message_dir)

    @template_path = File.join(@tmpdir, "prompt.txt")
    File.write(@template_path, "review {{repo}}#{'#'}{{pr_number}} for {{summoned_by}}: {{request}}")

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
      "name" => "review",
      "backend" => "claude",
      "max_attempts" => 3,
      "prompt_template_path" => @template_path,
      "trigger" => {
        "type" => "github",
        "token" => "tok",
        "repos" => [REPO],
        "interval" => 60,
        "jitter" => 0
      }.merge(trigger_overrides)
    }
  end

  def build_runner(client, reasons: [], trigger_overrides: {}, writes: true)
    runner = AgentDaemon::Runner::GitHub.new(
      runner_config(trigger_overrides), @message_dir, @project_path, GitHubStubShutdown.new
    )
    runner.instance_variable_set(:@backend,
                                 GitHubStubBackend.new(reasons, message_dir: @message_dir, writes: writes))
    runner.instance_variable_set(:@client, client)
    runner
  end

  def notification(id:, reason: "mention", repo: REPO, type: "PullRequest", number: 42, comment_url: "https://api.github.com/repos/#{repo}/issues/comments/#{id}")
    {
      "id" => id,
      "reason" => reason,
      "updated_at" => "2026-09-06T10:0#{id}:00Z",
      "repository" => { "full_name" => repo },
      "subject" => {
        "type" => type,
        "title" => "Add a thing",
        "url" => "https://api.github.com/repos/#{repo}/pulls/#{number}",
        "latest_comment_url" => comment_url
      }
    }
  end

  def comment(login:, body: "@bot посмотри")
    { "user" => { "login" => login }, "body" => body }
  end

  def fetch(runner) = runner.send(:fetch_work_items)
  def backend(runner) = runner.instance_variable_get(:@backend)

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

  def test_a_pull_request_mention_is_picked_up
    client = StubGitHubClient.new([[notification(id: "1")]], comments: { "https://api.github.com/repos/art/app/issues/comments/1" => comment(login: "zumkorn") })
    runner = build_runner(client, trigger_overrides: { "allowed_users" => %w[zumkorn] })

    assert_equal %w[1], fetch(runner).map { |n| n["id"] }
  end

  # The inbox carries every kind of notification; only being summoned counts.
  def test_other_reasons_are_skipped
    client = StubGitHubClient.new([[notification(id: "1", reason: "author")]])

    assert_empty fetch(build_runner(client))
  end

  def test_non_pull_request_subjects_are_skipped
    client = StubGitHubClient.new([[notification(id: "1", type: "Issue")]])

    assert_empty fetch(build_runner(client))
  end

  def test_repositories_outside_the_list_are_skipped
    client = StubGitHubClient.new([[notification(id: "1", repo: "other/repo")]])

    assert_empty fetch(build_runner(client))
  end

  def test_without_a_repo_list_every_watched_repository_counts
    notification = notification(id: "1", repo: "other/repo")
    client = StubGitHubClient.new(
      [[notification]],
      comments: { notification.dig("subject", "latest_comment_url") => comment(login: "zumkorn") }
    )
    runner = build_runner(client, trigger_overrides: { "repos" => nil })

    refute_empty fetch(runner)
  end

  # --- who actually asked ---------------------------------------------------

  # A thread comes back unread on any activity, not just a comment: a merge, a
  # push, a label, and the review this runner just posted. GitHub then points
  # latest_comment_url at the pull request itself, and the "author" read from
  # it is the PR's author — the person most likely to be on the allowlist.
  # Observed live: one pull request reviewed twice, and merging re-armed the
  # rest.
  def test_activity_that_is_not_a_comment_does_not_summon
    pr_url = "https://api.github.com/repos/#{REPO}/pulls/42"
    notification = notification(id: "1", comment_url: pr_url)
    client = StubGitHubClient.new([[notification]], comments: { pr_url => comment(login: "zumkorn") })
    runner = build_runner(client)

    assert_empty fetch(runner)
    assert_equal %w[1], client.read, "иначе тред возвращался бы каждый опрос"
  end

  # Nobody types anything to request a review, so that one needs no comment.
  def test_a_review_request_needs_no_comment
    pr_url = "https://api.github.com/repos/#{REPO}/pulls/42"
    notification = notification(id: "1", reason: "review_requested", comment_url: pr_url)
    client = StubGitHubClient.new([[notification]], comments: { pr_url => comment(login: "zumkorn") })

    refute_empty fetch(build_runner(client))
  end

  # Checked before the allowlist rather than through it: with no allowlist
  # every author passes, and the agent would answer its own review forever.
  def test_the_agents_own_comment_never_summons_it
    notification = notification(id: "1")
    client = StubGitHubClient.new(
      [[notification]],
      comments: { notification.dig("subject", "latest_comment_url") => comment(login: "bot") }
    )
    runner = build_runner(client, trigger_overrides: { "allowed_users" => nil })

    assert_empty fetch(runner)
  end

  # The agent answers publicly under this account, so who may summon it is a
  # wider question than who may ask it something in chat.
  def test_only_allowlisted_authors_may_summon
    notifications = [notification(id: "1", comment_url: "https://api.github.com/repos/art/app/issues/comments/1"), notification(id: "2", comment_url: "https://api.github.com/repos/art/app/issues/comments/2")]
    comments = { "https://api.github.com/repos/art/app/issues/comments/1" => comment(login: "stranger"), "https://api.github.com/repos/art/app/issues/comments/2" => comment(login: "zumkorn") }
    client = StubGitHubClient.new([notifications], comments: comments)
    runner = build_runner(client, trigger_overrides: { "allowed_users" => %w[zumkorn] })

    assert_equal %w[2], fetch(runner).map { |n| n["id"] }
  end

  def test_the_allowlist_ignores_login_case
    client = StubGitHubClient.new([[notification(id: "1")]], comments: { "https://api.github.com/repos/art/app/issues/comments/1" => comment(login: "ZumKorn") })
    runner = build_runner(client, trigger_overrides: { "allowed_users" => %w[zumkorn] })

    refute_empty fetch(runner)
  end

  # Without knowing who asked, the gate cannot be applied — and acting anyway
  # would make the allowlist decorative.
  def test_an_unattributable_notification_is_not_acted_on
    client = StubGitHubClient.new([[notification(id: "1")]], comments: {})
    runner = build_runner(client, trigger_overrides: { "allowed_users" => %w[zumkorn] })

    assert_empty fetch(runner)
  end

  # Fetching a comment costs a request, so it happens only after the cheap
  # checks have passed.
  def test_comments_are_not_fetched_for_notifications_already_ruled_out
    client = StubGitHubClient.new([[notification(id: "1", repo: "other/repo")]])
    runner = build_runner(client, trigger_overrides: { "allowed_users" => %w[zumkorn] })

    fetch(runner)

    assert_empty client.comment_urls
  end

  def test_the_effective_scope_is_logged_at_startup
    log = capture_log { build_runner(StubGitHubClient.new([]), trigger_overrides: { "repos" => nil }) }

    assert_match(/every repository this account is notified about/, log)
    assert_match(/summoned by ANY author/, log)
  end

  # --- acknowledgement -----------------------------------------------------

  def test_a_handled_notification_is_marked_read
    client = StubGitHubClient.new([[notification(id: "1")]], comments: { "https://api.github.com/repos/art/app/issues/comments/1" => comment(login: "zumkorn") })
    runner = build_runner(client)

    runner.send(:iterate)

    assert_equal %w[1], client.read
    assert_equal 1, backend(runner).prompts.size
  end

  # `participating=true` keeps returning unread threads, so a notification the
  # runner will never act on has to be cleared as well — otherwise every poll
  # re-examines it forever.
  def test_ignored_notifications_are_marked_read_too
    client = StubGitHubClient.new([[notification(id: "1", reason: "author")]])

    assert_empty fetch(build_runner(client))
    assert_equal %w[1], client.read
  end

  # Marking read is a destructive ack: the request is gone. A run that exits 0
  # without posting anything must not reach it.
  def test_a_run_that_posted_nothing_is_not_acknowledged
    client = StubGitHubClient.new([[notification(id: "1")]], comments: { "https://api.github.com/repos/art/app/issues/comments/1" => comment(login: "zumkorn") })
    runner = build_runner(client, writes: false)

    log = capture_log { runner.send(:iterate) }

    assert_empty client.read
    assert_match(/wrote no message/, log)
  end

  def test_a_failed_mark_read_is_retried_and_never_reprocessed
    notifications = [notification(id: "1")]
    client = StubGitHubClient.new([notifications, notifications],
                                  comments: { "https://api.github.com/repos/art/app/issues/comments/1" => comment(login: "zumkorn") },
                                  mark_failures: %w[1])
    runner = build_runner(client)

    runner.send(:iterate)
    assert_empty client.read

    runner.send(:iterate)

    assert_equal %w[1], client.read
    assert_equal 1, backend(runner).prompts.size, "ревью должно быть написано ровно один раз"
  end

  # --- prompt --------------------------------------------------------------

  def test_the_prompt_carries_the_pull_request_and_who_asked
    client = StubGitHubClient.new([[notification(id: "1", number: 77)]],
                                  comments: { "https://api.github.com/repos/art/app/issues/comments/1" => comment(login: "zumkorn", body: "глянь плиз") })
    runner = build_runner(client)

    prompt = runner.send(:render_prompt, fetch(runner).first)

    assert_equal "review art/app#77 for zumkorn: глянь плиз", prompt
  end

  # --- rate limiting -------------------------------------------------------

  def test_a_throttle_backs_off_without_counting_as_a_trigger_error
    client = Object.new
    def client.notifications = raise(AgentDaemon::RateLimitError.new(90))

    runner = build_runner(client)
    runner.send(:iterate)

    assert_equal 90, runner.instance_variable_get(:@backoff)
    assert_equal 0, runner.instance_variable_get(:@consecutive_errors)
  end
end
