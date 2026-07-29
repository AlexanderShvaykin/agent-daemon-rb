# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.7.2] - 2026-07-29

### Fixed
- Normalize Mattermost `sender_name` before matching `direct_users`, so the
  event's leading `@` does not prevent an allowlisted direct message from
  reaching its runner.

## [0.7.1] - 2026-07-29

### Changed
- Mattermost runners with a valid `trigger.direct_users` allowlist may now set
  `channels: []` for direct-message-only operation. Runners without that
  allowlist still require a non-empty channel list.

## [0.7.0] - 2026-07-29

### Added
- Optional `trigger.direct_users` allowlist for Mattermost runners. One-to-one direct messages from listed usernames trigger an agent run without an `@` mention; all non-DM posts retain the existing configured-team, channel-allowlist, and mention checks.

## [0.6.0] - 2026-07-23

### Added
- **`agent-supervisor` subsystem**: a new `bin/agent-supervisor <supervisor-config.yml>` entrypoint that runs N whole workflows, each an unchanged `AgentDaemon::Config`, as threads inside one MRI process, instead of one `agent-daemon` process per workflow.
- `Supervisor::Config`: enumerates workflows by unique name, each referencing an ordinary per-workflow config file; fails fast, collecting every problem into one `ConfigError` (duplicate/blank names, an identity-delimiter `:` in a workflow or runner name, a referenced config that fails to load, and colliding `message_dir`/`output_dir`/trigger work-dirs across workflows).
- `Supervisor::Master`: boots every workflow's runners and Messenger, plus exactly one fleet-wide `Mattermost::Reactor` shared across every workflow's mattermost runners. Centralized `SIGINT`/`SIGTERM` handling sets one shared `ShutdownFlag`, then drains every supervised thread (per-thread join timeout, sequential) followed by a last-resort **orphan sweep** that force-kills any straggler's in-flight agent process group (never `Thread#kill`).
- Per-entity supervisor (`RunnerSupervisor`): crash auto-restart with a fixed delay, driven by a non-blocking ~1s tick loop (no blocking sleeps), and a monotonic **generation** counter bumped on every (re)spawn so every published record can be traced to the instance that emitted it.
- Injected **publish seam** (`AgentDaemon::Sinks`): core components (runner, backend, messenger, reactor) report state/events only through a narrow sink protocol with no-op defaults, so the standalone daemon's behavior is completely unchanged (NFR5) while the supervisor can inject real per-generation sink adapters without the core ever naming a supervisor type.
- Centralized logging tagged per `(workflow, runner)` and generation, gated by each workflow's own configured `logging.level`; one shared `$stdout` sink for the whole fleet.
- **Load-time dependency isolation**: the standalone core `require "agent_daemon"` graph (and therefore `bin/agent-daemon`) loads no supervisor file and no supervisor-only dependency (`sqlite3`, the HTTP server gem, the OAuth client gem), guarded by a new test (`test/test_require_isolation.rb`) that shells out to a clean subprocess. `agent_daemon.gemspec` now declares `agent-supervisor` as a second `executables` entry alongside `agent-daemon`.
- `examples/deploy/agent-supervisor.service`: a plain (non-templated) systemd unit for the single master process, with `TimeoutStopSec=120` to comfortably exceed the sequential per-thread drain's worst case.

### Notes
- Isolation is **load-time, not install-time**: once `sqlite3`/`puma`/`rack`/`oauth2` are added as gemspec dependencies in a later release, they are still *installed* on every host that installs this gem, even one that only ever runs the standalone `agent-daemon` CLI.

## [0.5.0] - 2026-06-24

### Added
- `mattermost` **trigger**: an @-mention push trigger that drives an agent run and replies in-thread. A per-runner `Mattermost::Listener` connects over a WebSocket, resolves the bot id and team id once up front, filters `posted` events (not-self + event `team_id` matches the configured `team` + allowlisted `channels` + bot mentioned, so a like-named channel in another team cannot trigger), de-dups by post id, and writes `<post_id>.yml` work-items into an inbox; reconnects use capped backoff (1s→30s, reset on the server `hello`).
- A single shared `Mattermost::Reactor` thread (`:mattermost_reactor`, a peer to the Messenger) hosting every listener — one per process because EventMachine's reactor is a singleton — restarted by `monitor_threads` like any other thread.
- `Runner::Mattermost < Runner::File` consumes those work-items, reusing the file-poll machinery wholesale and exposing the captured fields (`message`, `channel_id`, `root_id`, `sender`, `channel_name`, `post_id`) as `{{...}}` prompt variables.
- `channel_id` (posted verbatim) and `root_id` (threads the post as a reply) reply fields in the message YAML, honored by the `mattermost` transport so a mentioned agent answers back in its originating channel and thread.
- Type-aware config validation for the `mattermost` trigger (`base_url`, `token`, `team`, non-empty `channels` list) with work dirs defaulting to `mentions/<name>/{inbox,done,failed}` under `project_path`. Documented in `examples/config.yml` with a new `examples/prompts/mention.txt`.

