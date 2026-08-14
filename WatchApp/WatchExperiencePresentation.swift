import CodexBridgeShared
import CodexWatchCore

enum WatchExperienceTone: Equatable {
    case neutral
    case active
    case confirmed
    case attention
    case destructive
}

enum SignalNodeVisualState: Equatable {
    case pending
    case active
    case confirmed
    case attention
}

struct SignalSpinePresentation: Equatable {
    let watch: SignalNodeVisualState
    let mac: SignalNodeVisualState
    let codex: SignalNodeVisualState
    let accessibilityValue: String
}

enum WatchPrimaryAction: Equatable {
    case record
    case stopAndSave
    case openPairing
    case retryRelay
    case recordAnother
    case none
}

struct CaptureScenePresentation: Equatable {
    let kicker: String
    let headline: String
    let detail: String
    let tone: WatchExperienceTone
    let spine: SignalSpinePresentation
    let primaryAction: WatchPrimaryAction
    let showsElapsedTime: Bool
    let primaryActionDisabled: Bool

    static func make(
        captureState: WatchCaptureState,
        bridgeState: WatchBridgeConnectionState
    ) -> Self {
        switch captureState {
        case .idle:
            return Self(
                kicker: "Watch ready",
                headline: "Capture the thought.",
                detail: bridgeDetail(bridgeState),
                tone: .active,
                spine: localSpine(
                    watch: .active,
                    accessibilityValue: "Watch ready; \(bridgeAccessibility(bridgeState)); Codex pending"
                ),
                primaryAction: .record,
                showsElapsedTime: false,
                primaryActionDisabled: false
            )
        case .preparing:
            return Self(
                kicker: "Preparing",
                headline: "Preparing microphone",
                detail: "Keep Voice Inbox open",
                tone: .active,
                spine: localSpine(
                    watch: .active,
                    accessibilityValue: "Preparing microphone on Watch; Mac pending; Codex pending"
                ),
                primaryAction: .none,
                showsElapsedTime: false,
                primaryActionDisabled: true
            )
        case .recording:
            return Self(
                kicker: "Recording",
                headline: "Recording",
                detail: "Audio stays on this Watch",
                tone: .active,
                spine: localSpine(
                    watch: .active,
                    accessibilityValue: "Recording on Watch; Mac pending; Codex pending"
                ),
                primaryAction: .stopAndSave,
                showsElapsedTime: true,
                primaryActionDisabled: false
            )
        case .saving:
            return Self(
                kicker: "Saving on Watch",
                headline: "Saving securely",
                detail: "Keep Voice Inbox open",
                tone: .active,
                spine: localSpine(
                    watch: .active,
                    accessibilityValue: "Saving on Watch; Mac pending; Codex pending"
                ),
                primaryAction: .none,
                showsElapsedTime: false,
                primaryActionDisabled: true
            )
        case .savedOnWatch:
            return Self(
                kicker: "Saved on Watch",
                headline: "Thought secured.",
                detail: "Waiting for your Mac bridge",
                tone: .confirmed,
                spine: localSpine(
                    watch: .confirmed,
                    accessibilityValue: "Saved on Watch; waiting for Mac"
                ),
                primaryAction: .recordAnother,
                showsElapsedTime: false,
                primaryActionDisabled: false
            )
        case .permissionDenied:
            return Self(
                kicker: "Microphone access needed",
                headline: "Enable microphone.",
                detail: "Allow microphone access in Watch Settings",
                tone: .attention,
                spine: localSpine(
                    watch: .attention,
                    accessibilityValue: "Microphone permission needed on Watch; Mac pending; Codex pending"
                ),
                primaryAction: .none,
                showsElapsedTime: false,
                primaryActionDisabled: true
            )
        case let .interruptedRecordingFound(count):
            let detail = count == 1
                ? "One recording is preserved locally"
                : "\(count) recordings are preserved locally"
            return Self(
                kicker: "Needs attention",
                headline: "Audio is safe here.",
                detail: detail,
                tone: .attention,
                spine: localSpine(
                    watch: .attention,
                    accessibilityValue: "Interrupted audio preserved on Watch; Mac pending; Codex pending"
                ),
                primaryAction: .record,
                showsElapsedTime: false,
                primaryActionDisabled: false
            )
        case let .failed(failure):
            return failurePresentation(failure)
        }
    }

    private static func localSpine(
        watch: SignalNodeVisualState,
        accessibilityValue: String
    ) -> SignalSpinePresentation {
        SignalSpinePresentation(
            watch: watch,
            mac: .pending,
            codex: .pending,
            accessibilityValue: accessibilityValue
        )
    }

    private static func bridgeDetail(_ state: WatchBridgeConnectionState) -> String {
        switch state {
        case .notPaired, .needsAttention:
            "Mac needs attention"
        case .pairing:
            "Pairing with Mac"
        case .paired:
            "Mac relay ready"
        case .waiting:
            "Waiting for Mac"
        case .sending:
            "Sending a saved idea to Mac"
        case .received:
            "Mac received a saved idea"
        }
    }

