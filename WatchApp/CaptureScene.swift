import Foundation
import SwiftUI

enum CaptureElapsedTime {
    static func text(start: Date, now: Date, maximumDuration: TimeInterval) -> String {
        let boundedMaximum = max(0, Int(maximumDuration.rounded(.down)))
        let elapsed = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
        let boundedElapsed = min(elapsed, boundedMaximum)
        return String(format: "%d:%02d", boundedElapsed / 60, boundedElapsed % 60)
    }
}

enum CapturePrivacyMode {
    case standard
    case reducedLuminance

    var showsState: Bool { true }
    var showsElapsedTime: Bool { true }
    var showsEssentialAction: Bool { true }
    var showsSecondaryDetail: Bool { self == .standard }
    var spineOpacity: Double { self == .standard ? 1 : 0.52 }
}

enum CaptureLayoutPolicy {
    static let fitAxes: Axis.Set = [.horizontal, .vertical]
    static var pinsPrimaryActionToBottomInset: Bool {
        CaptureAccessibilityPriority.branch(for: .primaryAction) == .bottomSafeAreaInset
    }
    static let primaryInsetSpacing: CGFloat = 6
    static let sceneHorizontalPadding: CGFloat = 7
    static let sceneBottomPadding: CGFloat = 5
}

struct CaptureScene: View {
    let presentation: CaptureScenePresentation
    let bridgeTitle: String
    let recordingStartedAt: Date?
    let maximumDuration: TimeInterval
    let recordingLimitDetail: (Date) -> String
    let queueCount: Int
    let onPrimaryAction: (WatchPrimaryAction) -> Void
    let onOpenPairing: () -> Void
    let onOpenRetention: () -> Void
    let onOpenQueue: () -> Void
    var bridgeIsPaired = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var privacyMode: CapturePrivacyMode {
        isLuminanceReduced ? .reducedLuminance : .standard
    }

    var body: some View {
        pinnedPrimaryAction(fittedInstrument)
            .padding(.horizontal, CaptureLayoutPolicy.sceneHorizontalPadding)
            .padding(.bottom, CaptureLayoutPolicy.sceneBottomPadding)
    }

