# Architecture

## Overview

AgentDaemon is a Ruby daemon that runs one thread per configured runner plus a
dedicated Messenger thread. Threads communicate exclusively through the
filesystem (YAML files in a shared directory). The core daemon is stdlib-only
except for `eventmachine` and `faye-websocket`, confined to the `mattermost`
trigger's WebSocket client. The optional supervisor web console separately owns
`puma`, `rack`, and `oauth2`; those dependencies are not loaded by
`require "agent_daemon"` or used outside `lib/agent_daemon/supervisor/console/`.

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

A `mattermost` runner turns Mattermost @-mentions — and, when configured,
direct messages from allowlisted users — into agent runs and posts the answer
back as a threaded reply. It is the only **push**-driven trigger, so it is split
across two cooperating pieces plus the shared reactor:

- **`Mattermost::Listener`** — a per-runner WebSocket handler. It does *not* own
  a thread: the reactor creates its faye-websocket client and drives the
  callbacks. Before the reactor loop starts, `#prepare` resolves the bot id once
  with a blocking `GET /api/v4/users/me` and the team id with
  `GET /api/v4/teams/name/{team}` (so the reactor thread never blocks on IO
  inside the loop). It then connects, sends an `authentication_challenge`,
  and for each incoming `posted` event rejects posts from the bot, then selects
  one route. A direct-message (`channel_type: "D"`) is accepted only when its
  `sender_name` is in the optional `direct_users` allowlist; it needs neither a
  mention nor a configured team or channel. Every other channel type retains
  the existing filters: the event's `team_id` matches the configured team (so a
  like-named channel in another team cannot trigger), its name is in the
  runner's `channels` allowlist, and its `mentions` include the bot id. The
  listener then de-duplicates by post id (checked across
  the inbox, done, and failed dirs). A qualifying post is written as a
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

For a Mattermost runner, `trigger.direct_users` is optional. When present it
must be a non-empty list of non-empty Mattermost usernames and enables incoming
one-to-one direct messages from exactly those users. The listener accepts the
Mattermost event's optional leading `@` in `sender_name`; configure usernames
without it. `channels` may be empty
only with a valid `direct_users` allowlist, which configures a direct-message-
only runner. Otherwise, `channels` remains required for non-DM posts.

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

## Supervisor

`bin/agent-supervisor <supervisor-config.yml>` runs **N whole workflows** (each
an ordinary, unchanged `AgentDaemon::Config`) as threads inside **one** MRI
process, instead of one `agent-daemon` process per workflow. It is a separate
subsystem layered *on top of* the core described above — the core itself does
not know it exists (see "Dependency isolation" below). The full invariant set
this subsystem is built against (AD-1…AD-16) is captured in the project's
internal architecture spine — a planning artifact kept outside this repository,
not a shipped document; this section describes the shape actually implemented in Epic 1
— the in-memory live console shipped in Epic 2; SQLite history and the metrics
exporter remain assigned to Epics 5 and 6.

### Layout

One file per concern under `lib/agent_daemon/supervisor/`:

| File                    | Responsibility                                              |
|--------------------------|-------------------------------------------------------------|
| `config.rb`              | Loads a supervisor config that enumerates per-workflow configs |
| `master.rb`              | Boots and drives every workflow's threads in one process     |
| `runner_supervisor.rb`   | Per-entity crash/restart state machine (generation tracking) |
| `runner_identity.rb`     | Composite `(workflow, runner)` identity value object          |
| `state_registry.rb`      | Generation-CAS current state plus accepted-write revision     |
| `event_bus.rb`           | Bounded event ring with independent pull cursors               |
| `fleet.rb`               | Config roster left-joined with current registry state          |
| `activity_log.rb`        | Per-entity recent events projected from the bounded bus         |
| `console/`               | Rack/Puma UI, GitLab OAuth sessions and authenticated SSE       |

### Supervisor config

`Supervisor::Config` enumerates workflows, each `{name:, config: <path>}`,
where `config` resolves relative to the supervisor config file's own directory
(the same rule core uses for `prompt_template`) and is loaded as an ordinary
`AgentDaemon::Config` — no new config dialect. Loading fails fast, collecting
every problem into one `ConfigError` (mirroring core): missing/duplicate
workflow names, a workflow or runner name containing the `:` identity
delimiter, a referenced config that fails to load, and two workflows whose
`message_dir`/`output_dir`/trigger work-dirs collide (a shared `project_path`
alone is not a collision). See `examples/supervisor.yml`.

