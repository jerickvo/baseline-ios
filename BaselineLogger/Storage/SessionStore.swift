import Foundation

/// A recorded session on disk: parsed metadata plus the folder holding the
/// CSVs.
struct SessionRecord: Identifiable, Hashable {
    let metadata: SessionMetadata
    let folderURL: URL

    var id: String { metadata.id }
}

/// Lists completed sessions by scanning Documents for folders containing a
/// session.json.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []

    func reload() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        let decoder = JSONDecoder()
        var records: [SessionRecord] = []
        for folder in folders {
            let metadataURL = folder.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? decoder.decode(SessionMetadata.self, from: data) else {
                continue
            }
            records.append(SessionRecord(metadata: metadata, folderURL: folder))
        }
        // startTime is ISO 8601, so lexicographic order is chronological.
        records.sort { $0.metadata.startTime > $1.metadata.startTime }
        sessions = records
    }

    func delete(_ record: SessionRecord) {
        try? FileManager.default.removeItem(at: record.folderURL)
        reload()
    }
}
