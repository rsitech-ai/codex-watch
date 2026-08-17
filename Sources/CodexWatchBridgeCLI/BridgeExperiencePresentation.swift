import CodexBridgeDelivery
import CodexBridgeService
import CodexBridgeShared
import Foundation
import SwiftUI

enum BridgeExperienceTone: Equatable {
    case neutral
    case active
    case confirmed
    case attention
    case destructive
}

enum BridgeSpineNodeState: Equatable {
    case pending
    case active
    case confirmed
    case attention
}

struct BridgeSpinePresentation: Equatable {
    let watch: BridgeSpineNodeState
    let mac: BridgeSpineNodeState
    let codex: BridgeSpineNodeState
    let accessibilityValue: String
}

enum BridgeExperienceTheme {
    // ponytail: same tokens as WatchExperienceTheme; extract a shared module if a third surface appears.
    enum ColorToken {
        static let active = Color(red: 0.18, green: 0.86, blue: 0.94)
        static let confirmed = Color(red: 0.69, green: 0.93, blue: 0.22)
        static let attention = Color(red: 1.00, green: 0.68, blue: 0.18)
        static let destructive = Color(red: 1.00, green: 0.27, blue: 0.32)
        static let neutral = Color.primary.opacity(0.42)

        static func forTone(_ tone: BridgeExperienceTone) -> Color {
            switch tone {
            case .neutral: neutral
            case .active: active
            case .confirmed: confirmed
            case .attention: attention
            case .destructive: destructive
            }
        }

        static func forNode(_ state: BridgeSpineNodeState) -> Color {
            switch state {
            case .pending: neutral
            case .active: active
            case .confirmed: confirmed
            case .attention: attention
            }
        }
    }
}

struct PairingChallengePresentation: Equatable {
    let phrase: String
    let code: String
    let expiresAt: Date
}

struct MacInboxItem: Identifiable, Equatable {
    let id: MemoID
    let capturedAt: Date
    let state: MemoState
    let transcript: String?
    let audioIsPresent: Bool
    let isRetained: Bool
}

struct MacInboxItemPresentation: Equatable {
    let status: String
    let detail: String
    let tone: BridgeExperienceTone
    let spine: BridgeSpinePresentation
    let retryEnabled: Bool
    let speechCTA: Bool
    let accessibilityValue: String

    static func make(
        item: MacInboxItem,
        speech: BridgeSpeechAuthorizationStatus
    ) -> Self {
        let speechBlocksTranscription = speech != .authorized
        switch item.state {
        case .received:
            return phase(
                status: "Received on Mac",
                detail: "Audio is on this Mac.",
                tone: .confirmed,
                spine: macConfirmed("received by Mac"),
                retryEnabled: false,
                speechCTA: false
            )
        case .transcribing:
            return phase(
                status: "Transcribing",
                detail: "Processing locally on this Mac.",
                tone: .active,
                spine: macActive("processing locally on Mac"),
                retryEnabled: false,
                speechCTA: false
            )
        case .readyForCodex:
            return phase(
                status: "Ready for Codex",
                detail: "Transcript is local. Codex insertion has not been confirmed.",
                tone: .active,
                spine: macConfirmed("prepared by Mac; ready for Codex"),
                retryEnabled: false,
                speechCTA: false
            )
        case .inserting:
            return phase(
                status: "Adding to Codex Inbox",
                detail: "Submitting the local transcript.",
                tone: .active,
                spine: codexActive("inserting into Codex"),
                retryEnabled: false,
                speechCTA: false
            )
        case .reconciling:
            return phase(
                status: "Confirming Codex delivery",
                detail: "Waiting for Codex to confirm the local Inbox item.",
                tone: .active,
                spine: codexActive("reconciling Codex delivery"),
                retryEnabled: false,
                speechCTA: false
            )
        case .delivered:
            return phase(
                status: "Delivered to Codex",
                detail: item.isRetained
                    ? "Codex delivery confirmed. Audio is in the Mac recovery archive."
                    : "Codex delivery confirmed.",
                tone: .confirmed,
                spine: BridgeSpinePresentation(
                    watch: .confirmed,
                    mac: .confirmed,
                    codex: .confirmed,
                    accessibilityValue: "Saved on Watch; received by Mac; delivered to Codex"
                ),
                retryEnabled: false,
                speechCTA: false
            )
        case .needsAttention:
            if speechBlocksTranscription, item.transcript == nil {
                return phase(
                    status: "Needs attention",
                    detail: BridgeSpeechCopy.blockedDetail(for: speech),
                    tone: .attention,
                    spine: macAttention("Speech Recognition is not authorized"),
                    retryEnabled: true,
                    speechCTA: true
                )
            }
            return phase(
                status: "Needs attention",
                detail: item.transcript == nil
                    ? "Audio is on this Mac. Transcription did not finish."
                    : "Audio is on this Mac. Codex delivery needs attention.",
                tone: .attention,
                spine: macAttention("Mac processing needs attention"),
                retryEnabled: item.transcript == nil,
                speechCTA: false
            )
        case .saved, .uploading:
            return phase(
                status: "Waiting for Mac",
                detail: "This Mac has not recorded receipt yet.",
                tone: .neutral,
                spine: BridgeSpinePresentation(
                    watch: .confirmed,
                    mac: .pending,
                    codex: .pending,
                    accessibilityValue: "Saved on Watch; waiting for Mac; Codex pending"
                ),
                retryEnabled: false,
                speechCTA: false
            )
        }
    }

