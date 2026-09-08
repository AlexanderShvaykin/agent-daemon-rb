# frozen_string_literal: true

require_relative "base"

module AgentDaemon
  module Backend
    class Claude < Base
      private

      def build_command(prompt, images: [])
        flags = extra_flags
        # `agent: null` suppresses the flag entirely; the default from
        # RUNNER_DEFAULTS still applies when the operator writes nothing.
        agent = @runner_config.fetch("agent", "task-analyst")
        model = @runner_config.dig("claude", "model")

        add_dir_flags = add_dir_paths.map { |p| "--add-dir #{p.shellescape}" }.join(" ")

        cmd = "cd #{@project_path.shellescape}" \
              " && claude -p #{prompt.shellescape}"
        cmd << " --agent #{agent.shellescape}" if agent.is_a?(String) && !agent.empty?
        cmd << " --model #{model.shellescape}" if model.is_a?(String) && !model.empty?
        cmd << " #{add_dir_flags}" \
               " --dangerously-skip-permissions" \
               " --output-format text"
        cmd << " #{flags}" unless flags.empty?
        cmd
      end
    end
  end
end
