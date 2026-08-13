# Physical Watch Preflight Evidence — 2026-08-13

- Source commit: `4a809fedd8051147a4f307762b2edd59cc6cb33e`
- Public Watch model: Apple Watch Ultra 2
- Watch OS: watchOS 26.4
- Pairing: paired
- Developer Mode: enabled
- Watch boot state: booted
- Watch tunnel: disconnected
- Watch developer disk-image services: unavailable
- Supporting phone: iPhone 15 on iOS 26.5
- Supporting phone path: paired, booted, wired tunnel connected, developer
  services available
- Preflight result: `WATCH_TUNNEL_DISCONNECTED`
- Command exit: 2
- Readiness label: `blocked:external`

The read-only preflight reproduced the device-service boundary without calling
Xcode or changing pairing, Developer Mode, registration, profiles, certificates,
or services. Earlier bounded physical `xcodebuild` attempts timed out before
provisioning and reported that the Watch might need to be unlocked to recover
from a previous preparation error. Restarting and unlocking the Watch and using
the wired developer-ready supporting phone did not establish the Watch tunnel.
No Voice Inbox application defect has been demonstrated at this boundary.

## Exact next action

Retry the read-only preflight after an Apple/Xcode/CoreDevice update or after
the Watch tunnel becomes connected. Do not run signing, provisioning, physical
build, install, or workflow acceptance until the preflight returns `READY`.
