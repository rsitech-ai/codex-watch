import AppKit
import SwiftUI

struct VoiceInboxBridgeApp: App {
    @StateObject private var model = BridgeAppModel()

    var body: some Scene {
        WindowGroup(CodexWatchBrand.productName, id: "bridge") {
            BridgeConsoleView(model: model)
                .frame(minWidth: 960, minHeight: 520)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
        }
        .defaultSize(width: 1100, height: 680)
        .defaultLaunchBehavior(.presented)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {
                Button(BridgeFileMenuCopy.saveSpec) {
                    model.saveSelectedSpec(asHTML: false)
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!model.canSaveSelectedSpec || model.specBusy)
                Button(BridgeFileMenuCopy.saveHTML) {
                    model.saveSelectedSpec(asHTML: true)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.canSaveSelectedSpec || model.specBusy)
            }
            CommandMenu("Bridge") {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button("Generate Pairing Code") {
                    Task { await model.generatePairingCode() }
                }
                .keyboardShortcut("p", modifiers: [.command])
                Button("Allow Speech Recognition") {
                    Task { await model.authorizeSpeech() }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Retry Transcription") {
                    Task { await model.retrySelected() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                Button("Use Current Address") {
                    Task { await model.rebindToCurrentAddress() }
                }
                .disabled(model.rebindBusy)
                Button("Reset…") {
                    model.presentResetConfirmation()
                }
                .disabled(model.resetBusy)
            }
        }

        MenuBarExtra(CodexWatchBrand.productName, systemImage: "point.3.connected.trianglepath.dotted") {
            BridgeMenuBarContent(model: model)
        }

        Settings {
            BridgeSettingsView(model: model)
        }
    }
}

private struct BridgeMenuBarContent: View {
    @ObservedObject var model: BridgeAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(BridgeMenuStatusCopy.line(model: model))
        Text(model.header.detail)
            .foregroundStyle(.secondary)
            .onAppear { model.start() }
        Divider()
        Button("Open \(CodexWatchBrand.productName)") {
            openWindow(id: "bridge")
            NSApp.activate()
        }
        Button("Generate Pairing Code") {
            Task { await model.generatePairingCode() }
            openWindow(id: "bridge")
        }
        Button("Allow Speech Recognition") {
            Task { await model.authorizeSpeech() }
            openWindow(id: "bridge")
        }
    }
}
