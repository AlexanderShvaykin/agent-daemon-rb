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

## Goals

- @-mention the bot in an allowed channel → an agent task runs.
- The mention's message text is available to the prompt as a variable
  (`{{message}}`); the template decides how to use it (hybrid model — neither a
  pure fixed prompt nor a raw passthrough).
- The agent's result is posted back as a **threaded reply** to the mention.
- Stdlib-only; no new runtime gem dependencies.
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

## Architecture decision

Three approaches were considered:

- **A — Daemon-managed listener thread + file bridge + file-style consumer
  (chosen).** A listener thread (peer to the Messenger) holds the WebSocket and
  writes each qualifying mention as a YAML work-item into an inbox directory; a
  file-poll consumer runner processes them. Honors the filesystem-IPC invariant,
  reuses the tested File-runner machinery, and both threads are Daemon-owned so
  crash-restart is uniform with no orphaned socket. Cost: the Daemon expands one
  `trigger.type: mattermost` config entry into two managed threads.
- **B — single `mattermost` runner with an internal `Queue`.** Cleaner config,
  but introduces an in-process queue (the one thing the architecture doc says to
  avoid) and risks an orphaned WebSocket reader thread on crash-restart.
  Rejected.
- **C — pure-push runner overriding `run`.** Lowest latency but discards the
  Base loop's attempt/escalation/shutdown machinery. Rejected.

## Data flow

```
Mattermost  ──wss event──▶  Listener thread  ──writes YAML──▶  inbox dir
 (bot @-mentioned)            (Daemon-managed)                     │
                                                                   ▼
   thread reply  ◀── Messenger ◀── message_dir ◀── agent ◀── Consumer runner
   (root_id)        (mattermost     (reply YAML)            (file-poll, backend)
                     transport)
```

1. The **listener** receives a `posted` event and applies three filters:
   - **not self:** `post.user_id != bot_id`,
   - **allowlisted channel:** `data.channel_name` ∈ configured `channels`,
   - **mentioned:** `bot_id` ∈ `data.mentions`.
   Survivors are written as `<post_id>.yml` into the inbox dir (the post id also
   de-dupes).
2. The **consumer** (file-poll runner) picks the oldest `*.yml`, renders the
   prompt with its fields, runs the backend — sequential, one at a time. Success
   → archive dir; exhausted attempts → failed dir.
3. The agent writes a **reply YAML** into `message_dir` with `channel_id`,
   `root_id`, and `message`. The **Messenger + Mattermost transport** post it
   back into the same thread.

## Components

### WebSocket client — `lib/agent_daemon/mattermost/web_socket.rb`

Stdlib-only RFC 6455 client over `TCPSocket` + `OpenSSL::SSL::SSLSocket` (for
`wss`). Uses `socket`, `openssl`, `securerandom`, `digest`, `base64`, `uri` —
all stdlib.

- **Handshake:** HTTP `GET` Upgrade with a random `Sec-WebSocket-Key` and
  `Sec-WebSocket-Version: 13`; verify the response is `101 Switching Protocols`
  and that `Sec-WebSocket-Accept` equals `base64(sha1(key + RFC6455-GUID))`.
- **Framing:** parse fin/opcode/payload-length; handle **text** (0x1, delivered
  to the caller), **ping** (0x9, reply with **pong** 0xA), **pong** (0xA),
  **close** (0x8, tear down). Client→server frames are masked (spec
  requirement); server→client frames are not.
- **Shutdown-aware reads:** the read loop blocks on `IO.select` with a ~1s
  timeout so it polls `shutdown_flag` between reads (no blocking call that
  ignores the flag). On shutdown it sends a close frame and returns.
- **Surface:** `connect`, `send_text(str)`, `each_message { |text| ... }`,
  `close`. Frame encode/decode is split from IO so it is unit-testable without a
  live socket.

### Listener — `lib/agent_daemon/mattermost/listener.rb`

A Daemon-managed thread, peer to the Messenger.

- **Bot id:** resolved once via `GET /api/v4/users/me` (Net::HTTP) and cached;
  used for the self-ignore and mention filters.
- **Auth:** after connecting, send the `authentication_challenge` action with the
  bot token, then read the `hello` event.
- **Loop:** `until shutdown { connect → auth → stream events → on drop,
  reconnect with capped exponential backoff (e.g. 1s → 30s) }`. Transient network
  errors are handled internally with backoff (not by crashing), so a blip does
  not incur the 60s `RESTART_DELAY`; only genuinely unexpected exceptions bubble
  to the Daemon's restart path.
- **Event handling:** a pure `handle_event(parsed_hash)` method (separate from
  IO) applies the filters and writes the work-item YAML — unit-testable by
  feeding it event hashes.

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

`runner_factory_for` currently returns a single factory keyed `runner:<name>`. It
will return **one-or-more** `{key => factory}` entries that `build_runner_factories`
merges:

- `tracker` / `file` → one entry (unchanged).
- `mattermost` → two entries: `runner:<name>` (the consumer) and
  `listener:<name>` (the listener).

Both entries live in `@runner_factories`, so `start_threads` and
`monitor_threads` start and independently restart each with no change to the
monitor loop.

## Edge cases

- **Self-trigger loop** prevented by the `user_id == bot_id` filter.
- **De-dup:** skip writing if `<post_id>.yml` already exists in inbox/done/failed.
- **Missed events while disconnected:** best-effort, no back-fill (documented
  limitation).
- **Out of scope events:** `post_edited`, deletions, and DMs are ignored; only
  `posted` events in allowlisted named channels trigger.
- **`root_id` logic:** reply to `post.root_id` when the mention is already in a
  thread, otherwise to `post.id` (open a thread on the mention).

## Testing

- **WebSocket client** (highest risk): a fake server via `TCPServer` in a thread
  performs the upgrade and emits frames — assert handshake verification,
  text-frame parse, masking, ping→pong, close handling, and shutdown-flag
  responsiveness.
- **Listener:** drive `handle_event(hash)` directly — mention hit/miss, allowlist
  in/out, self-ignore, and correct work-item YAML (including the `root_id`
  thread-vs-root logic). No live socket.
- **Consumer:** `render_prompt` maps YAML fields to template variables.
- **Transport:** `deliver` with `channel_id` + `root_id` builds the correct
  `POST /api/v4/posts` body (existing Net::HTTP-stub pattern).
- **Config:** mattermost validation errors, defaults, and dir resolution.
- **Daemon:** a `mattermost` runner yields two thread factories
  (`runner:<name>` + `listener:<name>`).

## Documentation & release

- Update `docs/architecture.md` (new trigger type, listener component, transport
  reply fields).
- Update `examples/config.yml` with a commented `mattermost` trigger block and an
  example mention prompt under `examples/prompts/`.
- Update `CHANGELOG.md` and bump `lib/agent_daemon/version.rb`.
