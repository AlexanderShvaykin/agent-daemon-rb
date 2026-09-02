# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.14.0] - 2026-09-02

### Added
- Optional per-runner `fallback_agent` configuration for Claude runners. Exact process-wide `FALLBACK_AGENT=1` selects each configured fallback when the backend is constructed; this is startup-time selection, not an automatic retry after Claude fails. Other values, runners without the block, and OpenCode runners keep their existing backend.
- The fallback runs from `project_path` and receives its required `command`, every String in required `args` (an empty Array is valid), and the rendered prompt as one final shell-escaped argument. All OMP options, including permissions, model, agent, and extra directories, must be declared explicitly in `args`; Claude-generated flags are not inherited.
- Configured fallbacks reuse the existing timeout, output, cooperative cancellation, shutdown, and process-group lifecycle. Runner logs report the effective executable.

### Changed
- `fallback_agent` is validated eagerly as a closed `{command, args}` shape. Unknown keys, a blank/non-String command, and non-String arguments are rejected while configurations without the block remain backward compatible.

## [0.13.0] - 2026-08-19

### Added
- Epic 4 supervisor lifecycle: serialized crash/manual restart intents, per-generation cooperative `CancelToken` propagation across runners, Messenger, and the Mattermost reactor, generation-safe respawn, and ephemeral restart events with actor/request/completion times.
- Authenticated restart control on every supervised entity's console detail page — runners, Messengers, and the global Mattermost reactor — with an explicit fleet-wide confirmation step for the reactor, restart progress and delay visibility, and a configurable `restart_warning_margin_seconds`. The fleet list keeps its disabled placeholder; the working control lives on the detail page.

### Security
- `POST /restart` stays behind default-deny session auth, requires constant-time CSRF validation, accepts its id and confirmation flag only from the form body, derives its actor only from the session, and returns the fixed non-disclosing 404 for unknown ids.
- Every accepted restart emits one `Log.info` line naming the actor and target generation, so a manual restart leaves a record that survives the process.
- Any member of any `allowed_groups` entry may restart any entity: roles are validated but do not gate actions in v1 (FR15), and that includes the fleet-wide reactor.

### Known limitations
- Restart activity is bounded and in-memory and does not survive supervisor restart; durable persistence remains Epic 5.
- The fleet-wide reactor confirmation is a UI step, not an authorization boundary — a client already holding a valid session and CSRF token can post `confirmed=fleet-wide` without visiting the page.

## [0.12.0] - 2026-08-11

### Added
- `agent: null` in a runner suppresses the `--agent` flag entirely, so a runner can run on the CLI's own default agent. Omitting the key keeps the `task-analyst` default, as before. Both backends honour it — `Backend::OpenCode` reads the same key and would otherwise have died on `nil.shellescape`.
- Optional `claude.model` key → `--model <value>` for the `claude` backend, mirroring the existing `opencode.model`. Absent means the CLI picks the model. Together with `agent: null` this is what lets a cheap, agent-less watchdog runner exist.

### Changed
- `Config` validates both new values at load and collects them with every other config problem: `agent` must be `null` or a non-empty String, and `claude.model` (when present) a non-empty String. `opencode.model` deliberately keeps its existing runtime `ArgumentError` — the asymmetry is documented, not an oversight.

A config that sets neither key builds a byte-for-byte identical command; there are no breaking changes.

## [0.11.0] - 2026-08-10

### Added
- Optional `description:` and `support:` (`owner`, `runbook`, `on_failure`) keys, accepted both at the top of a workflow config and inside a single `runners` entry. The daemon ignores them; they exist so someone on support who did not write the config can tell what a flow is for and what to do about it.
- The console renders them: one clipped description line under each entity and workflow name on the fleet page, and the full text plus the support block on the entity page — as two independent sections, the entity's own followed by its workflow's. `on_failure` keeps the operator's line breaks (`white-space: pre-wrap`).

### Security
- Descriptions are operator prose rendered escaped, never parsed as markdown. `support.runbook` is validated as an `http(s)` URL at config load, and the console re-checks the scheme before emitting an `<a href>` — a URL that fails renders as text. Descriptions do not pass through the Redactor, so they must not contain secrets.

## [0.10.1] - 2026-08-08

