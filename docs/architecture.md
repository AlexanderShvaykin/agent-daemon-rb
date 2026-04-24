# Architecture

## Overview

AgentDaemon is a Ruby daemon that runs one thread per configured runner plus a
dedicated Messenger thread. Threads communicate exclusively through the
filesystem (YAML files in a shared directory). The daemon has zero external gem
dependencies — it uses only the Ruby standard library.

## Component Map

```
┌──────────────────────────────────────────────────────┐
│                     Daemon                           │
│  ┌────────────┐  ┌────────────┐  ┌───────────────┐  │
│  │ Runner A   │  │ Runner B   │  │  Messenger    │  │
│  │ (Tracker)  │  │ (File)     │  │               │  │
│  │  ↕ Backend │  │  ↕ Backend │  │  Polls YAML → │──│──→ Webhook
│  │  ↕ Prompt  │  │  ↕ Prompt  │  │  in msg_dir   │  │
│  └────────────┘  └────────────┘  └───────────────┘  │
│          ↓               ↓                ↑          │
│          └───── message_dir (YAML) ───────┘          │
│                                                      │
│  ShutdownFlag (shared, mutex-free boolean)           │
└──────────────────────────────────────────────────────┘
```

## Threading Model

`Daemon` starts one `Thread` per runner entry in the config, plus one for
`Messenger`. All threads share a single `ShutdownFlag` instance — a lightweight
object whose `@value` boolean flips from `false` to `true` on shutdown. Because
MRI's GIL makes boolean reads/writes atomic, no mutex is needed.

The `Daemon#monitor_threads` loop checks every second whether any thread has
crashed (marked via `Thread.current[:crashed]`). A crashed thread is restarted
after a 60-second delay (`RESTART_DELAY`).

On `SIGTERM` or `SIGINT`, the flag is set. Each thread's main loop checks the
flag on every iteration and exits cleanly. `Daemon` then joins all threads with
a 30-second timeout per thread.

## Runners

### Runner::Base

The abstract base class that owns the shared loop: poll for work items, process
each one through a Backend, track per-item attempt counts, and escalate on
consecutive trigger failures.

Key extension points (subclasses must implement):

| Method             | Purpose                                |
|--------------------|----------------------------------------|
| `fetch_work_items` | Return an array of work items          |
| `work_item_key`    | Unique string key for attempt tracking |
| `render_prompt`    | Build the prompt string for the agent  |

Optional hooks: `after_success`, `after_failure`, `after_killed`,
`after_exhausted`.

### Runner::Tracker

Polls Yandex Tracker via `POST /v2/issues/_search` with a raw JQL `query`
string. Each returned issue becomes a work item keyed by its issue key.

### Runner::File

Polls `input_dir` for `*.yml` files. On success the file moves to
`archive_dir`; after exhausting `max_attempts` it moves to `failed_dir`.

## Backends

`Backend.for(runner_config, ...)` is a factory that returns the correct
subclass based on the `backend` key (`"claude"` or `"opencode"`).

### Backend::Base

Runs the agent CLI via `Open3.popen3` with `pgroup: true` (own process group).
A select-based loop drains stdout/stderr while checking the deadline and the
shutdown flag every 0.5 seconds. Returns a `Result` struct with one of four
`reason` values:

| Reason     | Meaning                                    |
|------------|--------------------------------------------|
| `:ok`      | Process exited successfully (exit code 0)  |
| `:failed`  | Process exited with a non-zero exit code   |
| `:timeout` | Exceeded the runner's `timeout` setting    |
| `:killed`  | Daemon is shutting down; process was killed |

On timeout or shutdown, the entire process group receives `SIGTERM`, then
`SIGKILL` after a 2-second grace period.

### Backend::Claude

Builds: `cd <project_path> && claude -p <prompt> --agent <agent> --allowedTools '*' --add-dir <dirs> --dangerously-skip-permissions --output-format text`

### Backend::OpenCode

Builds: `cd <project_path> && opencode run <prompt> --agent <agent> --model <model> --dangerously-skip-permissions`

Requires `opencode.model` in the runner config.

## Messenger

Polls `message_dir` for `*.yml` files every `messenger.interval` seconds. Each
file must contain at least a `message` key. The Messenger POSTs
`{"text": "<message>"}` to the configured `webhook_url`, then moves the file to
a `sent/` subdirectory.

Three consecutive send failures log a critical warning but do not escalate
further (there is no meta-notification path for the notifier itself).

## Prompt Templates

`PromptTemplate` loads a text file and substitutes `{{variable}}` placeholders
at render time. Available variables:

- **All keys** from the runner config entry (e.g. `{{signature}}`,
  `{{status_backlog}}`, `{{name}}`).
- `{{message_dir}}` — absolute path to the message directory.
- `{{output_dir}}` — if set on the runner.
- **Trigger-specific runtime vars**:
  - Tracker: `{{task_key}}` (the issue key).
  - File: `{{input_file}}` (absolute path to the YAML work item).

Undefined variables remain literal and produce a log warning.

## Error Handling and Escalation

Each runner tracks consecutive trigger failures (e.g. Tracker API errors, file
glob I/O errors). After `MAX_CONSECUTIVE_ERRORS` (3) consecutive failures, the
runner writes an error YAML file to `message_dir` with
`task_key: "SYSTEM:<runner-name>"`, which the Messenger picks up and sends as a
notification. The counter then resets.

Per-item failures use a separate attempt counter. After `max_attempts` (default
3) failed backend invocations for the same work item, the item is skipped and
`after_exhausted` is called.

## Configuration

YAML-based, loaded by `AgentDaemon::Config`. See `examples/config.yml` for a
fully commented example.

### Path Resolution

| Path                                          | Resolved relative to |
|-----------------------------------------------|----------------------|
| `message_dir`, `output_dir`                   | `project_path`       |
| `trigger.input_dir`, `archive_dir`, `failed_dir` | `project_path`   |
| `prompt_template`                             | Config file's directory |

Absolute paths are used verbatim.

### Validation

Config loading fails immediately with descriptive errors when:

- `runners` is missing, not a list, or empty.
- Runner names are duplicated.
- A runner is missing `name`, `prompt_template`, or `trigger`.
- `trigger.type` is not `tracker` or `file`.
- Trigger-specific required keys are missing.
- A prompt template file does not exist on disk.

## Deployment

The gem includes a systemd template unit at `examples/deploy/agent-daemon@.service`.
Each department or team gets its own instance:

```
systemctl start agent-daemon@sales
systemctl start agent-daemon@support
```

The `%i` specifier maps to a config file:
`<install_dir>/configs_decrypted/%i.yml`. Configs with secrets are typically
encrypted with SOPS and decrypted at deploy time.
