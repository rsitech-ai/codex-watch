## Learned User Preferences
- Prefer completing Watch pairing, Mac bridge install, and Watch-to-Mac delivery rather than handing back a walkthrough when asked to make it work.
- Keep draft PR #4 unmerged and not marked ready until physical Watch acceptance actually passes; simulator and CI green is not enough.
- Want one user-facing macOS companion: the existing VoiceInboxBridge binary branded **Codex Watch** (with a space), pairing/Speech/transcription/inbox, Signal Spine Watch visual language, hierarchy-first polish rather than extra glass; not a second daemon or `/tmp` sidecar.
- Treat hardware status only as `physical-watch-proven`, `blocked:external`, or `unverified`.
- Do not mint or rotate TLS certificates (that unpairs the Watch); reuse the live identity. Mac Reset may regenerate the pairing challenge and retry mailbox but must not wipe Watch Keychain from the Mac.
- Codex delivery copy must stay honest: local App Server Inbox, not ChatGPT.app; never invent Codex progress.
- The Mac window should show live operator status (bridge, Watch, Speech, memo pipeline) with an in-app Speech CTA when authorization is not determined.

## Learned Workspace Facts
- This worktree is `feat/andrzej_signal_spine_watch_ui` for rsitech-ai/codex-watch; hardware gating follows `docs/PHYSICAL-WATCH-ACCEPTANCE.md`.
- Watch app bundle ID is `ai.rsitech.voiceinbox`; physical install targets Apple Watch Ultra 2 and needs the companion iPhone CoreDevice tunnel held, or preflight stays `SUPPORTING_PHONE_UNAVAILABLE`.
- Mac intake is LaunchAgent `ai.rsitech.voiceinbox.bridge` advertising Bonjour `_voiceinbox._tcp` as **Codex Watch**; the installed UI+listener is `$HOME/Library/Application Support/VoiceInboxBridge/Service/VoiceInboxBridge.app` (same signed binary as the agent). Leave legacy `com.rsitech.codex-watch-bridge` on loopback alone; do not use `/tmp` sidecars.
- Pairing credentials live in Watch Keychain; Mac cannot inject them, so phrase and PIN must be entered on-wrist.
- Unpaired idle, saved, and interrupted home should show labeled **Pair with Mac**, not only an unlabeled computer icon.
- Watch UI must not treat `needsAttention` as unpaired unless copy is **Pair again**; that falsely claimed saved audio would stay only on the Watch after pairing.
- Speech TCC is per code signature; Codex transcription stays blocked until macOS Speech authorization is determined on the installed app, not a sidecar UI.
- Codex insert is a local App Server Inbox thread named Codex Watch, not ChatGPT.app (unverified).
- Swift package tests stay partitioned so PKCS#12 security fixtures do not exhaust process-local macOS state; use `Scripts/run-swift-package-tests.sh` rather than a single full `swift test`.
