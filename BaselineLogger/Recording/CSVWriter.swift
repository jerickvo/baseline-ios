import Foundation

/// Buffered CSV writer. Rows accumulate in a string buffer and are flushed to
/// disk through a FileHandle every `flushThreshold` rows, so memory stays flat
/// no matter how long the session runs. A 60 minute session is ~360k motion
/// rows plus ~720k raw accel rows — the full session must NEVER be held in
/// memory.
///
/// Row appends are not synchronized: each writer must only be fed from a
/// single serial queue (the sensor stream's delivery queue, or the main thread
/// for GPS). The failure state is the exception -- it is read by the main
/// thread's live-status timer while the sensor queue writes it, so it lives
/// behind a lock.
final class CSVWriter {
    private let fileHandle: FileHandle
    private var buffer: String
    private var rowsBuffered = 0
    private let flushThreshold: Int
    private var closed = false

    private let stateLock = NSLock()
    private var failed = false
    private var lostRows = 0

    /// Whether any write to disk has failed, and how many rows were discarded
    /// as a result. A failed flush drops its whole buffer, so `rowsLost` is
    /// the number of samples the sample counters credited that never reached
    /// the file. Safe to read from any thread.
    var failureState: (writeFailed: Bool, rowsLost: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (failed, lostRows)
    }

    /// Kept for callers that only need the flag.
    var writeFailed: Bool { failureState.writeFailed }

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
    /// `flushThreshold` rows. A row arriving after `close()` -- a sensor
    /// callback that was already in flight when updates were stopped -- is
    /// counted as lost rather than written to a closed handle.
    func appendRow(_ row: String) {
        if closed {
            stateLock.lock()
            lostRows += 1
            stateLock.unlock()
            return
        }
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
            stateLock.lock()
            failed = true
            lostRows += rowsBuffered
            stateLock.unlock()
        }
        buffer.removeAll(keepingCapacity: true)
        rowsBuffered = 0
    }

    /// Flush any buffered rows and close the file. Rows appended afterwards
    /// are counted in `failureState.rowsLost`.
    func close() {
        flush()
        closed = true
        try? fileHandle.close()
    }
}
