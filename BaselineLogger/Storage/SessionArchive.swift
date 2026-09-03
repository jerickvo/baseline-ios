import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// Wraps a session folder for the share sheet. The zip is created lazily when
/// the user actually shares, via NSFileCoordinator's `.forUploading` option —
/// the only folder-to-zip facility in Foundation, which keeps the project free
/// of third-party dependencies.
struct SessionArchive: Transferable {
    let folderURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { archive in
            SentTransferredFile(try archive.makeZip(), allowAccessingOriginalFile: false)
        }
    }

    /// Zip the session folder into the temporary directory and return the
    /// zip's URL. Synchronous; called off the main thread by the transfer
    /// machinery.
    func makeZip() throws -> URL {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileNoSuchFile))

        // With .forUploading, the coordinated read hands the accessor a
        // temporary zip of the directory. It only exists inside the block, so
        // copy it out before returning.
        coordinator.coordinate(
            readingItemAt: folderURL,
            options: .forUploading,
            error: &coordinatorError) { zippedURL in
            do {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(folderURL.lastPathComponent)
                    .appendingPathExtension("zip")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zippedURL, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        return try result.get()
    }
}