    private static func bridgeAccessibility(_ state: WatchBridgeConnectionState) -> String {
        switch state {
        case .notPaired:
            "Mac not paired"
        case .pairing:
            "pairing with Mac"
        case .paired:
            "Mac relay ready"
        case .waiting:
            "waiting for Mac"
        case .sending:
            "sending a saved idea to Mac"
        case .received:
            "Mac received a saved idea"
        case .needsAttention:
            "Mac needs attention"
        }
    }

    private static func failurePresentation(_ failure: WatchCaptureFailure) -> Self {
        let headline: String
        let detail: String
        let action: WatchPrimaryAction
        switch failure {
        case .recorderStart:
            headline = "Couldn’t start recording"
            detail = "Try recording again"
            action = .record
        case .recorderStop:
            headline = "Audio is safe here."
            detail = "The interrupted recording is preserved locally"
            action = .record
        case .queueCommit:
            headline = "Audio is safe here."
            detail = "The recording still needs a durable save"
            action = .none
        case .identifier, .recovery:
            headline = "Storage unavailable"
            detail = "Voice Inbox can’t safely record right now"
            action = .none
        }
        return Self(
            kicker: "Needs attention",
            headline: headline,
            detail: detail,
            tone: .attention,
            spine: localSpine(
                watch: .attention,
                accessibilityValue: "Watch capture needs attention; Mac pending; Codex pending"
            ),
            primaryAction: action,
            showsElapsedTime: false,
            primaryActionDisabled: action == .none
        )
    }
}

enum PairingVisualStep: Int, CaseIterable, Equatable {
    case discovery
    case identity
    case code
    case paired

    var title: String {
        switch self {
        case .discovery:
            "Mac"
        case .identity:
            "Identity"
        case .code:
            "Code"
        case .paired:
            "Paired"
        }
    }
}

struct PairingStepsPresentation: Equatable {
    let current: PairingVisualStep

    static func make(
        selectedBridge: Bool,
        fingerprintConfirmed: Bool,
        paired: Bool
    ) -> Self {
        if paired {
            return Self(current: .paired)
        }
        guard selectedBridge else {
            return Self(current: .discovery)
        }
        guard fingerprintConfirmed else {
            return Self(current: .identity)
        }
        return Self(current: .code)
    }

    func state(for step: PairingVisualStep) -> SignalNodeVisualState {
        if current == .paired {
            return .confirmed
        }
        if step.rawValue < current.rawValue {
            return .confirmed
        }
        if step == current {
            return .active
        }
        return .pending
    }
}

struct RelayItemPresentation: Equatable {
    let status: String
    let detail: String
    let tone: WatchExperienceTone
    let spine: SignalSpinePresentation
    let accessibilityValue: String

    static func make(item: WatchQueueItem) -> Self {
        let detail: String
        let tone: WatchExperienceTone
        let spine: SignalSpinePresentation
        switch item.state {
        case .saved:
            detail = "Waiting for Mac"
            tone = .neutral
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .pending,
                codex: .pending,
                accessibilityValue: "Saved on Watch; waiting for Mac; Codex pending"
            )
        case .uploading:
            detail = "Secure transfer in progress"
            tone = .active
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .active,
                codex: .pending,
                accessibilityValue: "Saved on Watch; sending to Mac; Codex pending"
            )
        case .received:
            detail = "Mac confirmed receipt"
            tone = .confirmed
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .confirmed,
                codex: .pending,
                accessibilityValue: "Saved on Watch; received by Mac; Codex pending"
            )
        case .transcribing:
            detail = "Processing locally on Mac"
            tone = .active
            spine = codexActiveSpine("transcribing locally")
        case .readyForCodex:
            detail = "Ready for Codex"
            tone = .active
            spine = codexActiveSpine("ready for Codex")
        case .inserting:
            detail = "Adding to local Inbox"
            tone = .active
            spine = codexActiveSpine("inserting into Codex")
        case .reconciling:
            detail = "Confirming Codex delivery"
            tone = .active
            spine = codexActiveSpine("reconciling Codex delivery")
        case .delivered:
            detail = "Codex delivery confirmed"
            tone = .confirmed
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .confirmed,
                codex: .confirmed,
                accessibilityValue: "Saved on Watch; received by Mac; delivered to Codex"
            )
        case .needsAttention:
            detail = "Audio remains on this Watch"
            tone = .attention
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .attention,
                codex: .pending,
                accessibilityValue: "Needs attention; last remote phase unavailable"
            )
        }
        return Self(
            status: item.statusText,
            detail: detail,
            tone: tone,
            spine: spine,
            accessibilityValue: "\(item.statusText). \(detail). \(spine.accessibilityValue)"
        )
    }

    private static func codexActiveSpine(_ phase: String) -> SignalSpinePresentation {
        SignalSpinePresentation(
            watch: .confirmed,
            mac: .confirmed,
            codex: .active,
            accessibilityValue: "Saved on Watch; received by Mac; \(phase)"
        )
    }
}

enum SignalMotionStyle: Equatable {
    case immediate
    case bounded(duration: Double)

    static func forTransition(reduceMotion: Bool) -> Self {
        reduceMotion ? .immediate : .bounded(duration: 0.24)
    }
}
