import CodexWatchCore
import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var model: VoiceCaptureModel
    @State private var selectedBridge: DiscoveredBridge?
    @State private var confirmedPin: ConfirmedCertificatePin?
    @State private var pairingCode = ""
    @State private var localError: String?

    private var stepsPresentation: PairingStepsPresentation {
        PairingStepsPresentation.make(
            selectedBridge: selectedBridge != nil,
            fingerprintConfirmed: confirmedPin != nil,
            paired: BridgeCredentialPresentation.showsSavedBridge(
                hasSavedCredential: model.hasSavedBridgeCredential
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                PairingStepRail(presentation: stepsPresentation)

                if BridgeCredentialPresentation.showsSavedBridge(
                    hasSavedCredential: model.hasSavedBridgeCredential
                ) {
                    pairedContent
                } else if let selectedBridge {
                    confirmationContent(selectedBridge)
                } else {
                    discoveryContent
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .navigationTitle("Mac Bridge")
        .task(id: model.hasSavedBridgeCredential) {
            if PairingDiscoveryPolicy.shouldRun(
                hasSavedCredential: model.hasSavedBridgeCredential
            ) {
                model.discovery.start()
            } else {
                model.discovery.stop()
            }
        }
        .onDisappear {
            model.discovery.stop()
        }
    }

    private var pairedContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(WatchExperienceTheme.ColorToken.confirmed)
            Text(model.bridgeState.title)
                .font(WatchExperienceTheme.TypeRole.emptyHeadline)
                .multilineTextAlignment(.center)
            Text(model.bridgeState.detail)
                .font(WatchExperienceTheme.TypeRole.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Forget This Mac", role: .destructive) {
                Task { await model.forgetBridge() }
            }
        }
    }

    @ViewBuilder
    private var discoveryContent: some View {
        if model.discovery.bridges.isEmpty {
            ProgressView()
            Text(BridgeCredentialPresentation.discoveryHeadline(
                bridgeState: model.bridgeState,
                discoveryUnavailable: model.discovery.state == .unavailable
            ))
                .font(WatchExperienceTheme.TypeRole.emptyHeadline)
                .multilineTextAlignment(.center)
            Text("Start the bridge on your Mac. Recordings stay on this Watch while it is unavailable.")
                .font(WatchExperienceTheme.TypeRole.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Text("Choose your Mac")
                .font(WatchExperienceTheme.TypeRole.emptyHeadline)
            ForEach(model.discovery.bridges) { bridge in
                Button {
                    selectedBridge = bridge
                    confirmedPin = nil
                    pairingCode = ""
                    localError = nil
                } label: {
                    Label(bridge.name, systemImage: "desktopcomputer")
                        .lineLimit(1)
                }
                .accessibilityHint("Shows the fingerprint phrase before pairing")
            }
        }
    }

    private func confirmationContent(_ bridge: DiscoveredBridge) -> some View {
        VStack(spacing: 8) {
            Text(bridge.name)
                .font(WatchExperienceTheme.TypeRole.emptyHeadline)
                .lineLimit(1)
            Text("Compare this phrase with the bridge on your Mac")
                .font(WatchExperienceTheme.TypeRole.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(bridge.certificatePin.comparisonPhrase)
                .font(.caption.monospaced().weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityLabel("Certificate phrase: \(bridge.certificatePin.comparisonPhrase)")

            if confirmedPin == nil {
                Button("Fingerprint Matches") {
                    confirmedPin = bridge.certificatePin.confirmedByUser()
                    localError = nil
                }
                .accessibilityHint("Only continue if the phrase exactly matches your Mac")
            } else {
                TextField("6-digit code", text: $pairingCode)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("One-time pairing code")
                    .onChange(of: pairingCode) { _, newValue in
                        pairingCode = PairingCode.sanitizeInput(newValue)
                    }
                if let localError {
                    Text(localError)
                        .font(WatchExperienceTheme.TypeRole.detail)
                        .foregroundStyle(WatchExperienceTheme.ColorToken.destructive)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel("Pairing error: \(localError)")
                }
                Button(model.bridgeState == .pairing ? "Pairing…" : "Pair with Mac") {
                    if let error = PairingSubmitPolicy.errorIfInvalidCode(pairingCode) {
                        localError = error
                        return
                    }
                    Task {
                        guard let confirmedPin else { return }
                        let paired = await model.pair(
                            bridge: bridge,
                            confirmedPin: confirmedPin,
                            code: pairingCode
                        )
                        localError = paired ? nil : pairingFailureCopy
                    }
                }
                .disabled(model.bridgeState == .pairing)
            }

            Button("Choose Another Mac") {
                selectedBridge = nil
                confirmedPin = nil
                pairingCode = ""
                localError = nil
            }
            .buttonStyle(.plain)
            .font(WatchExperienceTheme.TypeRole.detail)
        }
    }

    private var pairingFailureCopy: String {
        if case let .needsAttention(message) = model.bridgeState, let message {
            return message
        }
        return "Couldn’t pair. Check the bridge, phrase, and code."
    }
}

enum PairingDiscoveryPolicy {
    static func shouldRun(hasSavedCredential: Bool) -> Bool {
        !hasSavedCredential
    }
}

enum PairingSubmitPolicy {
    static let invalidCodeMessage = "Enter the 6-digit code from your Mac."

    static func errorIfInvalidCode(_ code: String) -> String? {
        PairingCode(rawValue: code) == nil ? invalidCodeMessage : nil
    }
}

enum PairingRailMetric {
    static let nodeSlot: CGFloat = 13
    static let pendingNode: CGFloat = 11
    static let activeNode: CGFloat = 10
    static let confirmedNode: CGFloat = 13
    static let attentionNode: CGFloat = 12
}

struct PairingStepRail: View {
    let presentation: PairingStepsPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(PairingVisualStep.allCases, id: \.rawValue) { step in
                    stepNode(step)
                    if step != .paired {
                        Rectangle()
                            .fill(connectorColor(after: step))
                            .frame(maxWidth: .infinity)
                            .frame(height: WatchExperienceTheme.Metric.spineWidth)
                    }
                }
            }

            Text(presentation.current.title.uppercased())
                .font(WatchExperienceTheme.TypeRole.pairingRailTitle)
                .tracking(WatchExperienceTheme.TypeRole.pairingRailTracking)
                .foregroundStyle(color(for: presentation.state(for: presentation.current)))
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pairing progress")
        .accessibilityValue(presentation.current.title)
        .animation(
            SignalMotionStyle.forTransition(reduceMotion: reduceMotion).animation,
            value: presentation
        )
    }

    @ViewBuilder
    private func stepNode(_ step: PairingVisualStep) -> some View {
        let state = presentation.state(for: step)
        ZStack {
            switch state {
            case .pending:
                Circle()
                    .stroke(color(for: state), lineWidth: 1.5)
                    .frame(
                        width: PairingRailMetric.pendingNode,
                        height: PairingRailMetric.pendingNode
                    )
            case .active:
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: state))
                    .frame(
                        width: PairingRailMetric.activeNode,
                        height: PairingRailMetric.activeNode
                    )
                    .rotationEffect(.degrees(45))
            case .confirmed:
                ZStack {
                    Circle()
                        .fill(color(for: state))
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black)
                }
                .frame(
                    width: PairingRailMetric.confirmedNode,
                    height: PairingRailMetric.confirmedNode
                )
            case .attention:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: PairingRailMetric.attentionNode, weight: .semibold))
                    .foregroundStyle(color(for: state))
            }
        }
        .frame(width: PairingRailMetric.nodeSlot, height: PairingRailMetric.nodeSlot)
    }

    private func connectorColor(after step: PairingVisualStep) -> Color {
        guard let next = PairingVisualStep(rawValue: step.rawValue + 1) else {
            return WatchExperienceTheme.ColorToken.neutral
        }
        return WatchExperienceTheme.Connector.color(destination: presentation.state(for: next))
    }

    private func color(for state: SignalNodeVisualState) -> Color {
        WatchExperienceTheme.ColorToken.forNode(state)
    }
}

