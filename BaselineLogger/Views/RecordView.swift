import SwiftUI
import Combine
import CoreLocation
import UIKit

/// Record screen: session label, big start/stop, elapsed time, live counters
/// and achieved motion Hz, and a Mark Event button for lap boundaries.
struct RecordView: View {
    @EnvironmentObject private var engine: RecordingEngine
    @EnvironmentObject private var store: SessionStore

    @State private var sessionLabel = ""
    @State private var markerNote = ""
    @State private var live = RecordingEngine.LiveStats()
    @State private var liveMotionHz = 0.0
    @State private var lastHzSampleCount = 0
    @State private var lastHzSampleUptime: TimeInterval = 0

    private let uiTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if needsAlwaysAuthorization {
                    authorizationWarning
                }
                if let startError = engine.startError {
                    Text(startError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TextField("Session label (e.g. normal 3mi)", text: $sessionLabel)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(engine.isRecording)

                Text(elapsedText)
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))

                startStopButton

                countersGrid

                markEventSection
            }
            .padding()
        }
        .navigationTitle("Record")
        .onAppear {
            engine.requestLocationAuthorization()
        }
        .onReceive(uiTimer) { _ in
            refreshLiveStats()
        }
        .sheet(item: $engine.lastFinishedSession, onDismiss: { store.reload() }) { metadata in
            SessionSummaryView(metadata: metadata)
        }
    }

    // MARK: Subviews

    private var authorizationWarning: some View {
        Label {
            Text("Location permission must be set to **Always** or recording will stop when the phone locks.")
                .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private var startStopButton: some View {
        Button {
            if engine.isRecording {
                engine.stop()
            } else {
                engine.start(label: sessionLabel)
            }
        } label: {
            Text(engine.isRecording ? "Stop" : "Start")
                .font(.title.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.isRecording ? .red : .green)
    }

    private var countersGrid: some View {
        VStack(spacing: 8) {
            counterRow("Motion samples", "\(live.motionSampleCount)")
            counterRow("Motion rate", String(format: "%.1f Hz", liveMotionHz))
            counterRow("Raw accel samples", "\(live.accelSampleCount)")
            counterRow("GPS samples", "\(live.gpsSampleCount)")
            counterRow("Gaps so far", "\(live.motionGapCount + live.accelGapCount)")
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func counterRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
        }
    }

    private var markEventSection: some View {
        VStack(spacing: 8) {
            TextField("Marker note (optional, e.g. lap 2)", text: $markerNote)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Button {
                engine.markEvent(note: markerNote)
                markerNote = ""
            } label: {
                Label("Mark Event", systemImage: "flag.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(!engine.isRecording)
            if engine.markerCount > 0 {
                Text("\(engine.markerCount) marker\(engine.markerCount == 1 ? "" : "s") this session")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Helpers

    private var needsAlwaysAuthorization: Bool {
        engine.locationAuthorization != .authorizedAlways
    }

    private var elapsedText: String {
        Format.duration(live.elapsedSeconds)
    }

    private func refreshLiveStats() {
        live = engine.liveStats()
        let now = ProcessInfo.processInfo.systemUptime
        if engine.isRecording {
            if lastHzSampleUptime > 0 {
                let dt = now - lastHzSampleUptime
                let dc = live.motionSampleCount - lastHzSampleCount
                if dt > 0 {
                    liveMotionHz = Double(dc) / dt
                }
            }
            lastHzSampleCount = live.motionSampleCount
            lastHzSampleUptime = now
        } else {
            liveMotionHz = 0
            lastHzSampleCount = 0
            lastHzSampleUptime = 0
        }
    }
}
