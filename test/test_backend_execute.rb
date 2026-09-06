# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestShutdownFlag
  attr_writer :value

  def initialize
    @value = false
  end

  def value
    @value
  end
end

class TestableBackend < AgentDaemon::Backend::Base
  def call(cmd, timeout:)
    execute(cmd, timeout: timeout)
  end
end

# Records every output-sink append as an [entity_id, stream, chunk] tuple,
# plus the Story 3.3 run lifecycle in one ordered `events` log so a test can
# assert that begin_run/end_run actually bracket the chunks.
class RecordingOutputSink
  attr_reader :calls, :events

  def initialize
    @calls = []
    @events = []
  end

  def append(entity_id, stream, chunk)
    @calls << [entity_id, stream, chunk]
    @events << [:append, stream, chunk]
  end

  def begin_run(_entity_id, run_id)
    @events << [:begin_run, run_id]
  end

  def end_run(_entity_id, run_id, reason)
    @events << [:end_run, run_id, reason]
  end
end

class TestBackendExecute < Minitest::Test
  def setup
    @shutdown = TestShutdownFlag.new
    Dir.mktmpdir do |dir|
      project_path = File.join(dir, "project")
      FileUtils.mkdir_p(project_path)
      @backend = TestableBackend.new(
        { "name" => "default", "timeout" => 10, "extra_flags" => "" },
        @shutdown,
        message_dir: File.join(project_path, "to_message"),
        project_path: project_path
      )
    end
  end

  def test_ok_command
    result = @backend.call("sleep 0.1; echo ok", timeout: 5)
    assert_equal :ok, result.reason
    assert result.success
    assert_includes result.stdout, "ok"
  end

  # Chunks arrive from read_nonblock as ASCII-8BIT, so a buffer stayed UTF-8
  # only as long as the agent spoke ASCII. The moment it did not, the Result
  # came back binary and interpolating it raised Encoding::CompatibilityError —
  # killing the runner thread at the point where it was reporting a failure.
  def test_output_comes_back_as_utf8
    result = @backend.call("echo 'ответ агента'", timeout: 5)

    assert_equal Encoding::UTF_8, result.stdout.encoding
    assert_includes result.stdout, "ответ агента"
    assert result.stdout.valid_encoding?
    # The thing that actually broke: this used to raise.
    assert_includes "ошибка: #{result.stdout}", "ответ агента"
  end

  # A 4096-byte read can land mid-character, so the tail of a chunk is
  # genuinely invalid UTF-8. A diagnostic message is not worth raising over.
  def test_invalid_bytes_are_scrubbed_rather_than_raised
    result = @backend.call("printf 'a\\xff\\xfeb'", timeout: 5)

    assert result.stdout.valid_encoding?
    assert_includes result.stdout, "a"
    assert_includes result.stdout, "b"
  end

  def test_failed_command
    result = @backend.call("exit 7", timeout: 5)
    assert_equal :failed, result.reason
    refute result.success
  end

  def test_timeout
    started = Time.now
    result = @backend.call("sleep 30", timeout: 1)
    elapsed = Time.now - started
    assert_equal :timeout, result.reason
    refute result.success
    assert elapsed < 5
  end

  def test_group_kill_terminates_children
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "child.pid")
      script = "sh -c 'sleep 60 & echo $! > #{pidfile}; wait'"

      result = @backend.call(script, timeout: 1)
      assert_equal :timeout, result.reason

      child_pid = nil
      30.times do
        if File.exist?(pidfile) && !File.read(pidfile).strip.empty?
          child_pid = File.read(pidfile).strip.to_i
          break
        end
        sleep(0.05)
      end
      refute_nil child_pid

      alive = true
      30.times do
        begin
          Process.kill(0, child_pid)
        rescue Errno::ESRCH
          alive = false
          break
        end
        sleep(0.1)
      end

      refute alive
    end
  end

  def test_shutdown_flag_kills_running_command
    thread = Thread.new do
      sleep(0.3)
      @shutdown.value = true
    end

    started = Time.now
    result = @backend.call("sleep 30", timeout: 60)
    elapsed = Time.now - started
    thread.join

    assert_equal :killed, result.reason
    assert elapsed < 5
  end

  def test_kill_already_dead_does_not_raise
    result = @backend.call("true", timeout: 5)
    assert_equal :ok, result.reason
    @backend.send(:kill_process_group, 999_999)
    pass
  end

  def test_incremental_output_through_sink
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))

    result = backend.call("echo one; sleep 0.7; echo two", timeout: 5)

    assert_equal :ok, result.reason
    stdout_appends = recorder.calls.select { |_id, stream, _chunk| stream == :stdout }
    assert_operator stdout_appends.size, :>=, 2
    assert_includes result.stdout, "one"
    assert_includes result.stdout, "two"
  end

  def test_stderr_chunk_arrives_tagged_stderr
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))

    result = backend.call("echo oops 1>&2", timeout: 5)

    assert_includes result.stderr, "oops"
    assert(recorder.calls.any? { |_id, stream, chunk| stream == :stderr && chunk.include?("oops") })
  end

  def test_drain_on_timeout_captures_late_output
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))

    result = backend.call(%(sh -c 'trap "echo dying; exit 0" TERM; sleep 30'), timeout: 1)

    assert_equal :timeout, result.reason
    assert_includes result.stdout, "dying"
    assert(recorder.calls.any? { |_id, stream, chunk| stream == :stdout && chunk.include?("dying") })
  end

  def test_drain_on_shutdown_kill_captures_late_output
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))
    thread = Thread.new do
      sleep(0.3)
      @shutdown.value = true
    end

    result = backend.call(%(sh -c 'trap "echo dying; exit 0" TERM; sleep 30'), timeout: 60)
    thread.join

    assert_equal :killed, result.reason
    assert_includes result.stdout, "dying"
    assert(recorder.calls.any? { |_id, stream, chunk| stream == :stdout && chunk.include?("dying") })
  end

  def test_cancel_flag_kills_running_command
    cancel = TestShutdownFlag.new
    backend = build_backend(cancel_flag: cancel)
    thread = Thread.new do
      sleep(0.3)
      cancel.value = true
    end

    started = Time.now
    result = backend.call(%(sh -c 'trap "echo dying; exit 0" TERM; sleep 30'), timeout: 60)
    elapsed = Time.now - started
    thread.join

    assert_equal :killed, result.reason
    assert elapsed < 5
    assert_includes result.stdout, "dying"
    assert_kind_of Time, result.started_at
    assert_kind_of Time, result.finished_at
    assert_operator result.finished_at, :>=, result.started_at
    assert_kind_of Integer, result.pid
    # A recycled pid owned by another user raises EPERM instead of ESRCH —
    # either way the original child is gone.
    assert_raises(Errno::ESRCH, Errno::EPERM) { Process.kill(0, result.pid) }
  end

  # AC6: the drain on the :killed path is the same code as the :timeout and
  # shutdown paths, but only shutdown had pipeline evidence. Pin the cancel
  # path on BOTH streams, through the sink the pipeline actually consumes —
  # result.stdout alone would pass even if append_chunk never fired.
  def test_cancel_drain_reaches_the_output_pipeline_on_both_streams
    recorder = RecordingOutputSink.new
    cancel = TestShutdownFlag.new
    backend = build_backend(sinks: sink_bundle(recorder), cancel_flag: cancel)
    thread = Thread.new do
      sleep(0.3)
      cancel.value = true
    end

    result = backend.call(
      %(sh -c 'trap "echo dying; echo failing >&2; exit 0" TERM; sleep 30'),
      timeout: 60
    )
    thread.join

    assert_equal :killed, result.reason
    assert_includes result.stdout, "dying"
    assert_includes result.stderr, "failing"
    assert(recorder.calls.any? { |_id, stream, chunk| stream == :stdout && chunk.include?("dying") },
           "the late stdout line never reached the output sink")
    assert(recorder.calls.any? { |_id, stream, chunk| stream == :stderr && chunk.include?("failing") },
           "the late stderr line never reached the output sink")
  end

  # AC4's second half. Every other kill test uses a TERM-killable child, so
  # the TERM -> TERM_GRACE_SECONDS probe -> KILL escalation in
  # kill_process_group was reachable but unexercised. This child ignores TERM
  # and restarts its sleeps, so only SIGKILL can end it.
  def test_cancel_escalates_to_sigkill_for_a_child_that_ignores_term
    cancel = TestShutdownFlag.new
    backend = build_backend(cancel_flag: cancel)
    thread = Thread.new do
      sleep(0.3)
      cancel.value = true
    end

    started = Time.now
    result = backend.call(%(sh -c 'trap "" TERM; while :; do sleep 0.2; done'), timeout: 60)
    elapsed = Time.now - started
    thread.join

    assert_equal :killed, result.reason
    assert_operator elapsed, :>=, AgentDaemon::Backend::TERM_GRACE_SECONDS,
                    "returned before the TERM grace period — the child cannot have ignored TERM"
    assert_operator elapsed, :<, 10
    assert_raises(Errno::ESRCH, Errno::EPERM) { Process.kill(0, -result.pid) }
  end

  # AC5 on the cancel path. A zombie still answers signal 0, so ESRCH on the
  # leader pid right after `call` returns is the proof that wait_thr.value
  # already reaped it — and a second kill against the now-absent group must
  # stay silent rather than surface as a runner error.
  def test_cancelled_child_is_reaped_once_and_a_second_kill_is_not_an_error
    cancel = TestShutdownFlag.new
    backend = build_backend(cancel_flag: cancel)
    thread = Thread.new do
      sleep(0.3)
      cancel.value = true
    end

    result = backend.call("sleep 30", timeout: 60)
    thread.join

    assert_equal :killed, result.reason
    assert_raises(Errno::ESRCH, Errno::EPERM) { Process.kill(0, result.pid) }
    assert_nil backend.instance_variable_get(:@current_pid),
               "the pid must be cleared only after the child was reaped"
    backend.send(:kill_process_group, result.pid)
    assert_raises(Errno::ECHILD) { Process.waitpid(result.pid) }
  end

  def test_ok_result_carries_timing_and_pid
    result = @backend.call("echo ok", timeout: 5)

    assert_equal :ok, result.reason
    assert_kind_of Time, result.started_at
    assert_kind_of Time, result.finished_at
    assert_operator result.finished_at, :>=, result.started_at
    assert_kind_of Integer, result.pid
    assert_operator result.pid, :>, 0
  end

  def test_timeout_result_carries_timing_and_pid
    result = @backend.call("sleep 30", timeout: 1)

    assert_equal :timeout, result.reason
    assert_kind_of Time, result.started_at
    assert_kind_of Time, result.finished_at
    assert_operator result.finished_at, :>=, result.started_at
    assert_kind_of Integer, result.pid
    assert_operator result.pid, :>, 0
  end

  def test_raising_output_sink_does_not_break_run
    raising = Object.new
    def raising.append(_entity_id, _stream, _chunk)
      raise "sink boom"
    end
    backend = build_backend(sinks: sink_bundle(raising))

    result = backend.call("echo ok", timeout: 5)

    assert_equal :ok, result.reason
    assert_includes result.stdout, "ok"
  end

  def test_raising_output_sink_does_not_break_cancel_cleanup
    raising = Object.new
    raising.define_singleton_method(:append) { |_entity_id, _stream, _chunk| raise "sink boom" }
    cancel = TestShutdownFlag.new
    backend = build_backend(sinks: sink_bundle(raising), cancel_flag: cancel)
    thread = Thread.new do
      sleep(0.3)
      cancel.value = true
    end

    result = backend.call("sleep 30", timeout: 60)
    thread.join

    assert_equal :killed, result.reason
    assert_raises(Errno::ESRCH, Errno::EPERM) { Process.kill(0, result.pid) }
  end

  # --- Story 3.3 / DR4+DR9: the output run lifecycle -----------------------

  def test_exactly_one_begin_run_brackets_the_chunks_and_one_end_run_closes_them
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))

    backend.call("echo one; echo two", timeout: 5)

    kinds = recorder.events.map(&:first)
    assert_includes kinds, :append, "positive control: chunks did reach the sink"
    assert_equal :begin_run, kinds.first
    assert_equal :end_run, kinds.last
    assert_equal 1, kinds.count(:begin_run)
    assert_equal 1, kinds.count(:end_run)
  end

  def test_the_run_id_increments_across_two_runs_on_one_backend_instance
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))

    backend.call("echo a", timeout: 5)
    backend.call("echo b", timeout: 5)

    assert_equal [[:begin_run, 1], [:end_run, 1, :ok], [:begin_run, 2], [:end_run, 2, :ok]],
                 recorder.events.reject { |e| e.first == :append }
  end

  # AC7's teeth: for every terminal reason, the run is closed with THAT reason
  # and the final newline-less line reached the sink before the close.
  {
    ok: %(sh -c 'printf tail-no-newline'),
    failed: %(sh -c 'printf tail-no-newline; exit 3'),
    timeout: %(sh -c 'trap "printf tail-no-newline; exit 0" TERM; sleep 30')
  }.each do |expected_reason, command|
    define_method(:"test_#{expected_reason}_run_closes_with_its_reason_after_a_newlineless_final_line") do
      recorder = RecordingOutputSink.new
      backend = build_backend(sinks: sink_bundle(recorder))

      result = backend.call(command, timeout: expected_reason == :timeout ? 1 : 5)

      assert_equal expected_reason, result.reason
      close = recorder.events.last
      assert_equal [:end_run, 1, expected_reason], close
      tail_index = recorder.events.index { |e| e.first == :append && e[2].include?("tail-no-newline") }
      refute_nil tail_index, "the newline-less final line must reach the sink"
      assert_operator tail_index, :<, recorder.events.size - 1, "it must arrive before end_run"
      refute_includes result.stdout, "\n"
    end
  end

  def test_killed_run_closes_with_its_reason_after_a_newlineless_final_line
    recorder = RecordingOutputSink.new
    backend = build_backend(sinks: sink_bundle(recorder))
    thread = Thread.new do
      sleep(0.3)
      @shutdown.value = true
    end

    result = backend.call(%(sh -c 'trap "printf tail-no-newline; exit 0" TERM; sleep 30'), timeout: 60)
    thread.join

    assert_equal :killed, result.reason
    assert_equal [:end_run, 1, :killed], recorder.events.last
    assert(recorder.events.any? { |e| e.first == :append && e[2].include?("tail-no-newline") })
  end

  # The lifecycle close sits in an ensure around the WHOLE execute body, so an
  # exception escaping it still flushes the run.
  def test_end_run_fires_when_the_execute_body_raises
    recorder = RecordingOutputSink.new
    # Not a Sinks::Bundle: Bundle#guard would swallow the error before it
    # could escape execute, which is the very thing under test here.
    exploding = Object.new
    exploding.define_singleton_method(:begin_output_run) { |run_id| recorder.begin_run("ent", run_id) }
    exploding.define_singleton_method(:end_output_run) { |run_id, reason| recorder.end_run("ent", run_id, reason) }
    exploding.define_singleton_method(:append_output) { |_stream, _chunk| raise "sink boom" }
    backend = build_backend(sinks: exploding)

    assert_raises(RuntimeError) { backend.call("echo boom", timeout: 5) }

    assert_equal [:begin_run, 1], recorder.events.first
    # The body raised before a terminal reason was assigned, so the run is
    # closed with a nil reason — pinned as protocol behavior.
    assert_equal [:end_run, 1, nil], recorder.events.last
  end

  private

  # Same construction as setup, but with extra Backend::Base kwargs
  # (sinks:, cancel_flag:) for the seam tests.
  def build_backend(**opts)
    Dir.mktmpdir do |dir|
      project_path = File.join(dir, "project")
      FileUtils.mkdir_p(project_path)
      return TestableBackend.new(
        { "name" => "default", "timeout" => 10, "extra_flags" => "" },
        @shutdown,
        message_dir: File.join(project_path, "to_message"),
        project_path: project_path,
        **opts
      )
    end
  end

  def sink_bundle(output_sink)
    AgentDaemon::Sinks::Bundle.new(entity_id: "backend-test", output: output_sink)
  end
