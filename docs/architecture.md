# Architecture

## Overview

AgentDaemon is a Ruby daemon that runs one thread per configured runner plus a
dedicated Messenger thread. Threads communicate exclusively through the
filesystem (YAML files in a shared directory). The daemon is stdlib-only with
two exceptions: `eventmachine` and `faye-websocket`. Those two are runtime
dependencies used *only* by the `mattermost` trigger, which needs a WebSocket
client to receive @-mentions; rather than hand-roll RFC 6455 over a raw socket,
that one trigger leans on faye-websocket running inside an EventMachine reactor.
Everything else — tracker/file triggers, backends, the Messenger and its
transports — stays on the standard library alone.

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
`Messenger`. When at least one `mattermost` runner exists it also starts a single
shared `Mattermost::Reactor` thread (`:mattermost_reactor`) — one for *all*
mattermost runners, because EventMachine's reactor is a process singleton (see
[Runner::Mattermost](#runnermattermost)). All threads share a single
`ShutdownFlag` instance — a lightweight object whose `@value` boolean flips from
`false` to `true` on shutdown. Because MRI's GIL makes boolean reads/writes
atomic, no mutex is needed.

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

### Runner::Mattermost

A `mattermost` runner turns Mattermost @-mentions into agent runs and posts the
answer back as a threaded reply. It is the only **push**-driven trigger, so it
is split across two cooperating pieces plus the shared reactor:

- **`Mattermost::Listener`** — a per-runner WebSocket handler. It does *not* own
  a thread: the reactor creates its faye-websocket client and drives the
  callbacks. Before the reactor loop starts, `#prepare` resolves the bot id once
  with a blocking `GET /api/v4/users/me` (so the reactor thread never blocks on
  IO inside the loop). It then connects, sends an `authentication_challenge`,
  and for each incoming `posted` event applies three filters — not the bot
  itself, channel in the runner's `channels` allowlist, and the bot id present
  in the event's `mentions` — before de-duplicating by post id (checked across
  the inbox, done, and failed dirs). A qualifying mention is written as a
  `<post_id>.yml` work-item into the inbox, carrying `message`, `channel_id`,
  `root_id` (the post's thread root, falling back to its own id for a top-level
  post), `sender`, `channel_name`, `post_id`, and `created_at`. On socket close
  it reconnects with capped exponential backoff (1s → 30s); the backoff resets
  only on the server's `hello` event (auth confirmed), so a bad token — which
  still opens the socket — keeps backing off instead of hot-looping.

- **`Mattermost::Reactor`** — the single shared EventMachine reactor thread that
  hosts *every* listener. EventMachine's reactor is a process singleton
  (`EM.run` runs once per process), so the daemon registers exactly one reactor
  (`:mattermost_reactor`), a peer to the Messenger, regardless of how many
  mattermost runners are configured. It resolves every listener's bot id up
  front; a listener that fails to prepare is logged and skipped without blocking
  the others. Inside `EM.run` each prepared listener opens its connection and a
  1-second periodic timer bridges the cooperative `ShutdownFlag` into `EM.stop`.
  The thread holds no un-recreatable state, so `monitor_threads` can restart it
  exactly like the runner/Messenger threads — it re-enters `EM.run` fresh and
  all clients reconnect.

- **`Runner::Mattermost < Runner::File`** — the consumer. It reuses the
  file-trigger machinery wholesale (oldest-first poll of the inbox, per-item
  attempt tracking, archive on success, move to failed on exhausted) and only
  overrides `render_prompt` to expose the work-item fields (`message`,
  `channel_id`, `root_id`, `sender`, `channel_name`, `post_id`) as `{{...}}`
  prompt variables alongside `input_file`.

