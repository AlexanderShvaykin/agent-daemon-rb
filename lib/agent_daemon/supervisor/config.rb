# frozen_string_literal: true

require "yaml"
require "erb"
require "json"
require "uri"

require_relative "../config"
require_relative "runner_identity"
require_relative "event_bus"

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
        "workflows" => [],
        # Records retained by the master's single EventBus. Operator-tunable
        # because events_dropped_total (AD-4) is a scrapeable Epic 6 metric —
        # an operator watching it climb needs a remedy other than editing a
        # constant and redeploying the fleet.
        "event_bus_capacity" => EventBus::DEFAULT_CAPACITY,
        # Bytes retained per run by the master's OutputBuffers store (Story
        # 3.4). Top-level, not under `console:` — the buffer exists whether or
        # not a console is configured (Epic 5's history writer and Epic 6's
        # counters both subscribe to the same pipeline).
        "output_buffer_bytes" => 262_144,
        # Optional web console (AD-6). nil ⇒ disabled and never validated, so a
        # supervisor config written before the console existed keeps loading
        # unchanged (Story 2.2 AC8).
        "console" => nil
      }.freeze

      # Server-side console defaults, merged UNDER a present `console:` block.
      # The auth sub-keys have no defaults on purpose — every one of them is
      # required, and a defaulted credential would be a fail-open path.
      CONSOLE_DEFAULTS = {
        # Loopback by default: the console is expected to sit behind a TLS
        # terminator, and a config that forgets `bind` must not become
        # world-reachable.
        "bind" => "127.0.0.1",
        "port" => 9292,
        # Must exceed the peak number of concurrent SSE streams (AD-6): each
        # live stream parks one Puma thread for its whole lifetime.
        "max_threads" => 16,
        "session_ttl" => 28_800, # 8 hours (FR16)
        "secure_cookies" => true
      }.freeze

      # The whole role vocabulary (FR15). Roles are parsed and validated here
      # but are NOT action-gating in v1 — every allowed authenticated user may
      # view and (from Epic 4) restart.
      KNOWN_ROLES = %w[viewer operator].freeze

      # A "positive integer" port still fails at bind time; the range is what
      # actually makes a typo a load-time error rather than a silently
      # console-less supervisor.
      PORT_RANGE = (1..65_535).freeze

      # Bounds output_buffer_bytes: the floor keeps a run's window usefully
      # small on a memory-constrained host, the ceiling caps the per-entity
      # memory ceiling (capacity_bytes × rostered entities, NFR7) an operator
      # can reach with a single typo.
      OUTPUT_BUFFER_BYTES_RANGE = (16_384..4_194_304).freeze

      attr_reader :config_path, :config_dir, :workflows, :event_bus_capacity, :output_buffer_bytes, :console

      def initialize(path)
        @config_path = File.expand_path(path)
        @config_dir  = File.dirname(@config_path)
        @resolved_secrets = []
        raw = YAML.safe_load(render(File.read(path))) || {}
        @data = deep_merge(DEFAULTS, raw)
        @workflows = build_workflows(@data["workflows"])
        @event_bus_capacity = @data["event_bus_capacity"]
        @output_buffer_bytes = @data["output_buffer_bytes"]
        @console = build_console(@data["console"])
        validate!
      end

      # Flat list of every loaded runner's composite identity.
      def runner_identities
        @workflows.flat_map { |w| w[:identities] || [] }
      end

      # Mirrors AgentDaemon::Config#resolved_secrets — the raw values this
      # config's `secret()` calls resolved, as a frozen copy. Never log,
      # inspect, render, or serialize these (the same rule `app_secret`
      # already carries in validate_console_auth).
      def resolved_secrets
        (@resolved_secrets || []).dup.freeze
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
      # Mirrors core Config#secret, including the raw-value recording (DR1).
      def secret(key)
        value = ENV.fetch(key)
        (@resolved_secrets ||= []) << value
        value.to_json
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

        # RunnerIdentity::DELIMITER also joins the runner half of
        # #thread_key/#log_tag; a runner name carrying it would make composite
        # keys ambiguous to parse back apart. Runner names are core's concern,
        # but the delimiter itself belongs to the supervisor (Story 1.1 review
        # deferral), so the guard lives here alongside the workflow-name one.
        colliding = config.runners.select { |r| r["name"].to_s.include?(RunnerIdentity::DELIMITER) }
        unless colliding.empty?
          bad_names = colliding.map { |r| r["name"].inspect }.join(", ")
          return { name: name, load_error: "workflow #{name.inspect}: runner name(s) #{bad_names} must not contain '#{RunnerIdentity::DELIMITER}' in #{config.config_path}" }
        end

        {
          name: name,
          config: config,
          identities: config.runners.map { |r| RunnerIdentity.new(workflow: name, runner: r["name"]) }
        }
      end

      # A present `console:` block gets CONSOLE_DEFAULTS merged underneath it;
      # an absent one stays nil (console disabled). A present-but-not-a-mapping
      # value is passed through untouched so validate_console can report it.
      def build_console(raw)
        return nil if raw.nil?
        return raw unless raw.is_a?(Hash)

        deep_merge(CONSOLE_DEFAULTS, raw)
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

        unless @event_bus_capacity.is_a?(Integer) && @event_bus_capacity.positive?
          errors << "event_bus_capacity must be a positive integer (got #{@event_bus_capacity.inspect}) in #{@config_path}"
        end

        unless positive_integer?(@output_buffer_bytes) && OUTPUT_BUFFER_BYTES_RANGE.cover?(@output_buffer_bytes)
          errors << "output_buffer_bytes must be an integer in #{OUTPUT_BUFFER_BYTES_RANGE} " \
                     "(got #{@output_buffer_bytes.inspect}) in #{@config_path}"
        end

        errors.concat(validate_console)

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

      # AC6 — the console block. Collects every problem like its siblings and
      # never raises early. Returns [] when the console is disabled: an absent
      # block must impose zero new requirements on an existing config (AC8).
      def validate_console
        return [] if @console.nil?
        return ["console must be a mapping in #{@config_path}"] unless @console.is_a?(Hash)

        validate_console_server + validate_console_auth(@console["auth"])
      end

      def validate_console_server
        base_url = @console["base_url"]
        errors = validate_base_url(base_url)

        errors << "console.bind is required (String) in #{@config_path}" unless non_empty_string?(@console["bind"])

        %w[max_threads session_ttl].each do |key|
          value = @console[key]
          next if positive_integer?(value)

          errors << "console.#{key} must be a positive integer (got #{value.inspect}) in #{@config_path}"
        end

        port = @console["port"]
        unless positive_integer?(port) && PORT_RANGE.cover?(port)
          errors << "console.port must be a port number in #{PORT_RANGE} (got #{port.inspect}) in #{@config_path}"
        end

        errors.concat(validate_secure_cookies(base_url))
      end

      # base_url is not merely a string: Server builds the OAuth redirect_uri
      # with URI.join, which raises on a relative value. Validating it here
      # turns a missing "https://" from a console that silently never starts
      # (Master#start_console logs and carries on, by AC7 design) into the
      # eager ConfigError this file promises everywhere else.
      def validate_base_url(base_url)
        return ["console.base_url is required (String) in #{@config_path}"] unless non_empty_string?(base_url)
        return [] if http_url?(base_url)

        ["console.base_url must be an absolute http(s) URL (got #{base_url.inspect}) in #{@config_path}"]
      end

      # The two keys are coupled, and the failure mode of getting them wrong is
      # invisible: over plain HTTP a browser silently discards a Secure cookie,
      # so every request arrives cookieless — indistinguishable server-side from
      # a first visit — and login loops forever with nothing in the log.
      def validate_secure_cookies(base_url)
        secure = @console["secure_cookies"]
        unless [true, false].include?(secure)
          return ["console.secure_cookies must be true or false (got #{secure.inspect}) in #{@config_path}"]
        end

        return [] unless secure && url_scheme(base_url) == "http"

        ["console.secure_cookies is true but console.base_url is plain http, so no session cookie can " \
         "ever be stored and login cannot complete — use https, or set secure_cookies: false " \
         "in #{@config_path}"]
      end

      # Credentials are reported by NAME only — an error message quoting a bad
      # app_secret would leak it into logs and operator terminals, which the
      # secrets rule forbids just as strictly as a log line would.
      def validate_console_auth(auth)
        return ["console.auth is required (mapping) in #{@config_path}"] unless auth.is_a?(Hash)

        errors = []

        %w[gitlab_host app_id app_secret].each do |key|
          errors << "console.auth.#{key} is required (String) in #{@config_path}" unless non_empty_string?(auth[key])
        end

        host = auth["gitlab_host"]
        if non_empty_string?(host) && !http_url?(host)
          errors << "console.auth.gitlab_host must be an http(s) URL (got #{host.inspect}) in #{@config_path}"
        end

        groups = auth["allowed_groups"]
        errors.concat(validate_allowed_groups(groups))
        errors.concat(validate_roles(auth["roles"], groups))

        errors
      end

      def validate_allowed_groups(groups)
        return ["console.auth.allowed_groups must be a list in #{@config_path}"] unless groups.is_a?(Array)
        return ["console.auth.allowed_groups is empty in #{@config_path}"] if groups.empty?

        bad = groups.reject { |g| non_empty_string?(g) }
        return [] if bad.empty?

        ["console.auth.allowed_groups entries must be non-empty strings (got #{bad.map(&:inspect).join(', ')}) in #{@config_path}"]
      end

      # `roles` is optional (FR15). When present it must name only known roles
      # and only groups the config actually allows: a role listing a group that
      # is not in allowed_groups can never match anyone, and a silently dead
      # role is precisely the kind of config bug this repo fails fast on.
      def validate_roles(roles, groups)
        return [] if roles.nil?
        return ["console.auth.roles must be a mapping in #{@config_path}"] unless roles.is_a?(Hash)

        # Only cross-check against a well-formed allowed_groups; otherwise the
        # dead-group errors below would just restate the allowed_groups error.
        known_groups = groups.is_a?(Array) && groups.all? { |g| non_empty_string?(g) } ? groups : nil

        roles.flat_map do |name, value|
          validate_role(name, value, known_groups)
        end
      end

      def validate_role(name, value, known_groups)
        unless KNOWN_ROLES.include?(name)
          return ["unknown role #{name.inspect} (expected one of: #{KNOWN_ROLES.join(', ')}) in #{@config_path}"]
        end

        unless value.is_a?(Array) && !value.empty? && value.all? { |g| non_empty_string?(g) }
          return ["console.auth.roles.#{name} must be a list of non-empty strings (got #{value.inspect}) in #{@config_path}"]
        end

        return [] if known_groups.nil?

        (value - known_groups).map do |dead|
          "console.auth.roles.#{name} references group #{dead.inspect} which is not in allowed_groups in #{@config_path}"
        end
      end

      def non_empty_string?(value)
        value.is_a?(String) && !value.empty?
      end

      # Rejects `true`, which is an Integer only to Ruby's duck-typing eye.
      def positive_integer?(value)
        value.is_a?(Integer) && value.positive?
      end

      # A host is as required as the scheme: URI.parse("https://") reports
      # scheme "https" with an empty host, which passes a scheme-only check and
      # then produces an unusable client at runtime.
      def http_url?(value)
        uri = URI.parse(value)
        %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end

      def url_scheme(value)
        return nil unless non_empty_string?(value)

        URI.parse(value).scheme
      rescue URI::InvalidURIError
        nil
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
