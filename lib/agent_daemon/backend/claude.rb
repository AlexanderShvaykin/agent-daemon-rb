# frozen_string_literal: true

require_relative "base"

module AgentDaemon
  module Backend
    class Claude < Base
      private

      def build_command(prompt)
        flags = extra_flags
        agent = @runner_config.fetch("agent", "task-analyst")

        add_dir_flags = add_dir_paths.map { |p| "--add-dir #{p.shellescape}" }.join(" ")

        cmd = "cd #{@project_path.shellescape}" \
              " && claude -p #{prompt.shellescape}" \
              " --agent #{agent.shellescape}" \
              " #{add_dir_flags}" \
              " --dangerously-skip-permissions" \
              " --output-format text"
        cmd << " #{flags}" unless flags.empty?
        cmd
      end
    end
  end
end
