# frozen_string_literal: true

require "yaml"
require "erb"
require "json"

require_relative "../config"
require_relative "runner_identity"

module AgentDaemon
  module Supervisor
    # Loads a supervisor config that enumerates existing per-workflow configs by
    # unique name. Its shape mirrors core AgentDaemon::Config exactly: ERB render
    # -> YAML.safe_load -> deep_merge over DEFAULTS -> eager collect-all
    # validate! (one ConfigError listing every problem).
    #
    # Each referenced config is parsed via AgentDaemon::Config, and every runner
    # is assigned a composite (workflow, runner) RunnerIdentity. Load fails fast
    # on duplicate workflow names, colliding work dirs, or a missing/invalid
    # referenced config.
    #
    # AD-5 isolation: this file is required only by bin/agent-supervisor (and the
    # supervisor tests), never by the core `require "agent_daemon"` graph. It
    # depends solely on core Config + Ruby stdlib.
    class Config
      DEFAULTS = {
        "workflows" => []
      }.freeze

      attr_reader :config_path, :config_dir, :workflows

      def initialize(path)
        @config_path = File.expand_path(path)
        @config_dir  = File.dirname(@config_path)
        raw = YAML.safe_load(render(File.read(path))) || {}
        @data = deep_merge(DEFAULTS, raw)
        @workflows = build_workflows(@data["workflows"])
        validate!
      end

      # Flat list of every loaded runner's composite identity.
      def runner_identities
        @workflows.flat_map { |w| w[:identities] || [] }
      end

      private

      # Render the config as an ERB template before YAML parsing, exposing
      # `secret` and `ENV`. Mirrors core Config#render — render-time failures
      # surface as ConfigError so the single-exception-type contract holds.
      def render(src)
        ERB.new(src).result(binding)
      rescue AgentDaemon::ConfigError
        raise
      rescue StandardError, SyntaxError => e
        raise AgentDaemon::ConfigError, "failed to render #{@config_path}: #{e.message}"
      end

      # Resolve a secret from the environment as a YAML-safe, quoted scalar.
      # Mirrors core Config#secret.
      def secret(key)
        ENV.fetch(key).to_json
      rescue KeyError
        raise AgentDaemon::ConfigError, "secret #{key} is not set in environment"
      end

      def build_workflows(entries)
        return [] unless entries.is_a?(Array)

        entries.map { |entry| build_workflow(entry) }
      end

      # Load one workflow entry. A load failure (invalid config OR missing file)
      # is captured as :load_error so validate! reports it as a collected
      # problem (AC4) rather than letting a raw Errno::ENOENT / ConfigError
      # escape here. Successful entries expose { name:, config:, identities: }.
      def build_workflow(entry)
        unless entry.is_a?(Hash)
          return { load_error: "workflow entry must be a mapping with 'name' and 'config' (got #{entry.inspect})" }
        end

        name = entry["name"]
        config_ref = entry["config"]

        # A blank/non-String name yields a degenerate identity and evades both
        # duplicate-name and collision detection (nil names get compacted away),
        # so require it up front — mirroring core's runner-name guard (AC1/AC2).
        unless name.is_a?(String) && !name.empty?
          return { load_error: "workflow name is required (String) (entry: #{entry.inspect}) in #{@config_path}" }
        end

        # RunnerIdentity::DELIMITER is what #thread_key/#log_tag join on;
        # permitting it in a workflow name would let distinct identities collide.
        # The delimiter is owned by RunnerIdentity (single source of truth).
        if name.include?(RunnerIdentity::DELIMITER)
          return { name: name, load_error: "workflow name #{name.inspect} must not contain '#{RunnerIdentity::DELIMITER}' in #{@config_path}" }
        end

        unless config_ref.is_a?(String) && !config_ref.empty?
          return { name: name, load_error: "workflow #{name.inspect}: config path is required (String) in #{@config_path}" }
        end

        # Referenced config path resolves relative to the supervisor config's
        # directory (the same rule core uses for prompt_template). Any load
        # failure — ConfigError, missing file (SystemCallError), malformed YAML
        # (Psych::SyntaxError), or non-Hash top-level (TypeError) — is wrapped as
        # a collected problem naming the entry (AC4).
        begin
          # expand_path sits inside the rescue too: an unexpandable ref (e.g.
          # "~nosuchuser/x.yml") raises ArgumentError and must stay per-entry.
          config = AgentDaemon::Config.new(File.expand_path(config_ref, @config_dir))
        rescue StandardError => e
          return { name: name, load_error: "workflow #{name.inspect} (#{config_ref}): #{e.message} in #{@config_path}" }
        end

        {
          name: name,
          config: config,
          identities: config.runners.map { |r| RunnerIdentity.new(workflow: name, runner: r["name"]) }
        }
      end

      def validate!
        errors = []

        raw = @data["workflows"]
        if raw.nil?
          errors << "workflows is missing in #{@config_path}"
        elsif !raw.is_a?(Array)
          errors << "workflows must be a list in #{@config_path}"
        elsif raw.empty?
          errors << "workflows is empty in #{@config_path}"
        else
          errors.concat(load_errors)
          errors.concat(validate_duplicate_names)
          errors.concat(validate_dir_collisions)
        end

        raise AgentDaemon::ConfigError, errors.join("\n") unless errors.empty?
      end

      # AC4 — per-entry load failures collected during build_workflows.
      def load_errors
        @workflows.filter_map { |w| w[:load_error] }
      end

      # AC2 — duplicate workflow names (mirror core validate_duplicate_names).
      def validate_duplicate_names
        names = @workflows.map { |w| w[:name] }.compact
        names.group_by(&:itself)
             .select { |_, v| v.size > 1 }
             .keys
             .map { |name| "duplicate workflow name #{name.inspect} in #{@config_path}" }
      end

      # AC3 — two workflows must not claim the same message_dir, output_dir, or
      # trigger work-dir. A shared project_path is never a key here, so it is
      # never flagged. Only successfully-loaded workflows contribute paths. A
      # referenced config that omits project_path loads in core but makes
      # message_dir raise KeyError; convert that to a collected problem here so
      # the single-exception-type contract holds.
      def validate_dir_collisions
        claims = Hash.new { |h, k| h[k] = [] }
        errors = []

        @workflows.each do |w|
          config = w[:config]
          next unless config

          begin
            dirs = claimed_dirs(config)
          rescue KeyError => e
            # Referenced config omits project_path (core does not validate it);
            # #message_dir then fetches a missing key.
            errors << "workflow #{w[:name].inspect}: referenced config is missing #{e.key.inspect} in #{@config_path}"
            next
          rescue StandardError => e
            # Any other work-dir resolution failure — e.g. a non-String
            # project_path/message_dir making File.expand_path raise TypeError.
            # Convert it so the single-ConfigError contract holds (mirrors the
            # broadened rescue around AgentDaemon::Config.new in build_workflow).
            errors << "workflow #{w[:name].inspect}: cannot resolve work dirs from referenced config: #{e.message} in #{@config_path}"
            next
          end

          dirs.each { |path| claims[path] << w[:name] }
        end

        errors.concat(
          claims.filter_map do |path, workflows|
            owners = workflows.uniq
            next if owners.size < 2

            "work-dir collision: #{path} is claimed by workflows #{owners.map(&:inspect).join(', ')} in #{@config_path}"
          end
        )
      end

      # Every absolute work dir a workflow's config claims: its message_dir, each
      # runner's output_dir (when set), and each file/mattermost runner's three
      # trigger dirs. #message_dir raises KeyError when the referenced config
      # omits project_path (core does not validate it) — the caller converts it.
      def claimed_dirs(config)
        dirs = [config.message_dir]

        config.runners.each do |runner|
          output_dir = runner["output_dir"]
          dirs << output_dir if output_dir.is_a?(String) && !output_dir.empty?

          # Core resolves trigger work dirs to absolute paths only for
          # file/mattermost triggers (resolve_trigger_dirs); a tracker trigger
          # has no work dirs, so any stray dir keys on it are unresolved
          # relative strings and must not enter the (absolute-path) claims map.
          trigger = runner["trigger"]
          next unless trigger.is_a?(Hash) && %w[file mattermost].include?(trigger["type"])

          %w[input_dir archive_dir failed_dir].each do |key|
            path = trigger[key]
            dirs << path if path.is_a?(String) && !path.empty?
          end
        end

        dirs
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
end
