# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"
require "fileutils"

# `description:` / `support:` at both the config level and the runner level.
# Nothing in the daemon reads them — they exist for the supervisor console, so
# what matters here is that they survive the load intact and that a malformed
# one is a load-time error rather than an empty block on someone's screen.
class TestConfigDocumentation < Minitest::Test
  def write_config(dir, data)
    config_path = File.join(dir, "config.yml")
    File.write(config_path, data.to_yaml)
    config_path
  end

  def with_project(dir)
    project_path = File.join(dir, "project")
    FileUtils.mkdir_p(project_path)
    template_path = File.join(dir, "prompts", "default.txt")
    FileUtils.mkdir_p(File.dirname(template_path))
    File.write(template_path, "prompt")
    project_path
  end

  def base_config(project_path, runner_overrides = {}, top_level = {})
    {
      "project_path" => project_path,
      "tracker" => { "token" => "t", "org_id" => "o" },
      "runners" => [{
        "name" => "default",
        "prompt_template" => "prompts/default.txt",
        "trigger" => { "type" => "tracker", "query" => "Queue: TI" }
      }.merge(runner_overrides)],
      "messenger" => { "webhook_url" => "https://example.com/h" }
    }.merge(top_level)
  end

  def load_config(runner_overrides = {}, top_level = {})
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, runner_overrides, top_level))
      yield AgentDaemon::Config.new(path)
    end
  end

  def error_from(runner_overrides = {}, top_level = {})
    Dir.mktmpdir do |dir|
      project_path = with_project(dir)
      path = write_config(dir, base_config(project_path, runner_overrides, top_level))
      error = assert_raises(AgentDaemon::ConfigError) { AgentDaemon::Config.new(path) }
      error.message
    end
  end

  # --- absence stays absence ------------------------------------------------

  # A config written before descriptions existed must load unchanged, and must
  # not grow an empty Hash the console would then render as a blank block.
  def test_both_keys_are_optional_and_absent_by_default
    load_config do |config|
      assert_nil config.description
      assert_nil config.support
      assert_nil config.runners.first["description"]
      assert_nil config.runners.first["support"]
    end
  end

  # --- values survive the load ---------------------------------------------

  def test_config_level_description_and_support_are_readable
    top = {
      "description" => "Analyses new tracker tasks.\nWrites the result as a comment.",
      "support" => {
        "owner" => "@alexander",
        "runbook" => "https://wiki.example.com/flows/task-analyst",
        "on_failure" => "Check the tracker token, then Restart."
      }
    }

    load_config({}, top) do |config|
      assert_equal "Analyses new tracker tasks.\nWrites the result as a comment.", config.description
      assert_equal "@alexander", config.support["owner"]
      assert_equal "https://wiki.example.com/flows/task-analyst", config.support["runbook"]
      assert_equal "Check the tracker token, then Restart.", config.support["on_failure"]
    end
  end

  def test_runner_level_description_and_support_are_readable
    runner = {
      "description" => "Picks up tasks matching the open-without-analysis filter.",
      "support" => { "owner" => "@alexander" }
    }

    load_config(runner) do |config|
      loaded = config.runners.first

      assert_equal "Picks up tasks matching the open-without-analysis filter.", loaded["description"]
      assert_equal({ "owner" => "@alexander" }, loaded["support"])
    end
  end

  # Every runner key becomes a prompt variable (PromptTemplate), and these two
  # are no exception — a prompt may legitimately quote what the work is for.
  def test_runner_documentation_is_available_as_a_prompt_variable
    load_config("description" => "Reviews merge requests.") do |config|
      assert_equal "Reviews merge requests.", config.runners.first["description"]
    end
  end

  # --- malformed values fail the load --------------------------------------

  def test_blank_description_is_rejected
    assert_match(/description must be a non-empty String/, error_from({}, "description" => "   "))
  end

  def test_non_string_description_is_rejected
    assert_match(/description must be a non-empty String/, error_from("description" => 42))
  end

  def test_runner_errors_name_the_runner
    message = error_from("support" => { "owner" => "" })

    assert_match(/runner "default": support\.owner must be a non-empty String/, message)
  end

  def test_support_must_be_a_hash
    assert_match(/support must be a Hash/, error_from({}, "support" => "@alexander"))
  end

  # A typo'd key would otherwise vanish silently and the console would show
  # nothing where support expects a runbook.
  def test_unknown_support_key_is_rejected
    message = error_from({}, "support" => { "runbok" => "https://wiki.example.com" })

    assert_match(/support has unknown key\(s\) runbok/, message)
  end

  def test_non_http_runbook_is_rejected
    message = error_from({}, "support" => { "runbook" => "javascript:alert(1)" })

    assert_match(/support\.runbook must be an http\(s\) URL/, message)
  end

  def test_schemeless_runbook_is_rejected
    assert_match(/support\.runbook must be an http\(s\) URL/,
                 error_from({}, "support" => { "runbook" => "wiki.example.com/flows" }))
  end

  def test_malformed_runbook_uri_is_rejected_without_raising
    assert_match(/support\.runbook must be an http\(s\) URL/,
                 error_from({}, "support" => { "runbook" => "http://[bad" }))
  end

  def test_http_and_https_runbooks_are_accepted
    load_config({}, "support" => { "runbook" => "http://wiki.example.com/flows" }) do |config|
      assert_equal "http://wiki.example.com/flows", config.support["runbook"]
    end
  end

  # The config collects every problem into one ConfigError (fail-fast, but
  # complete) — documentation errors must join that list, not short-circuit it.
  def test_documentation_errors_are_collected_with_the_rest
    message = error_from({ "support" => { "owner" => "" } }, "description" => "")

    assert_match(/description must be a non-empty String/, message)
    assert_match(/runner "default": support\.owner must be a non-empty String/, message)
  end
end
