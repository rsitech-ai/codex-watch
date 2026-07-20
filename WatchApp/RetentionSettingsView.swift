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
                Text("Only ideas already added to Codex are eligible. Waiting or attention items stay on this Watch.")
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
