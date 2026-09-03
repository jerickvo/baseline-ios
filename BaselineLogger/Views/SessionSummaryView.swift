import SwiftUI

/// Shown as a sheet the moment a session ends. If the session has gaps, the
/// user finds out here — before building a week of analysis on it.
struct SessionSummaryView: View {
    let metadata: SessionMetadata
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if metadata.totalGapCount > 0 {
                        Label(
                            "\(metadata.totalGapCount) gap(s) detected — largest \(SessionFormat.seconds(metadata.largestGapSeconds)). Treat this session with suspicion.",
                            systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    } else {
                        Label(
                            "Continuous — no gaps detected.",
                            systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    }
                }
                Section("Session") {
                    LabeledContent("Label", value: metadata.label.isEmpty ? "—" : metadata.label)
                    LabeledContent("Duration", value: SessionFormat.duration(metadata.durationSeconds))
                }
                Section("Samples") {
                    LabeledContent(
                        "Motion",
                        value: "\(metadata.motionSampleCount)  ·  \(SessionFormat.hz(metadata.achievedMotionHz))")
                    LabeledContent(
                        "Raw accel",
                        value: "\(metadata.accelSampleCount)  ·  \(SessionFormat.hz(metadata.achievedAccelHz))")
                    LabeledContent("GPS", value: "\(metadata.gpsSampleCount)")
                }
                Section("Data integrity") {
                    LabeledContent("Motion gaps", value: "\(metadata.motionGapCount)")
                    LabeledContent("Accel gaps", value: "\(metadata.accelGapCount)")
                    LabeledContent("Largest gap", value: SessionFormat.seconds(metadata.largestGapSeconds))
                }
                if !metadata.eventMarkers.isEmpty {
                    Section("Event markers") {
                        LabeledContent("Count", value: "\(metadata.eventMarkers.count)")
                    }
                }
            }
            .navigationTitle("Session Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
