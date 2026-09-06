# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.18.0] - 2026-09-08

### Fixed
- A run that exits 0 without writing anything is no longer treated as a success. Agent CLIs report success for plenty of runs that produced nothing: an unauthenticated `claude -p` prints "Not logged in" and exits 0, a sandbox that refused the write leaves the agent explaining it could not save the file, a `message_dir` that does not exist does the same. For `Runner::File` that meant archiving an unprocessed work item — bad, but visible. For `Runner::Pachca`, which acknowledges by deleting the event from Pachca's history, it meant the question was gone and nobody learned it went unanswered. Found in use, on a real question.
- A runner that expects a reply now says so through `expects_message_file?` (default `false`), and a run leaving no new file in `message_dir` counts as a failure: attempt counted, work item kept, next cycle retries, exhaustion still reported through the usual `SYSTEM:<runner>` path. Opt-in because a runner whose agent is expected to act rather than write has no artefact to look for, and demanding one would turn working setups into failing ones.

- The reply check no longer calls a run silent because it reused a filename. Prompts name the reply after the work item ("write your answer to `<event id>.yml`"), so a retry — or a second summons on the same pull request, which GitHub reports under the notification id it used before — writes a name already sitting in `sent/` from the previous run. Comparing names alone declared that run empty and retried an answer the person had already received. The snapshot now carries each name's mtime and a run counts when a name is new *or* has been written again. Found in use, on a review that had been posted to GitHub and delivered to the chat while the daemon reported it as having produced nothing.
- Backend output comes back as UTF-8. `read_nonblock` hands back ASCII-8BIT, and appending a chunk carrying a single non-ASCII byte flipped the whole buffer to binary — so a `Result` stayed UTF-8 only as long as the agent spoke ASCII. Interpolating the binary one into a message raised `Encoding::CompatibilityError`, killing the runner thread at the exact moment it was trying to report a failure. Invalid sequences (a 4096-byte read can land mid-character) are scrubbed rather than raised over. Reaching this needed both a non-ASCII agent and a failure to report, which is why it surfaced only now: the reply check below is the first path that feeds agent prose into `create_error_message`.

## [0.17.0] - 2026-09-07

### Added
- The `pachca` transport attaches files. A reply YAML may carry `files:` — local paths, or a Hash with `path` plus an optional `name` (what the chat displays) and `file_type` (`image` renders inline, `file` attaches) — and the transport uploads each one before posting. The agent writes a path and nothing else: the three-step dance is the daemon's, not the prompt's.
- Uploading is three requests, and the middle one is not Pachca's: `POST /uploads` returns presigned S3 form fields, the bytes go to the storage host directly (no bearer token there — the signature is the authorization) and the returned key is what the message references. The signed policy fixes the field set and their order, and the storage stops reading the form at the `file` part, so the multipart body is assembled by hand rather than through `Net::HTTP#set_form`, which promises no order. The body is binary throughout: a PNG does not survive a transcode.
- The transfer happens at delivery rather than when the agent writes the file, because an upload is an orphan object on the storage until a message references its key — there is nothing to leak and nothing to clean up if the run fails before writing its YAML. A path that cannot be read raises, exactly like a half-written destination does: when the file *is* the answer, sending the text without it would look like a complete reply. `file_type` defaults from the extension because Pachca never infers it from the bytes — a screenshot sent as `file` arrives as a download link.

## [0.16.0] - 2026-09-05

### Added
- `codex` backend: OpenAI's Codex CLI as a first-class option alongside `claude` and `opencode`, selected the same way (`backend: codex`, with an optional `codex.model` and `codex.extra_flags`). It runs `codex exec` with `--sandbox workspace-write` plus an `--add-dir` for every directory the runner writes to. That sandbox choice is deliberate and stated in the class: the agent's whole output is a message YAML written into `message_dir`, so under the safer-sounding read-only sandbox a run would finish successfully having written nothing — and a trigger that acknowledges on success would then discard the work item. Codex's `--dangerously-bypass-approvals-and-sandbox` is *not* the counterpart of Claude's `--dangerously-skip-permissions`: Claude has no sandbox to disable, so copying the flag across would not equalise behaviour but remove a protection. Operators who want it can pass it through `codex.extra_flags`.
- `fallback_agent` now accepts a backend name as well as a `{command, args}` Hash: `fallback_agent: claude`. The Hash form inherits none of the flags a backend builds for itself, so writing a known agent as a raw command means restating `--add-dir`, `--model`, `--agent`, `--output-format` and `--dangerously-skip-permissions` by hand — and getting one wrong yields a fallback that fails exactly when it is needed. Naming the backend keeps its own command-building.

