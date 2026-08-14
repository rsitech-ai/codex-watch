# Signal Spine Watch Simulator Evidence — 2026-08-14

## Proven scope

- Readiness: `repo-ready` and `simulator-proven` for the seven deterministic
  Watch scenes on every installed supported display size. Physical Watch proof
  remains `blocked:external` and is not implied by this document.
- UI source commit: `0166cb13af9e6d6319cacbb6671086efce717eef` on
  `feat/andrzej_signal_spine_watch_ui`, based on `213604fb`.
- Toolchain: Xcode 26.6 (17F113), watchOS Simulator SDK/runtime 26.5.
- Public destinations: Apple Watch SE 3 (40 mm), Apple Watch Series 11
  (42 mm), Apple Watch SE 3 (44 mm), Apple Watch Series 11 (46 mm), and
  Apple Watch Ultra 3 (49 mm). Device identifiers are intentionally omitted.

## Rendered matrix

The capture contains 35 content-free PNGs: `ready`, `recording`,
`savedOnWatch`, `delivered`, `needsAttention`, `queue`, and `pairing` on each
of the five sizes. The manifest contains one row per matrix cell and a SHA-256
for every PNG. All 35 hashes were independently recomputed and matched.

- Evidence directory:
  `/Users/s1kor/.codex/visualizations/2026/08/14/signal-spine-0166cb1/`
- Manifest: `manifest.tsv` in that directory.
- Capture command: `Scripts/capture-watch-ui-evidence.sh` with the exact Debug
  app and a new empty output directory.

Visual review covered clipping, truncation, rounded corners/system time,
primary actions, state shape plus color, private content, and fabricated data.
The first matrix exposed compact kicker/detail truncation and a malformed TSV
separator. Those defects were repaired and the complete matrix was recaptured.
The retained matrix has no observed clipping or ellipsis in the core capture
states. Queue and pairing remain intentionally scrollable; their initial
viewport presents the current state and first meaningful control without
inventing progress.

## Fresh verification

| Check | Result |
| --- | --- |
| Swift package suite | 582 tests in 11 suites, 0 failures |
| Watch app suite, exact 40 mm watchOS 26.5 destination | 72 tests, 0 failures |
| Debug generic watchOS Simulator build-for-testing | Passed |
| Release generic watchOS Simulator build | Passed |
| Dynamic screenshot shell contract | Passed; 35 fixture images |
| Perpetual-motion source scan | Empty |
| Manifest verification | 35/35 SHA-256 values matched |

The name-only 40 mm Xcode destination became ambiguous after watchOS 27.0
simulators were installed. Final Watch tests therefore used the selector-
resolved watchOS 26.5 destination identifier. This is an environment command
hardening requirement, not an application failure.

## Accessibility evidence and gaps

- Proven in code/tests: the Signal Spine exposes one combined delivery-path
  accessibility element; node states use distinct shapes as well as color;
  motion is bounded and becomes immediate under Reduce Motion; reduced-
  luminance privacy presentation preserves the essential state/action.
- Render-proven: the fixed primary action and essential state fit the normal
  40–49 mm matrix.
- Unverified at runtime: largest accessibility text, Bold Text, VoiceOver
  reading/focus order, Increase Contrast, Differentiate Without Color, Reduce
  Transparency, and Reduce Motion. `simctl ui` reports both `content_size` and
  `increase_contrast` as `unsupported` for the selected watchOS 26.5
  simulators; the other settings were not controllable through the retained
  automation. These require manual physical-Watch observation.

## Physical gate

Fresh `watch-device-preflight` returned
`blocked:external / SUPPORTING_PHONE_UNAVAILABLE` for the public model Apple
Watch Ultra 2 on watchOS 26.4; Watch lock state was unobserved. No signed build,
install, launch, microphone, haptic, Always On, or end-to-end relay claim was
made. Hardware work may resume only after the paired iPhone is visible to
Xcode/devicectl and preflight returns `READY`.

## Risks and next checks

1. Run the physical acceptance checklist with disposable synthetic speech once
   preflight is `READY`; retain only privacy-reviewed, content-free evidence.
2. Exercise VoiceOver, largest text, Bold Text, contrast, transparency,
   differentiate-without-color, and Reduce Motion on 40 mm and 49 mm hardware.
3. Verify cold launch, restart persistence, microphone denial/recovery,
   pairing, local relay acknowledgement, playback, deletion, and retention
   without promoting any row that was not observed.
4. Keep selector-resolved exact-runtime destinations in automation; duplicate
   simulator names make name-only Xcode commands nondeterministic.
