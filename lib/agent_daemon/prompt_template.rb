# frozen_string_literal: true

module AgentDaemon
  class PromptTemplate
    def initialize(path)
      @path = path
      unless File.exist?(@path)
        raise "Prompt template file not found: #{@path}"
      end
      @template = File.read(@path)
    end

    def render(variables)
      @template.gsub(/\{\{(\w+)\}\}/) do
        key = $1
        if variables.key?(key)
          variables[key].to_s
        else
          Log.warn("[PromptTemplate] Undefined variable: {{#{key}}} in #{@path}")
          "{{#{key}}}"
        end
      end
    end
  end
end