    private var fittedInstrument: some View {
        ViewThatFits(in: CaptureLayoutPolicy.fitAxes) {
            instrument(isCompact: false)
            instrument(isCompact: true)
            ScrollView {
                instrument(isCompact: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func pinnedPrimaryAction<Content: View>(_ content: Content) -> some View {
        if CaptureLayoutPolicy.pinsPrimaryActionToBottomInset,
           CaptureAccessibilityPriority.branch(for: .primaryAction) == .bottomSafeAreaInset
        {
            content.safeAreaInset(edge: .bottom, spacing: CaptureLayoutPolicy.primaryInsetSpacing) {
                primaryActionChrome
                    .accessibilitySortPriority(CaptureAccessibilityPriority.primaryAction)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var primaryActionChrome: some View {
        if privacyMode.showsEssentialAction {
            WatchPrimaryActionView(
                action: presentation.primaryAction,
                tone: actionTone,
                isDisabled: presentation.primaryActionDisabled
            ) {
                onPrimaryAction(presentation.primaryAction)
            }
        }
    }

    private func instrument(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 9) {
            statusHeader(isCompact: isCompact)

            HStack(alignment: .center, spacing: isCompact ? 10 : 14) {
                SignalSpineView(
                    presentation: presentation.spine,
                    nodeSpacing: isCompact ? 10 : WatchExperienceTheme.Metric.nodeSpacing
                )
                    .opacity(privacyMode.spineOpacity)
                    .fixedSize()
                    .accessibilitySortPriority(CaptureAccessibilityPriority.relayPath)

                hero(isCompact: isCompact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilitySortPriority(CaptureAccessibilityPriority.state)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusHeader(isCompact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(presentation.kicker.uppercased())
                .font(WatchExperienceTheme.TypeRole.kicker(compact: isCompact))
                .tracking(WatchExperienceTheme.TypeRole.kickerTracking(compact: isCompact))
                .foregroundStyle(WatchExperienceTheme.ColorToken.forTone(presentation.tone))
                .lineLimit(1)
                .minimumScaleFactor(isCompact ? 0.68 : 0.85)
                .layoutPriority(1)
                .accessibilitySortPriority(CaptureAccessibilityPriority.state)

            Spacer(minLength: 4)

            Button(action: onOpenRetention) {
                Image(systemName: "gearshape")
                    .font(WatchExperienceTheme.TypeRole.headerUtility)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .layoutPriority(2)
            .accessibilityLabel("Retention settings")
            .accessibilityHint("Changes how long delivered audio remains on this Watch")
            .accessibilitySortPriority(CaptureAccessibilityPriority.secondaryNavigation)

            Button(action: onOpenPairing) {
                if CapturePairingChrome.showsLabeledHeader(isPaired: bridgeIsPaired) {
                    Text(CapturePairingChrome.unpairedHeaderTitle)
                        .font(WatchExperienceTheme.TypeRole.headerUtility)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Image(systemName: "desktopcomputer")
                        .font(WatchExperienceTheme.TypeRole.headerUtility)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .layoutPriority(2)
            .accessibilityLabel(
                CapturePairingChrome.showsLabeledHeader(isPaired: bridgeIsPaired)
                    ? CapturePairingChrome.unpairedHeaderTitle
                    : "Mac bridge status: \(bridgeTitle)"
            )
            .accessibilityHint("Opens secure Mac pairing")
            .accessibilitySortPriority(CaptureAccessibilityPriority.secondaryNavigation)

            Button(action: onOpenQueue) {
                Image(systemName: "tray.full")
                    .font(WatchExperienceTheme.TypeRole.headerUtility)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .layoutPriority(2)
            .accessibilityLabel("Relay ledger")
            .accessibilityValue("\(queueCount) \(queueCount == 1 ? "item" : "items")")
            .accessibilityHint("Opens saved recordings and relay status")
            .accessibilitySortPriority(CaptureAccessibilityPriority.secondaryNavigation)
        }
    }

    @ViewBuilder
    private func hero(isCompact: Bool) -> some View {
        if presentation.showsElapsedTime, let recordingStartedAt {
            TimelineView(.periodic(from: recordingStartedAt, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(CaptureElapsedTime.text(
                        start: recordingStartedAt,
                        now: context.date,
                        maximumDuration: maximumDuration
                    ))
                    .font(WatchExperienceTheme.TypeRole.recordingTime(compact: isCompact))
                    .monospacedDigit()
                    .contentTransition(
                        SignalMotionStyle.forTransition(reduceMotion: reduceMotion) == .crossFade
                            ? .opacity
                            : .numericText()
                    )
                    .animation(
                        SignalMotionStyle.forTransition(reduceMotion: reduceMotion).animation,
                        value: context.date
                    )
                    .accessibilityLabel("Recording time")

                    if privacyMode.showsSecondaryDetail {
                        let limitDetail = recordingLimitDetail(context.date)
                        Text(limitDetail)
                            .font(WatchExperienceTheme.TypeRole.detail)
                            .foregroundStyle(
                                limitDetail == "Tap to stop"
                                    ? Color.secondary
                                    : WatchExperienceTheme.ColorToken.attention
                            )
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .allowsTightening(true)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if privacyMode.showsState {
                    Text(presentation.headline)
                        .font(WatchExperienceTheme.TypeRole.heroHeadline(compact: isCompact))
                        .minimumScaleFactor(0.75)
                        .lineLimit(isCompact ? 2 : 3)
                }

                if privacyMode.showsSecondaryDetail {
                    Text(presentation.detail)
                        .font(WatchExperienceTheme.TypeRole.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(isCompact ? 0.68 : 0.82)
                        .allowsTightening(true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var actionTone: WatchExperienceTone {
        presentation.primaryAction == .stopAndSave ? .destructive : presentation.tone
    }
}
