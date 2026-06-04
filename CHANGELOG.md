# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

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
