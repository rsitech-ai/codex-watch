import CodexBridgeDelivery
import CodexBridgeService
import CodexBridgeShared
import Foundation
import SwiftUI

enum CodexWatchBrand {
    static let productName = "Codex Watch"
}

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
    enum ColorToken {
        static let active = rgb(SignalExperienceToken.RGB.active)
        static let confirmed = rgb(SignalExperienceToken.RGB.confirmed)
        static let attention = rgb(SignalExperienceToken.RGB.attention)
        static let destructive = rgb(SignalExperienceToken.RGB.destructive)
        static let neutral = Color.primary.opacity(0.42)

        private static func rgb(_ token: (red: Double, green: Double, blue: Double)) -> Color {
            Color(red: token.red, green: token.green, blue: token.blue)
        }

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

    enum Metric {
        static let nodeSize: CGFloat = 20
        static let nodeSpacing: CGFloat = 28
        static let spineWidth: CGFloat = 2
    }

    enum TypeRole {
        static let spineLabel = Font.system(.caption, design: .rounded, weight: .semibold)
        static let inspectorTitle = Font.title2.weight(.bold)
        static let pairingCode = Font.system(.largeTitle, design: .rounded, weight: .bold)
    }
}

enum BridgeMotionStyle: Equatable {
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

enum BridgePairingFill {
    static let standardOpacity = 0.06
    static let increasedContrastOpacity = 0.12

    static func opacity(increasedContrast: Bool) -> Double {
        increasedContrast ? increasedContrastOpacity : standardOpacity
    }
}

enum BridgeFileMenuCopy {
    static let saveSpec = "Save Spec…"
    static let saveHTML = "Save HTML…"
}

enum BridgePairingCopy {
    static let sheetTitle = "Pair with Watch"
    static let onWristInstruction =
        "Compare the certificate phrase on your Watch, then enter the 6-digit code there."
    static let macShowsOnly = "This Mac only shows the phrase and code. Enter them on your Watch."
}

enum BridgeSpineCopy {
    static let labels = ["WATCH", "MAC", "CODEX"]
    static let accessibilityLabel = "Delivery path"
}

struct BridgeConsoleStatusHierarchy: Equatable {
    let chromeHeadline: String?
    let listStatus: String?
    let inspectorTitle: String?

    var renderedStatusTexts: [String] {
        [chromeHeadline, listStatus, inspectorTitle].compactMap { $0 }
    }

    func repeatCount(of status: String) -> Int {
        renderedStatusTexts.filter { $0.caseInsensitiveCompare(status) == .orderedSame }.count
    }

    static func make(
        header: BridgeConsoleHeaderPresentation,
        selected: MacInboxItemPresentation?
    ) -> Self {
        guard let selected else {
            return Self(chromeHeadline: header.headline, listStatus: nil, inspectorTitle: nil)
        }
        return Self(
            chromeHeadline: header.headline,
            listStatus: selected.status,
            inspectorTitle: selected.status
        )
    }
}

struct BridgeConsoleToolbarPresentation: Equatable {
    let headerPrimaryTitle: String?
    let headerPrimaryHint: String?
    let headerPrimarySymbol: String
    let showsPairingCode: Bool
    let showsSaveSpec: Bool

    var showsHeaderPrimary: Bool { headerPrimaryTitle != nil }

    static func make(
        header: BridgeConsoleHeaderPresentation,
        canSaveSelectedSpec: Bool
    ) -> Self {
        Self(
            headerPrimaryTitle: header.primaryTitle,
            headerPrimaryHint: header.primaryHint,
            headerPrimarySymbol: symbol(for: header.primaryTitle),
            showsPairingCode: header.primaryTitle != "Generate pairing code",
            showsSaveSpec: canSaveSelectedSpec
        )
    }

