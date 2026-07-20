# Privacy

Voice Inbox is local-first software. RSI Tech does not operate an analytics,
telemetry, transcription, or memo-storage service for this project.

## Data handled

- The Apple Watch stores the recording, capture time, locale, delivery state,
  and a random memo identifier.
- The paired Mac bridge receives the recording over authenticated local HTTPS
  and transcribes it with on-device Apple Speech recognition.
- When optional Codex Inbox delivery is enabled, the bridge sends only the
  transcript, capture time, locale, and stable memo marker to the locally
  installed Codex App Server. It does not send raw audio or its filesystem path.

Use of Codex is governed by the terms and privacy controls of the user's OpenAI
account and installed Codex software. RSI Tech cannot determine or control
whether that separate service syncs or retains submitted transcript text.

## Retention and deletion

The Watch keeps undelivered recordings until delivery succeeds or the user
deletes them. Delivered Watch audio is retained for the selected 1, 7, or 30
day period. The Mac bridge keeps a separate recoverable copy and delivery
journal for seven days. Automatic cleanup never selects unresolved material.

The bridge's `purge-delivered` command removes all verified delivered material
immediately while the service is stopped. Normal uninstall preserves state;
`uninstall --purge-data` explicitly removes the installer-owned bridge state.

## Permissions and network use

The Watch uses Microphone, local-network, and Bonjour access. The Mac bridge
uses local-network, Bonjour, and Speech Recognition access. There is no iPhone
relay and no cloud-audio fallback. Pairing requires a one-time code and manual
certificate-phrase comparison before the Watch pins the Mac identity.

Privacy or confidential project questions may be sent to
[info@rsitech.ai](mailto:info@rsitech.ai).
