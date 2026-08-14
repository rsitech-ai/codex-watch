# Signal Spine Watch Experience Design

## Status

- Direction B, **Signal Spine**, was selected and visually approved in
  conversation on 2026-08-14.
- This document specifies the approved experience before implementation.
- The implementation branch is `feat/andrzej_signal_spine_watch_ui`, based on
  evidence-hardening commit `213604fb558d24edb1cd5ce29b28c6aeb8b8aee6`.
- The inherited baseline passes 578 Swift tests with zero failures.
- Concept renderings are `preview-reviewed`; no redesigned runtime screen is
  yet `simulator-proven` or `physical-watch-proven`.

## Outcome

Turn Voice Inbox from a generic stack of status capsules and controls into a
distinctive wrist-native relay instrument. A user should be able to capture a
thought immediately, understand exactly where it is in the Watch-to-Mac-to-
Codex lifecycle, and recover safely when delivery cannot advance.

The experience must feel precise, calm, and specific to this product. Its
identity comes from truthful state, asymmetric composition, and bounded motion,
not ornamental effects or invented telemetry.

## Current Audit

### Blocker

- On the baseline 40mm and 44mm simulator renders, the primary record action is
  partially below the initial viewport. The smallest supported display is a
  hard release gate; capture must never require exploratory scrolling.

### Major findings

- The bridge-status capsule dominates the capture action and truncates on the
  40mm baseline.
- The large navigation title, gray capsule, centered copy, and circular blue
  microphone form a generic Watch layout without product-specific structure.
- The repeating recording pulse is perpetual decorative motion. It does not
  communicate more truth than the elapsed-time value and costs attention and
  energy.
- Queue rows flatten materially different lifecycle phases into similar list
  cells and reuse generic symbols across multiple Codex states.
- Scaling and line-limit modifiers compensate for hierarchy rather than
  adapting the composition deliberately.

### Existing strengths to preserve

- The state model distinguishes local capture, durable Watch save, Mac receipt,
  transcription, Codex insertion, reconciliation, delivery, and recovery.
- Audio remains local and durable through recoverable failures.
- User-visible copy does not equate “saved” with “sent” or “delivered.”
- Recording start, success, and failure already have meaningful haptics.
- Permission, interruption, retry, retention, playback, and pairing flows are
  implemented and testable.

## Experience DNA

### Product truth

Voice Inbox is a relay, not a recorder with a decorative status badge. A
thought begins on the Watch, may cross to the Mac, and is complete only after
Codex insertion is confirmed.

### Signature motif

A slim vertical **Signal Spine** carries three semantic nodes:

1. **Watch** — capture and durable local save;
2. **Mac** — authenticated receipt by the bridge;
3. **Codex** — confirmed insertion and reconciliation.

The spine is a compact state visualization and persistent spatial landmark. It
is not a progress estimate. A segment or node resolves only after the model has
authoritative evidence for that phase.

### Tone

- quiet precision rather than dashboard density;
- asymmetric and instrument-like rather than centered card stacks;
- direct language rather than celebratory or anthropomorphic copy;
- one clear wrist action at a time.

## Experience Flow

### Ready

- The first node is active and labeled `Watch ready`.
- The hero reads `Capture the thought.`
- Mac status is secondary copy such as `Mac needs attention`; it never obscures
  the local capture capability.
- A fixed bottom action reads `Tap to record`.
- Recording remains tap-to-start and tap-to-stop. The concept's provisional
  press-and-hold label is explicitly rejected.

### Preparing

- The first node remains active.
- The primary label changes to `Preparing microphone`.
- The action is temporarily disabled without implying that recording began.
- If preparation fails, the state resolves to a typed failure with a recovery
  action where one exists.

### Recording locally

- Elapsed time is the dominant metric and uses monospaced digits.
- Copy states `Audio stays on this Watch`.
- The first node remains active. No later node illuminates during recording.
- The bottom action reads `Stop & save`.
- No waveform is shown unless a future implementation adds real, tested audio
  metering and its privacy/energy cost is accepted separately.

### Saving and saved on Watch

- `Saving on Watch` remains visually distinct from a durable save.
- After the store confirms persistence, the Watch node resolves as saved.
- The Mac node stays pending until authenticated receipt is confirmed.
- The user may record another thought while the saved memo waits in the relay
  ledger.

### Received and processing on Mac

- The Mac node resolves only from an authoritative bridge receipt.
- Supporting text names the actual phase: received, transcribing, ready for
  Codex, inserting, or reconciling.
- The final Codex node remains pending through all nonterminal phases.

