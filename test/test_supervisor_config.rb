# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

# AD-5 lazy-require isolation: the supervisor file is loaded explicitly here and
# is NOT part of the core `require "agent_daemon"` graph.
require "agent_daemon/supervisor/config"

class TestSupervisorConfig < Minitest::Test
  # Build a supervisor config in a fresh tmpdir. `specs` is a list of
  # { name:, file:, data: } — `data` is a per-workflow config hash written to
  # workflows/<file>.yml (nil => file intentionally absent; a Proc is called
  # with the tmpdir so project_path can live inside the sandbox). `entries`,
  # when given, overrides the supervisor's workflows list (used to fake
  # duplicate names / bad entries independently of the files on disk).
  def with_supervisor(specs, entries: nil)
    Dir.mktmpdir do |dir|
      wf_dir = File.join(dir, "workflows")
      FileUtils.mkdir_p(File.join(wf_dir, "prompts"))
      File.write(File.join(wf_dir, "prompts", "default.txt"), "Prompt {{task_key}}")

      specs.each do |spec|
        if spec.key?(:raw)
          File.write(File.join(wf_dir, "#{spec[:file]}.yml"), spec[:raw])
        elsif spec[:data]
          data = spec[:data]
          data = data.call(dir) if data.respond_to?(:call)
          File.write(File.join(wf_dir, "#{spec[:file]}.yml"), data.to_yaml)
        end
      end

      entries ||= specs.map { |s| { "name" => s[:name], "config" => "workflows/#{s[:file]}.yml" } }
      path = File.join(dir, "supervisor.yml")
      File.write(path, { "workflows" => entries }.to_yaml)

      yield dir, path
    end
  end

  # Write raw supervisor-config content verbatim (for ERB/secret/malformed-shape
  # cases the structured helper cannot express).
  def with_raw_supervisor(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "supervisor.yml")
      File.write(path, content)
      yield path
    end
  end

  # A valid per-workflow config (mirrors test_config_defaults.rb's with_config).
  def workflow_data(project_path:, message_dir: "to_message", trigger: nil, runner_extra: {})
    trigger ||= { "type" => "tracker", "query" => 'Queue: TI AND Status: "New"' }
    {
      "project_path" => project_path,
      "message_dir" => message_dir,
      "tracker" => { "token" => "t", "org_id" => "o" },
      "runners" => [
        {
          "name" => "default",
          "prompt_template" => "prompts/default.txt",
          "trigger" => trigger
        }.merge(runner_extra)
      ],
      "messenger" => { "webhook_url" => "https://example.com/h" }
    }
  end

  # workflow_data whose project_path lives inside the test's tmpdir (resolved
  # lazily by with_supervisor) instead of a hardcoded global path.
  def sandboxed_workflow_data(**kwargs)
    ->(dir) { workflow_data(project_path: File.join(dir, "proj"), **kwargs) }
  end

  def file_trigger(input_dir:, archive_dir:, failed_dir:)
    {
      "type" => "file",
      "input_dir" => input_dir,
      "archive_dir" => archive_dir,
      "failed_dir" => failed_dir
    }
  end

  # AC1 — happy path: every runner gets a composite (workflow, runner) identity
  # whose thread_key/log_tag are workflow-qualified and distinct from a
  # name-only key, even when two workflows share the same runner name.
  def test_happy_path_assigns_composite_identities
    with_supervisor(
      [
        { name: "task-analyst", file: "task-analyst",
          data: sandboxed_workflow_data(message_dir: "to_message_a") },
        { name: "reviewer", file: "reviewer",
          data: sandboxed_workflow_data(message_dir: "to_message_b") }
      ]
    ) do |_dir, path|
      config = AgentDaemon::Supervisor::Config.new(path)

      assert_equal 2, config.workflows.size
      names = config.workflows.map { |w| w[:name] }
      assert_equal %w[task-analyst reviewer], names

      config.workflows.each do |w|
        assert_instance_of AgentDaemon::Config, w[:config]
        assert_equal 1, w[:identities].size
      end

      ta = config.workflows.first[:identities].first
      assert_equal :"runner:task-analyst:default", ta.thread_key
      assert_equal "task-analyst:default", ta.log_tag
      assert_equal "task-analyst:default", ta.to_s
      assert_equal "task-analyst", ta.workflow
      assert_equal "default", ta.runner

      rv = config.workflows.last[:identities].first
      # Same runner name, different workflow => distinct composite identity.
      refute_equal ta.thread_key, rv.thread_key
      assert_equal :"runner:reviewer:default", rv.thread_key
      # And distinct from a core name-only key.
      refute_equal :"runner:default", ta.thread_key

      assert_equal %i[runner:task-analyst:default runner:reviewer:default],
                   config.runner_identities.map(&:thread_key)
    end
  end

  # AC2 — duplicate workflow names raise a ConfigError naming the duplicate.
  def test_duplicate_workflow_names_raise
    specs = [
      { name: "dup", file: "one",
        data: sandboxed_workflow_data(message_dir: "to_message_a") },
      { name: "dup", file: "two",
        data: sandboxed_workflow_data(message_dir: "to_message_b") }
    ]
    with_supervisor(specs) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/duplicate workflow name/, err.message)
      assert_match(/dup/, err.message)
    end
  end

  # AC3a — two workflows resolving to the same message_dir collide.
  def test_same_message_dir_collides
    # Shared project_path + shared default message_dir => same absolute path.
    specs = [
      { name: "a", file: "a", data: sandboxed_workflow_data },
      { name: "b", file: "b", data: sandboxed_workflow_data }
    ]
    with_supervisor(specs) do |dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/collision/, err.message)
      assert_includes err.message, File.join(dir, "proj", "to_message")
      assert_match(/"a"/, err.message)
      assert_match(/"b"/, err.message)
    end
  end

  # AC3b — two workflows sharing a trigger work-dir collide (message_dirs differ).
  def test_same_trigger_workdir_collides
    shared = file_trigger(input_dir: "shared_inbox", archive_dir: "a_done", failed_dir: "a_failed")
    other  = file_trigger(input_dir: "shared_inbox", archive_dir: "b_done", failed_dir: "b_failed")
    specs = [
      { name: "a", file: "a",
        data: sandboxed_workflow_data(message_dir: "to_message_a", trigger: shared) },
      { name: "b", file: "b",
        data: sandboxed_workflow_data(message_dir: "to_message_b", trigger: other) }
    ]
    with_supervisor(specs) do |dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/collision/, err.message)
      assert_includes err.message, File.join(dir, "proj", "shared_inbox")
    end
  end

  # AC3c — a merely shared project_path (distinct work dirs) loads fine.
  def test_shared_project_path_only_loads
    specs = [
      { name: "a", file: "a",
        data: sandboxed_workflow_data(message_dir: "to_message_a") },
      { name: "b", file: "b",
        data: sandboxed_workflow_data(message_dir: "to_message_b") }
    ]
    with_supervisor(specs) do |_dir, path|
      config = AgentDaemon::Supervisor::Config.new(path)
      assert_equal 2, config.workflows.size
    end
  end

  # AC4 — a missing referenced config surfaces as ConfigError (not Errno::ENOENT).
  def test_missing_referenced_config_raises
    specs = [
      { name: "ghost", file: "ghost", data: nil } # file intentionally not written
    ]
    with_supervisor(specs) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/ghost/, err.message)
    end
  end

  # AC4 — a referenced config that is itself invalid surfaces as ConfigError
  # naming the offending entry.
  def test_invalid_referenced_config_raises
    specs = [
      { name: "broken", file: "broken",
        # core Config rejects empty runners
        data: ->(dir) { workflow_data(project_path: File.join(dir, "proj")).merge("runners" => []) } }
    ]
    with_supervisor(specs) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/broken/, err.message)
    end
  end

  # AC5 — collect-all: two independent problems produce a single ConfigError
  # that mentions both.
  def test_collect_all_reports_multiple_problems
    specs = [
      { name: "dup", file: "one",
        data: sandboxed_workflow_data(message_dir: "to_message_a") },
      { name: "dup", file: "two",
        data: sandboxed_workflow_data(message_dir: "to_message_b") },
      { name: "ghost", file: "ghost", data: nil }
    ]
    with_supervisor(specs) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/duplicate workflow name/, err.message)
      assert_match(/ghost/, err.message)
    end
  end

  # AC5 / mirror core — non-list and empty workflows are rejected.
  def test_empty_workflows_raises
    with_supervisor([], entries: []) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/workflows is empty/, err.message)
    end
  end

  # --- Review follow-ups -----------------------------------------------------

  # [Patch HIGH] a missing workflow name is rejected (not silently accepted).
  def test_missing_workflow_name_raises
    with_supervisor(
      [{ name: "x", file: "x", data: sandboxed_workflow_data }],
      entries: [{ "config" => "workflows/x.yml" }] # no "name" key
    ) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/workflow name is required/, err.message)
    end
  end

  # [Patch HIGH] a non-String workflow name is rejected.
  def test_non_string_workflow_name_raises
    with_supervisor(
      [{ name: "x", file: "x", data: sandboxed_workflow_data }],
      entries: [{ "name" => 123, "config" => "workflows/x.yml" }]
    ) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/workflow name is required/, err.message)
    end
  end

  # [Patch MED] a ':' in a workflow name is rejected (identity delimiter).
  def test_workflow_name_with_colon_raises
    with_supervisor(
      [{ name: "a:b", file: "x", data: sandboxed_workflow_data }],
      entries: [{ "name" => "a:b", "config" => "workflows/x.yml" }]
    ) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/must not contain ':'/, err.message)
      assert_match(/a:b/, err.message)
    end
  end

  # [Patch MED] two workflows resolving to the same output_dir collide.
  def test_same_output_dir_collides
    specs = [
      { name: "a", file: "a",
        data: sandboxed_workflow_data(message_dir: "to_message_a",
                                      runner_extra: { "output_dir" => "shared_out" }) },
      { name: "b", file: "b",
        data: sandboxed_workflow_data(message_dir: "to_message_b",
                                      runner_extra: { "output_dir" => "shared_out" }) }
    ]
    with_supervisor(specs) do |dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/collision/, err.message)
      assert_includes err.message, File.join(dir, "proj", "shared_out")
    end
  end

  # [Patch MED] a referenced config that omits project_path surfaces as a
  # ConfigError (message_dir would otherwise raise a raw KeyError).
  def test_referenced_config_missing_project_path_raises
    data = {
      "message_dir" => "to_message",
      "tracker" => { "token" => "t", "org_id" => "o" },
      "runners" => [
        { "name" => "default", "prompt_template" => "prompts/default.txt",
          "trigger" => { "type" => "tracker", "query" => "Queue: TI" } }
      ],
      "messenger" => { "webhook_url" => "https://example.com/h" }
    }
    with_supervisor([{ name: "np", file: "np", data: data }]) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/np/, err.message)
      assert_match(/project_path/, err.message)
    end
  end

  # [Patch MED] a non-String project_path in a referenced config surfaces as a
  # ConfigError, not a raw TypeError (message_dir -> File.expand_path(_, 123)).
  # Core Config never type-checks project_path, so the collision check must
  # absorb the failure to keep the single-exception-type contract.
  def test_referenced_config_non_string_project_path_raises
    with_supervisor(
      [{ name: "badpath", file: "badpath", data: workflow_data(project_path: 123) }]
    ) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/badpath/, err.message)
      assert_match(/cannot resolve work dirs/, err.message)
    end
  end

  # [Patch MED] malformed YAML in a referenced config surfaces as ConfigError
  # naming the entry (broadened rescue covers Psych::SyntaxError).
  def test_malformed_referenced_config_raises
    with_supervisor([{ name: "bad", file: "bad", raw: "runners: [oops\n" }]) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/bad/, err.message)
      # The wrapped message names the referenced file, not just the entry.
      assert_match(%r{workflows/bad\.yml}, err.message)
    end
  end

  # [Patch MED] a non-Hash top-level referenced config surfaces as ConfigError
  # naming the entry (broadened rescue covers TypeError).
  def test_non_hash_referenced_config_raises
    with_supervisor([{ name: "arr", file: "arr", raw: "- a\n- b\n" }]) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/arr/, err.message)
      # The wrapped message names the referenced file and carries the cause.
      assert_match(%r{workflows/arr\.yml}, err.message)
      assert_match(/Hash/, err.message)
    end
  end

  # [Patch MED] non-Array workflows is rejected (spec Task 3 branch).
  def test_non_array_workflows_raises
    with_raw_supervisor("workflows: not-a-list\n") do |path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/workflows must be a list/, err.message)
    end
  end

  # [Patch MED] nil/missing workflows is rejected (spec Task 3 branch).
  def test_nil_workflows_raises
    with_raw_supervisor("workflows:\n") do |path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/workflows is missing/, err.message)
    end
  end

  # [Patch MED] the supervisor's own ERB/secret path wraps a missing secret as
  # ConfigError naming the key.
  def test_missing_secret_in_supervisor_config_raises
    with_raw_supervisor("workflows: <%= secret('UNSET_SUPERVISOR_SECRET_XYZ') %>\n") do |path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/UNSET_SUPERVISOR_SECRET_XYZ/, err.message)
    end
  end

  # [Patch MED] an ERB render error in the supervisor config is wrapped as
  # ConfigError (single-exception-type contract).
  def test_erb_render_error_in_supervisor_config_raises
    with_raw_supervisor("workflows:\n<%= 1 + %>\n") do |path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/failed to render/, err.message)
    end
  end

  # [R3 Patch LOW] a non-Hash workflow entry is rejected with the entry shown.
  def test_non_hash_workflow_entry_raises
    with_supervisor(
      [{ name: "x", file: "x", data: sandboxed_workflow_data }],
      entries: ["just-a-string"]
    ) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/workflow entry must be a mapping/, err.message)
      assert_match(/just-a-string/, err.message)
    end
  end

  # [R3 Patch LOW] stray trigger work-dir keys on a tracker trigger (which core
  # never resolves to absolute paths) must not enter the collision map — two
  # workflows with the same leftover relative input_dir do NOT collide.
  def test_tracker_trigger_stray_dirs_do_not_collide
    tracker_with_stray = {
      "type" => "tracker", "query" => "Queue: TI",
      "input_dir" => "inbox", "archive_dir" => "done", "failed_dir" => "failed"
    }
    specs = [
      { name: "a", file: "a",
        data: sandboxed_workflow_data(message_dir: "to_message_a", trigger: tracker_with_stray) },
      { name: "b", file: "b",
        data: sandboxed_workflow_data(message_dir: "to_message_b", trigger: tracker_with_stray) }
    ]
    with_supervisor(specs) do |_dir, path|
      config = AgentDaemon::Supervisor::Config.new(path)
      assert_equal 2, config.workflows.size
    end
  end
end