### Master: one process, many workflows

`Supervisor::Master` builds one entity factory per runner across every
workflow, plus one per-workflow Messenger (skipped if unconfigured) and
exactly **one** fleet-wide `Mattermost::Reactor` shared by every workflow's
mattermost runners — EventMachine's reactor is a process singleton, so this
mirrors the standalone daemon's one-reactor rule at fleet scale instead of
per-config. Runners are keyed by the composite `(workflow, runner)`
`RunnerIdentity` (`workflow:runner` thread key and log tag) rather than by
runner name alone, since a runner name is only unique *within* its workflow.

Each entity is wrapped in a `RunnerSupervisor` (below); `Master#start` drives
all of them through a single non-blocking ~1s tick loop
(`supervise_until_shutdown`) instead of a blocking idle sleep, so one entity's
restart delay never stalls another's supervision.

**Shutdown** is centralized: `SIGINT`/`SIGTERM` set one shared `ShutdownFlag`
(same primitive as the standalone daemon), which stops the tick loop and joins
every supervised thread with a per-thread timeout (`JOIN_TIMEOUT`, 30s
default) — sequentially, so the worst case for N wedged entities is
`N * JOIN_TIMEOUT`. After the join, one final tick lets any entity that died
during the drain publish its terminal state (the tick loop otherwise never
observes a death after the flag flips). Finally, an **orphan sweep** force-kills
the in-flight agent process group of any thread still alive after its join
timeout (never `Thread#kill` — the thread itself is abandoned to process exit;
only its owned OS process group is killed).

### Per-entity supervisor: crash auto-restart and generation

`RunnerSupervisor` is a small state machine (`:running → :stopping →
:restarting → :running…` or terminal `:exited`) supervising a single entity's
full lifecycle — this covers all three entity kinds (runner, messenger,
reactor), not just runners. `#tick` is its only driver, called ~1/s by the
master; it never sleeps, so a pending restart is a recorded monotonic
deadline, not a blocking wait.

