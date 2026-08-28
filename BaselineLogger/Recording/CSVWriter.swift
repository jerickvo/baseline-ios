import Foundation

/// Buffered CSV writer. Rows accumulate in a string buffer and are flushed to
/// disk through a FileHandle every `flushThreshold` rows, so memory stays flat
/// no matter how long the session runs. A 60 minute session is ~360k motion
/// rows plus ~720k raw accel rows — the full session must NEVER be held in
/// memory.
///
/// Not internally synchronized: each writer must only be touched from a single
/// serial queue (the sensor stream's delivery queue, or the main thread for
/// GPS).
final class CSVWriter {
    private let fileHandle: FileHandle
    private var buffer: String
    private var rowsBuffered = 0
    private let flushThreshold: Int

    /// Set to true if any write to disk fails. Checked at session end so a
    /// silently truncated file is surfaced instead of trusted.
    private(set) var writeFailed = false

    init(url: URL, header: String, flushThreshold: Int = 500) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.fileHandle = try FileHandle(forWritingTo: url)
        self.flushThreshold = flushThreshold
        var buffer = String()
        // ~500 rows of the widest CSV comfortably fits in 96 KB.
        buffer.reserveCapacity(96 * 1024)
        buffer += header
        buffer += "\n"
        self.buffer = buffer
    }

    /// Append one row (without trailing newline). Flushes to disk every
    /// `flushThreshold` rows.
    func appendRow(_ row: String) {
        buffer += row
        buffer += "\n"
        rowsBuffered += 1
        if rowsBuffered >= flushThreshold {
            flush()
        }
    }

    /// Write the buffer to disk and reset it, keeping its capacity so the
    /// steady state does no reallocation.
    func flush() {
        guard !buffer.isEmpty else { return }
        do {
            try fileHandle.write(contentsOf: Data(buffer.utf8))
        } catch {
            writeFailed = true
        }
        buffer.removeAll(keepingCapacity: true)
        rowsBuffered = 0
    }

    /// Flush any buffered rows and close the file. The writer must not be used
    /// after this.
    func close() {
        flush()
        try? fileHandle.close()
    }
}
