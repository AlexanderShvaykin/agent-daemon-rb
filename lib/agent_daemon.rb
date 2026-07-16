# frozen_string_literal: true

require_relative "agent_daemon/version"
require_relative "agent_daemon/config"
require_relative "agent_daemon/log"
require_relative "agent_daemon/tracker"
require_relative "agent_daemon/prompt_template"
require_relative "agent_daemon/sinks"
require_relative "agent_daemon/backend/base"
require_relative "agent_daemon/backend/claude"
require_relative "agent_daemon/backend/opencode"
require_relative "agent_daemon/transport/base"
require_relative "agent_daemon/transport/webhook"
require_relative "agent_daemon/transport/mattermost"
require_relative "agent_daemon/runner/base"
require_relative "agent_daemon/runner/tracker"
require_relative "agent_daemon/runner/file"
require_relative "agent_daemon/runner/mattermost"
require_relative "agent_daemon/mattermost/listener"
require_relative "agent_daemon/mattermost/reactor"
require_relative "agent_daemon/messenger"
require_relative "agent_daemon/daemon"

module AgentDaemon
end