### Delivered

- All three nodes resolve only after confirmed Codex delivery.
- The resting state reads `Delivered` and shows a confirmation time.
- The primary action becomes `Record another`.
- Success motion and haptic fire once for the transition, not on every render or
  relaunch.

### Needs attention

- The spine stops at the last confirmed node.
- Copy names the failed or blocked phase without exposing internal secrets.
- When true, the screen states `Audio is safe here`.
- The primary action is the narrowest valid recovery, such as `Retry relay` or
  `Pair with Mac`.
- Failure never animates a later node or removes unresolved audio.

## Scene Design

### Capture scene

- Replaces the large navigation-title hierarchy with an inline compact title
  and the persistent spine.
- Reserves the lower safe region for one full-width primary control.
- Keeps status, timer, and action visible together on the smallest family.
- Uses `ViewThatFits`, size-aware spacing, or explicit compact/regular variants
  rather than global downscaling.

### Relay ledger

- Reframes the queue as a chronological relay ledger.
- Each memo row shows its last confirmed phase, duration, and useful relative
  time.
- The row's node and explicit label provide redundant state encoding.
- Playback, destructive deletion, diagnostics, and retry actions remain in the
  detail or platform-native contextual affordances rather than competing in
  every row.
- Empty state returns attention to capture instead of presenting a decorative
  placeholder.

### Pairing

- Uses the spine's step vocabulary for discovery, code confirmation, and relay
  readiness.
- The one-time code uses monospaced digits with sufficient spacing.
- Certificate phrase and trust confirmation remain exact and security-relevant;
  visual simplification must not weaken them.
- Failure and expiry states keep their existing truth and recovery semantics.

### Retention and settings

- Remain recognizably platform-native and low-frequency.
- Adopt semantic color, type, and concise status language without forcing the
  full spine composition onto form controls.

## Adaptive Layout Contract

Validation covers every supported size family, with named device/runtime
evidence retained for at least the smallest, one representative, and largest
installed simulator. Size-family targets are:

| Family | Representative dimensions | Layout policy |
| --- | --- | --- |
| Compact | 40, 41, and 42mm | Two-line hero, shortest truthful copy, fixed action above fold |
| Standard | 44, 45, and 46mm | Larger timer and moderate explanatory copy |
| Ultra | 49mm | More context and breathing room, never a uniform scale-up |

For every supported installed simulator destination:

- no primary action is clipped or initially offscreen;
- no status truncates into ambiguity;
- navigation, Digital Crown scrolling, and tap targets remain usable;
- dynamic type and accessibility settings do not overlap critical content;
- screenshots identify device name, logical size, runtime, source commit, and
  state fixture.

## Visual System

### Color

- **Cyan:** current active phase or primary capture action.
- **Lime:** authoritative completion.
- **Amber:** recoverable wait or attention state.
- **Red:** destructive action or terminal failure, never ordinary recording
  emphasis by itself.
- **Neutral:** pending phases and supporting content.

Color is always redundant with text, iconography, node shape/fill, or position.
The implementation uses semantic tokens rather than scattered literal values.

### Typography

- System rounded/display typography for short state and action language.
- Monospaced digits only for elapsed time and pairing codes.
- Compact labels are uppercase only when short and nonessential to continuous
  reading.
- Minimum-scale modifiers are a last resort, not the primary adaptation tool.

### Shape and depth

- The spine and nodes are the primary geometry.
- Full-width primary controls use a compact rounded rectangle, not another
  oversized circle competing with the state visualization.
- Depth remains restrained and compatible with Reduce Transparency and
  Increase Contrast.

## Motion and Haptics

### Principles

- Motion explains cause, destination, or confirmed state change.
- Every animation is bounded and reaches rest.
- The idle screen has no perpetual animation.
- Haptics reinforce meaningful state changes and are not used as decoration.

### Motion contract

- Recording start: one approximately 180ms node ignition and the existing start
  haptic.
- Confirmed phase advance: one approximately 240ms spine-segment draw after the
  authoritative model transition.
- Delivery: one restrained terminal-node/check transition plus success haptic.
- Failure: immediate state change plus failure haptic; no shaking or repeated
  warning pulse.
- Elapsed time updates must not trigger whole-scene layout or animation churn.

### Reduce Motion and Always On

- Reduce Motion replaces travel and drawing with an immediate state swap while
  preserving copy, icon, color redundancy, and haptic semantics.
- Always On shows only non-sensitive state, elapsed duration when appropriate,
  and a dimmed spine. It never exposes transcript text or memo content.
