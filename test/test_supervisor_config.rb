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

  # Task 5 (1.4) — a ':' in a runner name is rejected (identity delimiter),
  # closing the 1.1 review deferral ("runner names come from core and remain a
  # Story 1.4 concern").
  def test_runner_name_with_colon_raises
    specs = [
      { name: "wf", file: "wf",
        data: sandboxed_workflow_data(runner_extra: { "name" => "a:b" }) }
    ]
    with_supervisor(specs) do |_dir, path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/must not contain ':'/, err.message)
      assert_match(/wf/, err.message)
      assert_match(/a:b/, err.message)
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

  # --- event_bus_capacity (AD-10 convention: DEFAULTS + validate!) ---------

  # Rewrite the supervisor.yml the helper produced, keeping its (valid)
  # workflows list, so a capacity case is exercised against a config that is
  # otherwise clean.
  def with_capacity(value)
    specs = [{ name: "a", file: "a", data: sandboxed_workflow_data }]
    with_supervisor(specs) do |_dir, path|
      data = YAML.safe_load(File.read(path))
      data["event_bus_capacity"] = value unless value == :omitted
      File.write(path, data.to_yaml)
      yield path
    end
  end

  def test_event_bus_capacity_defaults_to_the_bus_constant
    with_capacity(:omitted) do |path|
      config = AgentDaemon::Supervisor::Config.new(path)
      assert_equal AgentDaemon::Supervisor::EventBus::DEFAULT_CAPACITY, config.event_bus_capacity
    end
  end

  def test_event_bus_capacity_accepts_a_positive_integer_override
    with_capacity(50) do |path|
      assert_equal 50, AgentDaemon::Supervisor::Config.new(path).event_bus_capacity
    end
  end

  def test_event_bus_capacity_rejects_zero_negative_and_non_integer
    [0, -1, "2000", 12.5].each do |bad|
      with_capacity(bad) do |path|
        err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
        assert_match(/event_bus_capacity must be a positive integer/, err.message)
      end
    end
  end

  # --- console block (Story 2.2, AC6/AC8) ---------------------------------

  # A minimal VALID console block. Callers mutate the returned hash (or drop
  # keys from it) so every failure case starts from something that would
  # otherwise load cleanly — a case that fails for two reasons proves nothing.
  def valid_console
    {
      "base_url" => "https://console.example.com",
      "auth" => {
        "gitlab_host" => "https://gitlab.example.com",
        "app_id" => "id",
        "app_secret" => "secret",
        "allowed_groups" => ["backoffice", "platform/sre"]
      }
    }
  end

  # Same shape as with_capacity: keep the helper's valid workflows list and
  # splice a console block into the supervisor.yml. :omitted writes no key.
  def with_console(value)
    specs = [{ name: "a", file: "a", data: sandboxed_workflow_data }]
    with_supervisor(specs) do |_dir, path|
      data = YAML.safe_load(File.read(path))
      data["console"] = value unless value == :omitted
      File.write(path, data.to_yaml)
      yield path
    end
  end

  def console_error(value)
    with_console(value) do |path|
      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      return err.message
    end
  end

  # AC8 — the whole point of the nil default: a pre-console supervisor config
  # loads with zero new requirements.
  def test_console_absent_loads_and_disables_the_console
    with_console(:omitted) do |path|
      assert_nil AgentDaemon::Supervisor::Config.new(path).console
    end
  end

  def test_console_explicit_nil_disables_the_console
    with_console(nil) do |path|
      assert_nil AgentDaemon::Supervisor::Config.new(path).console
    end
  end

  def test_console_applies_defaults_under_a_present_block
    with_console(valid_console) do |path|
      console = AgentDaemon::Supervisor::Config.new(path).console
      assert_equal "127.0.0.1", console["bind"]
      assert_equal 9292, console["port"]
      assert_equal 16, console["max_threads"]
      assert_equal 28_800, console["session_ttl"]
      assert_equal true, console["secure_cookies"]
      assert_equal "https://console.example.com", console["base_url"]
      assert_equal %w[backoffice platform/sre], console.dig("auth", "allowed_groups")
    end
  end

  def test_console_overrides_defaults
    console = valid_console.merge("bind" => "0.0.0.0", "port" => 8080, "max_threads" => 4,
                                  "session_ttl" => 60, "secure_cookies" => false)
    with_console(console) do |path|
      loaded = AgentDaemon::Supervisor::Config.new(path).console
      assert_equal "0.0.0.0", loaded["bind"]
      assert_equal 8080, loaded["port"]
      assert_equal 4, loaded["max_threads"]
      assert_equal 60, loaded["session_ttl"]
      assert_equal false, loaded["secure_cookies"]
    end
  end

  def test_console_must_be_a_mapping
    assert_match(/console must be a mapping/, console_error("yes"))
  end

  def test_console_base_url_is_required
    assert_match(/console\.base_url is required/, console_error(valid_console.tap { |c| c.delete("base_url") }))
    assert_match(/console\.base_url is required/, console_error(valid_console.merge("base_url" => "")))
    assert_match(/console\.base_url is required/, console_error(valid_console.merge("base_url" => 42)))
  end

  def test_console_auth_is_required
    assert_match(/console\.auth is required/, console_error(valid_console.tap { |c| c.delete("auth") }))
    assert_match(/console\.auth is required/, console_error(valid_console.merge("auth" => "nope")))
  end

  def test_console_auth_credentials_are_required
    %w[gitlab_host app_id app_secret].each do |key|
      console = valid_console
      console["auth"].delete(key)
      assert_match(/console\.auth\.#{key} is required \(String\)/, console_error(console))
    end
  end

  # The secret must never be echoed back, not even as the "got" half of its own
  # error message.
  def test_console_app_secret_value_never_appears_in_the_error
    console = valid_console
    console["auth"]["app_secret"] = ""
    console["auth"]["app_id"] = { "leaky" => "s3kr3t-value" }
    message = console_error(console)
    assert_match(/console\.auth\.app_secret is required \(String\)/, message)
    refute_match(/s3kr3t-value/, message)
  end

  def test_console_gitlab_host_must_be_an_http_url
    ["ftp://gitlab.example.com", "gitlab.example.com", "://"].each do |bad|
      console = valid_console
      console["auth"]["gitlab_host"] = bad
      assert_match(/console\.auth\.gitlab_host must be an http\(s\) URL/, console_error(console))
    end
  end

  def test_console_gitlab_host_accepts_plain_http
    console = valid_console
    console["auth"]["gitlab_host"] = "http://gitlab.internal"
    with_console(console) do |path|
      assert_equal "http://gitlab.internal", AgentDaemon::Supervisor::Config.new(path).console.dig("auth", "gitlab_host")
    end
  end

  def test_console_allowed_groups_must_be_a_non_empty_list_of_strings
    console = valid_console
    console["auth"]["allowed_groups"] = "backoffice"
    assert_match(/console\.auth\.allowed_groups must be a list/, console_error(console))

    console = valid_console
    console["auth"]["allowed_groups"] = []
    assert_match(/console\.auth\.allowed_groups is empty/, console_error(console))

    console = valid_console
    console["auth"]["allowed_groups"] = ["ok", "", 7]
    assert_match(/console\.auth\.allowed_groups entries must be non-empty strings/, console_error(console))
  end

  def test_console_numeric_keys_must_be_positive_integers
    %w[max_threads session_ttl].each do |key|
      [0, -1, "9292", 1.5, true].each do |bad|
        message = console_error(valid_console.merge(key => bad))
        assert_match(/console\.#{key} must be a positive integer/, message)
      end
    end
  end

  # A "positive integer" port still fails at bind time, which Master demotes to
  # a logged warning and a console-less supervisor — so the range is what makes
  # a typo an eager ConfigError.
  def test_console_port_must_be_inside_the_tcp_port_range
    [0, -1, 65_536, 70_000, "9292", 1.5, true].each do |bad|
      assert_match(/console\.port must be a port number in 1\.\.65535/,
                   console_error(valid_console.merge("port" => bad)))
    end

    with_console(valid_console.merge("port" => 65_535)) do |path|
      assert_equal 65_535, AgentDaemon::Supervisor::Config.new(path).console["port"]
    end
  end

  def test_console_secure_cookies_must_be_boolean
    assert_match(/console\.secure_cookies must be true or false/,
                 console_error(valid_console.merge("secure_cookies" => "true")))
  end

  # base_url feeds URI.join in Server, which raises on a relative value — and
  # Master demotes that raise to a logged warning and a console-less
  # supervisor. Validating it here keeps the eager-ConfigError contract.
  def test_console_base_url_must_be_an_absolute_http_url
    ["console.example.com", "/console", "ftp://c.example.com", "https://", "https:"].each do |bad|
      assert_match(/console\.base_url must be an absolute http\(s\) URL/,
                   console_error(valid_console.merge("base_url" => bad)),
                   "#{bad.inspect} must be rejected")
    end
  end

  # A scheme-only check passes "https://", whose host is empty — the client
  # then fails at runtime with a generic wrapped error instead of at load.
  def test_console_gitlab_host_must_carry_a_host_not_just_a_scheme
    console = valid_console
    console["auth"]["gitlab_host"] = "https://"

    assert_match(/console\.auth\.gitlab_host must be an http\(s\) URL/, console_error(console))
  end

  # The two keys are coupled: over plain HTTP the browser silently discards a
  # Secure cookie, so every request arrives cookieless and login loops forever
  # with nothing in the log to explain it.
  def test_console_secure_cookies_conflicts_with_a_plain_http_base_url
    console = valid_console.merge("base_url" => "http://console.internal")

    assert_match(/console\.secure_cookies is true but console\.base_url is plain http/,
                 console_error(console))
  end

  def test_console_plain_http_base_url_is_fine_when_secure_cookies_is_off
    console = valid_console.merge("base_url" => "http://console.internal", "secure_cookies" => false)

    with_console(console) do |path|
      assert_equal false, AgentDaemon::Supervisor::Config.new(path).console["secure_cookies"]
    end
  end

  def test_console_roles_are_optional
    with_console(valid_console) do |path|
      assert_nil AgentDaemon::Supervisor::Config.new(path).console.dig("auth", "roles")
    end
  end

  def test_console_roles_are_parsed_when_valid
    console = valid_console
    console["auth"]["roles"] = { "viewer" => ["backoffice"], "operator" => ["platform/sre"] }
    with_console(console) do |path|
      roles = AgentDaemon::Supervisor::Config.new(path).console.dig("auth", "roles")
      assert_equal({ "viewer" => ["backoffice"], "operator" => ["platform/sre"] }, roles)
    end
  end

  def test_console_roles_must_be_a_mapping
    console = valid_console
    console["auth"]["roles"] = %w[viewer]
    assert_match(/console\.auth\.roles must be a mapping/, console_error(console))
  end

  def test_console_unknown_role_name_is_rejected
    console = valid_console
    console["auth"]["roles"] = { "admin" => ["backoffice"] }
    message = console_error(console)
    assert_match(/unknown role "admin"/, message)
    assert_match(/expected one of: viewer, operator/, message)
  end

  def test_console_malformed_role_value_is_rejected
    [["backoffice", ""], "backoffice", []].each do |bad|
      console = valid_console
      console["auth"]["roles"] = { "viewer" => bad }
      assert_match(/console\.auth\.roles\.viewer must be a list of non-empty strings/, console_error(console))
    end
  end

  # A role naming a group nobody can hold is a dead rule, and a dead rule is a
  # config bug this repo fails fast on.
  def test_console_role_referencing_a_group_outside_allowed_groups_is_rejected
    console = valid_console
    console["auth"]["roles"] = { "viewer" => ["backoffice", "ghost/group"] }
    message = console_error(console)
    assert_match(/console\.auth\.roles\.viewer references group "ghost\/group"/, message)
    assert_match(/not in allowed_groups/, message)
    refute_match(/"backoffice"/, message)
  end

  # Collect-all, same contract as every sibling validator.
  def test_console_collects_every_problem_into_one_error
    console = valid_console.merge("base_url" => "", "port" => 0)
    console["auth"]["allowed_groups"] = []
    console["auth"]["roles"] = { "admin" => ["x"] }
    message = console_error(console)

    assert_match(/console\.base_url is required/, message)
    assert_match(/console\.port must be a port number/, message)
    assert_match(/console\.auth\.allowed_groups is empty/, message)
    assert_match(/unknown role "admin"/, message)
  end

  # A console problem must not mask a workflow problem (or vice versa): both
  # validators contribute to the same collected error.
  def test_console_problems_collect_alongside_workflow_problems
    specs = [{ name: "a", file: "a", data: sandboxed_workflow_data }]
    with_supervisor(specs) do |_dir, path|
      data = YAML.safe_load(File.read(path))
      data["console"] = valid_console.merge("port" => 0)
      data["event_bus_capacity"] = -5
      File.write(path, data.to_yaml)

      err = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Supervisor::Config.new(path) }
      assert_match(/event_bus_capacity must be a positive integer/, err.message)
      assert_match(/console\.port must be a port number/, err.message)
    end
  end
end
