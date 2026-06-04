# CLAUDE.md

This file provides guidance to Code Agents when working with code in this repository.

## What this is

`agent_daemon` is a packaged Ruby gem: a daemon that orchestrates CLI AI agents (Claude Code, OpenCode). It runs one thread per configured runner, each with a trigger (Yandex Tracker query or file polling), a backend, and a prompt template, plus one Messenger thread that delivers webhook notifications. **Stdlib only — no runtime gem dependencies.** Do not add gems to the runtime path; `minitest`/`rake` are dev-only.

## Commands

```bash
bundle install
rake test                                   # full suite
ruby -Ilib -Itest test/test_config_defaults.rb   # single test file
bin/agent-daemon config.yml                 # run the daemon against a config
gem build agent_daemon.gemspec              # build the gem
```

There is no linter configured. Tests are Minitest (`test/test_*.rb`), no spec DSL.

## Architecture

Read `docs/architecture.md` first — it is the authoritative design reference. Key points that span multiple files:

- **Threads communicate only through the filesystem.** Runners write YAML files into `message_dir`; the Messenger polls that same directory and POSTs them to the webhook. There is no in-process queue or shared mutable state between runners.
- **`ShutdownFlag` (`daemon.rb`) is an intentionally mutex-free boolean.** It relies on MRI's GIL for atomic read/write. Every long loop (runner iteration, backend select-loop, `wait_interval`) polls it ~every 1s (0.5s in the backend) so shutdown is cooperative. Don't add locking around it or introduce blocking sleeps that ignore it.
- **Runner inheritance:** `Runner::Base` owns the poll → process → attempt-tracking loop. Subclasses (`Runner::Tracker`, `Runner::File`) implement only `fetch_work_items`, `work_item_key`, `render_prompt`, plus optional `after_success/after_failure/after_killed/after_exhausted` hooks. Add new trigger types here and wire them in `Daemon#runner_factory_for`.
- **Backend factory:** `Backend.for(...)` dispatches on the `backend` config key. Backends run the CLI via `Open3.popen3` with `pgroup: true` and return a `Result` with `reason` ∈ `:ok | :failed | :timeout | :killed`. On timeout/shutdown the whole process group gets `SIGTERM` then `SIGKILL` after 2s.
- **Two independent failure counters:** per-item attempts (`max_attempts`, default 3 → `after_exhausted`) vs. consecutive *trigger* errors (`MAX_CONSECUTIVE_ERRORS` = 3 → writes a `SYSTEM:<runner>` error YAML to `message_dir` for the Messenger to notify). `:killed` results roll the attempt counter back (shutdown is not a failure).
- **Crash recovery:** `Daemon#monitor_threads` restarts any thread that died with `Thread.current[:crashed]` after `RESTART_DELAY` (60s).

## Config (`config.rb`)

Loaded from a YAML path (CLI arg to `bin/agent-daemon`). Config is validated eagerly in the constructor and raises `ConfigError` with all problems collected — preserve this fail-fast behavior. Note the path-resolution rules, which are easy to get wrong:

- `message_dir`, `output_dir`, and file-trigger `input_dir/archive_dir/failed_dir` resolve relative to **`project_path`**.
- `prompt_template` resolves relative to the **config file's directory**, and the resolved value is stored as `prompt_template_path` (this is the key the runner reads, not `prompt_template`).
- Defaults live in `DEFAULTS` / `RUNNER_DEFAULTS` / trigger default constants; new config keys should get a default there and validation in `validate!`.

The config file is rendered through ERB before YAML parsing (`read → ERB.result(binding) → safe_load`), so secrets can come from the environment via `<%= secret('KEY') %>` (fail-fast + `.to_json` YAML-safe quoting) or raw `<%= ENV['KEY'] %>` (lenient). Render-time failures are wrapped as `ConfigError`. The daemon stays sops-agnostic — operators populate `ENV` themselves (e.g. `sops exec-env secrets.enc.yml -- bin/agent-daemon config.yml`). See `docs/secrets.md`.

`examples/config.yml` is a fully commented reference.

## Prompt templates

`{{variable}}` substitution. Variables come from: every key in the runner config hash, plus `message_dir`, optional `output_dir`, and trigger-runtime vars (`task_key` for tracker, `input_file` for file). Undefined `{{...}}` stay literal and log a warning — intentional, don't make them raise.

## Conventions

- All files use `# frozen_string_literal: true`.
- This is a published gem — bump `lib/agent_daemon/version.rb` and update `CHANGELOG.md` for releases.
