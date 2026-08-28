import Foundation

/// A finished session on disk: parsed metadata plus the folder that holds its
/// CSVs.
struct RecordedSession: Identifiable {
    let metadata: SessionMetadata
    let folderURL: URL
    var id: String { metadata.id }
}

/// Scans the Documents directory for session folders. A folder counts as a
/// session when it contains a decodable session.json; folders without one
/// (e.g. a session that crashed mid-recording) still hold their CSVs and stay
/// reachable through the Files app, they just do not show up here.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [RecordedSession] = []

    func reload() {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            sessions = []
            return
        }
        let decoder = SessionMetadata.decoder()
        let contents = (try? fileManager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var found: [RecordedSession] = []
        for url in contents {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            let jsonURL = url.appendingPathComponent(SessionMetadata.jsonFileName)
            guard let data = try? Data(contentsOf: jsonURL),
                  let metadata = try? decoder.decode(SessionMetadata.self, from: data) else {
                continue
            }
            found.append(RecordedSession(metadata: metadata, folderURL: url))
        }
        sessions = found.sorted { $0.metadata.startTime > $1.metadata.startTime }
    }
}
