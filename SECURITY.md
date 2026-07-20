# Security policy

## Watch voice and privacy boundary

The Watch recording is the durable source of truth. An interrupted or failed
upload must leave the committed `.m4a` on the Watch, and the bridge acknowledges
only after it has durably committed the authenticated body and metadata. Audio
is transcribed locally on the Mac with on-device Apple Speech recognition. The
Codex delivery adapter receives only formatted transcript text, capture time,
locale, and a stable memo marker; raw audio bytes and the local audio path are
not part of the App Server request.

The bridge is a local HTTPS service advertised over Bonjour. Pairing requires a
short-lived one-use code plus explicit comparison of the certificate phrase.
The Watch pins the confirmed public-key fingerprint, keeps the bearer/HMAC
credential in Keychain, and signs the exact method, path, timestamp, nonce,
body digest, and protocol revision. The bridge rejects stale timestamps,
replayed nonces, invalid signatures, oversized or malformed requests, and a
same-ID upload with different audio content.

Well-formed pairing redemption is limited to five attempts per minute. Requests
with a valid bearer credential are limited to 120 audio uploads per minute;
malformed or unauthenticated upload traffic cannot consume that authenticated
budget. A limited pairing response remains reason-opaque, and both limits use
bounded in-memory windows. App Server reconnect delay is exponential with
bounded jitter and never exceeds sixty seconds.

Committed audio and delivery journals use private directories, constrained file
identities, atomic replacement, and synchronization before acknowledgement.
The bridge refuses intake under its disk reserve. Delivery persists intent
before submission and reconciles the stable memo marker after ambiguous App
Server acceptance; it does not blindly resend a transcript.

Only journal-verified delivered material enters the bridge's private retention
area. Audio, its receipt, and the matching delivered journal remain recoverable
for seven days and are then removed together. Unresolved material is never
selected by automatic or explicit cleanup. The `purge-delivered` command holds
the resident service lease for the full destructive operation, and every
automatic or explicit pass shares a separate retention-maintenance lease. A
purge therefore refuses to race the running bridge or startup maintenance.
Retention failures keep data intact and emit only a content-free retry
diagnostic—never memo IDs, paths, transcripts, or audio.

Bridge diagnostics use a private descriptor-pinned service directory and
owner-only regular single-link files opened without following links.
`bridge.log` is capped at 256 KiB and retains at most the three rotated
generations `bridge.log.1` through `bridge.log.3`. Each line contains only an
integral Unix timestamp and a closed lifecycle or retention event code. The
logger has no free-form text or identifier API; write failures are ignored by
the intake, retention, and delivery paths after preserving the existing
content-free stderr fallback.

The Watch app contains no OpenAI credential. There is no iPhone relay and no
cloud-audio fallback. The background bridge owns only the App Server child it
starts and must never signal or take over a process owned by the official Codex
desktop app. Pause is a persistent kill switch; committed work remains intact.

Automated tests and `Scripts/run-watch-bridge-smoke.sh` use an ephemeral TLS
identity, loopback networking, deterministic local transcription, and a fake
Inbox. They do not create a real Codex thread or turn. Real Inbox mutation,
persistent LaunchAgent installation, Apple signing, and physical-Watch use are
separate operator-authorized gates.

The read-only `speech-status` command does not request TCC access. The operator
must run `authorize-speech` explicitly to show the macOS Speech Recognition
prompt. Denial or restriction remains a local actionable error and never
enables a cloud-transcription fallback.

The read-only `status` command does not create a lease file. Its output is a
fixed content-free projection of versions, state, listener health, Speech
authorization, and durable queue counts; it excludes paths and record identity.

## Endpoint and process safety

The bridge does not copy Codex credentials or attach to a process owned by the
official Codex app. Its supervisor may stop only the exact App Server child it
created. Paths accepted at the installation boundary are canonicalized and
validated before they are persisted or launched.

Inbox delivery is intrinsic to using the bridge. The bridge persists delivery
intent before submission, records only stable non-content identifiers in its
private journal, and reconciles an ambiguous response before retrying. A
transport interruption never causes a blind duplicate transcript submission.
Each submission starts a Codex model turn with a read-only sandbox, network
disabled, and approvals set to `never`. The message instructs the model not to
inspect files or execute the idea, but read-only sandboxing can still permit
filesystem reads and is not a technical no-tools boundary.

## Reporting a vulnerability

Use a private GitHub Security Advisory for this repository when available. If
private advisories are unavailable, email [info@rsitech.ai](mailto:info@rsitech.ai)
with a minimal synthetic reproduction first. Do not open a public issue
containing audio, transcript text, screenshots, video, a token, cookie, exact
task ID, local path, delivery journal, or raw JSON-RPC evidence. RSI Tech can
arrange a private transfer only if the redacted synthetic reproduction is
insufficient.
