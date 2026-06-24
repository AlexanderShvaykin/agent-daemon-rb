# Mattermost WebSocket Mention Trigger — Design

**Date:** 2026-06-24
**Status:** Approved (pending implementation plan)

## Summary

Add a new trigger type, `mattermost`, that launches an agent task when the bot is
@-mentioned in Mattermost. The daemon opens a persistent WebSocket connection to
the Mattermost Bot API (`wss://<base_url>/api/v4/websocket`), listens for
`posted` events where the bot is mentioned in an allowlisted channel, and turns
each one into an agent run. The agent replies **in the same thread** it was
mentioned in.

This is the first **push-based** trigger in a daemon whose triggers are otherwise
poll-based. The push→pull bridge is the **filesystem**, consistent with the core
architectural invariant ("threads communicate only through the filesystem; no
in-process queue or shared mutable state").

The WebSocket protocol itself is handled by **`faye-websocket`** running on an
**EventMachine** reactor — a deliberate, owner-approved exception to the project's
prior "stdlib only" stance (see Dependencies). Hand-rolling RFC 6455 (handshake,
framing, ping/pong, close handshake, TLS) was judged the riskiest part of the
work; a mature library removes that risk.

## Goals

- @-mention the bot in an allowed channel → an agent task runs.
- The mention's message text is available to the prompt as a variable
  (`{{message}}`); the template decides how to use it (hybrid model — neither a
  pure fixed prompt nor a raw passthrough).
- The agent's result is posted back as a **threaded reply** to the mention.
- Use battle-tested WebSocket protocol handling (faye-websocket / EventMachine)
  rather than hand-rolling RFC 6455.
- Reuse the existing runner / file-trigger machinery and crash-restart model.

## Non-goals

- Replaying mentions missed while the daemon (or the connection) was down —
  best-effort live delivery only.
- Reacting to `post_edited` / deleted posts.
- Direct messages to the bot (only allowlisted named channels trigger). A DM
  toggle is a possible future addition, not part of this change.
- Concurrent task execution — mentions are processed **sequentially**, one at a
  time, exactly like every other runner today.
- A shared top-level Mattermost connection block (DRY-ing the trigger and the
  messenger transport credentials). The trigger carries its own connection keys;
  operators typically point both at the same `MM_BOT_TOKEN`.

## Dependencies (exception to "stdlib only")

The project previously declared **zero runtime gem dependencies** (AGENTS.md,
`architecture.md`). Ruby stdlib has no WebSocket client, and the owner chose a
library over a hand-rolled implementation. This change therefore adds two runtime
dependencies to the gemspec:

- **`eventmachine`** — the C-extension reactor (event loop).
- **`faye-websocket`** — the WebSocket client/protocol layer that runs on it.

`AGENTS.md` and `architecture.md` must be updated to state that the daemon is
stdlib-only **except** for these two gems, which back the `mattermost` trigger.

### Consequence: a single shared reactor

EventMachine's reactor is a **process singleton** (`EM.run` runs once per
process). The daemon's "one thread per runner" model cannot give each Mattermost
listener its own `EM.run`. Therefore **all** Mattermost listeners share one
Daemon-managed reactor thread (`Mattermost::Reactor`). The per-runner *logic*
(allowlist, bot id, work-item writing) lives in a per-runner `Mattermost::Listener`
handler object hosted inside that single reactor.

## Architecture decision

The chosen shape (after rejecting an in-process-queue runner and a pure-push
runner that discards the Base loop) is:

- A **single Daemon-managed reactor thread** holds the EventMachine loop and one
  `faye-websocket` client per `mattermost` runner.
- Each client, on a qualifying mention, writes a YAML **work-item** into that
  runner's inbox directory.
- A **file-poll consumer runner** (`Runner::Mattermost < Runner::File`) processes
  the work-items sequentially through the backend — reusing the entire tested
  File-runner machinery.

This honors the filesystem-IPC invariant (listeners and consumers share no
in-process state — only files), keeps the consumer side identical to the existing
file trigger, and confines all EventMachine/faye specifics to two small files.

## Data flow

