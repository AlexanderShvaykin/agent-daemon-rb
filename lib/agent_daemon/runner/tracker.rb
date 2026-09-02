# frozen_string_literal: true

require_relative "base"

module AgentDaemon
  module Runner
    class Tracker < Base
      def initialize(runner_config, message_dir, project_path, shutdown_flag, tracker_config, sinks: nil, cancel_flag: nil)
        super(runner_config, message_dir, project_path, shutdown_flag, sinks: sinks, cancel_flag: cancel_flag)
        @query = runner_config.fetch("trigger").fetch("query")
        @tracker = ::AgentDaemon::Tracker.new(tracker_config)
      end

      private

      def fetch_work_items
        @tracker.search_issues(@query)
      end

      def work_item_key(item)
        item["key"]
      end

      def render_prompt(item)
        variables = base_template_variables.merge("task_key" => item["key"])
        @prompt_template.render(variables)
      end
    end
  end
end
