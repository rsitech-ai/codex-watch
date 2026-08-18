import CodexBridgeService
import CodexBridgeShared
import SwiftUI

struct BridgeConsoleView: View {
    @ObservedObject var model: BridgeAppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var hierarchy: BridgeConsoleStatusHierarchy {
        model.statusHierarchy
    }

    var body: some View {
        NavigationSplitView {
            inboxList
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .inspector(isPresented: .constant(true)) {
            operatorInspector
                .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
        }
        .background(consoleBackground)
        .navigationTitle(CodexWatchBrand.productName)
        .modifier(OptionalNavigationSubtitle(hierarchy.chromeHeadline))
        .toolbar { toolbar }
        .sheet(isPresented: $model.pairingSheetPresented) {
            pairingSheet
        }
        .bridgeResetConfirmation(model: model)
        .onAppear {
            model.start()
            Task { await model.improveSelectedSpecIfNeeded() }
        }
        .onChange(of: model.selectedMemoID) {
            Task { await model.improveSelectedSpecIfNeeded() }
        }
    }

    private var inboxList: some View {
        List(model.items, selection: $model.selectedMemoID) { item in
            let presentation = MacInboxItemPresentation.make(item: item, speech: model.speech)
            HStack(spacing: 8) {
                inboxGlyph(for: presentation.tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.status)
                        .font(.body.weight(.medium))
                        .foregroundStyle(BridgeExperienceTheme.ColorToken.forTone(presentation.tone))
                    Text(item.capturedAt, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .tag(item.id)
            .accessibilityLabel(presentation.accessibilityValue)
            .contextMenu {
                if presentation.retryEnabled {
                    Button(item.transcript == nil ? "Retry transcription" : "Retry Codex insert") {
                        model.selectedMemoID = item.id
                        Task { await model.retrySelected() }
                    }
                }
                if presentation.showsSpecDownload {
                    Button(BridgeFileMenuCopy.saveSpec) { model.saveSelectedSpec(asHTML: false) }
                    Button(BridgeFileMenuCopy.saveHTML) { model.saveSelectedSpec(asHTML: true) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("Inbox empty", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Memos appear here after the Watch delivers audio to this Mac.")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarChrome
        }
    }

    private var sidebarChrome: some View {
        HStack(spacing: 16) {
            labeledValue("Watch", model.watchPaired ? "Paired" : "Not paired")
            labeledValue("Listener", listenerLabel)
            labeledValue("Speech", BridgeSpeechCopy.menuStatus(for: model.speech))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var listenerLabel: String {
        if model.listenerPaused { return "Paused" }
        return model.listenerOnline ? "Online" : "Offline"
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedItem {
            memoInspector(item: item)
        } else {
            emptyDetail
        }
    }

    private func memoInspector(item: MacInboxItem) -> some View {
        let presentation = MacInboxItemPresentation.make(item: item, speech: model.speech)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BridgeSpineView(presentation: presentation.spine)
                    .accessibilitySortPriority(3)

                if let title = hierarchy.inspectorTitle {
                    Text(title)
                        .font(BridgeExperienceTheme.TypeRole.inspectorTitle)
                        .foregroundStyle(BridgeExperienceTheme.ColorToken.forTone(presentation.tone))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilitySortPriority(4)
                }

                Text(presentation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                pipelineSection(for: item, speech: model.speech)

                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(BridgeExperienceTheme.ColorToken.attention)
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

                if presentation.showsSpecDownload, let specMarkdown = item.specMarkdown {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Spec")
                            .font(.headline)
                        Text(MemoSpecCopy.provenanceLabel(item.specProvenance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button(BridgeFileMenuCopy.saveSpec) {
                                model.saveSelectedSpec(asHTML: false)
                            }
                            .disabled(model.specBusy)
                            Button(BridgeFileMenuCopy.saveHTML) {
                                model.saveSelectedSpec(asHTML: true)
                            }
                            .disabled(model.specBusy)
                        }
                        Text(specMarkdown)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if presentation.retryEnabled, !presentation.speechCTA {
                    let retryTitle = item.transcript == nil
                        ? "Retry transcription"
                        : "Retry Codex insert"
                    Button(retryTitle) {
                        Task { await model.retrySelected() }
                    }
                    .buttonStyle(.bordered)
                    .tint(BridgeExperienceTheme.ColorToken.attention)
                    .disabled(item.transcript == nil && model.speech != .authorized)
                    .accessibilityLabel(retryTitle)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    @ViewBuilder
    private var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            BridgeSpineView(presentation: model.header.spine)
            Text(model.header.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(BridgeExperienceTheme.ColorToken.attention)
            }
            if model.pairing != nil, !model.pairingSheetPresented {
                Button("Show pairing code") {
                    model.pairingSheetPresented = true
                }
            }
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("Waiting for the Watch", systemImage: "applewatch")
                } description: {
                    Text("Pairing, Speech, and listener status stay in the sidebar.")
                }
            } else {
                ContentUnavailableView {
                    Label("Select a memo", systemImage: "waveform")
                } description: {
                    Text("The Watch-to-Mac-to-Codex path for that recording appears here.")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pairingSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(BridgePairingCopy.macShowsOnly)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let pairing = model.pairing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Certificate phrase")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(pairing.phrase)
                            .font(.body.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                            .accessibilityLabel("Certificate phrase: \(pairing.phrase)")
                        Text(pairing.code)
                            .font(BridgeExperienceTheme.TypeRole.pairingCode)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .accessibilityLabel("Pairing code: \(pairing.code)")
                        TimelineView(.periodic(
                            from: pairing.expiresAt.addingTimeInterval(-BridgeCommand.pairingChallengeLifetime),
                            by: 1
                        )) { context in
                            Text(PairingExpiryCopy.text(expiresAt: pairing.expiresAt, now: context.date))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                                .animation(
                                    BridgeMotionStyle.forTransition(reduceMotion: reduceMotion).animation,
                                    value: context.date
                                )
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(pairingBackground)
                }
                Button("Generate new code") {
                    Task { await model.generatePairingCode() }
                }
                .disabled(model.pairingBusy)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(BridgePairingCopy.sheetTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.pairingSheetPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private var toolbarPresentation: BridgeConsoleToolbarPresentation {
        .make(header: model.header, canSaveSelectedSpec: model.canSaveSelectedSpec)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .labelStyle(.titleAndIcon)
            .help("Reload listener, pairing, Speech, and inbox state")
        }

        ToolbarItem(placement: .automatic) {
            Button("Reset", systemImage: "arrow.counterclockwise") {
                model.presentResetConfirmation()
            }
            .labelStyle(.titleAndIcon)
            .help("Regenerate pairing display and clear retries. Does not wipe Watch Keychain or rotate TLS.")
            .disabled(model.resetBusy)
        }

        if toolbarPresentation.showsPairingCode {
            ToolbarItem(placement: .automatic) {
                Button("Pairing code", systemImage: "link") {
                    Task { await model.generatePairingCode() }
                }
                .labelStyle(.titleAndIcon)
                .help("Generate a certificate phrase and 6-digit Watch code")
                .disabled(model.pairingBusy)
            }
        }

        if let title = toolbarPresentation.headerPrimaryTitle {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.performHeaderAction() }
                } label: {
                    Label(title, systemImage: toolbarPresentation.headerPrimarySymbol)
                }
                .labelStyle(.titleAndIcon)
                .help(toolbarPresentation.headerPrimaryHint ?? title)
                .disabled(model.speechBusy || model.pairingBusy || model.rebindBusy)
            }
        }

        if toolbarPresentation.showsSaveSpec {
            ToolbarItem(placement: toolbarPresentation.showsHeaderPrimary ? .automatic : .primaryAction) {
                Button(BridgeFileMenuCopy.saveSpec, systemImage: "doc.badge.arrow.up") {
                    model.saveSelectedSpec(asHTML: false)
                }
                .labelStyle(.titleAndIcon)
                .help("Save the markdown spec")
                .disabled(model.specBusy)
            }
            ToolbarItem(placement: .automatic) {
                Button(BridgeFileMenuCopy.saveHTML, systemImage: "doc.richtext") {
                    model.saveSelectedSpec(asHTML: true)
                }
                .labelStyle(.titleAndIcon)
                .help("Save a simple HTML document of the spec")
                .disabled(model.specBusy)
            }
        }
    }

    private var consoleBackground: some View {
        Color(nsColor: .windowBackgroundColor)
    }

    private var pairingBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                reduceTransparency
                    ? Color(nsColor: .windowBackgroundColor)
                    : Color.primary.opacity(
                        BridgePairingFill.opacity(increasedContrast: contrast == .increased)
                    )
            )
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func pipelineSection(for item: MacInboxItem, speech: BridgeSpeechAuthorizationStatus) -> some View {
        let stages = MemoPipelinePresentation.stages(item: item, speech: speech)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Pipeline")
                .font(.headline)
            ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    inboxGlyph(for: tone(for: stage.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.label)
                            .font(.body.weight(.medium))
                        Text(stage.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stage.label). \(stage.detail)")
            }
        }
    }

    private var operatorInspector: some View {
        let status = model.operatorStatus ?? BridgeOperatorStatusPresentation.make(
            loaded: model.loaded,
            healthy: model.healthy,
            bindHost: model.bindHost,
            advertisedHost: model.advertisedHost,
            currentHosts: model.currentHosts,
            fingerprint: nil,
            launchAgentPID: model.launchAgentPID,
            lastEvent: model.lastDiagnostic,
            watchPaired: model.watchPaired,
            lastIntake: model.items.first?.capturedAt,
            speech: model.speech,
            foundationModels: FoundationModelsAvailability.current()
        )
        return Form {
            Section("Bridge") {
                LabeledContent("Loaded", value: status.loaded)
                LabeledContent("Healthy", value: status.healthy)
                LabeledContent("Listening", value: status.listening)
                LabeledContent("Bonjour", value: status.bonjourInstance)
                LabeledContent("TLS pin", value: status.tlsFingerprintShort)
                LabeledContent("LaunchAgent pid", value: status.launchAgentPID)
                LabeledContent("Last error", value: status.lastError)
            }
            Section("Watch") {
                LabeledContent("Pairing", value: status.watchPaired)
                LabeledContent("Last intake", value: status.lastIntake)
                LabeledContent("Last upload", value: status.lastUploadAttempt)
                LabeledContent("Queue", value: status.queueDepth)
            }
            Section("Speech") {
                LabeledContent("Status", value: status.speech)
                if status.speechNeedsCTA {
                    Button(model.speech == .notDetermined ? "Allow Speech Recognition" : "Open Speech Settings") {
                        if model.speech == .notDetermined {
                            Task { await model.authorizeSpeech() }
                        } else {
                            model.openSpeechSettings()
                        }
                    }
                }
            }
            Section("Spec") {
                Text(status.specEngine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.bindUnreachable {
                Section("Reachability") {
                    Text(status.detail)
                        .foregroundStyle(BridgeExperienceTheme.ColorToken.attention)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use current address") {
                        Task { await model.rebindToCurrentAddress() }
                    }
                    .disabled(model.rebindBusy)
                }
            }
            Section("Operator") {
                Button("Reset…") {
                    model.presentResetConfirmation()
                }
                .disabled(model.resetBusy)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tone(for state: BridgeSpineNodeState) -> BridgeExperienceTone {
        switch state {
        case .pending: .neutral
        case .active: .active
        case .confirmed: .confirmed
        case .attention: .attention
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

private struct OptionalNavigationSubtitle: ViewModifier {
    let subtitle: String?

    init(_ subtitle: String?) {
        self.subtitle = subtitle
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let subtitle, !subtitle.isEmpty {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}

struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        Form {
            Section("App") {
                LabeledContent("App", value: CodexWatchBrand.productName)
                LabeledContent("State") {
                    Text(model.stateRootPath)
                        .textSelection(.enabled)
                        .font(.body.monospaced())
                }
            }
            Section("Network") {
                LabeledContent("Advertised name", value: model.advertisedName)
                LabeledContent("Advertised host", value: model.advertisedHost)
                LabeledContent("Bind host", value: model.bindHost)
            }
            Section("Status") {
                LabeledContent("Watch", value: model.watchPaired ? "Paired" : "Not paired")
                LabeledContent("Listener", value: model.listenerOnline ? "Online" : "Offline")
                LabeledContent("Speech", value: BridgeSpeechCopy.menuStatus(for: model.speech))
                LabeledContent("TLS pin", value: model.tlsFingerprintShort)
                LabeledContent("LaunchAgent pid", value: model.launchAgentPID.map(String.init) ?? "unknown")
            }
            Section("Operator") {
                Button("Use current address") {
                    Task { await model.rebindToCurrentAddress() }
                }
                .disabled(model.rebindBusy)
                Button("Reset…", role: .destructive) {
                    model.presentResetConfirmation()
                }
                .disabled(model.resetBusy)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .padding()
        .bridgeResetConfirmation(model: model)
    }
}

private extension View {
    func bridgeResetConfirmation(model: BridgeAppModel) -> some View {
        confirmationDialog(
            BridgeResetCopy.confirmTitle,
            isPresented: Binding(
                get: { model.resetConfirmationPresented },
                set: { model.resetConfirmationPresented = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button(BridgeResetCopy.confirm) {
                Task { await model.performReset(confirmed: true, forgetDisplayedPairing: false) }
            }
            Button(BridgeResetCopy.confirmAndForget) {
                Task { await model.performReset(confirmed: true, forgetDisplayedPairing: true) }
            }
            Button(BridgeResetCopy.cancel, role: .cancel) {
                model.cancelReset()
            }
        } message: {
            Text(BridgeResetCopy.message)
        }
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

#Preview("Delivered") {
    previewConsole(.delivered)
}

#Preview("Delivered dark") {
    previewConsole(.delivered)
        .preferredColorScheme(.dark)
}

#Preview("Needs attention") {
    previewConsole(.needsAttention)
}

#Preview("Needs attention dark") {
    previewConsole(.needsAttention)
        .preferredColorScheme(.dark)
}

#Preview("Unpaired") {
    previewConsole(.unpaired)
}

#Preview("Unpaired dark") {
    previewConsole(.unpaired)
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    previewConsole(.empty)
}

#Preview("Empty dark") {
    previewConsole(.empty)
        .preferredColorScheme(.dark)
}

@MainActor
private func previewConsole(_ kind: BridgeAppModel.PreviewKind) -> some View {
    let model = BridgeAppModel(pollsRuntime: false)
    model.seedPreview(kind)
    return BridgeConsoleView(model: model)
        .frame(minWidth: 1100, minHeight: 680)
}