```
Mattermost  ──ws event──▶  Reactor thread        ──writes YAML──▶  inbox dir
 (bot @-mentioned)          (one EM loop, faye                         │
                             client + Listener                         │
                             handler per runner)                       ▼
   thread reply  ◀── Messenger ◀── message_dir ◀── agent ◀── Consumer runner
   (root_id)        (mattermost     (reply YAML)            (file-poll, backend)
                     transport)
```

1. A `faye-websocket` client receives a `posted` event; its `Listener` applies
   three filters:
   - **not self:** `post.user_id != bot_id`,
   - **allowlisted channel:** `data.channel_name` ∈ configured `channels`,
   - **mentioned:** `bot_id` ∈ `data.mentions`.
   Survivors are written as `<post_id>.yml` into the inbox dir (the post id also
   de-dupes against inbox/done/failed).
2. The **consumer** (file-poll runner) picks the oldest `*.yml`, renders the
   prompt with its fields, runs the backend — sequential, one at a time. Success
   → archive dir; exhausted attempts → failed dir.
3. The agent writes a **reply YAML** into `message_dir` with `channel_id`,
   `root_id`, and `message`. The **Messenger + Mattermost transport** post it
   back into the same thread.

## Components

### WebSocket via faye-websocket + EventMachine

`faye-websocket` handles the RFC 6455 handshake, framing, masking, ping/pong
(`ping: 30` keepalive), close handshake, and `wss://` TLS — none of which we
implement ourselves. We supply only: the auth challenge on open, the message
filter, and reconnection scheduling.

### Reactor — `lib/agent_daemon/mattermost/reactor.rb`

A single Daemon-managed thread, peer to the Messenger. Its `run`:

1. Resolves every listener's bot id up front (`prepare`, a blocking
   `GET /api/v4/users/me`) **before** `EM.run`, so the reactor thread never
   blocks on network IO. A listener that fails to prepare is logged and skipped
   (it does not take down the other bots).
2. Enters `EM.run`, registers a 1s periodic timer that calls `EM.stop` once the
   shutdown flag flips (bridging the daemon's cooperative shutdown into the
   reactor), and starts each prepared listener.

Crash-restart is uniform: if the reactor thread dies, `monitor_threads` rebuilds
it after `RESTART_DELAY`, reconnecting all clients fresh.

### Listener — `lib/agent_daemon/mattermost/listener.rb`

A per-runner handler hosted in the reactor (not a thread).

- **Bot id:** resolved once via `GET /api/v4/users/me` (Net::HTTP), cached.
- **`start`** (called inside the reactor): creates the `faye-websocket` client and
  wires `:open` → send `authentication_challenge`, `:message` → `on_message`,
  `:close` → schedule reconnect with capped exponential backoff (1s → 30s).
- **`on_message(raw)` / `handle_event(hash)`:** pure of EventMachine — decode the
  JSON, apply the filters, write the work-item. Unit-testable by direct calls.

**Work-item YAML** (keys become prompt template variables):

| Key            | Source                                                            |
|----------------|-------------------------------------------------------------------|
| `message`      | `post.message` (verbatim, includes the `@mention`)                |
| `channel_id`   | `post.channel_id`                                                  |
| `root_id`      | `post.root_id` if the mention is already threaded, else `post.id` |
| `sender`       | `data.sender_name`                                                |
| `channel_name` | `data.channel_name`                                               |
| `post_id`      | `post.id`                                                          |
| `created_at`   | ISO-8601 timestamp                                                |

### Consumer — `lib/agent_daemon/runner/mattermost.rb`

`Runner::Mattermost < Runner::File`. Inherits inbox-poll, archive/failed moves,
attempt tracking, and exhaustion handling unchanged. Overrides:

- `render_prompt(path)` — load the work-item YAML and merge its fields into
  `base_template_variables`, exposing `{{message}}`, `{{channel_id}}`,
  `{{root_id}}`, `{{sender}}`, `{{channel_name}}`, `{{post_id}}`.
- `work_item_key` stays the basename (`<post_id>.yml`, already unique).

### Mattermost transport — `lib/agent_daemon/transport/mattermost.rb`

Extend `deliver` with two optional fields carried by the reply YAML:

- `channel_id` — used **verbatim** when present (skips name resolution; the
  listener already knows the numeric id).
- `root_id` — added to the `POST /api/v4/posts` body for threading.

