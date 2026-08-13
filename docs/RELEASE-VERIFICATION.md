# Release Verification

This record separates source, downloadable package, simulator, Codex protocol,
physical Watch, and Apple distribution evidence. No row promotes another row.

| Gate | Exact scope | Result | Readiness label |
|---|---|---|---|
| Published source | `v0.1.0`, commit `636c630047893daa2c7ce691f7fffdf1267cfce9` | Exact-main hosted CI passed the Swift package, Watch simulator, production-composed bridge smoke, and packaging gates | `repo-ready` |
| Artifact tag | `v0.1.0` | Public GitHub release inspected on 2026-08-13 | `package-ready` |
| Artifact SHA-256 | `VoiceInboxBridge-0.1.0-macos-arm64.zip`: `a344c4877c7e07c3fa2a4e5130ecaaf0871d5bf4628bd75e58378dba000ce0d6` | GitHub release digest and the published checksum were verified for the exact archive | `package-ready` |
| Signing identity class | Exact `v0.1.0` bridge app; Developer ID Application | Strict code-signature verification passed on the freshly downloaded archive on 2026-08-03 | `package-ready` |
| Gatekeeper | Exact `v0.1.0` bridge app | Assessment accepted on 2026-08-03 | `package-ready` |
| Notarization | Exact `v0.1.0` bridge app | Accepted ticket observed on 2026-08-03 | `package-ready` |
| Staple | Exact `v0.1.0` bridge app | Staple validation passed on 2026-08-03 | `package-ready` |
| Codex CLI/App Server | `codex-cli 0.147.0-alpha.6.5`; `initialize` plus `thread/list`; hardening source `091808f9e49aaf0e0a93273d0f5f5f0a10f8ae77`; 2026-08-13 | Isolated empty-home smoke passed; it did not read a normal Codex home or create/read a task | `unverified` |
| Watch simulator | Apple Watch SE 3 (40 mm), watchOS 26.5; deterministic exact-runtime selection; 2026-08-13 | Named `CodexWatch` test run passed with `xcodebuild_status=0` | `simulator-proven` |
| Physical Watch | Apple Watch Ultra 2, watchOS 26.4; 2026-08-13 | Preflight returned `WATCH_TUNNEL_DISCONNECTED`; no build, install, launch, capture, or end-to-end workflow was attempted | `blocked:external` |
| App Store/TestFlight | Watch distribution signing, archive validation, metadata, privacy answers, review assets, and upload | Not performed | `unverified` |

The retained Codex result is
[`docs/evidence/codex-compatibility-20260813T111246Z-A0074CC0-E714-4A86-B4D1-0E4C2DA010E3.json`](evidence/codex-compatibility-20260813T111246Z-A0074CC0-E714-4A86-B4D1-0E4C2DA010E3.json).
It proves only the named non-mutating method on the exact version and date.
Other Codex versions remain `unverified`.

The physical gate remains fail-closed. Retry `watch-device-preflight` after the
Watch tunnel becomes connected. Provisioning, signing changes, installation,
and physical acceptance must not begin until the preflight returns `READY`.