### Fixed
- The terminal panel's `out`/`err` stream labels are painted again. Story 3.6's hanging indent (`text-indent: -2.7rem` on `.terminal-line`, which keeps a wrapped continuation line out of the gutter column) inherits, and an `inline-block` applies it to its own first line box — so the label's glyphs rendered 2.7rem to the left of their span, outside the scroll container. The label's box, hit-testing, computed style and `textContent` all remained correct, so this was invisible to every DOM-level check; the user-visible effect was that stdout and stderr became distinguishable by colour alone at every viewport width (WCAG 1.4.1). Fixed by resetting `text-indent` on the label rather than dropping the hanging indent.

## [0.10.0] - 2026-08-08

### Added
- Epic 3 supervisor terminal: a single-ingress output pipeline with secret redaction, a bounded per-run output buffer with a sequence-cursor snapshot contract, and a server-rendered run-output panel on the entity page.
- Authenticated live output streaming multiplexed onto the existing `GET /events` connection — `output`, `output_run`, `output_lagged`, and `output_state` frames, resumable through `Last-Event-ID`, with lagged-cursor recovery and run-change resets. A viewer still costs exactly one Puma thread.
- Terminal panel autoscroll that follows new output only while the operator is at the bottom, plus an accessible "newer output below" control when they are not.

### Security
- Record text is attacker-influenceable and is treated as such end to end: JSON-encoded on the wire, inserted with `textContent` in the browser, escaped in every HTML attribute, and never interpolated into log messages. Redaction stays at the single pipeline ingress; the console opens no second path to raw backend bytes.
- `/events` rejects malformed, unknown, and non-runner entity ids with the existing fixed non-disclosing 404 before the hijack, and reduces any cursor value that is not a non-negative base-10 integer to "no cursor" rather than trusting it.

### Notes
- Multi-line secrets (PEM keys, JSON service-account blobs) remain structurally unredactable, because redaction matches complete lines. Access control is the barrier.
- The NFR1 output-to-DOM p95 acceptance protocol has **not** been executed for this release; it requires a production Puma deployment, ~20 runner entities, and 9 concurrent browser sessions. Treat the streaming latency budget as unverified.

## [0.9.1] - 2026-08-05

### Added
- A robot-head favicon on the console, inlined into `<head>` as a data URI. No `/favicon.ico` route is added: the default-deny middleware would answer the browser's unauthenticated probe with a login redirect, so the unauthenticated boundary is unchanged.

## [0.9.0] - 2026-08-05

### Added
- Epic 2 supervisor read model: one master-owned generation-CAS `StateRegistry`, one bounded/drop-oldest `EventBus`, config-rostered `Fleet` liveness, per-entity detail, and newest-first `ActivityLog` timelines.
- Optional single-process Puma console with fail-closed GitLab OAuth, authenticated fleet/detail/activity pages, stable escaped live-content markup, and bare GET/HEAD `/healthz` liveness.
- Authenticated `GET /events` SSE invalidations for state and activity changes, 250 ms observation polling, approximately 15 s heartbeats, reconnect reconciliation through a current-page refresh, exception-safe tail cursor cleanup, and cooperative shutdown of open streams.

### Security
- OAuth access tokens remain only in private server-side sessions; renderers receive an immutable username/CSRF view. GitLab membership is revalidated fail-closed at most once per session per 60 seconds **for sessions with a live SSE stream**, coalescing concurrent streams without holding the session-store mutex over network I/O. Page renders validate the local session only, so a client that never opens the stream keeps its session until `session_ttl` expires.
- Separate bounded multi-tab OAuth pending states, single-use/session-bound callbacks, authenticated-id rotation, validated origin-local deep-link returns, fixed denial responses, and clean rejection of malformed Rack parameter shapes.
- `/events` remains behind the default-deny middleware and carries no agent-influenced payload; browser updates reuse the existing escaped server renderer.

### Notes
- Activity history is bounded and in-memory: it can evict old records and does not survive supervisor restart. Reconnect repairs state gaps from the current registry and retained ring; it does not provide durable replay.
- Each SSE stream occupies one Puma thread. The default `max_threads: 16` leaves request headroom for the supported `<10` concurrent viewers, but operators must size it above their own peak streams plus ordinary requests.

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
