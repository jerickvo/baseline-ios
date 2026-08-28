import SwiftUI

/// Full metadata for one session plus zip export through the share sheet.
struct SessionDetailView: View {
    let record: SessionRecord

    @State private var exportedZip: ExportedZip?
    @State private var isExporting = false
    @State private var exportError: String?

    private var metadata: SessionMetadata { record.metadata }

    var body: some View {
        List {
            if metadata.hasGaps {
                Section {
                    Label {
                        Text("\(metadata.totalGapCount) gap\(metadata.totalGapCount == 1 ? "" : "s") detected, largest \(String(format: "%.3f", metadata.largestGapSeconds)) s.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
            }
            Section("Session") {
                row("Label", metadata.label.isEmpty ? "—" : metadata.label)
                row("Start", metadata.startTime)
                row("End", metadata.endTime)
                row("Duration", Format.duration(metadata.durationSeconds))
                row("ID", metadata.id)
                row("Device", metadata.deviceModel)
                row("iOS", metadata.iosVersion)
            }
            Section("Samples") {
                row("Motion", "\(metadata.motionSampleCount)")
                row("Raw accel", "\(metadata.accelSampleCount)")
                row("GPS", "\(metadata.gpsSampleCount)")
                row("Achieved motion rate", String(format: "%.2f Hz", metadata.achievedMotionHz))
                row("Achieved accel rate", String(format: "%.2f Hz", metadata.achievedAccelHz))
            }
            Section("Gaps") {
                row("Motion gaps", "\(metadata.motionGapCount)")
                row("Accel gaps", "\(metadata.accelGapCount)")
                row("Largest gap", String(format: "%.3f s", metadata.largestGapSeconds))
            }
            if !metadata.eventMarkers.isEmpty {
                Section("Event markers") {
                    ForEach(0..<metadata.eventMarkers.count, id: \.self) { index in
                        let marker = metadata.eventMarkers[index]
                        row(Format.duration(marker.t), marker.note.isEmpty ? "—" : marker.note)
                    }
                }
            }
            Section {
                Button {
                    export()
                } label: {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("Zipping…")
                                .padding(.leading, 8)
                        }
                    } else {
                        Label("Export Zip", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)
                if let exportError {
                    Text(exportError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            } footer: {
                Text("Session folders can also be copied without zipping via the Files app or Finder (On My iPhone › BaselineLogger).")
            }
        }
        .navigationTitle(metadata.label.isEmpty ? "Session" : metadata.label)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportedZip) { zip in
            ShareSheet(items: [zip.url])
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private func export() {
        isExporting = true
        exportError = nil
        let folderURL = record.folderURL
        Task.detached(priority: .userInitiated) {
            do {
                let url = try SessionExporter.zipSessionFolder(at: folderURL)
                await MainActor.run {
                    exportedZip = ExportedZip(url: url)
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }
}

private struct ExportedZip: Identifiable {
    let url: URL
    var id: String { url.path }
}
