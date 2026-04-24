# frozen_string_literal: true

require "yaml"

module AgentDaemon
  class ConfigError < StandardError; end

  class Config
    DEFAULTS = {
      "message_dir" => "to_message",
      "runners" => [],
      "messenger" => {
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

    TRACKER_TRIGGER_DEFAULTS = { "interval" => 60 }.freeze
    FILE_TRIGGER_DEFAULTS    = { "interval" => 10 }.freeze

    VALID_TRIGGER_TYPES = %w[tracker file].freeze
    VALID_BACKENDS      = %w[claude opencode].freeze

    attr_reader :data, :config_dir, :config_path

    def initialize(path)
      @config_path = File.expand_path(path)
      @config_dir  = File.dirname(@config_path)
      raw = YAML.safe_load_file(path) || {}
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

    private

    def build_runners(raw_runners)
      return [] unless raw_runners.is_a?(Array)

      raw_runners.map { |r| build_runner(r) }
    end

    def build_runner(raw)
      return raw unless raw.is_a?(Hash)

      runner = deep_merge(RUNNER_DEFAULTS, raw)
      runner["trigger"] = build_trigger(runner["trigger"])

      if runner["output_dir"].is_a?(String) && !runner["output_dir"].empty?
        runner["output_dir"] = File.expand_path(runner["output_dir"], @data["project_path"] || "")
      end

      if runner["prompt_template"].is_a?(String) && !runner["prompt_template"].empty?
        runner["prompt_template_path"] = File.expand_path(runner["prompt_template"], @config_dir)
      end

      runner
    end

    def build_trigger(raw_trigger)
      return {} unless raw_trigger.is_a?(Hash)

      case raw_trigger["type"]
      when "tracker"
        deep_merge(TRACKER_TRIGGER_DEFAULTS, raw_trigger)
      when "file"
        trigger = deep_merge(FILE_TRIGGER_DEFAULTS, raw_trigger)
        %w[input_dir archive_dir failed_dir].each do |key|
          if trigger[key].is_a?(String) && !trigger[key].empty?
            trigger[key] = File.expand_path(trigger[key], @data["project_path"] || "")
          end
        end
        trigger
      else
        raw_trigger
      end
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

      raise ConfigError, errors.join("\n") unless errors.empty?
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

      errors.concat(validate_trigger(label, runner["trigger"]))
      errors
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
