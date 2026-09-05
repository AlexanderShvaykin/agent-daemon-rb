# frozen_string_literal: true

require_relative "base"

module AgentDaemon
  module Backend
    # Runs OpenAI's Codex CLI non-interactively.
    #
    # `-s workspace-write` is not a detail: the agent's whole output is a
    # message YAML it writes into message_dir, and message_dir lives inside
    # project_path. Under the safer-sounding read-only sandbox the run would
    # finish successfully having written nothing — and a trigger that
    # acknowledges on success would then discard the work item. A default that
    # loses questions silently is worse than one that grants write access
    # inside the working tree, so this is stated here rather than left to a
    # flag nobody sets.
    class Codex < Base
      SANDBOX = "workspace-write"

      private

      def build_command(prompt)
        model = @runner_config.dig("codex", "model")
        flags = combined_extra_flags

        cmd = "cd #{@project_path.shellescape}" \
              " && codex exec"
        cmd << " --model #{model.shellescape}" if model.is_a?(String) && !model.empty?
        cmd << " --sandbox #{SANDBOX}"
        # The runner may write outside the working tree (an output_dir
        # elsewhere), and those directories have to be named explicitly.
        add_dir_paths.each { |path| cmd << " --add-dir #{path.shellescape}" }
        # Codex refuses to run outside a git repository unless told otherwise,
        # and project_path is frequently just a working directory.
        cmd << " --skip-git-repo-check"
        # Output is captured, not shown: escape codes would only make the log
        # unreadable.
        cmd << " --color never"
        cmd << " #{flags}" unless flags.empty?
        # The prompt goes last: `codex exec [OPTIONS] [PROMPT]`.
        cmd << " #{prompt.shellescape}"
        cmd
      end

      def combined_extra_flags
        general = extra_flags
        specific = @runner_config.dig("codex", "extra_flags").to_s.strip
        [general, specific].reject(&:empty?).join(" ")
      end
    end
  end
end