### Changed
- The `FALLBACK_AGENT=1` switch applies to every backend, not just `claude`. Whichever agent a runner normally uses is the one whose quota can run out. Runners without a `fallback_agent` are unaffected, and the switch remains process-wide by design — it exists for the case where one account's quota is exhausted and every runner has to move at once.
- `codex.model` is validated at config load, like `claude.model` and unlike `opencode.model`, so a typo surfaces on startup rather than hours later on the first work item.
## [0.15.1] - 2026-09-05

### Fixed
- Thread context now includes the message the thread hangs off. That message lives in the parent chat, not in the thread, so listing the thread returned every reply and not the question that started it — the one message that made the rest make sense. Found in use: an agent asked to follow up inside a thread it had opened saw only its own answer and reported the context as incomplete. A standalone thread reports no such message and is unaffected; a failed fetch warns and keeps the rest of the transcript.

## [0.15.0] - 2026-09-05

### Added
- `pachca` trigger: a poller over a Pachca bot's event history. Pachca offers only outgoing webhooks and this history endpoint — there is no realtime API — and the history needs no public URL (the bot's "save event history" setting works with an empty Webhook URL), so the daemon stays a purely outbound client and the core gains no HTTP server and no new dependency. Reading plus deleting makes the history a queue with an explicit ack, which lands on `Runner::Base`'s existing hooks unchanged.
- `pachca` transport: `POST /messages` with one bot token. No name-to-id cache and no channel to open first, because Pachca addresses everything by numeric id and a direct message creates its conversation on first contact. Destination by precedence: a `thread` entity pair → `reply_to_message_id` → any other `entity_id` → `user` → `chat_id` → `default_chat_id`.
- Answering "in the thread" is two different calls depending on where the question was asked: a message posted in a channel has no thread of its own, so its thread is created (idempotently) and answered in. The reply YAML states all three routing fields unconditionally and the transport decides — a prompt cannot be trusted to branch on that.
- `Runner::Base#before_attempt`, the first hook that fires *before* the backend rather than after it. `Runner::Pachca` uses it to add an `agent-thinking` reaction, for which Pachca renders a live timer; a run takes minutes, and a chat needs an acknowledgement sooner than that.
- Thread context: for a question asked in a thread, the last `context_messages` messages (default 50) are fetched and exposed as `{{thread_context}}`, the agent's own lines labelled `bot`. A reply in a thread is routinely unreadable on its own. Threads only — a question asked in a channel carries its own context. Above one page of 50 the client pages through the cursor, capped at 500.

### Changed
- `RateLimitError` moves up to `AgentDaemon` so every polling client can raise the kind `Runner::Base` already treats as pacing rather than failure. `Tracker::RateLimitError` remains as a subclass; existing configs, rescues and tests are unaffected.

### Security
- A `pachca` runner requires `trigger.bot_user_id`. The agent replies into the chat it reads, so without its own id it re-ingests its own answers as new questions and loops.
- An event the runner decides not to act on is deleted too. Otherwise every answer comes back as an event authored by the bot, the author gate drops it, nothing clears it, and once `limit` of them accumulate real questions are pushed off the first page and the runner goes deaf. One bot token must therefore belong to exactly one runner.
- `trigger.allowed_users` gates authors by id. While it is empty the right to command the agent is the right to talk to the bot; the effective scope is logged in one line at startup rather than left to be inferred from the config.

## [0.14.1] - 2026-09-03

### Fixed
- The Messenger now discovers outgoing message files with either the `.yml` or `.yaml` extension, processes the combined queue in lexicographic filename order, and preserves each filename and extension when moving successfully delivered messages to `sent/`.

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
