import SwiftUI

struct RetentionSettingsView: View {
    @EnvironmentObject private var model: VoiceCaptureModel

    var body: some View {
        List {
            Section("Delivered audio") {
                Picker("Keep delivered audio", selection: retentionSelection) {
                    ForEach(WatchDeliveredRetentionChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section {
                Label {
                    Text("Only audio with confirmed Codex delivery is eligible. Waiting, sending, and needs-attention recordings remain on this Watch.")
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(WatchExperienceTheme.ColorToken.confirmed)
                }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Audio retention")
    }

    private var retentionSelection: Binding<WatchDeliveredRetentionChoice> {
        Binding(
            get: { model.deliveredRetentionChoice },
            set: { choice in
                Task {
                    await model.setDeliveredRetentionChoice(choice)
                }
            }
        )
    }
}
