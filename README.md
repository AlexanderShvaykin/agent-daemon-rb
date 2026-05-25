# AgentDaemon

A Ruby daemon engine for orchestrating CLI AI agents. It runs one thread per configured runner, each with its own trigger (Yandex Tracker queries or file polling), backend (Claude Code or OpenCode), and prompt template. A dedicated Messenger thread delivers webhook notifications to Loop, Slack, or any compatible endpoint. Zero external gems -- stdlib only.

## Installation

Add to your Gemfile:

```ruby
gem "agent_daemon"
```

Or install directly:

```bash
gem install agent_daemon
```

## Quick Start

1. Create a `config.yml`:

```yaml
project_path: /path/to/your/agent/project
message_dir: to_message

tracker:
  token: YOUR_TRACKER_TOKEN
  org_id: "123456"

runners:
  - name: my-runner
    prompt_template: prompts/default.txt
    backend: claude
    trigger:
      type: tracker
      query: "Queue: MYQUEUE AND Status: Open"
      interval: 120

messenger:
  webhook_url: https://example.com/webhook
```

2. Create a prompt template (`prompts/default.txt`):

```
Analyze task {{task_key}}.
Write results to {{message_dir}}/{{task_key}}.yml
```

3. Run the daemon:

```bash
agent-daemon config.yml
```

Stop with `Ctrl+C` or `kill <pid>` -- graceful shutdown waits for current iterations to finish.

## Configuration Reference

| Key | Description |
|-----|-------------|
| `project_path` | Working directory where the agent CLI runs |
| `message_dir` | Directory for outgoing message YAML files (relative to `project_path`) |
| `tracker.token` | Yandex Tracker OAuth token |
| `tracker.org_id` | Yandex Tracker organization ID |
| `tracker.base_url` | API base URL (default: `https://api.tracker.yandex.net`) |
| `runners` | List of runner configurations (see below) |
| `messenger.webhook_url` | Webhook URL for notifications (optional; if omitted, the messenger thread is not started) |
| `messenger.interval` | Polling interval for outgoing messages in seconds (default: `30`) |
| `logging.level` | Log level: `debug`, `info`, `warn`, `error` (default: `info`) |
| `logging.file` | Log file path (default: stdout) |

### Runner Configuration

| Key | Description |
|-----|-------------|
| `name` | Unique runner name (required) |
| `prompt_template` | Path to prompt template file, relative to config directory (required) |
| `backend` | `claude` (default) or `opencode` |
| `agent` | Agent name passed to the CLI (default: `task-analyst`) |
| `timeout` | Backend execution timeout in seconds (default: `1200`) |
| `max_attempts` | Retries before giving up on a task (default: `3`) |
| `extra_flags` | Additional CLI flags passed to the backend |
| `output_dir` | Additional directory added to backend `--add-dir` |
| `trigger` | Trigger configuration (required, see below) |

## Triggers

### Tracker Trigger

Polls Yandex Tracker with a JQL query:

```yaml
trigger:
  type: tracker
  query: "Queue: DEV AND Status: Open"
  interval: 60  # seconds between polls
```

### File Trigger

Watches a directory for YAML files:

```yaml
trigger:
  type: file
  input_dir: incoming
  archive_dir: archive
  failed_dir: failed
  interval: 10
```

Files are moved to `archive_dir` on success or `failed_dir` after `max_attempts` exhausted.

## Backends

- **claude** -- Invokes Claude Code CLI (`claude`) with `--dangerously-skip-permissions`
- **opencode** -- Invokes OpenCode CLI (`opencode`) with the same flags

Both backends `cd` into `project_path` and pass `--add-dir` for `message_dir` and `output_dir`.

## Prompt Templates

Templates use `{{variable}}` substitution. Available variables:

| Variable | Availability | Description |
|----------|-------------|-------------|
| `{{task_key}}` | Tracker trigger | Current issue key (e.g., `PROJ-123`) |
| `{{input_file}}` | File trigger | Absolute path to the input YAML file |
| `{{message_dir}}` | All runners | Resolved message directory path |
| `{{output_dir}}` | When configured | Resolved output directory path |
| Any runner key | All runners | Custom keys from the runner config (e.g., `{{signature}}`) |

Undefined variables stay literal and emit a warning.

## Multi-Instance Deployment

Use a `systemd` template unit for running multiple instances:

```ini
# /etc/systemd/system/agent-daemon@.service
[Unit]
Description=AgentDaemon %i

[Service]
ExecStart=/usr/local/bin/agent-daemon /etc/agent-daemon/%i.yml
Restart=always

[Install]
WantedBy=multi-user.target
```

Enable instances: `systemctl enable --now agent-daemon@myteam.service`

For a full production setup, including server layout, manual installation of
the bundled template from `examples/deploy/agent-daemon@.service`, and update
flow, see [docs/deployment.md](docs/deployment.md).

## Development

```bash
bundle install
rake test
```

Run a single test:

```bash
ruby -Ilib -Itest test/test_config_defaults.rb
```

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Write tests for your changes
4. Ensure all tests pass (`rake test`)
5. Commit your changes
6. Open a pull request

## License

[MIT](LICENSE)
