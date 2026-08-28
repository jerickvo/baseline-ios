import SwiftUI

/// Every recorded session: label, date, duration, and a warning icon when the
/// session has gaps.
struct SessionListView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No sessions recorded yet")
                        .foregroundColor(.secondary)
                }
            } else {
                List {
                    ForEach(store.sessions) { record in
                        NavigationLink {
                            SessionDetailView(record: record)
                        } label: {
                            SessionRow(record: record)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("Sessions")
        .onAppear { store.reload() }
    }

    private func delete(at offsets: IndexSet) {
        let records = offsets.map { store.sessions[$0] }
        for record in records {
            store.delete(record)
        }
    }
}

private struct SessionRow: View {
    let record: SessionRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.metadata.label.isEmpty ? "Untitled session" : record.metadata.label)
                    .font(.headline)
                Text(dateText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(Format.duration(record.metadata.durationSeconds))
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.secondary)
            if record.metadata.hasGaps {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
    }

    private var dateText: String {
        if let date = record.metadata.startDate {
            return Format.listDate.string(from: date)
        }
        return record.metadata.startTime
    }
}