The reply path is the ordinary Messenger contract: the prompt instructs the
agent to write a message YAML into `message_dir` with `channel_id` and `root_id`
copied from the work-item, which the `mattermost` transport posts verbatim into
the originating thread (see [Transports](#transports)).

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

Builds: `cd <project_path> && claude -p <prompt> --agent <agent> --add-dir <dirs> --dangerously-skip-permissions --output-format text`

### Backend::OpenCode

Builds: `cd <project_path> && opencode run <prompt> --agent <agent> --model <model> --dangerously-skip-permissions`

Requires `opencode.model` in the runner config.

## Messenger

Polls `message_dir` for `*.yml` files every `messenger.interval` seconds. Each
file must contain at least a `message` key. The Messenger delegates delivery to
a **transport** chosen by `messenger.type`, then moves the file to a `sent/`
subdirectory on success.

Three consecutive send failures log a critical warning but do not escalate
further (there is no meta-notification path for the notifier itself).

### Transports

`Transport.for(messenger_config)` (`transport/base.rb`) dispatches on
`messenger.type` — mirroring `Backend.for` — and returns a transport whose
`deliver(message_data)` raises on failure (the Messenger's consecutive-error
counting is unchanged). The `else` branch raises `ArgumentError` listing the
valid values. Adding a transport means a new `transport/<name>.rb` plus a
`when` clause.

- **`webhook`** (default, `transport/webhook.rb`): POSTs `{"text": "<message>"}`
  to `webhook_url`. Ignores any `channel`/`user` routing fields — a webhook is
  a single fixed destination — so the same message YAML is portable across
  transports.
- **`mattermost`** (`transport/mattermost.rb`): posts via the Loop/Mattermost
  bot REST API with one bot `token`. Resolves the bot id (`GET /users/me`),
  `team` id (`GET /teams/name/{team}`), channel ids
  (`GET /teams/{team_id}/channels/name/{name}`) and user ids /
  direct-channel ids (`GET /users/username/{name}` +
  `POST /channels/direct`), caching each resolution for the daemon's lifetime
  (ids are stable). Destination is chosen by precedence: a verbatim
  `channel_id` (skips all name resolution) → `user` (DM) → `channel` (named) →
  `default_channel`. An optional `root_id` threads the post as a reply. Posts
  via `POST /api/v4/posts` with `{channel_id, message}` (plus `root_id` when
  set). The `channel_id`/`root_id` pair is what the mattermost *trigger*
  consumer copies from a mention work-item so the agent's answer lands back in
  the originating thread. stdlib only (`Net::HTTP`, `json`, `uri`).

### Message routing

A message YAML may carry optional routing fields the agent fills in from the
context it already has:

- `channel_id: <id>` — post verbatim to that channel id (no name resolution).
  Combined with `root_id: <id>` it threads the reply. This is the pair the
  mattermost mention trigger surfaces, letting a replying agent answer in the
  exact channel and thread it was mentioned in.
- `channel: <name>` — post to that named channel (within the configured `team`).
- `user: <username>` — send a direct message to that user.
- none of the above — post to `messenger.default_channel`. `SYSTEM:<runner>`
  error messages always fall here, since the runner does not set routing fields.

Specifying both `channel` and `user` is an error — the `mattermost` transport
raises rather than silently picking one. The `webhook` transport ignores all of
these routing fields (a webhook is a single fixed destination).

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
  - Mattermost: `{{input_file}}` plus the captured work-item fields
    `{{message}}`, `{{channel_id}}`, `{{root_id}}`, `{{sender}}`,
    `{{channel_name}}`, `{{post_id}}`.

Undefined variables remain literal and produce a log warning.

When the agent writes a message YAML into `message_dir`, the prompt template
should teach it the contract: a required `message` key plus, for the
`mattermost` transport, optional routing fields. To reply to a mention in its
originating thread, the prompt copies `channel_id: {{channel_id}}` and
`root_id: {{root_id}}` straight from the work-item. To notify a named
destination instead, set at most one of `channel: <name>` or `user: <username>`
(both is an error). Omitting all routing fields sends to
`messenger.default_channel`.

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

A `mattermost` trigger reuses the same `input_dir`/`archive_dir`/`failed_dir`
resolution as the file trigger; when those keys are omitted they default to
`mentions/<runner-name>/inbox`, `mentions/<runner-name>/done`, and
`mentions/<runner-name>/failed` (each then resolved relative to `project_path`).

### Validation

Config loading fails immediately with descriptive errors when:

- `runners` is missing, not a list, or empty.
- Runner names are duplicated.
- A runner is missing `name`, `prompt_template`, or `trigger`.
- `trigger.type` is not `tracker`, `file`, or `mattermost`.
- Trigger-specific required keys are missing (e.g. a `mattermost` trigger
  requires `base_url`, `token`, `team`, and a non-empty `channels` list).
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

For an operator-oriented setup guide, see [deployment.md](deployment.md).
