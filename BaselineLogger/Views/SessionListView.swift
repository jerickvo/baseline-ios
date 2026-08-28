import SwiftUI

/// Every recorded session: label, date, duration, and a warning icon when the
/// session has gaps.
struct SessionListView: View {
    @StateObject private var store = SessionStore()

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No sessions yet")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(store.sessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionRowView(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .onAppear {
                store.reload()
            }
        }
    }
}

private struct SessionRowView: View {
    let session: RecordedSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.metadata.label.isEmpty ? "Untitled" : session.metadata.label)
                    .font(.headline)
                Text(session.metadata.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if session.metadata.totalGapCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            Text(SessionFormat.duration(session.metadata.durationSeconds))
                .font(.body.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}
