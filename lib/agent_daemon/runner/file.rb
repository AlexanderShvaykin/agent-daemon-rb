# frozen_string_literal: true

require "fileutils"

require_relative "base"

module AgentDaemon
  module Runner
    class File < Base
      def initialize(runner_config, message_dir, project_path, shutdown_flag, sinks: nil, cancel_flag: nil)
        super
        trigger = runner_config.fetch("trigger")
        @input_dir   = trigger.fetch("input_dir")
        @archive_dir = trigger.fetch("archive_dir")
        @failed_dir  = trigger.fetch("failed_dir")

        FileUtils.mkdir_p(@input_dir)
        FileUtils.mkdir_p(@archive_dir)
        FileUtils.mkdir_p(@failed_dir)
      end

      private

      def fetch_work_items
        path = Dir.glob(::File.join(@input_dir, "*.yml")).sort.first
        path ? [path] : []
      end

      def work_item_key(path)
        ::File.basename(path)
      end

      def render_prompt(path)
        variables = base_template_variables.merge("input_file" => ::File.expand_path(path))
        @prompt_template.render(variables)
      end

      def after_success(path)
        FileUtils.mv(path, ::File.join(@archive_dir, ::File.basename(path)))
      end

      def after_failure(path)
        key = work_item_key(path)
        return unless @attempts[key] >= @max_attempts

        move_to_failed(path)
        @attempts.delete(key)
      end

      def after_exhausted(path)
        move_to_failed(path)
        @attempts.delete(work_item_key(path))
      end

      def move_to_failed(path)
        return unless ::File.exist?(path)

        FileUtils.mv(path, ::File.join(@failed_dir, ::File.basename(path)))
        Log.error("[#{log_tag}] moved #{::File.basename(path)} to failed_dir after exhausted attempts")
      end
    end
  end
end
