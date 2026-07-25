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
  spec.executables = ["agent-daemon", "agent-supervisor"]
  spec.require_paths = ["lib"]

  spec.add_dependency "eventmachine"
  spec.add_dependency "faye-websocket"

  # Supervisor console only (AD-5/AD-6): reachable exclusively from
  # lib/agent_daemon/supervisor/console/, never from `require "agent_daemon"`.
  # test/test_require_isolation.rb enforces that boundary.
  spec.add_dependency "oauth2", "~> 2.0"
  # Upper-bounded because the console embeds Puma through its internal API
  # (Puma::Server.new's positional args, add_tcp_listener, #run, puma/log_writer),
  # not through a documented embedding contract. A new major may move any of it.
  spec.add_dependency "puma", ">= 6", "< 9"
  spec.add_dependency "rack", "~> 3"

  spec.add_development_dependency "minitest"
end