    private static func phase(
        status: String,
        detail: String,
        tone: BridgeExperienceTone,
        spine: BridgeSpinePresentation,
        retryEnabled: Bool,
        speechCTA: Bool
    ) -> Self {
        Self(
            status: status,
            detail: detail,
            tone: tone,
            spine: spine,
            retryEnabled: retryEnabled,
            speechCTA: speechCTA,
            accessibilityValue: "\(status). \(detail). \(spine.accessibilityValue)"
        )
    }

    private static func macConfirmed(_ phase: String) -> BridgeSpinePresentation {
        BridgeSpinePresentation(
            watch: .confirmed,
            mac: .confirmed,
            codex: .pending,
            accessibilityValue: "Saved on Watch; \(phase); Codex pending"
        )
    }

    private static func macActive(_ phase: String) -> BridgeSpinePresentation {
        BridgeSpinePresentation(
            watch: .confirmed,
            mac: .active,
            codex: .pending,
            accessibilityValue: "Saved on Watch; \(phase); Codex pending"
        )
    }

    private static func macAttention(_ phase: String) -> BridgeSpinePresentation {
        BridgeSpinePresentation(
            watch: .confirmed,
            mac: .attention,
            codex: .pending,
            accessibilityValue: "Saved on Watch; \(phase); Codex pending"
        )
    }

    private static func codexActive(_ phase: String) -> BridgeSpinePresentation {
        BridgeSpinePresentation(
            watch: .confirmed,
            mac: .confirmed,
            codex: .active,
            accessibilityValue: "Saved on Watch; received by Mac; \(phase)"
        )
    }
}

struct BridgeConsoleHeaderPresentation: Equatable {
    let kicker: String
    let headline: String
    let detail: String
    let tone: BridgeExperienceTone
    let spine: BridgeSpinePresentation
    let primaryTitle: String?
    let primaryHint: String?

    static func make(
        installed: Bool,
        listenerOnline: Bool,
        listenerPaused: Bool,
        watchPaired: Bool,
        speech: BridgeSpeechAuthorizationStatus,
        advertisedName: String,
        latest: MacInboxItem?
    ) -> Self {
        if !installed {
            return Self(
                kicker: "Mac needs attention",
                headline: "Install the Mac bridge.",
                detail: "Voice Inbox Bridge is not installed for this user yet.",
                tone: .attention,
                spine: BridgeSpinePresentation(
                    watch: .pending,
                    mac: .attention,
                    codex: .pending,
                    accessibilityValue: "Watch pending; Mac not installed; Codex pending"
                ),
                primaryTitle: nil,
                primaryHint: nil
            )
        }
        if speech != .authorized {
            return Self(
                kicker: "Speech needs attention",
                headline: "Allow Speech Recognition.",
                detail: BridgeSpeechCopy.blockedDetail(for: speech),
                tone: .attention,
                spine: latest.map { MacInboxItemPresentation.make(item: $0, speech: speech).spine }
                    ?? BridgeSpinePresentation(
                        watch: watchPaired ? .confirmed : .pending,
                        mac: listenerOnline ? .attention : .pending,
                        codex: .pending,
                        accessibilityValue: "Speech Recognition is not authorized on Mac; Codex pending"
                    ),
                primaryTitle: speech == .notDetermined
                    ? "Allow Speech Recognition"
                    : "Open Speech Settings",
                primaryHint: BridgeSpeechCopy.blockedDetail(for: speech)
            )
        }
        if !watchPaired {
            return Self(
                kicker: "Watch ready to pair",
                headline: "Show the phrase and code.",
                detail: "Compare the certificate phrase on your Watch, then enter the 6-digit code there.",
                tone: .active,
                spine: BridgeSpinePresentation(
                    watch: .pending,
                    mac: listenerOnline ? .active : .attention,
                    codex: .pending,
                    accessibilityValue: "Watch not paired; Mac \(listenerOnline ? "listening" : "offline"); Codex pending"
                ),
                primaryTitle: "Generate pairing code",
                primaryHint: "Shows a certificate phrase and a 6-digit code for the Watch"
            )
        }
        if listenerPaused {
            return Self(
                kicker: "Mac paused",
                headline: "Listener is paused.",
                detail: "\(advertisedName) is installed but not accepting Watch audio.",
                tone: .attention,
                spine: BridgeSpinePresentation(
                    watch: .confirmed,
                    mac: .attention,
                    codex: .pending,
                    accessibilityValue: "Watch paired; Mac listener paused; Codex pending"
                ),
                primaryTitle: nil,
                primaryHint: nil
            )
        }
        if !listenerOnline {
            return Self(
                kicker: "Mac needs attention",
                headline: "Listener is offline.",
                detail: "\(advertisedName) is paired, but this Mac is not accepting Watch audio right now.",
                tone: .attention,
                spine: BridgeSpinePresentation(
                    watch: .confirmed,
                    mac: .attention,
                    codex: .pending,
                    accessibilityValue: "Watch paired; Mac listener offline; Codex pending"
                ),
                primaryTitle: nil,
                primaryHint: nil
            )
        }
        if let latest {
            let item = MacInboxItemPresentation.make(item: latest, speech: speech)
            return Self(
                kicker: item.status,
                headline: item.status,
                detail: item.detail,
                tone: item.tone,
                spine: item.spine,
                primaryTitle: item.speechCTA ? "Allow Speech Recognition" : (item.retryEnabled ? "Retry transcription" : nil),
                primaryHint: item.detail
            )
        }
        return Self(
            kicker: "Mac relay ready",
            headline: "Waiting for the Watch.",
            detail: "\(advertisedName) is paired and listening.",
            tone: .confirmed,
            spine: BridgeSpinePresentation(
                watch: .confirmed,
                mac: .confirmed,
                codex: .pending,
                accessibilityValue: "Watch paired; Mac relay ready; Codex pending"
            ),
            primaryTitle: nil,
            primaryHint: nil
        )
    }
}

