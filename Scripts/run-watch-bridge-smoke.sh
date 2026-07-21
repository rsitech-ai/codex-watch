#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"

# This smoke is intentionally local-only. It composes the production TLS
# listener, router, durable replay/intake/delivery/final-status stores,
# bounded intake processor admission/rescan, completion publication, retained
# archival, Watch coordinator/store, local deterministic transcription, and a
# fake Inbox. It exercises restart,
# ambiguous acceptance, authoritative absence, replay, status recovery,
# corrupt or contradictory terminal truth, final-ack loss, terminal-capacity
# rejection before intake, and durable-intake admission after terminal
# reservation persistence failure. It never launches or mutates a real Codex
# App Server.
swift test \
  --package-path "$repo_root" \
  --no-parallel \
  --filter 'production(ArchiveStatus|TimeoutAfterPossible|AuthoritativeZero|ReplayAfterBridge|Status404|CorruptFinalStatus|ContradictoryDualStatusTruth|FinalAckLoss|TerminalReceiptCapacity|ReservationCommitFailure)'
