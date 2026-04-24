# frozen_string_literal: true

require_relative "lib/agent_daemon/version"

Gem::Specification.new do |spec|
  spec.name = "agent_daemon"
  spec.version = AgentDaemon::VERSION
  spec.authors = ["Alexander Shvaykin"]
  spec.email = ["skiline.alex@gmail.com"]

  spec.summary = "Ruby daemon engine for orchestrating CLI AI agents"
  spec.description = "A Ruby daemon engine for orchestrating CLI AI agents with triggers, " \
                     "prompt templates, and webhook notifications. Supports Yandex Tracker " \
                     "and file-based triggers, Claude and OpenCode backends, and Loop/Slack " \
                     "compatible webhook messaging."
  spec.homepage = "https://github.com/AlexanderShvaykin/agent-daemon-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/AlexanderShvaykin/agent-daemon-rb",
    "changelog_uri" => "https://github.com/AlexanderShvaykin/agent-daemon-rb/blob/master/CHANGELOG.md"
  }

  spec.files = Dir["lib/**/*.rb", "bin/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.bindir = "bin"
  spec.executables = ["agent-daemon"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest"
end
