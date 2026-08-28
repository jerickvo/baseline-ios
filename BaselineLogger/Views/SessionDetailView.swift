import SwiftUI

/// Full metadata for one session, plus a share sheet button that exports the
/// session folder as a zip.
struct SessionDetailView: View {
    let session: RecordedSession

    private var metadata: SessionMetadata { session.metadata }

    var body: some View {
        List {
            if metadata.totalGapCount > 0 {
                Section {
                    Label(
                        "This session has gaps. Check the integrity numbers below before analyzing it.",
                        systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                }
            }
            Section("Session") {
                LabeledContent("Label", value: metadata.label.isEmpty ? "—" : metadata.label)
                LabeledContent("Start", value: metadata.startTime.formatted(date: .abbreviated, time: .standard))
                LabeledContent("End", value: metadata.endTime.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Duration", value: SessionFormat.duration(metadata.durationSeconds))
                LabeledContent("Folder", value: session.folderURL.lastPathComponent)
                LabeledContent("ID", value: metadata.id)
                    .font(.footnote)
            }
            Section("Samples & rates") {
                LabeledContent("Motion samples", value: "\(metadata.motionSampleCount)")
                LabeledContent("Achieved motion rate", value: SessionFormat.hz(metadata.achievedMotionHz))
                LabeledContent("Raw accel samples", value: "\(metadata.accelSampleCount)")
                LabeledContent("Achieved accel rate", value: SessionFormat.hz(metadata.achievedAccelHz))
                LabeledContent("GPS samples", value: "\(metadata.gpsSampleCount)")
            }
            Section("Data integrity") {
                LabeledContent("Motion gaps", value: "\(metadata.motionGapCount)")
                LabeledContent("Accel gaps", value: "\(metadata.accelGapCount)")
                LabeledContent("Largest gap", value: SessionFormat.seconds(metadata.largestGapSeconds))
            }
            Section("Device") {
                LabeledContent("Model", value: metadata.deviceModel)
                LabeledContent("iOS", value: metadata.iosVersion)
            }
            Section("Event markers") {
                if metadata.eventMarkers.isEmpty {
                    Text("None")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(metadata.eventMarkers.enumerated()), id: \.offset) { _, marker in
                        LabeledContent(
                            SessionFormat.duration(marker.t),
                            value: marker.note.isEmpty ? "—" : marker.note)
                    }
                }
            }
            Section {
                ShareLink(
                    item: SessionArchive(folderURL: session.folderURL),
                    preview: SharePreview("\(session.folderURL.lastPathComponent).zip")) {
                    Label("Export Session Zip", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(metadata.label.isEmpty ? "Session" : metadata.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}