A crash (an uncaught exception on the entity's own thread) schedules an
automatic respawn after `RESTART_DELAY` (60s); a clean exit does not
auto-restart (manual restart is Epic 4's concern) and becomes terminal.
Every (re)spawn increments a monotonic **generation** counter starting at 1,
and builds a fresh sink bundle for that generation — a superseded (old-gen)
entity's late publish still carries its own, now-stale generation, so a
downstream consumer (Epic 2's read model) can always tell which instance a
record came from.

### Publish seam (why the core needs no supervisor require)

Core components (runner, backend, messenger, reactor) report state/events only
through the narrow `AgentDaemon::Sinks` protocol defined in `sinks.rb` — a
`Bundle` of `NullState`/`NullEvent`/`NullOutput` sinks by default, so the
standalone CLI path silently discards everything it publishes (zero behavior
change, NFR5). The supervisor injects a real `Bundle` per generation
(`RunnerSupervisor#default_sinks_factory`, gen-stamped via `GenerationStamp`)
at entity-construction time; the core class being supervised is identical to
the one the standalone daemon instantiates and never names a supervisor type.
The standalone daemon keeps the no-op defaults. `Supervisor::Master` instead
injects its one `StateRegistry` and one `EventBus`, both generation-stamped,
without touching runner/backend/messenger code. Accepted registry writes
increment a mutex-protected revision; stale-generation writes do not. The bus
retains a bounded drop-oldest ring, supports backlog or tail cursors, and keeps
cursor cleanup exception-safe without producer-thread callbacks.

### Epic 2 read model and console

`Fleet` left-joins the master's immutable configured roster with current
`StateRegistry` snapshots, so an entity that has never published remains
visible as unknown. `ActivityLog` projects the newest retained records for one
entity from `EventBus`; this history is bounded, in-memory, and lost on process
restart. Neither observer reads runners, threads, or `RunnerSupervisor`.

The optional console is one non-clustered Puma server in the master process.
`Auth` is a default-deny Rack middleware: `/healthz` (GET/HEAD) is the only
public app route; `/auth/login` and `/auth/callback` are unauthenticated OAuth
legs handled inside the middleware, and `/auth/logout` is a CSRF-protected
POST. Every other route, including `GET /events`, requires a live server-side
session. GitLab tokens remain in private session records; HTML receives only an
immutable username/CSRF view. Group membership is rechecked fail-closed at most
once per session per 60 seconds, with concurrent streams coalesced onto one
lookup and no store mutex held during network I/O.

That recheck is driven by the live SSE stream, not by page rendering: `Auth`
publishes the revalidation callable into the Rack environment and `GET /events`
is its only caller. Page renders (`/`, `/entity`) validate the local session
only, deliberately — a GitLab round-trip on the render path would put network
latency in front of every page and would put access-control code inside `App`,
which owns none by design. Because every rendered page carries the live-update
script, a browser session loses access within one recheck interval; a client
that never opens the stream (scripting disabled, a stolen cookie replayed by a
CLI) keeps its already-issued session until `session_ttl` expires or it is
destroyed. Shortening that window is a session-TTL decision, not a rendering
one.

`GET /events` uses Rack partial hijack and emits only fixed SSE invalidations:
an initial `refresh`, one coalesced `refresh` when the registry revision, event
cursor, or cursor-loss count changes, an approximately 15-second comment
heartbeat, and `authorization_lost` before a detected revocation closes the
stream. The poll interval is 250 ms. Every terminal path closes the IO and
unsubscribes the tail cursor; server shutdown first stops these loops, then
stops Puma. Each live stream occupies one Puma request thread, so `max_threads`
must stay above peak concurrent viewers with headroom for HTML, OAuth, health,
and reconnect requests.

The browser owns one `EventSource` per page. On open/reconnect and every
`refresh`, it fetches the current authenticated URL and replaces only
`<main id="console-content">`; a trailing dirty flag coalesces notifications
that arrive during a fetch. Server-rendered escaping remains the only HTML
formatting contract, and a successful reconnect fetch repairs gaps by re-reading
current registry state plus the retained activity ring rather than promising
durable replay; a fetch that fails leaves the previous DOM in place until the
next notification. A stream the browser closes as fatal — which is how an
expired session appears once the socket is already down, since `/events` then
answers with a redirect rather than `text/event-stream` — navigates to the login
path instead of leaving a stale page that still looks live.

### Centralized, tagged logging

The master installs one shared logger (`bin/agent-supervisor`, `Logger::DEBUG`)
for the whole fleet; each supervised entity's own thread binds ambient log
context (`Log.bind_context`) tagging every line with its `(workflow, runner)`
tag and current generation, gated by that *workflow's* configured
`logging.level` (per-tag, not global). A per-workflow `logging.file` is
ignored under the supervisor — there is one shared `$stdout` sink for the
fleet. The standalone daemon's own single-workflow logger is unchanged.

### Dependency isolation (AD-5) — the contract this story's test guards

All supervisor code lives under `AgentDaemon::Supervisor::` in files required
**only** from `bin/agent-supervisor` (directly, or transitively through
`master.rb` → `config.rb`/`runner_supervisor.rb` → `runner_identity.rb`). The
core load path — `require "agent_daemon"` and therefore `bin/agent-daemon` —
requires no supervisor file and defines no `AgentDaemon::Supervisor` constant.
`test/test_require_isolation.rb` asserts this in a clean child Ruby process
(the shared Minitest process is unsuitable: sibling test files already load
supervisor code into it before this test runs), and asserts by *feature path*
that none of `sqlite3`/`puma`/`rack`/`oauth2` are loaded. Puma, Rack and OAuth2
are installed runtime dependencies for the console but remain lazily isolated;
SQLite is still forward-guarded for Epic 5. `agent_daemon.gemspec` declares
`agent-supervisor` as a second executable alongside `agent-daemon`.

**Accepted residual:** isolation is *load-time*, not *install-time* —
`puma`/`rack`/`oauth2` are installed on every host that installs this gem, even
one that only runs the standalone `agent-daemon` CLI. The same will apply to
SQLite if Epic 5 adds it.

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
