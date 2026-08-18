import CodexBridgeShared
import CodexWatchCore
import SwiftUI

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

enum CapturePairingActionPolicy {
    static func primaryAction(
        captureState: WatchCaptureState,
        bridgeState: WatchBridgeConnectionState,
        captureAction: WatchPrimaryAction
    ) -> WatchPrimaryAction {
        guard !bridgeState.isPaired else { return captureAction }
        switch captureState {
        case .idle, .savedOnWatch, .interruptedRecordingFound:
            return .openPairing
        case .preparing, .recording, .saving, .permissionDenied, .failed:
            return captureAction
        }
    }
}

enum CapturePairingChrome {
    static let unpairedHeaderTitle = "Mac Bridge"

    static func showsLabeledHeader(isPaired: Bool) -> Bool {
        !isPaired
    }
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
        let presentation: Self
        switch captureState {
        case .idle:
            presentation = Self(
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
            presentation = Self(
                kicker: "Preparing",
                headline: "Preparing microphone",
                detail: "Keep Codex Watch open",
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
            presentation = Self(
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
            presentation = Self(
                kicker: "Saving on Watch",
                headline: "Saving securely",
                detail: "Keep Codex Watch open",
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
            presentation = Self(
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
            presentation = Self(
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
            presentation = Self(
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
            presentation = failurePresentation(failure)
        }
        return presentation.offeringPairingIfNeeded(
            captureState: captureState,
            bridgeState: bridgeState
        )
    }

    private func offeringPairingIfNeeded(
        captureState: WatchCaptureState,
        bridgeState: WatchBridgeConnectionState
    ) -> Self {
        let action = CapturePairingActionPolicy.primaryAction(
            captureState: captureState,
            bridgeState: bridgeState,
            captureAction: primaryAction
        )
        guard action != primaryAction else { return self }
        return Self(
            kicker: kicker,
            headline: headline,
            detail: detail,
            tone: tone,
            spine: spine,
            primaryAction: action,
            showsElapsedTime: showsElapsedTime,
            primaryActionDisabled: primaryActionDisabled
        )
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
        case .notPaired:
            "Mac needs attention"
        case let .needsAttention(message):
            message ?? "Mac needs attention"
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
        case let .needsAttention(message):
            message == "Pair again" ? "Mac not paired" : "Mac needs attention"
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
            detail = "Codex Watch can’t safely record right now"
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
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .active,
                codex: .pending,
                accessibilityValue: "Saved on Watch; processing locally on Mac; Codex pending"
            )
        case .readyForCodex:
            detail = "Ready for Codex"
            tone = .active
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .confirmed,
                codex: .pending,
                accessibilityValue: "Saved on Watch; prepared by Mac; ready for Codex"
            )
        case .inserting:
            detail = "Adding to local Inbox"
            tone = .active
            spine = codexActiveSpine("inserting into Codex")
        case .reconciling:
            detail = "Confirming Codex delivery"
            tone = .active
            spine = codexActiveSpine("reconciling Codex delivery")
        case .delivered:
            detail = "Saved to local Inbox"
            tone = .confirmed
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .confirmed,
                codex: .confirmed,
                accessibilityValue: "Saved on Watch; received by Mac; saved to local Inbox"
            )
        case .needsAttention:
            detail = "Audio remains on this Watch"
            tone = .attention
            spine = SignalSpinePresentation(
                watch: .confirmed,
                mac: .pending,
                codex: .pending,
                accessibilityValue: "Saved on Watch; remote phase unavailable"
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
    case crossFade
    case spring(response: Double, damping: Double)

    static let defaultResponse = SignalExperienceToken.Motion.springResponse
    static let defaultDamping = SignalExperienceToken.Motion.springDamping
    static let crossFadeDuration = SignalExperienceToken.Motion.crossFadeDuration

    static func forTransition(reduceMotion: Bool) -> Self {
        reduceMotion
            ? .crossFade
            : .spring(response: defaultResponse, damping: defaultDamping)
    }

    var animation: Animation {
        switch self {
        case .crossFade:
            .easeInOut(duration: Self.crossFadeDuration)
        case let .spring(response, damping):
            .spring(response: response, dampingFraction: damping)
        }
    }
}

enum CaptureAccessibilityPriority {
    static let state = 4.0
    static let relayPath = 3.0
    static let primaryAction = 2.0
    static let secondaryNavigation = 1.0

    enum Branch: Equatable {
        case instrument
        case bottomSafeAreaInset
    }

    static func branch(for role: Role) -> Branch {
        switch role {
        case .state, .relayPath, .secondaryNavigation:
            .instrument
        case .primaryAction:
            .bottomSafeAreaInset
        }
    }

    enum Role {
        case state
        case relayPath
        case primaryAction
        case secondaryNavigation
    }
}
