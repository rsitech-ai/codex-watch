import AppKit
import CodexBridgeShared
import SwiftUI

struct BridgeConsoleView: View {
    @ObservedObject var model: BridgeAppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            NavigationSplitView {
                inboxList
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
            } detail: {
                detail
            }
        }
        .background(consoleBackground)
        .navigationTitle(CodexWatchBrand.productName)
        .toolbar { toolbar }
        .onAppear { model.start() }
    }

    private var header: some View {
        let presentation = model.header
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                BridgeSpineView(presentation: presentation.spine)
                    .accessibilitySortPriority(3)

                VStack(alignment: .leading, spacing: 4) {
                    if presentation.kicker.caseInsensitiveCompare(presentation.headline) != .orderedSame {
                        Text(presentation.kicker.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(BridgeExperienceTheme.ColorToken.forTone(presentation.tone))
                    }
                    Text(presentation.headline)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(presentation.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let statusMessage = model.statusMessage {
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(BridgeExperienceTheme.ColorToken.attention)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilitySortPriority(4)

                if let title = presentation.primaryTitle {
                    Button {
                        Task { await model.performHeaderAction() }
                    } label: {
                        Label(title, systemImage: headerSymbol(for: title))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BridgeExperienceTheme.ColorToken.forTone(presentation.tone))
                    .disabled(model.speechBusy || model.pairingBusy)
                    .accessibilityHint(presentation.primaryHint ?? "")
                    .accessibilitySortPriority(2)
                }
            }

            metaRow
            pairingStrip
        }
        .padding(20)
        .background {
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                Rectangle().fill(.thinMaterial)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 16) {
            labeledValue("Watch", model.watchPaired ? "Paired" : "Not paired")
            labeledValue("Listener", listenerLabel)
            labeledValue("Speech", BridgeSpeechCopy.menuStatus(for: model.speech))
            labeledValue("Advertised", model.advertisedName)
            labeledValue("Host", model.advertisedHost)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }

    private var listenerLabel: String {
        if model.listenerPaused { return "Paused" }
        return model.listenerOnline ? "Online" : "Offline"
    }

    @ViewBuilder
    private var pairingStrip: some View {
        if let pairing = model.pairing {
            VStack(alignment: .leading, spacing: 8) {
                Text("Certificate phrase")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(pairing.phrase)
                    .font(.body.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("Certificate phrase: \(pairing.phrase)")
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(pairing.code)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .accessibilityLabel("Pairing code: \(pairing.code)")
                    TimelineView(.periodic(from: pairing.expiresAt.addingTimeInterval(-BridgeCommand.pairingChallengeLifetime), by: 1)) { context in
                        Text(PairingExpiryCopy.text(expiresAt: pairing.expiresAt, now: context.date))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(reduceMotion ? .identity : .opacity)
                    }
                    Button("Generate new code") {
                        Task { await model.generatePairingCode() }
                    }
                    .disabled(model.pairingBusy)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pairingBackground)
        }
    }

    private var inboxList: some View {
        List(model.items, selection: $model.selectedMemoID) { item in
            let presentation = MacInboxItemPresentation.make(item: item, speech: model.speech)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    inboxGlyph(for: presentation.tone)
                    Text(presentation.status)
                        .font(.headline)
                        .foregroundStyle(BridgeExperienceTheme.ColorToken.forTone(presentation.tone))
                }
                Text(item.capturedAt, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .tag(item.id)
            .accessibilityLabel(presentation.accessibilityValue)
            .contextMenu {
                if presentation.retryEnabled {
                    Button("Retry transcription") {
                        model.selectedMemoID = item.id
                        Task { await model.retrySelected() }
                    }
                }
            }
        }
        .overlay {
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("Relay ledger empty", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Memos appear here after the Watch delivers audio to this Mac.")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedItem {
            let presentation = MacInboxItemPresentation.make(item: item, speech: model.speech)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if presentation.spine != model.header.spine {
                        BridgeSpineView(presentation: presentation.spine)
                    }
                    if item.id != model.items.first?.id {
                        Text(presentation.status)
                            .font(.title2.weight(.bold))
                        Text(presentation.detail)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Captured", value: item.capturedAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Audio") {
                        Text(item.audioIsPresent ? "On this Mac" : "Not on this Mac")
                    }
                    if let transcript = item.transcript {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Transcript")
                                .font(.headline)
                            Text(transcript)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    HStack {
                        if presentation.retryEnabled, !presentation.speechCTA {
                            Button("Retry transcription") {
                                Task { await model.retrySelected() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(BridgeExperienceTheme.ColorToken.attention)
                            .disabled(model.speech != .authorized)
                            .accessibilityLabel("Retry transcription")
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("Select a memo", systemImage: "waveform")
            } description: {
                Text("The Watch-to-Mac-to-Codex path for that recording appears here.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .labelStyle(.titleAndIcon)
            .help("Reload listener, pairing, Speech, and inbox state")
            Button("Pairing code", systemImage: "link") {
                Task { await model.generatePairingCode() }
            }
            .labelStyle(.titleAndIcon)
            .help("Generate a certificate phrase and 6-digit Watch code")
            .disabled(model.pairingBusy)
            Button("Speech", systemImage: "waveform") {
                Task { await model.authorizeSpeech() }
            }
            .labelStyle(.titleAndIcon)
            .help("Ask macOS for Speech Recognition so memos can transcribe locally")
            .disabled(model.speechBusy)
        }
    }

    private var consoleBackground: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color.clear
            }
        }
    }

    private var pairingBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(contrast == .increased ? 0.12 : 0.06))
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.6)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func headerSymbol(for title: String) -> String {
        switch title {
        case "Allow Speech Recognition": "waveform"
        case "Open Speech Settings": "gearshape"
        case "Generate pairing code": "link"
        case "Retry transcription": "arrow.clockwise"
        default: "exclamationmark.triangle.fill"
        }
    }

    private func inboxGlyph(for tone: BridgeExperienceTone) -> some View {
        Group {
            switch tone {
            case .neutral:
                Circle().stroke(BridgeExperienceTheme.ColorToken.forTone(tone), lineWidth: 1.5)
            case .active:
                RoundedRectangle(cornerRadius: 2)
                    .fill(BridgeExperienceTheme.ColorToken.forTone(tone))
                    .rotationEffect(.degrees(45))
            case .confirmed:
                ZStack {
                    Circle().fill(BridgeExperienceTheme.ColorToken.forTone(tone))
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black)
                }
            case .attention, .destructive:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(BridgeExperienceTheme.ColorToken.forTone(tone))
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        Form {
            LabeledContent("App", value: CodexWatchBrand.productName)
            LabeledContent("Advertised name", value: model.advertisedName)
            LabeledContent("Advertised host", value: model.advertisedHost)
            LabeledContent("Bind host", value: model.bindHost)
            LabeledContent("State") {
                Text(model.stateRootPath)
                    .textSelection(.enabled)
                    .font(.body.monospaced())
            }
            LabeledContent("Watch", value: model.watchPaired ? "Paired" : "Not paired")
            LabeledContent("Listener", value: model.listenerOnline ? "Online" : "Offline")
            LabeledContent("Speech", value: BridgeSpeechCopy.menuStatus(for: model.speech))
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 280)
        .padding()
    }
}

enum BridgeMenuStatusCopy {
    @MainActor
    static func line(model: BridgeAppModel) -> String {
        let watch = model.watchPaired ? "Watch paired" : "Watch not paired"
        let mac = model.listenerOnline ? "Mac online" : "Mac offline"
        let speech = BridgeSpeechCopy.menuStatus(for: model.speech)
        return "\(watch) · \(mac) · \(speech)"
    }
}
