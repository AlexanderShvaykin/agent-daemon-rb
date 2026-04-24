# frozen_string_literal: true

require_relative "base"

module AgentDaemon
  module Backend
    class OpenCode < Base
      private

      def build_command(prompt)
        model = @runner_config.dig("opencode", "model")
        raise ArgumentError, "Model not specified for opencode in runner #{@runner_config['name'].inspect}: opencode.model" if model.nil? || model.empty?

        agent = @runner_config.fetch("agent", "task-analyst")
        flags = combined_extra_flags

        cmd = "cd #{@project_path.shellescape}" \
              " && opencode run #{prompt.shellescape}" \
              " --agent #{agent.shellescape}" \
              " --model #{model.shellescape}" \
              " --dangerously-skip-permissions"
        cmd << " #{flags}" unless flags.empty?
        cmd
      end

      def combined_extra_flags
        general = extra_flags
        specific = @runner_config.dig("opencode", "extra_flags").to_s.strip
        [general, specific].reject(&:empty?).join(" ")
      end
    end
  end
end