enum BridgeSpeechCopy {
    static func blockedDetail(for status: BridgeSpeechAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            "Audio can sit on this Mac, but transcription is blocked until Speech Recognition is allowed."
        case .denied:
            "Speech Recognition is off for Voice Inbox Bridge. Enable it in System Settings, then retry the memo."
        case .restricted:
            "Speech Recognition is restricted by macOS policy on this Mac."
        case .authorized:
            "On-device Speech is allowed. Codex still needs a confirmed local transcript."
        }
    }

    static func menuStatus(for status: BridgeSpeechAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Speech not determined"
        case .denied: "Speech denied"
        case .restricted: "Speech restricted"
        case .authorized: "Speech allowed"
        }
    }
}

enum MacInboxSnapshot {
    static func items(
        intake: [CommittedIntakeRecord],
        journals: [MemoID: DeliveryRecord],
        retained: [RetainedIntakeRecord]
    ) -> [MacInboxItem] {
        var items: [MacInboxItem] = intake.map { record in
            let journal = journals[record.memoID]
            return MacInboxItem(
                id: record.memoID,
                capturedAt: journal?.capturedAt ?? record.receipt.capturedAt,
                state: journal?.state ?? .received,
                transcript: journal?.transcript,
                audioIsPresent: true,
                isRetained: false
            )
        }
        let intakeIDs = Set(intake.map(\.memoID))
        for record in retained where !intakeIDs.contains(record.memoID) {
            let journal = journals[record.memoID]
            items.append(
                MacInboxItem(
                    id: record.memoID,
                    capturedAt: journal?.capturedAt ?? record.deliveredAt,
                    state: journal?.state ?? .delivered,
                    transcript: journal?.transcript,
                    audioIsPresent: true,
                    isRetained: true
                )
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt > rhs.capturedAt }
            return lhs.id.rawValue > rhs.id.rawValue
        }
    }
}

enum PairingExpiryCopy {
    static func text(expiresAt: Date, now: Date) -> String {
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return "Code expired. Generate a new code." }
        let seconds = Int(remaining.rounded(.down))
        return String(format: "Expires in %d:%02d", seconds / 60, seconds % 60)
    }
}

struct BridgeSpineView: View {
    let presentation: BridgeSpinePresentation
    var nodeSize: CGFloat = 20
    var nodeSpacing: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nodes: [(label: String, state: BridgeSpineNodeState)] {
        [
            ("WATCH", presentation.watch),
            ("MAC", presentation.mac),
            ("CODEX", presentation.codex),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                VStack(spacing: 6) {
                    BridgeSpineNode(state: node.state, size: nodeSize)
                    Text(node.label)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(BridgeExperienceTheme.ColorToken.forNode(node.state))
                }
                if index < nodes.count - 1 {
                    Rectangle()
                        .fill(segmentColor(after: index))
                        .frame(width: nodeSpacing, height: 2)
                        .padding(.bottom, 18)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Delivery path")
        .accessibilityValue(presentation.accessibilityValue)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: presentation)
    }

    private func segmentColor(after index: Int) -> Color {
        let states = [presentation.watch, presentation.mac, presentation.codex]
        let destination = states[index + 1]
        return destination == .pending
            ? BridgeExperienceTheme.ColorToken.neutral.opacity(0.45)
            : BridgeExperienceTheme.ColorToken.forNode(destination).opacity(0.8)
    }
}

private struct BridgeSpineNode: View {
    let state: BridgeSpineNodeState
    let size: CGFloat

    var body: some View {
        ZStack {
            switch state {
            case .pending:
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .padding(4)
            case .active:
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .padding(4)
                    .rotationEffect(.degrees(45))
            case .confirmed:
                Circle()
                    .fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.black)
            case .attention:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var color: Color {
        BridgeExperienceTheme.ColorToken.forNode(state)
    }
}