end

class TestBackendFactory < Minitest::Test
  def setup
    @shutdown = TestShutdownFlag.new
    @original_fallback_agent = ENV["FALLBACK_AGENT"]
    ENV.delete("FALLBACK_AGENT")
  end

  def teardown
    if @original_fallback_agent
      ENV["FALLBACK_AGENT"] = @original_fallback_agent
    else
      ENV.delete("FALLBACK_AGENT")
    end
  end

  def test_factory_builds_claude_by_default
    backend = AgentDaemon::Backend.for(
      { "name" => "r", "backend" => "claude" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    assert_instance_of AgentDaemon::Backend::Claude, backend
  end

  def test_factory_builds_opencode
    backend = AgentDaemon::Backend.for(
      { "name" => "r", "backend" => "opencode" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    assert_instance_of AgentDaemon::Backend::OpenCode, backend
  end

  def test_factory_builds_configured_agent_for_claude_when_exactly_enabled
    ENV["FALLBACK_AGENT"] = "1"

    backend = factory_backend("backend" => "claude", "fallback_agent" => fallback_config)

    assert_instance_of AgentDaemon::Backend::ConfiguredAgent, backend
  end

  def test_factory_builds_configured_agent_when_backend_key_is_omitted
    ENV["FALLBACK_AGENT"] = "1"

    backend = factory_backend("fallback_agent" => fallback_config)

    assert_instance_of AgentDaemon::Backend::ConfiguredAgent, backend
  end

  def test_factory_keeps_claude_for_every_other_environment_value
    [nil, "", "0", "true", "01"].each do |value|
      value ? ENV["FALLBACK_AGENT"] = value : ENV.delete("FALLBACK_AGENT")

      assert_instance_of AgentDaemon::Backend::Claude,
                         factory_backend("backend" => "claude", "fallback_agent" => fallback_config),
                         "expected primary backend for FALLBACK_AGENT=#{value.inspect}"
    end
  end

  def test_factory_keeps_claude_when_enabled_without_fallback_config
    ENV["FALLBACK_AGENT"] = "1"

    assert_instance_of AgentDaemon::Backend::Claude, factory_backend("backend" => "claude")
  end

  # The fallback used to apply to claude runners alone. Whichever agent a
  # runner normally uses is the one whose quota can run out, so the switch now
  # reaches every backend.
  def test_the_fallback_applies_to_every_backend
    ENV["FALLBACK_AGENT"] = "1"

    backend = factory_backend("backend" => "opencode", "fallback_agent" => fallback_config)

    assert_instance_of AgentDaemon::Backend::ConfiguredAgent, backend
  end

  def test_only_runners_that_configured_a_fallback_select_one
    ENV["FALLBACK_AGENT"] = "1"

    backends = [
      factory_backend("name" => "configured", "backend" => "claude", "fallback_agent" => fallback_config),
      factory_backend("name" => "primary", "backend" => "claude"),
      factory_backend("name" => "opencode", "backend" => "opencode")
    ]

    assert_equal [AgentDaemon::Backend::ConfiguredAgent, AgentDaemon::Backend::Claude,
                  AgentDaemon::Backend::OpenCode], backends.map(&:class)
  end

  # Naming a backend instead of a command is what makes the switch usable in
  # both directions: written as a raw command, a claude fallback would have to
  # restate every flag Backend::Claude builds for itself, and one of them being
  # wrong is a fallback that fails exactly when it is needed.
  def test_a_fallback_may_name_another_backend
    ENV["FALLBACK_AGENT"] = "1"

    assert_instance_of AgentDaemon::Backend::Claude,
                       factory_backend("backend" => "codex", "fallback_agent" => "claude")
    assert_instance_of AgentDaemon::Backend::Codex,
                       factory_backend("backend" => "claude", "fallback_agent" => "codex")
  end

  def test_a_named_fallback_is_ignored_without_the_switch
    ENV.delete("FALLBACK_AGENT")

    assert_instance_of AgentDaemon::Backend::Codex,
                       factory_backend("backend" => "codex", "fallback_agent" => "claude")
  end

  def test_codex_is_selectable_as_a_backend
    assert_instance_of AgentDaemon::Backend::Codex, factory_backend("backend" => "codex")
  end

  def codex_command(**config)
    factory_backend(**{ "backend" => "codex" }.merge(config)).send(:build_command, "спроси")
  end

  # workspace-write is not a detail: the agent's whole output is a message YAML
  # written into message_dir. Under read-only the run would finish successfully
  # having written nothing, and a trigger that acknowledges on success would
  # discard the work item — a default that loses questions silently.
  def test_codex_runs_with_a_writable_workspace
    assert_includes codex_command, "--sandbox workspace-write"
  end

  # message_dir and output_dir routinely sit outside project_path, and the
  # sandbox has to be told about them by name.
  def test_codex_makes_the_message_and_output_dirs_writable
    command = codex_command("output_dir" => "/tmp/out")

    assert_includes command, "--add-dir /tmp/msg"
    assert_includes command, "--add-dir /tmp/out"
  end

  def test_codex_puts_the_prompt_last_and_escapes_it
    assert_match(/codex exec .* спроси\z/, codex_command.gsub("\\", ""))
  end

  def test_codex_model_is_optional
    refute_includes codex_command, "--model"
    assert_includes codex_command("codex" => { "model" => "gpt-5.3-codex" }), "--model gpt-5.3-codex"
  end

  # project_path is frequently just a working directory, and codex refuses to
  # run outside a git repository unless told otherwise.
  def test_codex_does_not_require_a_git_repository
    assert_includes codex_command, "--skip-git-repo-check"
  end

  # Output is captured for the log, never shown to anyone: escape codes would
  # only make it unreadable.
  def test_codex_output_is_uncoloured
    assert_includes codex_command, "--color never"
  end

  def test_codex_takes_extra_flags_from_both_places
    command = codex_command("extra_flags" => "--general", "codex" => { "extra_flags" => "--specific" })

    assert_includes command, "--general"
    assert_includes command, "--specific"
  end

  def test_configured_agent_shell_escapes_each_token_and_appends_prompt_last
    ENV["FALLBACK_AGENT"] = "1"
    backend = factory_backend(
      "backend" => "claude",
      "fallback_agent" => {
        "command" => "/tmp/My Agent/omp",
        "args" => ["--label", "two words", "$(touch /tmp/not-created)"]
      }
    )
    prompt = "hello; touch /tmp/not-created either"

    command = backend.send(:build_command, prompt)
    invocation = command.split(" && ", 2).last

    assert_equal ["/tmp/My Agent/omp", "--label", "two words", "$(touch /tmp/not-created)", prompt],
                 Shellwords.split(invocation)
    assert_equal prompt, Shellwords.split(invocation).last
  end

  def test_configured_agent_executes_prompt_as_one_final_argument
    ENV["FALLBACK_AGENT"] = "1"
    prompt = "two words; printf injected"
    backend = factory_backend(
      "backend" => "claude",
      "fallback_agent" => {
        "command" => RbConfig.ruby,
        "args" => ["-e", "STDOUT.write(ARGV.inspect)", "fixed argument"]
      },
      project_path: Dir.tmpdir
    )

    result = backend.run(prompt)

    assert_equal :ok, result.reason
    assert_equal ["fixed argument", prompt].inspect, result.stdout
  end

  def test_configured_agent_receives_all_lifecycle_dependencies
    ENV["FALLBACK_AGENT"] = "1"
    cancel = TestShutdownFlag.new
    sinks = AgentDaemon::Sinks::Bundle.null("configured")
    runner = { "name" => "r", "backend" => "claude", "fallback_agent" => fallback_config }

    backend = AgentDaemon::Backend.for(
      runner,
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj",
      sinks: sinks,
      cancel_flag: cancel
    )

    assert_same runner, backend.instance_variable_get(:@runner_config)
    assert_same @shutdown, backend.instance_variable_get(:@shutdown_flag)
    assert_equal "/tmp/msg", backend.instance_variable_get(:@message_dir)
    assert_equal "/tmp/proj", backend.instance_variable_get(:@project_path)
    assert_same sinks, backend.instance_variable_get(:@sinks)
    assert_same cancel, backend.instance_variable_get(:@cancel_flag)
  end

  def test_factory_forwards_cancel_flag
    flag = TestShutdownFlag.new
    backend = AgentDaemon::Backend.for(
      { "name" => "r", "backend" => "claude" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj",
      cancel_flag: flag
    )
    assert_same flag, backend.instance_variable_get(:@cancel_flag)
  end

  def test_factory_rejects_unknown_backend
    err = assert_raises(ArgumentError) do
      AgentDaemon::Backend.for(
        { "name" => "r", "backend" => "magic" },
        @shutdown,
        message_dir: "/tmp/msg",
        project_path: "/tmp/proj"
      )
    end
    assert_includes err.message, "magic"
    assert_includes err.message, "\"r\""
  end

  def test_claude_command_includes_both_add_dirs
    backend = AgentDaemon::Backend::Claude.new(
      { "name" => "r", "agent" => "task-analyst", "extra_flags" => "", "output_dir" => "/tmp/out" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    cmd = backend.send(:build_command, "hello")
    assert_includes cmd, "--add-dir /tmp/msg"
    assert_includes cmd, "--add-dir /tmp/out"
  end

  def test_claude_command_deduplicates_add_dir
    backend = AgentDaemon::Backend::Claude.new(
      { "name" => "r", "agent" => "task-analyst", "extra_flags" => "", "output_dir" => "/tmp/msg" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    cmd = backend.send(:build_command, "hello")
    assert_equal 1, cmd.scan("--add-dir /tmp/msg").size
  end

  def test_claude_command_without_output_dir_adds_only_message_dir
    backend = AgentDaemon::Backend::Claude.new(
      { "name" => "r", "agent" => "task-analyst", "extra_flags" => "" },
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    cmd = backend.send(:build_command, "hello")
    assert_equal 1, cmd.scan("--add-dir").size
    assert_includes cmd, "--add-dir /tmp/msg"
  end

  # --- Optional --agent, optional claude.model -----------------------------

  # The exact bytes each backend produced before --agent became suppressible.
  # Pinned literally: the guarantee "a config without the new keys builds the
  # same command" is otherwise easy to break by a stray space or a reordered
  # flag while every other assertion here still passes.
  CLAUDE_BASELINE = "cd /tmp/proj && claude -p hello --agent task-analyst " \
                    "--add-dir /tmp/msg --dangerously-skip-permissions --output-format text"
  OPENCODE_BASELINE = "cd /tmp/proj && opencode run hello --agent task-analyst " \
                      "--model gpt --dangerously-skip-permissions"

  def test_commands_are_byte_identical_without_the_new_keys
    assert_equal CLAUDE_BASELINE, command_for(AgentDaemon::Backend::Claude, "agent" => "task-analyst")
    assert_equal OPENCODE_BASELINE,
                 command_for(AgentDaemon::Backend::OpenCode,
                             "agent" => "task-analyst", "opencode" => { "model" => "gpt" })
  end

  def test_disabled_fallback_keeps_primary_claude_command_byte_identical
    ENV["FALLBACK_AGENT"] = "0"
    backend = factory_backend(
      "backend" => "claude",
      "agent" => "task-analyst",
      "extra_flags" => "",
      "fallback_agent" => fallback_config
    )

    assert_instance_of AgentDaemon::Backend::Claude, backend
    assert_equal CLAUDE_BASELINE, backend.send(:build_command, "hello")
  end

  def test_claude_command_omits_agent_when_explicitly_null
    refute_includes command_for(AgentDaemon::Backend::Claude, "agent" => nil), "--agent"
  end

  def test_opencode_command_omits_agent_when_explicitly_null
    cmd = command_for(AgentDaemon::Backend::OpenCode, "agent" => nil, "opencode" => { "model" => "gpt" })
    refute_includes cmd, "--agent"
    assert_includes cmd, "--model gpt"
  end

  def test_commands_keep_the_default_agent_when_the_key_is_absent
    assert_includes command_for(AgentDaemon::Backend::Claude), "--agent task-analyst"
    assert_includes command_for(AgentDaemon::Backend::OpenCode, "opencode" => { "model" => "gpt" }),
                    "--agent task-analyst"
  end

  def test_claude_command_adds_model_when_configured
    assert_includes command_for(AgentDaemon::Backend::Claude, "claude" => { "model" => "haiku" }),
                    "--model haiku"
  end

  def test_claude_command_omits_model_when_not_configured
    refute_includes command_for(AgentDaemon::Backend::Claude), "--model"
  end

  private

  def fallback_config
    { "command" => "omp", "args" => ["--print", "--auto-approve"] }
  end

  def factory_backend(project_path: "/tmp/proj", **config)
    AgentDaemon::Backend.for(
      { "name" => "r" }.merge(config),
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: project_path
    )
  end

  def command_for(klass, runner_config = {})
    backend = klass.new(
      { "name" => "r", "extra_flags" => "" }.merge(runner_config),
      @shutdown,
      message_dir: "/tmp/msg",
      project_path: "/tmp/proj"
    )
    backend.send(:build_command, "hello")
  end
end