Resolution precedence: `channel_id` → `user` (DM) → `channel` (by name) →
`default_channel`. The existing "both `channel` and `user`" guard stays. The
`webhook` transport ignores both new fields (single fixed destination), keeping
message YAML portable across transports.

## Configuration

```yaml
runners:
  - name: mention-bot
    backend: claude
    agent: task-analyst
    prompt_template: prompts/mention.txt
    trigger:
      type: mattermost
      base_url: https://chat.example.com
      token: <%= secret('MM_BOT_TOKEN') %>
      team: myteam
      channels: [dev-bots, support]   # allowlist — required, non-empty
      interval: 2                      # consumer poll cadence (optional)
      # input_dir/archive_dir/failed_dir: optional; default under project_path
```

- New `MATTERMOST_TRIGGER_DEFAULTS = { "interval" => 2, "jitter" => 0 }` (a
  single local consumer has nothing to de-phase, so jitter defaults to 0).
- `"mattermost"` is added to `VALID_TRIGGER_TYPES`.
- Default work dirs when unset: `mentions/<name>/{inbox,done,failed}`, resolved
  relative to `project_path` (same rule as the file trigger) and stored back onto
  the trigger so the consumer reads them like any file runner.
- **Validation** (new `when "mattermost"` branch in `validate_trigger`):
  `base_url` / `token` / `team` are required non-empty strings; `channels` is a
  required non-empty Array of strings; `interval` is a positive Integer. Errors
  are collected fail-fast like the rest of config validation.

## Daemon wiring

- For **every** runner, register the consumer thread `runner:<name>` as today
  (`runner_factory_for` gains a `when "mattermost"` returning a
  `Runner::Mattermost`).
- If **any** `mattermost` runner exists, register **one** extra thread,
  `:mattermost_reactor`, whose factory builds a `Mattermost::Reactor` with one
  `Mattermost::Listener` per mattermost runner.

`monitor_threads` restarts the reactor and each consumer independently, with no
change to the monitor loop.

## Edge cases

- **Self-trigger loop** prevented by the `user_id == bot_id` filter.
- **De-dup:** skip writing if `<post_id>.yml` already exists in inbox/done/failed.
- **Missed events while disconnected:** best-effort, no back-fill (documented
  limitation).
- **Out of scope events:** `post_edited`, deletions, and DMs are ignored; only
  `posted` events in allowlisted named channels trigger.
- **`root_id` logic:** reply to `post.root_id` when the mention is already in a
  thread, otherwise to `post.id` (open a thread on the mention).
- **EM reactor reuse:** a crashed reactor thread is restarted by
  `monitor_threads`; `EM.run` is re-entered fresh in the new thread.

## Testing

- **Listener logic** (no EventMachine needed): drive `on_message(raw)` /
  `handle_event(hash)` directly — mention hit/miss, allowlist in/out,
  self-ignore, de-dup, and correct work-item YAML (including the `root_id`
  thread-vs-root logic). `GET /api/v4/users/me` is stubbed via the existing
  `stub_net_http` / `FakeHttp` helpers.
- **Consumer:** `render_prompt` maps YAML fields to template variables.
- **Transport:** `deliver` with `channel_id` + `root_id` builds the correct
  `POST /api/v4/posts` body (existing Net::HTTP-stub pattern).
- **Config:** mattermost validation errors, defaults, and dir resolution.
- **Daemon:** a `mattermost` runner yields a `runner:<name>` consumer factory and
  a single `:mattermost_reactor` factory.
- **Reactor / faye wiring:** the EventMachine-driven connect/reconnect path is
  covered by a manual smoke test against a real bot token, not in CI (spinning a
  real reactor in unit tests is flaky). The reactor's shutdown bridge and
  per-listener `prepare` skip-on-failure are the testable seams.

## Documentation & release

- Update `AGENTS.md` and `docs/architecture.md`: the daemon is stdlib-only
  **except** `eventmachine` + `faye-websocket`, which back the `mattermost`
  trigger; document the new trigger, the shared reactor, the listener, and the
  transport reply fields.
- Update `examples/config.yml` with a commented `mattermost` trigger block and an
  example mention prompt under `examples/prompts/`.
- Update `CHANGELOG.md` and bump `lib/agent_daemon/version.rb`.
