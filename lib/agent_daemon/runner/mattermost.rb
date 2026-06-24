# frozen_string_literal: true

require "yaml"

require_relative "file"

module AgentDaemon
  module Runner
    # Consumes Mattermost mention work-items written by the listener into the
    # inbox. Reuses the file-trigger machinery wholesale (oldest-first poll,
    # attempt tracking, archive on success, move to failed on exhausted) and
    # only extends prompt rendering to expose the work-item fields.
    class Mattermost < File
      private

      def render_prompt(path)
        item = YAML.safe_load(::File.read(path)) || {}
        fields = item.slice("message", "channel_id", "root_id", "sender", "channel_name", "post_id")
        variables = base_template_variables
                    .merge("input_file" => ::File.expand_path(path))
                    .merge(fields)
        @prompt_template.render(variables)
      end
    end
  end
end
