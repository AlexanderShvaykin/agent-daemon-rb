# frozen_string_literal: true

require "yaml"
require "erb"
require "json"
require "uri"

module AgentDaemon
  class ConfigError < StandardError; end

  class Config
    DEFAULTS = {
      "message_dir" => "to_message",
      "runners" => [],
      "tracker" => {
        "default_backoff" => 60
      },
      "messenger" => {
        "type" => "webhook",
        "interval" => 30
      },
      "logging" => {
        "level" => "info",
        "output" => "file",
        "file" => "logs/task-analyst.log"
      }
    }.freeze

    RUNNER_DEFAULTS = {
      "backend" => "claude",
      "agent" => "task-analyst",
      "extra_flags" => "",
      "timeout" => 1200,
      "max_attempts" => 3,
      "trigger" => {}
    }.freeze

    TRACKER_TRIGGER_DEFAULTS    = { "interval" => 60, "jitter" => 5 }.freeze
    FILE_TRIGGER_DEFAULTS       = { "interval" => 10, "jitter" => 5 }.freeze
    MATTERMOST_TRIGGER_DEFAULTS = { "interval" => 2, "jitter" => 0 }.freeze

    # The whole `support:` vocabulary, at both the config and the runner level.
    # Closed on purpose: a typo'd key would otherwise vanish silently and the
    # console would show nothing where support expects a runbook.
    SUPPORT_KEYS = %w[owner runbook on_failure].freeze

    # A runbook is rendered as an anchor by the console, so anything but http(s)
    # is rejected at load rather than turned into a javascript:/data: link.
    RUNBOOK_SCHEMES = %w[http https].freeze

    VALID_TRIGGER_TYPES   = %w[tracker file mattermost].freeze
    VALID_BACKENDS        = %w[claude opencode].freeze
    VALID_MESSENGER_TYPES = %w[webhook mattermost].freeze
    MATTERMOST_REQUIRED   = %w[base_url token team default_channel].freeze

    attr_reader :data, :config_dir, :config_path

    def initialize(path)
      @config_path = File.expand_path(path)
      @config_dir  = File.dirname(@config_path)
      @resolved_secrets = []
      raw = YAML.safe_load(render(File.read(path))) || {}
      @data = deep_merge(DEFAULTS, raw)
      @runners = build_runners(raw["runners"])
      validate!
    end

    def project_path
      @data.fetch("project_path")
    end

    def tracker
      @data.fetch("tracker")
    end

    def messenger
      @data.fetch("messenger")
    end

    def logging
      @data.fetch("logging")
    end

    def message_dir
      File.expand_path(@data.fetch("message_dir"), project_path)
    end

    def runners
      @runners
    end

    # Operator-authored prose describing what this whole workflow is for, and
    # who to page when it breaks (both optional). Nothing in the daemon reads
    # these — they exist so the supervisor console can tell someone who did not
    # write the config what a flow does. The same two keys are accepted on a
    # runner, where they describe that single piece of work.
    def description
      @data["description"]
    end

    def support
      @data["support"]
    end

    # Every raw value `secret()` resolved while rendering this config, in call
    # order and unfiltered — the supervisor's Redactor is what dedups, orders,
    # and compiles them (AD-8). Returns a frozen copy: the live array must
    # never escape, and these values must never be logged, inspected into a
    # message, rendered, or serialized.
    def resolved_secrets
      (@resolved_secrets || []).dup.freeze
    end

    private

    # Render the config file as an ERB template before YAML parsing. The
    # binding exposes `secret` and `ENV`. Render-time failures (ERB syntax
    # errors, missing secrets) surface as ConfigError so callers keep relying
    # on the single-exception-type contract.
    def render(src)
      ERB.new(src).result(binding)
    rescue ConfigError
      raise
    rescue StandardError, SyntaxError => e
      raise ConfigError, "failed to render #{@config_path}: #{e.message}"
    end

    # Resolve a secret from the environment as a YAML-safe, quoted scalar.
    # Fails fast (ConfigError) when the variable is unset. `.to_json` produces
    # a double-quoted, escaped string so values containing YAML-significant
    # characters (#, :, ?, &, quotes) parse intact.
    #
    # The RAW value — not the quoted form — is recorded for #resolved_secrets:
    # the raw string is what survives into @data, reaches the agent, and can be
    # echoed back on stdout, so it is what the Redactor must match (DR1).
    def secret(key)
      value = ENV.fetch(key)
      (@resolved_secrets ||= []) << value
      value.to_json
    rescue KeyError
      raise ConfigError, "secret #{key} is not set in environment"
    end

    def build_runners(raw_runners)
      return [] unless raw_runners.is_a?(Array)

      raw_runners.map { |r| build_runner(r) }
    end

    def build_runner(raw)
      return raw unless raw.is_a?(Hash)

      runner = deep_merge(RUNNER_DEFAULTS, raw)
      runner["trigger"] = build_trigger(runner["trigger"], runner["name"])

      if runner["output_dir"].is_a?(String) && !runner["output_dir"].empty?
        runner["output_dir"] = File.expand_path(runner["output_dir"], @data["project_path"] || "")
      end

      if runner["prompt_template"].is_a?(String) && !runner["prompt_template"].empty?
        runner["prompt_template_path"] = File.expand_path(runner["prompt_template"], @config_dir)
      end

      runner
    end

    def build_trigger(raw_trigger, runner_name = nil)
      return {} unless raw_trigger.is_a?(Hash)

      case raw_trigger["type"]
      when "tracker"
        deep_merge(TRACKER_TRIGGER_DEFAULTS, raw_trigger)
      when "file"
        resolve_trigger_dirs(deep_merge(FILE_TRIGGER_DEFAULTS, raw_trigger))
      when "mattermost"
        trigger = deep_merge(MATTERMOST_TRIGGER_DEFAULTS, raw_trigger)
        name = runner_name.to_s
        trigger["input_dir"]   ||= "mentions/#{name}/inbox"
        trigger["archive_dir"] ||= "mentions/#{name}/done"
        trigger["failed_dir"]  ||= "mentions/#{name}/failed"
        resolve_trigger_dirs(trigger)
      else
        raw_trigger
      end
    end

    # Resolve a file-poll trigger's three work dirs relative to project_path.
    # Shared by the file and mattermost triggers; leaves absolute paths verbatim.
    def resolve_trigger_dirs(trigger)
      %w[input_dir archive_dir failed_dir].each do |key|
        if trigger[key].is_a?(String) && !trigger[key].empty?
          trigger[key] = File.expand_path(trigger[key], @data["project_path"] || "")
        end
      end
      trigger
    end

    def validate!
      errors = []

      raw_runners = @data["runners"]
      if raw_runners.nil?
        errors << "runners is missing in #{@config_path}"
      elsif !raw_runners.is_a?(Array)
        errors << "runners must be a list in #{@config_path}"
      elsif raw_runners.empty?
        errors << "runners is empty in #{@config_path}"
      else
        errors.concat(validate_duplicate_names)
        @runners.each { |runner| errors.concat(validate_runner(runner)) }
      end

      errors.concat(validate_documentation(@data["description"], @data["support"]))
      errors.concat(validate_tracker)
      errors.concat(validate_messenger)

      raise ConfigError, errors.join("\n") unless errors.empty?
    end

    # Validate the tracker block's default backoff (seconds used when a 429
    # response carries no usable Retry-After). The key always has a default, so
    # we only guard against an operator overriding it with a negative number.
    def validate_tracker
      tracker = @data["tracker"]
      return [] unless tracker.is_a?(Hash)

      backoff = tracker["default_backoff"]
      return [] if backoff.is_a?(Numeric) && backoff >= 0

      ["tracker.default_backoff must be a non-negative number (got #{backoff.inspect})"]
    end

    # Validate the messenger block per its transport type. The webhook type
    # keeps webhook_url optional (an absent URL leaves the messenger thread
    # disabled — see daemon.rb), preserving prior behavior. The mattermost
    # type is opt-in and strict: all connection keys must be present.
    def validate_messenger
      messenger = @data["messenger"] || {}
      type = messenger["type"]

      unless VALID_MESSENGER_TYPES.include?(type)
        return ["messenger.type must be one of #{VALID_MESSENGER_TYPES.join(', ')} (got #{type.inspect})"]
      end

      return validate_alerts(messenger, type) unless type == "mattermost"

      errors = MATTERMOST_REQUIRED.filter_map do |key|
        next if messenger[key].is_a?(String) && !messenger[key].empty?

        "messenger.#{key} is required when messenger.type is mattermost"
      end
      errors.concat(validate_alerts(messenger, type))
    end

    def validate_alerts(messenger, type)
      return [] unless messenger.key?("alerts")

      return ["messenger.alerts is only supported when messenger.type is mattermost"] unless type == "mattermost"

      alerts = messenger["alerts"]
      unless alerts.is_a?(Hash)
        return ["messenger.alerts must be a Hash with exactly one of user or channel"]
      end

      destinations = %w[user channel].select { |key| alerts.key?(key) }
      unless destinations.size == 1
        return ["messenger.alerts must contain exactly one of user or channel"]
      end

      key = destinations.first
      return [] if alerts[key].is_a?(String) && !alerts[key].empty?

      ["messenger.alerts.#{key} must be a non-empty String"]
    end

    def validate_duplicate_names
      names = @runners.map { |r| r.is_a?(Hash) ? r["name"] : nil }.compact
      names.group_by(&:itself)
           .select { |_, v| v.size > 1 }
           .keys
           .map { |name| "duplicate runner name #{name.inspect} in #{@config_path}" }
    end

    def validate_runner(runner)
      errors = []
      name = runner.is_a?(Hash) ? runner["name"] : nil
      label = name.is_a?(String) && !name.empty? ? name : "<unnamed>"

      unless runner.is_a?(Hash)
        return ["runner must be a Hash (#{runner.inspect})"]
      end

      unless name.is_a?(String) && !name.empty?
        errors << "runner #{label.inspect}: name is required (String)"
      end

      unless runner["prompt_template"].is_a?(String) && !runner["prompt_template"].empty?
        errors << "runner #{label.inspect}: prompt_template is required"
      end

      if runner["prompt_template_path"] && !File.exist?(runner["prompt_template_path"])
        errors << "runner #{label.inspect}: prompt template file not found: #{runner['prompt_template_path']}"
      end

      unless VALID_BACKENDS.include?(runner["backend"])
        errors << "runner #{label.inspect}: backend must be one of #{VALID_BACKENDS.join(', ')} (got #{runner['backend'].inspect})"
      end

      # `agent` is present in every merged runner (RUNNER_DEFAULTS supplies it),
      # so the rule is about the value, not the key: nil means "pass no --agent
      # flag" and is legal, anything else must work as the flag's argument.
      agent = runner["agent"]
      unless agent.nil? || (agent.is_a?(String) && !agent.empty?)
        errors << "runner #{label.inspect}: agent must be a non-empty String or null (got #{agent.inspect})"
      end

      errors.concat(validate_claude(label, runner["claude"]))
      errors.concat(validate_trigger(label, runner["trigger"]))
      errors.concat(validate_documentation(runner["description"], runner["support"],
                                           prefix: "runner #{label.inspect}: "))
      errors
    end

    # Shared by the config level (no prefix) and the runner level. Both keys are
    # optional; an absent key is not an error, but a present one must carry real
    # text — a blank description is worse than none, since the console would
    # render an empty block where support expects an answer.
    def validate_documentation(description, support, prefix: "")
      errors = []

      unless description.nil? || (description.is_a?(String) && !description.strip.empty?)
        errors << "#{prefix}description must be a non-empty String (got #{description.inspect})"
      end

      return errors if support.nil?

      unless support.is_a?(Hash)
        return errors << "#{prefix}support must be a Hash with any of #{SUPPORT_KEYS.join(', ')}"
      end

      unknown = support.keys - SUPPORT_KEYS
      unless unknown.empty?
        errors << "#{prefix}support has unknown key(s) #{unknown.join(', ')} (known: #{SUPPORT_KEYS.join(', ')})"
      end

      SUPPORT_KEYS.each do |key|
        next unless support.key?(key)

        value = support[key]
        unless value.is_a?(String) && !value.strip.empty?
          errors << "#{prefix}support.#{key} must be a non-empty String (got #{value.inspect})"
        end
      end

      errors.concat(validate_runbook(support["runbook"], prefix))
    end

    def validate_runbook(runbook, prefix)
      return [] unless runbook.is_a?(String) && !runbook.strip.empty?

      uri = URI.parse(runbook.strip)
      return [] if RUNBOOK_SCHEMES.include?(uri.scheme) && !uri.host.to_s.empty?

      ["#{prefix}support.runbook must be an http(s) URL (got #{runbook.inspect})"]
    rescue URI::InvalidURIError
      ["#{prefix}support.runbook must be an http(s) URL (got #{runbook.inspect})"]
    end

    # The claude backend's optional per-backend block, mirroring `opencode:`.
    # Only `model` lives here; an absent block leaves the model choice to the
    # CLI. Unlike opencode.model this is checked at load, because it is
    # optional and a bad value is cheap to catch here.
    def validate_claude(runner_label, claude)
      return [] if claude.nil?

      unless claude.is_a?(Hash)
        return ["runner #{runner_label.inspect}: claude must be a Hash (got #{claude.inspect})"]
      end

      model = claude["model"]
      return [] if model.nil? || (model.is_a?(String) && !model.empty?)

      ["runner #{runner_label.inspect}: claude.model must be a non-empty String (got #{model.inspect})"]
    end

    def validate_trigger(runner_label, trigger)
      errors = []
      unless trigger.is_a?(Hash) && !trigger.empty?
        return ["runner #{runner_label.inspect}: trigger is required"]
      end

      type = trigger["type"]
      unless VALID_TRIGGER_TYPES.include?(type)
        return ["runner #{runner_label.inspect}: trigger.type must be one of #{VALID_TRIGGER_TYPES.join(', ')} (got #{type.inspect})"]
      end

      jitter = trigger["jitter"]
      unless jitter.is_a?(Numeric) && jitter >= 0
        errors << "runner #{runner_label.inspect}: trigger.jitter must be a non-negative number (got #{jitter.inspect})"
      end

      case type
      when "tracker"
        unless trigger["query"].is_a?(String) && !trigger["query"].empty?
          errors << "runner #{runner_label.inspect}: trigger.query is required (String)"
        end
        unless trigger["interval"].is_a?(Integer) && trigger["interval"] > 0
          errors << "runner #{runner_label.inspect}: trigger.interval must be a positive Integer"
        end
      when "file"
        %w[input_dir archive_dir failed_dir].each do |key|
          unless trigger[key].is_a?(String) && !trigger[key].empty?
            errors << "runner #{runner_label.inspect}: trigger.#{key} is required (String)"
          end
        end
        unless trigger["interval"].is_a?(Integer) && trigger["interval"] > 0
          errors << "runner #{runner_label.inspect}: trigger.interval must be a positive Integer"
        end
      when "mattermost"
        %w[base_url token team].each do |key|
          unless trigger[key].is_a?(String) && !trigger[key].empty?
            errors << "runner #{runner_label.inspect}: trigger.#{key} is required (String)"
          end
        end
        channels = trigger["channels"]
        direct_users = trigger["direct_users"]
        direct_users_valid = direct_users.is_a?(Array) && !direct_users.empty? &&
                             direct_users.all? { |user| user.is_a?(String) && !user.empty? }
        if trigger.key?("direct_users") && !direct_users_valid
          errors << "runner #{runner_label.inspect}: trigger.direct_users must be a non-empty Array of non-empty Strings"
        end
        channels_valid = channels.is_a?(Array) && channels.all? { |channel| channel.is_a?(String) && !channel.empty? }
        unless channels_valid && (!channels.empty? || direct_users_valid)
          errors << "runner #{runner_label.inspect}: trigger.channels must be an Array of non-empty Strings and cannot be empty without valid trigger.direct_users"
        end
        unless trigger["interval"].is_a?(Integer) && trigger["interval"] > 0
          errors << "runner #{runner_label.inspect}: trigger.interval must be a positive Integer"
        end
      end

      errors
    end

    def deep_merge(base, override)
      base.merge(override || {}) do |_key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(old_val, new_val)
        else
          new_val
        end
      end
    end
  end
end
