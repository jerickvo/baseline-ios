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
                    Label(
                        metadata.integritySummary,
                        systemImage: metadata.isContinuous
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(metadata.isContinuous ? .green : .orange)
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
                    LabeledContent("Dropped samples (est.)", value: "\(metadata.totalDroppedSampleEstimate)")
                    LabeledContent("Duplicated/reordered", value: "\(metadata.totalNonMonotonicCount)")
                    LabeledContent("Rows lost to disk", value: "\(metadata.csvRowsLost ?? 0)")
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
