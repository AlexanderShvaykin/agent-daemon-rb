# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestConfigSecrets < Minitest::Test
  # Build a config file from a raw body string (may contain ERB tags) inside a
  # temp dir with a valid runner + prompt template, then load it.
  def with_config(token: "t", webhook: "https://example.com/h", extra_tracker: "")
    Dir.mktmpdir do |dir|
      project_path = File.join(dir, "project")
      FileUtils.mkdir_p(project_path)
      template_path = File.join(dir, "prompts", "default.txt")
      FileUtils.mkdir_p(File.dirname(template_path))
      File.write(template_path, "Test prompt {{task_key}}")

      body = <<~YAML
        project_path: #{project_path}
        tracker:
          token: #{token}
          org_id: o
        #{extra_tracker}
        messenger:
          webhook_url: #{webhook}
        runners:
          - name: default
            prompt_template: prompts/default.txt
            trigger:
              type: tracker
              query: 'Queue: TI AND Status: "New"'
      YAML

      config_path = File.join(dir, "config.yml")
      File.write(config_path, body)
      yield AgentDaemon::Config.new(config_path)
    end
  end

  def with_env(vars)
    saved = {}
    vars.each { |k, v| saved[k] = ENV[k]; ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # 2.1 backward compatibility: no ERB tags
  def test_config_without_erb_tags_parses_identically
    with_config(token: "plain-token") do |config|
      assert_equal "plain-token", config.tracker["token"]
      assert_equal "https://example.com/h", config.messenger["webhook_url"]
    end
  end

  # 2.2 raw ENV interpolation resolves a set var
  def test_raw_env_resolves_set_variable
    with_env("TRACKER_TOKEN" => "env-token") do
      with_config(token: "<%= ENV['TRACKER_TOKEN'] %>") do |config|
        assert_equal "env-token", config.tracker["token"]
      end
    end
  end

  # 2.3 secret() resolves set vars for tracker.token and messenger.webhook_url
  def test_secret_resolves_set_variables
    with_env("TRACKER_TOKEN" => "s3cr3t", "WEBHOOK_URL" => "https://hooks.example.com/abc") do
      with_config(token: "<%= secret('TRACKER_TOKEN') %>",
                  webhook: "<%= secret('WEBHOOK_URL') %>") do |config|
        assert_equal "s3cr3t", config.tracker["token"]
        assert_equal "https://hooks.example.com/abc", config.messenger["webhook_url"]
      end
    end
  end

  # 2.4 missing secret raises ConfigError naming the key
  def test_missing_secret_raises_config_error_naming_key
    error = assert_raises(AgentDaemon::ConfigError) do
      with_config(token: "<%= secret('TRACKER_TOKEN') %>") { |_| }
    end
    assert_includes error.message, "TRACKER_TOKEN"
  end

  # 2.5 YAML-special characters preserved via .to_json quoting
  def test_secret_with_yaml_special_characters_preserved
    value = "p:a#s?s&w\"o'rd #notacomment"
    with_env("TRACKER_TOKEN" => value) do
      with_config(token: "<%= secret('TRACKER_TOKEN') %>") do |config|
        assert_equal value, config.tracker["token"]
      end
    end
  end

  # 2.6 raw ENV with unset var loads without raising (lenient path)
  def test_raw_env_with_unset_variable_is_lenient
    with_env("TRACKER_ORG_ID" => nil) do
      with_config(extra_tracker: "  extra: <%= ENV['TRACKER_ORG_ID'] %>") do |config|
        assert_nil config.tracker["extra"]
      end
    end
  end

  # 2.7 malformed ERB raises ConfigError
  def test_malformed_erb_raises_config_error
    assert_raises(AgentDaemon::ConfigError) do
      with_config(token: "<%= secret('X' %>") { |_| }
    end
  end

  # --- Story 3.3 / DR1: resolved secrets are recorded for the Redactor -------

  # The recorder must keep the RAW value, not the .to_json quoted form: the raw
  # string is what reaches the agent and can be echoed back on stdout.
  def test_resolved_secrets_records_the_raw_value_not_the_json_form
    value = "sekret-value-1"
    with_env("TRACKER_TOKEN" => value) do
      with_config(token: "<%= secret('TRACKER_TOKEN') %>") do |config|
        assert_equal [value], config.resolved_secrets
        refute_includes config.resolved_secrets, value.to_json
      end
    end
  end

  # Dedup is the Redactor's job (DR2), not the recorder's — verbatim capture.
  def test_two_references_to_one_key_are_recorded_twice
    with_env("TRACKER_TOKEN" => "sekret-value-1") do
      with_config(token: "<%= secret('TRACKER_TOKEN') %>",
                  extra_tracker: "  second: <%= secret('TRACKER_TOKEN') %>") do |config|
        assert_equal %w[sekret-value-1 sekret-value-1], config.resolved_secrets
      end
    end
  end

  def test_config_without_secret_calls_exposes_an_empty_collection
    with_config(token: "plain-token") do |config|
      assert_empty config.resolved_secrets
    end
  end

  # AD-8's accepted residual: raw ENV interpolation is not captured.
  # The positive control is test_resolved_secrets_records_the_raw_value_...
  def test_raw_env_interpolation_records_nothing
    with_env("TRACKER_TOKEN" => "sekret-value-1") do
      with_config(token: "<%= ENV['TRACKER_TOKEN'] %>") do |config|
        assert_equal "sekret-value-1", config.tracker["token"], "positive control: the value did reach the config"
        assert_empty config.resolved_secrets
      end
    end
  end

  # A missing secret raises before recording anything.
  def test_missing_secret_records_nothing
    config = AgentDaemon::Config.allocate

    assert_raises(AgentDaemon::ConfigError) { config.send(:secret, "UNSET_SECRET_XYZ_3_3") }

    assert_empty config.resolved_secrets
  end

  def test_resolved_secrets_hands_out_a_copy
    with_env("TRACKER_TOKEN" => "sekret-value-1") do
      with_config(token: "<%= secret('TRACKER_TOKEN') %>") do |config|
        first = config.resolved_secrets
        assert_raises(FrozenError) { first << "injected" }
        assert_equal %w[sekret-value-1], config.resolved_secrets
        refute_same first, config.resolved_secrets
      end
    end
  end
end