    private static func symbol(for title: String?) -> String {
        switch title {
        case "Allow Speech Recognition": "waveform"
        case "Open Speech Settings": "gearshape"
        case "Generate pairing code": "link"
        case "Retry transcription": "arrow.clockwise"
        case "Use current address": "network"
        default: "exclamationmark.triangle.fill"
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
    let specMarkdown: String?
    let specProvenance: MemoSpecProvenance?

    init(
        id: MemoID,
        capturedAt: Date,
        state: MemoState,
        transcript: String?,
        audioIsPresent: Bool,
        isRetained: Bool,
        specMarkdown: String? = nil,
        specProvenance: MemoSpecProvenance? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.state = state
        self.transcript = transcript
        self.audioIsPresent = audioIsPresent
        self.isRetained = isRetained
        self.specMarkdown = specMarkdown
        self.specProvenance = specProvenance
    }
}

struct MacInboxItemPresentation: Equatable {
    let status: String
    let detail: String
    let tone: BridgeExperienceTone
    let spine: BridgeSpinePresentation
    let retryEnabled: Bool
    let speechCTA: Bool
    let showsSpecDownload: Bool
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
                speechCTA: false,
                showsSpecDownload: hasSpec(item)
            )
        case .transcribing:
            return phase(
                status: "Transcribing",
                detail: "Processing locally on this Mac.",
                tone: .active,
                spine: macActive("processing locally on Mac"),
                retryEnabled: false,
                speechCTA: false,
                showsSpecDownload: hasSpec(item)
            )
        case .readyForCodex:
            return phase(
                status: "Ready for Codex",
                detail: "Transcript is local. Codex insertion has not been confirmed.",
                tone: .active,
                spine: macConfirmed("prepared by Mac; ready for Codex"),
                retryEnabled: true,
                speechCTA: false,
                showsSpecDownload: hasSpec(item)
            )
        case .inserting:
            return phase(
                status: "Adding to Codex Inbox",
                detail: "Submitting the local transcript.",
                tone: .active,
                spine: codexActive("inserting into Codex"),
                retryEnabled: false,
                speechCTA: false,
                showsSpecDownload: hasSpec(item)
            )
        case .reconciling:
            return phase(
                status: "Confirming Codex delivery",
                detail: "Waiting for Codex to confirm the local Inbox item.",
                tone: .active,
                spine: codexActive("reconciling Codex delivery"),
                retryEnabled: false,
                speechCTA: false,
                showsSpecDownload: hasSpec(item)
            )
        case .delivered:
            return phase(
                status: "Saved to local Inbox",
                detail: deliveredDetail(item),
                tone: .confirmed,
                spine: BridgeSpinePresentation(
                    watch: .confirmed,
                    mac: .confirmed,
                    codex: .confirmed,
                    accessibilityValue: "Saved on Watch; received by Mac; saved to local Inbox"
                ),
                retryEnabled: false,
                speechCTA: false,
                showsSpecDownload: hasSpec(item)
            )
        case .needsAttention:
            if speechBlocksTranscription, item.transcript == nil {
                return phase(
                    status: "Needs attention",
                    detail: BridgeSpeechCopy.blockedDetail(for: speech),
                    tone: .attention,
                    spine: macAttention("Speech Recognition is not authorized"),
                    retryEnabled: true,
                    speechCTA: true,
                    showsSpecDownload: hasSpec(item)
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
                speechCTA: false,
                showsSpecDownload: hasSpec(item)
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
                speechCTA: false,
                showsSpecDownload: hasSpec(item)
            )
        }
    }

    private static func deliveredDetail(_ item: MacInboxItem) -> String {
        var detail = item.isRetained
            ? "Confirmed in this Mac’s Codex Inbox thread. Audio is in the Mac recovery archive."
            : "Confirmed in this Mac’s Codex Inbox thread."
        if hasSpec(item) {
            switch item.specProvenance {
            case .appServer:
                detail += " Spec is ready to save."
            case .foundationModels:
                detail += " Spec was improved on-device by Foundation Models."
            case .localFallback, nil:
                detail += " Spec is an unverified local wrapper."
            }
        }
        return detail
    }

