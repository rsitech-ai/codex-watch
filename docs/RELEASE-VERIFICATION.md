# Release Verification

This record separates source, downloadable package, simulator, Codex protocol,
physical Watch, and Apple distribution evidence. No row promotes another row.

| Gate | Exact scope | Result | Readiness label |
|---|---|---|---|
| Published source | `v0.1.0`, commit `636c630047893daa2c7ce691f7fffdf1267cfce9` | Exact-main hosted CI passed the Swift package, Watch simulator, production-composed bridge smoke, and packaging gates | `repo-ready` |
| Candidate source | `feat/andrzej_signal_spine_watch_ui`, commit `c8f0bc3d75b4af0d0fe5022a8bf28c8b76fee716` | 585 package tests, 75 Watch tests, fresh Release build, analyzer, 35-cell render matrix, bridge restart smoke, and clean capture-window logs passed locally; physical tunnels remain disconnected | `repo-ready`; `simulator-proven`; hardware `blocked:external` |
| Artifact tag | `v0.1.0` | Public GitHub release inspected on 2026-08-13 | `package-ready` |
| Artifact SHA-256 | `VoiceInboxBridge-0.1.0-macos-arm64.zip`: `a344c4877c7e07c3fa2a4e5130ecaaf0871d5bf4628bd75e58378dba000ce0d6` | GitHub release digest and the published checksum were verified for the exact archive | `package-ready` |
| Signing identity class | Exact `v0.1.0` bridge app; Developer ID Application | Strict code-signature verification passed on the freshly downloaded archive on 2026-08-03 | `package-ready` |
| Gatekeeper | Exact `v0.1.0` bridge app | Assessment accepted on 2026-08-03 | `package-ready` |
| Notarization | Exact `v0.1.0` bridge app | Accepted ticket observed on 2026-08-03 | `package-ready` |
| Staple | Exact `v0.1.0` bridge app | Staple validation passed on 2026-08-03 | `package-ready` |
| Codex CLI/App Server | `codex-cli 0.148.0-alpha.9`; `initialize` plus `thread/list`; source `c8f0bc3d75b4af0d0fe5022a8bf28c8b76fee716`; 2026-08-14 | Isolated empty-home smoke passed with a replaced child environment and bounded concurrent output drains; it did not read a normal Codex home or create/read a task | `unverified` |
| Watch simulator | 40, 42, 44, 46, and 49 mm watches on watchOS 26.5; deterministic exact-runtime selection; 2026-08-14 | 75 Watch tests passed on 40 mm and 35/35 final render hashes matched across all five sizes | `simulator-proven` |
| Physical Watch | Apple Watch Ultra 2, watchOS 26.4; 2026-08-14 | Watch and iPhone were visible, paired, and Developer Mode enabled, but both CoreDevice tunnels were disconnected; preflight returned `SUPPORTING_PHONE_UNAVAILABLE`; no signed build, install, or workflow was attempted | `blocked:external` |
| App Store/TestFlight | Watch distribution signing, archive validation, metadata, privacy answers, review assets, and upload | Not performed | `unverified` |

The latest retained Codex result is
[`docs/evidence/codex-compatibility-20260814T100145Z-8EE1612B-244E-42DF-90B6-5E64EDD3ECAD.json`](evidence/codex-compatibility-20260814T100145Z-8EE1612B-244E-42DF-90B6-5E64EDD3ECAD.json).
It proves only the named non-mutating method on the exact version and date.
Other Codex versions remain `unverified`.

The physical gate remains fail-closed. Retry `watch-device-preflight` after the
Watch tunnel becomes connected. Provisioning, signing changes, installation,
and physical acceptance must not begin until the preflight returns `READY`.