### Changed
- The daemon is no longer pure-stdlib: it now declares two runtime dependencies, `eventmachine` and `faye-websocket`, used **only** by the `mattermost` trigger to handle the WebSocket protocol instead of hand-rolling RFC 6455. Every other component (tracker/file triggers, backends, Messenger, transports) remains stdlib-only.

## [0.4.1] - 2026-06-09

### Fixed
- Dropped the hardcoded `--allowedTools '*'` flag from the Claude backend command. Recent Claude CLI versions reject `*` as an allow rule and exit non-zero, which the daemon surfaced as `CLI failed` and moved the task to `failed_dir`. The flag was redundant — `--dangerously-skip-permissions` already bypasses all permission checks.

## [0.4.0] - 2026-06-05

### Added
- Per-cycle **poll interval jitter** in the runner loop (`trigger.jitter`, seconds, default `5`, `0` disables). A fresh random `0..jitter` is added to each wait so independently running pollers — threads or separate daemon processes sharing a trigger source — de-phase instead of firing in the same instant. Shutdown responsiveness is unchanged (the existing chunked, `ShutdownFlag`-polling wait is reused).
- Typed **rate-limit handling** for the Tracker client: an HTTP 429 raises `AgentDaemon::Tracker::RateLimitError` carrying a retry-after duration, taken from the `Retry-After` header (integer-seconds form) or a configured fallback (`tracker.default_backoff`, seconds, default `60`) when the header is absent or unparseable.
- The runner **backs off** for the suggested duration (interruptible by shutdown) on a rate-limit signal and logs it at WARN. A throttle does **not** increment the consecutive-error counter, so it never escalates to a `SYSTEM:<runner>` message — genuine errors still escalate as before.
- Eager validation for both new keys (non-negative numbers), documented in `examples/config.yml`.

## [0.3.0] - 2026-06-04

### Added
- Pluggable Messenger delivery **transports** selected by `messenger.type` (default `webhook`), mirroring the `Backend.for` factory idiom.
- `mattermost` transport: delivers via the Loop/Mattermost bot REST API with a single bot token, reaching any channel by name and DMing any user. Channel/user names resolve to ids (cached for the process lifetime); messages route by optional `channel`/`user` fields with a `default_channel` fallback. stdlib only (`Net::HTTP`).
- Optional `channel` / `user` routing fields in the message YAML the agent writes; specifying both is an error, and the `webhook` transport ignores both.
- Type-aware config validation (`mattermost` requires `base_url`, `token`, `team`, `default_channel`) and a type-aware Messenger start gate.

### Changed
- Internal `loop` terminology renamed to transport-neutral wording: `Messenger#send_to_loop` is gone (logic moved to the `webhook` transport), and "Loop API"/"Loop webhook" log strings now read "message transport"/"Webhook". No config key was renamed — webhook configs keep `webhook_url`.

## [0.2.0] - 2026-06-04

### Added
- Config files are rendered through ERB before YAML parsing, with a `secret('KEY')` helper that resolves environment variables fail-fast and YAML-safe (`.to_json` quoting). Raw `<%= ENV['KEY'] %>` remains available for lenient resolution. Fully backward compatible with tag-free configs.

### Documentation
- Add `docs/secrets.md` covering the ERB render path, the `secret()` contract, the `sops exec-env` run pattern, and the `safe_load`-vs-ERB trust note.

## [0.1.1] - 2026-05-25

### Fixed
- Handle empty webhook URL configuration

### Documentation
- Add systemd deployment guide

## [0.1.0] - 2026-04-24

### Added
- Initial release extracted from private deployment repo
- Daemon engine with thread-per-runner architecture
- Tracker trigger (Yandex Tracker JQL queries)
- File trigger (YAML file polling with archive/failed dirs)
- Claude and OpenCode backend support
- Prompt template engine with {{variable}} substitution
- Messenger thread for webhook notifications (Loop/Slack compatible)
- Error escalation (3 consecutive failures → webhook alert)
- Graceful shutdown with SIGTERM/SIGINT handling
- Configurable logging (stdout or file)