    private static func hasSpec(_ item: MacInboxItem) -> Bool {
        guard let specMarkdown = item.specMarkdown else { return false }
        return !specMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func phase(
        status: String,
        detail: String,
        tone: BridgeExperienceTone,
        spine: BridgeSpinePresentation,
        retryEnabled: Bool,
        speechCTA: Bool,
        showsSpecDownload: Bool
    ) -> Self {
        Self(
            status: status,
            detail: detail,
            tone: tone,
            spine: spine,
            retryEnabled: retryEnabled,
            speechCTA: speechCTA,
            showsSpecDownload: showsSpecDownload,
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
        latest: MacInboxItem?,
        bindHost: String = "—",
        currentHosts: [String] = []
    ) -> Self {
        if !installed {
            return Self(
                headline: "Install the Mac bridge.",
                detail: "\(CodexWatchBrand.productName) is not installed for this user yet.",
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
        if WatchReachableAddress.bindLooksUnreachable(bindHost: bindHost, currentHosts: currentHosts) {
            let current = currentHosts.joined(separator: ", ")
            return Self(
                headline: "Watch cannot reach this Mac.",
                detail: "The listener is bound to \(bindHost). This Mac’s current address is \(current). Use the current address so Watch uploads can land.",
                tone: .attention,
                spine: BridgeSpinePresentation(
                    watch: watchPaired ? .confirmed : .pending,
                    mac: .attention,
                    codex: .pending,
                    accessibilityValue: "Mac listener is bound to an address this Mac is not using; Watch uploads cannot land"
                ),
                primaryTitle: "Use current address",
                primaryHint: "Rebinds the LaunchAgent to this Mac’s current LAN address without rotating TLS"
            )
        }
        if speech != .authorized {
            return Self(
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
                headline: "Show the phrase and code.",
                detail: BridgePairingCopy.onWristInstruction,
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
            let attentionWithoutTranscript = item.tone == .attention && latest.transcript == nil
            return Self(
                headline: attentionWithoutTranscript ? "Transcription did not finish." : item.status,
                detail: item.detail,
                tone: item.tone,
                spine: item.spine,
                primaryTitle: item.speechCTA ? "Allow Speech Recognition" : nil,
                primaryHint: item.speechCTA ? item.detail : nil
            )
        }
        return Self(
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
            "Speech Recognition is off for \(CodexWatchBrand.productName). Enable it in System Settings, then retry the memo."
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

enum MemoSpecCopy {
    static func provenanceLabel(_ provenance: MemoSpecProvenance?) -> String {
        switch provenance {
        case .foundationModels:
            "Improved on-device by Foundation Models"
        case .appServer:
            "Improved by Codex App Server"
        case .localFallback, nil:
            "Unverified local wrapper"
        }
    }
}

enum MacInboxSnapshot {
    static func items(
        intake: [CommittedIntakeRecord],
        journals: [MemoID: DeliveryRecord],
        retained: [RetainedIntakeRecord],
        specs: [MemoID: MemoSpec] = [:]
    ) -> [MacInboxItem] {
        var items: [MacInboxItem] = intake.map { record in
            let journal = journals[record.memoID]
            let spec = specs[record.memoID]
            return MacInboxItem(
                id: record.memoID,
                capturedAt: journal?.capturedAt ?? record.receipt.capturedAt,
                state: journal?.state ?? .received,
                transcript: journal?.transcript,
                audioIsPresent: true,
                isRetained: false,
                specMarkdown: spec?.markdown,
                specProvenance: spec?.provenance
            )
        }
        let intakeIDs = Set(intake.map(\.memoID))
        for record in retained where !intakeIDs.contains(record.memoID) {
            let journal = journals[record.memoID]
            let spec = specs[record.memoID]
            items.append(
                MacInboxItem(
                    id: record.memoID,
                    capturedAt: journal?.capturedAt ?? record.deliveredAt,
                    state: journal?.state ?? .delivered,
                    transcript: journal?.transcript,
                    audioIsPresent: true,
                    isRetained: true,
                    specMarkdown: spec?.markdown,
                    specProvenance: spec?.provenance
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
    var nodeSize: CGFloat = BridgeExperienceTheme.Metric.nodeSize
    var nodeSpacing: CGFloat = BridgeExperienceTheme.Metric.nodeSpacing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nodes: [(label: String, state: BridgeSpineNodeState)] {
        [
            (BridgeSpineCopy.labels[0], presentation.watch),
            (BridgeSpineCopy.labels[1], presentation.mac),
            (BridgeSpineCopy.labels[2], presentation.codex),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                VStack(spacing: 6) {
                    BridgeSpineNode(state: node.state, size: nodeSize)
                    Text(node.label)
                        .font(BridgeExperienceTheme.TypeRole.spineLabel)
                        .tracking(0.7)
                        .foregroundStyle(BridgeExperienceTheme.ColorToken.forNode(node.state))
                }
                if index < nodes.count - 1 {
                    Rectangle()
                        .fill(segmentColor(after: index))
                        .frame(width: nodeSpacing, height: BridgeExperienceTheme.Metric.spineWidth)
                        .padding(.bottom, 18)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BridgeSpineCopy.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .animation(BridgeMotionStyle.forTransition(reduceMotion: reduceMotion).animation, value: presentation)
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
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(color)
                    .padding(4)
                    .rotationEffect(.degrees(45))
            case .confirmed:
                Circle()
                    .fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.black)
            case .attention:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
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
