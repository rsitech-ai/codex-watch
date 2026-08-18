# Changelog

All notable public releases are documented here.

## Unreleased

### Changed

- Protocol and on-disk identity is now Codex Watch: bundle IDs
  `ai.rsitech.codexwatch` / `ai.rsitech.codexwatch.bridge`, Bonjour
  `_codexwatch._tcp`, LaunchAgent `ai.rsitech.codexwatch.bridge`, Application
  Support `CodexWatch/`, `CodexWatch.app`, and TLS CN **Codex Watch**. Existing
  Watch pairing and Speech TCC for the old signature are invalidated; re-pair
  on-wrist. Do not wipe Watch Keychain from the Mac.

### Added

- User-facing macOS Codex Watch window and menu bar for pairing, Speech
  authorization, inbox status, and operator retry. The LaunchAgent still owns
  the listener; opening the app does not start a second daemon. Retry of a
  stalled memo transcribes in the window that already has Speech permission
  when the installed listener is an older binary that ignores the retry mailbox.
  Ready-for-Codex memos can retry Inbox insert without re-transcribing.
  Delivered copy names the local Codex Inbox thread, not the ChatGPT app.
- After a local Speech transcript, Codex Watch writes a markdown spec next to
  the delivery journal (`*.spec.md`). Codex App Server can improve it; otherwise
  the file is an unverified local wrapper. The window can save `.md` or `.html`.
  Inbox insert uses the App Server spec when improvement succeeds, and still
  names local Inbox rather than ChatGPT.app.

## 0.1.0 - 2026-07-20

### Added

- Standalone Apple Watch voice capture with a durable local queue.
- Authenticated local transfer to a headless macOS bridge.
- Local Apple Speech transcription with no cloud-audio fallback.
- Durable, exactly-once-oriented Codex Inbox delivery and recovery boundaries.
- Transactional per-user bridge installation, pause, status, and uninstall.
- Apache-2.0 licensing, public CI, and signed bridge release packaging.
