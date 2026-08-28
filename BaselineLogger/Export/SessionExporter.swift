import Foundation

enum SessionExportError: LocalizedError {
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .zipFailed(let reason):
            return "Could not create zip: \(reason)"
        }
    }
}

enum SessionExporter {
    /// Zips a session folder using NSFileCoordinator's `forUploading` option —
    /// the only archive facility built into Foundation, which keeps the app
    /// free of third-party dependencies. Blocks while compressing; call it
    /// off the main thread.
    static func zipSessionFolder(at folderURL: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderURL.lastPathComponent)
            .appendingPathExtension("zip")
        try? FileManager.default.removeItem(at: destination)

        var coordinatorError: NSError?
        var copyError: Error?
        var succeeded = false

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: folderURL, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                // zipURL is temporary and vanishes when this block returns;
                // copy the archive out first.
                try FileManager.default.copyItem(at: zipURL, to: destination)
                succeeded = true
            } catch {
                copyError = error
            }
        }

        if let coordinatorError {
            throw SessionExportError.zipFailed(coordinatorError.localizedDescription)
        }
        if let copyError {
            throw SessionExportError.zipFailed(copyError.localizedDescription)
        }
        guard succeeded else {
            throw SessionExportError.zipFailed("Unknown failure.")
        }
        return destination
    }
}
