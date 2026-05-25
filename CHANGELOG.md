# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

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
