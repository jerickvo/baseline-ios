import SwiftUI

/// Shown as a sheet when a session ends: duration, sample counts, achieved
/// rates, and — most importantly — whether the session has gaps.
struct SessionSummaryView: View {
    @Environment(\.dismiss) private var dismiss

    let metadata: SessionMetadata

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if metadata.hasGaps {
                        Label {
                            Text("\(metadata.totalGapCount) gap\(metadata.totalGapCount == 1 ? "" : "s") detected, largest \(String(format: "%.3f", metadata.largestGapSeconds)) s. Samples were dropped — check this session before analyzing it.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    } else {
                        Label {
                            Text("No gaps detected")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                Section("Session") {
                    row("Label", metadata.label.isEmpty ? "—" : metadata.label)
                    row("Duration", Format.duration(metadata.durationSeconds))
                }
                Section("Samples") {
                    row("Motion", "\(metadata.motionSampleCount)")
                    row("Raw accel", "\(metadata.accelSampleCount)")
                    row("GPS", "\(metadata.gpsSampleCount)")
                    row("Achieved motion rate", String(format: "%.1f Hz", metadata.achievedMotionHz))
                    row("Achieved accel rate", String(format: "%.1f Hz", metadata.achievedAccelHz))
                }
                Section("Gaps") {
                    row("Motion gaps", "\(metadata.motionGapCount)")
                    row("Accel gaps", "\(metadata.accelGapCount)")
                    row("Largest gap", String(format: "%.3f s", metadata.largestGapSeconds))
                }
            }
            .navigationTitle("Session Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.body.monospacedDigit())
        }
    }
}