enum BridgeCredentialPresentation {
    static func discoveryHeadline(
        bridgeState: WatchBridgeConnectionState,
        discoveryUnavailable: Bool
    ) -> String {
        if bridgeState.title == "Pair again" {
            return "Pair again"
        }
        return discoveryUnavailable ? "Mac bridge unavailable" : "Searching for your Mac"
    }

    static func showsSavedBridge(hasSavedCredential: Bool) -> Bool {
        hasSavedCredential
    }

    static func afterRejectedUpload(
        readStatus: BridgeCredentialReadStatus
    ) -> BridgeCredentialAttentionPresentation {
        switch readStatus {
        case .missing:
            return .init(hasSavedCredential: false, state: .notPaired)
        case .present:
            return .init(
                hasSavedCredential: true,
                state: .needsAttention(
                    "The bridge rejected this recording. The audio remains on this Watch."
                )
            )
        case .unreadable:
            return .init(
                hasSavedCredential: true,
                state: .needsAttention("The saved bridge credential couldn’t be read.")
            )
        }
    }
}

enum BridgeCredentialReadStatus: Equatable {
    case missing
    case present
    case unreadable
}

struct BridgeCredentialAttentionPresentation: Equatable {
    let hasSavedCredential: Bool
    let state: WatchBridgeConnectionState
}