- The implementation must not create an independent high-frequency timeline
  solely for decorative rendering.

## Accessibility

- VoiceOver order follows state, essential detail, primary action, then
  secondary navigation.
- The three visual nodes expose a concise combined accessibility value such as
  `Saved on Watch; waiting for Mac` rather than three unlabeled controls.
- Decorative line segments are hidden from accessibility.
- Tap targets meet platform guidance and remain separated on compact displays.
- Differentiate Without Color, Increase Contrast, Reduce Transparency, Reduce
  Motion, bold text, and larger accessibility text receive explicit simulator
  review.
- The design does not require precision gestures, press-and-hold, or motion to
  understand progress.

## Architecture

Keep the existing state and persistence model authoritative. The redesign adds
presentation components and pure mapping logic rather than parallel workflow
state.

Expected boundaries:

- a pure presentation mapper converts capture, bridge, and memo states into
  node phases, semantic tone, primary action, and accessibility copy;
- reusable `SignalSpine`, node, primary action, and elapsed-time components are
  stateless or bind only to minimal presentation values;
- scene containers own layout adaptation and navigation;
- `VoiceCaptureModel`, `WatchMemoStore`, and transfer coordinators continue to
  own workflow truth and side effects;
- animation triggers derive from stable semantic transitions, not view
  appearance or timer ticks.

No external dependency is required.

## Test Strategy

Implementation follows red-green-refactor.

### Pure presentation tests

- every capture state maps to exact headline, detail, primary action, and spine
  phase;
- every bridge and memo state maps to the last authoritative node only;
- saved-on-Watch never maps to Mac receipt or delivery;
- received, transcribing, inserting, and reconciling never map to delivered;
- needs-attention output preserves the last confirmed phase and the correct
  recovery action;
- accessibility summaries are content-free and truthful.

### View and interaction tests

- tap-to-start, tap-to-stop, permission denial, interruption, save failure,
  retry, playback, pairing, retention, and destructive confirmation;
- success motion/haptic fires once per semantic transition;
- timer changes do not restart node or spine animation;
- Reduce Motion chooses the nontravel transition path;
- VoiceOver labels, values, traits, and focus order are meaningful.

### Render matrix

Capture deterministic screenshots for ready, recording, saved-on-Watch,
delivered, needs-attention, queue, and pairing states across compact, standard,
and Ultra families. At minimum retain the smallest hard gate, one representative
device, and the largest device. Exercise all installed supported logical sizes
and record any missing simulator family as `unverified`, not passed.

### Regression and runtime proof

- focused Watch unit tests;
- full Swift package suite;
- generic watchOS simulator build-for-testing;
- named simulator install and launch;
- restart and state-restoration smoke;
- runtime screenshots with exact source commit and simulator metadata;
- physical Watch capture, haptics, energy, Always On, and paired-device behavior
  only when the physical preflight reports `READY`.

## Evidence Labels and Completion Bar

- `source-inspected`: implementation and mappings reviewed.
- `preview-reviewed`: concept or Xcode preview reviewed.
- `simulator-proven`: named state ran on a named simulator/runtime.
- `physical-watch-proven`: named workflow ran on the identified physical Watch.
- `unverified`: required proof was not performed.
- `blocked:external`: external device services prevent proof, with exact next
  action recorded.

Implementation is complete only when:

1. the smallest supported screen shows the primary capture action without
   scrolling or clipping;
2. truth-mapping tests cover all reachable workflow states;
3. motion is bounded and has a Reduce Motion alternative;
4. the render matrix passes for every available supported size family;
5. the full inherited regression suite remains green;
6. runtime evidence is retained and labeled without promoting simulator proof
   to physical Watch proof.

Physical-device gates remain separate. Simulator success must not be described
as microphone, haptic, energy, Always On, or end-to-end paired-device proof.

## Non-Goals

- Adding fabricated audio waveforms, sensor telemetry, network percentage, or
  probabilistic progress.
- Reworking bridge protocol, persistence, transcription, or Codex delivery
  semantics.
- Adding a cloud audio path.
- Adopting an iOS-version-specific visual material that would raise the current
  watchOS 10 deployment target.
- Publishing, pushing, opening a pull request, or claiming physical-device
  readiness.

## Rollback

The redesign remains presentation-layer work on an isolated branch. Retain the
existing state model and side-effect boundaries so individual scenes can be
reverted without migrating stored memos or credentials. If a new scene fails a
smallest-size, accessibility, truth, or performance gate, restore the previous
scene while keeping independently proven presentation mappings and tests.
