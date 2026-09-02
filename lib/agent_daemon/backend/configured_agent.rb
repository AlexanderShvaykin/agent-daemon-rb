# frozen_string_literal: true

require_relative "base"

module AgentDaemon
  module Backend
    class ConfiguredAgent < Base
      private

      def build_command(prompt)
        config = @runner_config.fetch("fallback_agent")
        argv = [config.fetch("command"), *config.fetch("args"), prompt]

        "cd #{@project_path.shellescape} && #{argv.map(&:shellescape).join(' ')}"
      end
    end
  end
end
