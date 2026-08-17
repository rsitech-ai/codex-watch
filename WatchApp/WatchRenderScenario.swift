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

    static func parse(environment: [String: String]) -> Self? {
        guard let rawValue = environment[environmentKey] else { return nil }
        return Self(rawValue: rawValue)
    }
}

struct WatchRenderScenarioRoot: View {
    let scenario: WatchRenderScenario

    var body: some View {
        Group {
            switch scenario {
            case .ready, .recording, .savedOnWatch, .delivered, .needsAttention:
                captureFixture
            case .queue:
                queueFixture
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
            presentation: capturePresentation,
            bridgeTitle: "Studio Mac",
            recordingStartedAt: scenario == .recording ? .distantPast : nil,
            maximumDuration: scenario == .recording ? 18 : 900,
            recordingLimitDetail: { _ in "Tap to stop" },
            queueCount: scenario == .ready || scenario == .recording ? 0 : 1,
            onPrimaryAction: { _ in },
            onOpenPairing: {},
            onOpenRetention: {},
            onOpenQueue: {},
            bridgeIsPaired: scenario != .savedOnWatch && scenario != .needsAttention
        )
    }

    private var capturePresentation: CaptureScenePresentation {
        switch scenario {
        case .ready:
            CaptureScenePresentation.make(
                captureState: .idle,
                bridgeState: .paired("Studio Mac")
            )
        case .recording:
            capture(
                kicker: "Recording",
                headline: "Recording",
                detail: "Audio stays on this Watch",
                tone: .active,
                spine: .init(
                    watch: .active,
                    mac: .pending,
                    codex: .pending,
                    accessibilityValue: "Recording on Watch; Mac pending; Codex pending"
                ),
                action: .stopAndSave,
                showsElapsedTime: true
            )
        case .savedOnWatch:
            capture(
                kicker: "Saved on Watch",
                headline: "Thought secured.",
                detail: "Waiting for Studio Mac",
                tone: .confirmed,
                spine: .init(
                    watch: .confirmed,
                    mac: .pending,
                    codex: .pending,
                    accessibilityValue: "Saved on Watch; waiting for Mac; Codex pending"
                ),
                action: .recordAnother
            )
        case .delivered:
            capture(
                kicker: "Delivered",
                headline: "Relay complete.",
                detail: "Confirmed 10:10",
                tone: .confirmed,
                spine: .init(
                    watch: .confirmed,
                    mac: .confirmed,
                    codex: .confirmed,
                    accessibilityValue: "Saved on Watch; received by Mac; delivered to Codex"
                ),
                action: .recordAnother
            )
        case .needsAttention:
            capture(
                kicker: "Needs attention",
                headline: "Relay needs attention.",
                detail: "Audio remains on this Watch",
                tone: .attention,
                spine: .init(
                    watch: .confirmed,
                    mac: .pending,
                    codex: .pending,
                    accessibilityValue: "Saved on Watch; remote phase unavailable"
                ),
                action: .retryRelay
            )
        case .queue, .pairing:
            CaptureScenePresentation.make(
                captureState: .idle,
                bridgeState: .paired("Studio Mac")
            )
        }
    }

    private func capture(
        kicker: String,
        headline: String,
        detail: String,
        tone: WatchExperienceTone,
        spine: SignalSpinePresentation,
        action: WatchPrimaryAction,
        showsElapsedTime: Bool = false
    ) -> CaptureScenePresentation {
        CaptureScenePresentation(
            kicker: kicker,
            headline: headline,
            detail: detail,
            tone: tone,
            spine: spine,
            primaryAction: action,
            showsElapsedTime: showsElapsedTime,
            primaryActionDisabled: false
        )
    }

    private var queueFixture: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text("RELAY LEDGER")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.75)
                    .foregroundStyle(WatchExperienceTheme.ColorToken.active)
                Text("2 saved recordings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(Array(queueItems.enumerated()), id: \.element.id) { index, item in
                    RelayLedgerRow(
                        item: item,
                        presentation: RelayItemPresentation.make(item: item),
                        isLast: index == queueItems.count - 1,
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

    private var queueItems: [WatchQueueItem] {
        let fixtures: [(String, MemoState)] = [
            ("11111111-1111-1111-1111-111111111111", .delivered),
            ("22222222-2222-2222-2222-222222222222", .needsAttention),
        ]
        return fixtures.compactMap { rawID, state in
            guard let memoID = try? MemoID(rawID) else { return nil }
            return WatchQueueItem(
                id: memoID,
                capturedAt: Date(timeIntervalSince1970: 0),
                state: state
            )
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
                    .font(.headline)
                Text("Compare the identity phrase with the bridge on your Mac.")
                    .font(.caption2)
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
#endif
