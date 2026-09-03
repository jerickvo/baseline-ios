import SwiftUI

/// The recording screen: session label, start/stop, elapsed time, live sample
/// counters, live achieved motion Hz, and a Mark Event button. Deliberately
/// plain — this app is a data collection instrument, not a product.
struct RecordView: View {
    @EnvironmentObject private var recorder: SessionRecorder
    @State private var label = ""
    @State private var showMarkAlert = false
    @State private var markNote = ""
    /// Session time captured the instant Mark Event was tapped, so the
    /// marker lands where the tap happened rather than where the note was
    /// finished.
    @State private var pendingMarkTime: TimeInterval?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    labelField
                    elapsedReadout
                    startStopButton
                    counters
                    markEventButton
                    warnings
                }
                .padding()
            }
            .navigationTitle("Record")
        }
        .onAppear {
            recorder.requestPermissions()
        }
        .sheet(item: $recorder.finishedSession) { metadata in
            SessionSummaryView(metadata: metadata)
        }
        .alert("Mark Event", isPresented: $showMarkAlert) {
            TextField("Note (optional)", text: $markNote)
            Button("Mark") {
                if let t = pendingMarkTime {
                    recorder.markEvent(at: t, note: markNote)
                }
                markNote = ""
                pendingMarkTime = nil
            }
            Button("Cancel", role: .cancel) {
                markNote = ""
                pendingMarkTime = nil
            }
        } message: {
            Text("The marker is stamped at the moment you tapped Mark Event.")
        }
    }

    private var labelField: some View {
        TextField("Session label (e.g. \"normal 3mi\")", text: $label)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .disabled(recorder.isRecording)
    }

    private var elapsedReadout: some View {
        Text(SessionFormat.duration(recorder.elapsedSeconds))
            .font(.system(size: 48, weight: .semibold, design: .monospaced))
            .frame(maxWidth: .infinity)
    }

    private var startStopButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopSession()
            } else {
                recorder.startSession(
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } label: {
            Text(recorder.isRecording ? "Stop" : "Start")
                .font(.title.bold())
                .frame(maxWidth: .infinity, minHeight: 80)
        }
        .buttonStyle(.borderedProminent)
        .tint(recorder.isRecording ? .red : .green)
    }

    private var counters: some View {
        VStack(spacing: 10) {
            counterRow(
                name: "Motion",
                count: recorder.motionSampleCount,
                detail: SessionFormat.hz(recorder.liveMotionHz))
            counterRow(
                name: "Raw accel",
                count: recorder.accelSampleCount,
                detail: nil)
            counterRow(
                name: "GPS",
                count: recorder.gpsSampleCount,
                detail: nil)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func counterRow(name: String, count: Int, detail: String?) -> some View {
        HStack {
            Text(name)
                .foregroundColor(.secondary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Text("\(count)")
                .font(.body.monospacedDigit())
                .frame(minWidth: 80, alignment: .trailing)
        }
    }

    private var markEventButton: some View {
        Button {
            pendingMarkTime = recorder.currentSessionTime()
            showMarkAlert = true
        } label: {
            Label("Mark Event", systemImage: "flag")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!recorder.isRecording)
    }

    @ViewBuilder
    private var warnings: some View {
        if let warning = recorder.locationAuthWarning {
            warningLabel(warning, color: .orange)
        }
        if let error = recorder.lastError {
            warningLabel(error, color: .red)
        }
    }

    private func warningLabel(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
