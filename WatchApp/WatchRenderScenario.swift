#if DEBUG
import CodexBridgeShared
import Foundation
import SwiftUI

enum WatchRenderScenario: String, CaseIterable, Equatable {
    case ready
    case recording
    case savedOnWatch
    case delivered
    case needsAttention
    case queue
    case pairing

    private static let environmentKey = "CODEX_WATCH_RENDER_SCENARIO"

    static let fixtureMemoID: MemoID = {
        do {
            return try MemoID("11111111-1111-1111-1111-111111111111")
        } catch {
            preconditionFailure("DEBUG fixture UUID is a valid MemoID")
        }
    }()

    static func parse(environment: [String: String]) -> Self? {
        guard let rawValue = environment[environmentKey] else { return nil }
        return Self(rawValue: rawValue)
    }

    enum Destination: Equatable {
        case captureHome
        case ledger
        case pairing
    }

    var showsCaptureHome: Bool {
        switch self {
        case .ready, .recording, .savedOnWatch, .needsAttention:
            true
        case .delivered, .queue, .pairing:
            false
        }
    }

    var destination: Destination {
        if showsCaptureHome { return .captureHome }
        return self == .pairing ? .pairing : .ledger
    }

    var previewBridgeIsPaired: Bool {
        self != .savedOnWatch
    }

    func capturePresentation() -> CaptureScenePresentation? {
        switch self {
        case .ready:
            CaptureScenePresentation.make(
                captureState: .idle,
                bridgeState: .paired("Studio Mac")
            )
        case .recording:
            CaptureScenePresentation.make(
                captureState: .recording(Self.fixtureMemoID),
                bridgeState: .paired("Studio Mac")
            )
        case .savedOnWatch:
            CaptureScenePresentation.make(
                captureState: .savedOnWatch(Self.fixtureMemoID),
                bridgeState: .notPaired
            )
        case .needsAttention:
            CaptureScenePresentation.make(
                captureState: .interruptedRecordingFound(1),
                bridgeState: .paired("Studio Mac")
            )
        case .delivered, .queue, .pairing:
            nil
        }
    }

    func previewLedgerItems() -> [WatchQueueItem] {
        switch self {
        case .delivered:
            [Self.queueItem(id: "11111111-1111-1111-1111-111111111111", state: .delivered)]
        case .queue:
            [
                Self.queueItem(id: "11111111-1111-1111-1111-111111111111", state: .delivered),
                Self.queueItem(id: "22222222-2222-2222-2222-222222222222", state: .needsAttention),
            ]
        case .ready, .recording, .savedOnWatch, .needsAttention, .pairing:
            []
        }
    }

    private static func queueItem(id: String, state: MemoState) -> WatchQueueItem {
        do {
            return WatchQueueItem(
                id: try MemoID(id),
                capturedAt: Date(timeIntervalSince1970: 0),
                state: state
            )
        } catch {
            preconditionFailure("DEBUG fixture UUID is a valid MemoID")
        }
    }
}

struct WatchRenderScenarioRoot: View {
    let scenario: WatchRenderScenario

    var body: some View {
        Group {
            switch scenario.destination {
            case .captureHome:
                captureFixture
            case .ledger:
                ledgerFixture
            case .pairing:
                pairingFixture
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private var captureFixture: some View {
        CaptureScene(
            presentation: scenario.capturePresentation() ?? CaptureScenePresentation.make(
                captureState: .idle,
                bridgeState: .paired("Studio Mac")
            ),
            bridgeTitle: scenario.previewBridgeIsPaired ? "Studio Mac" : "Pair with Mac",
            recordingStartedAt: scenario == .recording ? .distantPast : nil,
            maximumDuration: scenario == .recording ? 18 : 900,
            recordingLimitDetail: { _ in "Tap to stop" },
            queueCount: scenario == .ready || scenario == .recording ? 0 : 1,
            onPrimaryAction: { _ in },
            onOpenPairing: {},
            onOpenRetention: {},
            onOpenQueue: {},
            bridgeIsPaired: scenario.previewBridgeIsPaired
        )
    }

    private var ledgerFixture: some View {
        let items = scenario.previewLedgerItems()
        return ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text("RELAY LEDGER")
                    .font(WatchExperienceTheme.TypeRole.kicker(compact: false))
                    .tracking(WatchExperienceTheme.TypeRole.kickerTracking(compact: false))
                    .foregroundStyle(WatchExperienceTheme.ColorToken.active)
                Text(RelayLedgerSummary(count: items.count).accessibilityValue)
                    .font(WatchExperienceTheme.TypeRole.detail)
                    .foregroundStyle(.secondary)

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    RelayLedgerRow(
                        item: item,
                        presentation: RelayItemPresentation.make(item: item),
                        isLast: index == items.count - 1,
                        playbackActionTitle: "Play recording",
                        playbackIcon: "play.fill",
                        playbackDisabled: false,
                        timestampLabel: index == 0 ? "Captured 10:10" : "Captured 9:42",
                        onPlayback: {},
                        onDelete: {}
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private var pairingFixture: some View {
        ScrollView {
            VStack(spacing: 9) {
                PairingStepRail(
                    presentation: PairingStepsPresentation(current: .identity)
                )
                Image(systemName: "desktopcomputer.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(WatchExperienceTheme.ColorToken.active)
                Text("Studio Mac")
                    .font(WatchExperienceTheme.TypeRole.emptyHeadline)
                Text("Compare the identity phrase with the bridge on your Mac.")
                    .font(WatchExperienceTheme.TypeRole.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Fingerprint Matches") {}
                    .accessibilityHint("Only continue if the phrase exactly matches Studio Mac")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }
}

#Preview("Paired ready") {
    WatchRenderScenarioRoot(scenario: .ready)
}

#Preview("Unpaired saved") {
    WatchRenderScenarioRoot(scenario: .savedOnWatch)
}

#Preview("Needs attention") {
    WatchRenderScenarioRoot(scenario: .needsAttention)
}

#Preview("Delivered ledger") {
    WatchRenderScenarioRoot(scenario: .delivered)
}

#Preview("Empty ledger") {
    RelayLedgerEmptyView()
}

#Preview("Pairing rail") {
    WatchRenderScenarioRoot(scenario: .pairing)
}
#endif
