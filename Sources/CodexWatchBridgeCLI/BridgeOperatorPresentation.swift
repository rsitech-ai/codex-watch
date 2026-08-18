import CodexBridgeService
import Darwin
import Foundation

struct BridgeOperatorStatusPresentation: Equatable {
    let loaded: String
    let healthy: String
    let listening: String
    let bonjourInstance: String
    let tlsFingerprintShort: String
    let launchAgentPID: String
    let lastError: String
    let watchPaired: String
    let lastIntake: String
    let lastUploadAttempt: String
    let queueDepth: String
    let speech: String
    let speechNeedsCTA: Bool
    let bindUnreachable: Bool
    let currentHost: String
    let specEngine: String
    let headline: String
    let detail: String

    static func make(
        loaded: Bool,
        healthy: Bool,
        bindHost: String,
        advertisedHost: String,
        currentHosts: [String],
        fingerprint: String?,
        launchAgentPID: pid_t?,
        lastEvent: BridgeDiagnosticEvent?,
        watchPaired: Bool,
        lastIntake: Date?,
        speech: BridgeSpeechAuthorizationStatus,
        foundationModels: FoundationModelsAvailability,
        now: Date = Date()
    ) -> Self {
        let unreachable = WatchReachableAddress.bindLooksUnreachable(
            bindHost: bindHost,
            currentHosts: currentHosts
        )
        let currentHost = currentHosts.isEmpty ? "unknown" : currentHosts.joined(separator: ", ")
        let listening: String
        if unreachable {
            listening = "Bound to \(bindHost) — not on this Mac"
        } else if loaded {
            listening = bindHost == "—" ? "Listening" : "Listening on \(bindHost)"
        } else {
            listening = "Not listening"
        }
        let error: String
        switch lastEvent {
        case .serviceFailed:
            error = "Listener failed and is retrying."
        case .retentionMaintenanceFailed:
            error = "Retention maintenance failed."
        case .servicePaused:
            error = "Listener is paused."
        case .none, .serviceStarting, .serviceRunning, .retryScheduled, .serviceStopped:
            error = "None"
        }
        let specEngine: String
        switch foundationModels {
        case .available:
            specEngine = "Foundation Models, then Codex App Server, then local wrapper"
        case let .unavailable(reason):
            specEngine = "Foundation Models unavailable. \(reason) Codex App Server, then local wrapper."
        }
        let headline: String
        let detail: String
        if unreachable {
            headline = "Watch cannot reach this Mac."
            detail = "The listener is bound to \(bindHost). This Mac’s current address is \(currentHost). Use the current address so Watch uploads can land."
        } else {
            headline = loaded && healthy ? "Bridge is listening." : "Bridge is not ready."
            detail = listening
        }
        return Self(
            loaded: loaded ? "Loaded" : "Not loaded",
            healthy: healthy ? "Healthy" : "Not healthy",
            listening: listening,
            bonjourInstance: CodexWatchBrand.productName,
            tlsFingerprintShort: shortFingerprint(fingerprint),
            launchAgentPID: launchAgentPID.map(String.init) ?? "unknown",
            lastError: error,
            watchPaired: watchPaired ? "Paired on this Mac" : "Not paired",
            lastIntake: lastIntake.map { relative($0, now: now) } ?? "None on this Mac",
            lastUploadAttempt: "Unknown from this Mac",
            queueDepth: "Unknown — Watch queue is not visible from this Mac",
            speech: BridgeSpeechCopy.menuStatus(for: speech),
            speechNeedsCTA: speech != .authorized,
            bindUnreachable: unreachable,
            currentHost: currentHost,
            specEngine: specEngine,
            headline: headline,
            detail: detail
        )
    }

    private static func shortFingerprint(_ value: String?) -> String {
        guard let value, value.utf8.count >= 8 else { return "unknown" }
        return String(value.prefix(8))
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct BridgeResetPlan: Equatable {
    let regeneratesPairingChallenge: Bool
    let canForgetDisplayedPairing: Bool
    let clearsRetryMailbox: Bool
    let wipesWatchKeychain: Bool
    let rotatesTLS: Bool
    let factoryResetsDevices: Bool

    static let `operator` = Self(
        regeneratesPairingChallenge: true,
        canForgetDisplayedPairing: true,
        clearsRetryMailbox: true,
        wipesWatchKeychain: false,
        rotatesTLS: false,
        factoryResetsDevices: false
    )
}

enum BridgeResetGate {
    static func allow(_ confirmed: Bool) -> Bool { confirmed }
}

enum BridgeResetCopy {
    static let confirmTitle = "Reset operator state?"
    static let message = """
    This regenerates the pairing code on this Mac and clears queued retries. It does not wipe the Watch Keychain, rotate TLS, or factory-reset devices.
    """
    static let confirm = "Reset"
    static let confirmAndForget = "Reset and forget displayed pairing"
    static let cancel = "Cancel"
}

struct MemoPipelineStagePresentation: Equatable {
    let label: String
    let state: BridgeSpineNodeState
    let detail: String
}

enum MemoPipelinePresentation {
    static func stages(
        item: MacInboxItem,
        speech: BridgeSpeechAuthorizationStatus
    ) -> [MemoPipelineStagePresentation] {
        let transcript = item.transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTranscript = transcript.map { !$0.isEmpty } ?? false
        let transcribe: (BridgeSpineNodeState, String)
        if hasTranscript {
            transcribe = (.confirmed, "Local transcript is on this Mac.")
        } else if speech != .authorized {
            transcribe = (.attention, BridgeSpeechCopy.blockedDetail(for: speech))
        } else if item.state == .transcribing {
            transcribe = (.active, "Processing locally on this Mac.")
        } else if item.state == .needsAttention {
            transcribe = (.attention, "Transcription did not finish.")
        } else {
            transcribe = (.pending, "Waiting for a local transcript.")
        }

        let spec: (BridgeSpineNodeState, String)
        if let provenance = item.specProvenance, item.specMarkdown?.isEmpty == false {
            spec = (.confirmed, MemoSpecCopy.provenanceLabel(provenance))
        } else if hasTranscript {
            spec = (.pending, "No spec yet. Local wrapper can still be saved after a retry.")
        } else {
            spec = (.pending, "Spec waits on a transcript.")
        }

        let inbox: (BridgeSpineNodeState, String)
        switch item.state {
        case .delivered:
            inbox = (.confirmed, "Saved to this Mac’s local Codex Inbox thread.")
        case .inserting, .reconciling:
            inbox = (.active, "Submitting or confirming the local Inbox item.")
        case .readyForCodex:
            inbox = (.pending, "Transcript is local. Codex insertion has not been confirmed.")
        default:
            inbox = (.pending, "Local Codex Inbox is waiting.")
        }

        return [
            .init(label: "Watch saved", state: .confirmed, detail: "The recording exists far enough to appear here."),
            .init(
                label: "Upload",
                state: item.audioIsPresent ? .confirmed : .pending,
                detail: item.audioIsPresent ? "Audio reached this Mac." : "This Mac has not recorded receipt."
            ),
            .init(
                label: "Intake",
                state: .confirmed,
                detail: "Durable intake is on this Mac."
            ),
            .init(label: "Transcribe", state: transcribe.0, detail: transcribe.1),
            .init(label: "Spec", state: spec.0, detail: spec.1),
            .init(label: "Local Codex Inbox", state: inbox.0, detail: inbox.1),
        ]
    }
}
