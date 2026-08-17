# Changelog

All notable public releases are documented here.

## Unreleased

### Added

- User-facing macOS CodexWatch window and menu bar for pairing, Speech
  authorization, inbox status, and operator retry. The LaunchAgent still owns
  the listener; opening the app does not start a second daemon.

## 0.1.0 - 2026-07-20

### Added

- Standalone Apple Watch voice capture with a durable local queue.
- Authenticated local transfer to a headless macOS bridge.
- Local Apple Speech transcription with no cloud-audio fallback.
- Durable, exactly-once-oriented Codex Inbox delivery and recovery boundaries.
- Transactional per-user bridge installation, pause, status, and uninstall.
- Apache-2.0 licensing, public CI, and signed bridge release packaging.
