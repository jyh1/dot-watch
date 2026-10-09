import SwiftUI

struct CallDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var call: CallModel
    @ObservedObject private var diagnostics = CallDiagnostics.shared
    @State private var deleting: CallDiagnostics.Recording?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Record next call", isOn: $diagnostics.recordNextCall)
                        .disabled(call.phase != "idle" || call.finishing)
                    Text("Records incoming agent audio and timing for one call. Your microphone audio is not saved. Turns off after that call starts and when the app restarts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Each recording is limited to 5 minutes or 10 MB. The call continues after recording stops.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Saved only on this device. Nothing is uploaded or transferred automatically. The five most recent recordings are kept, up to 64 MB.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status = diagnostics.status { Text(status).font(.caption) }
                }
                if diagnostics.recordings.isEmpty {
                    Section("Saved recordings") {
                        Text("No recordings on this device.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(diagnostics.recordings) { recording in
                    Section("Saved recording") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(recording.date, format: .dateTime.month().day().hour().minute()).font(.headline)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(recording.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        // List's automatic button style activates the whole row.
                        // Keep transfer/export and deletion in distinct rows.
                        #if os(iOS)
                        ShareLink(item: recording.url) { Label("Export recording", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("diagnostic-export")
                        #else
                        Button { diagnostics.sendToPhone(recording) } label: {
                            Label("Send to iPhone", systemImage: "iphone.and.arrow.forward")
                        }
                        .accessibilityIdentifier("diagnostic-send")
                        .disabled(call.phase != "idle" || call.finishing)
                        #endif
                        Button("Delete recording", role: .destructive) { deleting = recording }
                            .accessibilityIdentifier("diagnostic-delete")
                    }
                }
                #if os(watchOS)
                Section {
                    Text("Tap Send to iPhone to transfer a recording, then open Call audio diagnostics on iPhone to export it. The Watch copy stays here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("Call diagnostics")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { diagnostics.refresh() }
            .confirmationDialog("Delete this recording?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete recording", role: .destructive) { if let deleting { diagnostics.delete(deleting) }; deleting = nil }
            }
        }
    }
}
