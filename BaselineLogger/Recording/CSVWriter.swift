import Foundation

/// Buffered CSV writer backed by a FileHandle.
///
/// Rows accumulate in an in-memory string buffer that is written to disk every
/// `flushThreshold` rows, so memory stays flat no matter how long the session
/// runs. A 60 minute session is over a million rows across the three streams;
/// nothing here ever holds more than one flush window of them.
///
/// NOT thread-safe. Each instance must be touched from exactly one serial
/// queue — the queue that receives that stream's sensor callbacks.
final class CSVWriter {
    private let fileHandle: FileHandle
    private let flushThreshold: Int
    private var buffer: String
    private var bufferedRowCount = 0
    private var isClosed = false

    init(url: URL, header: String, flushThreshold: Int = 500) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
        self.flushThreshold = flushThreshold
        self.buffer = header + "\n"
        self.buffer.reserveCapacity(flushThreshold * 128)
    }

    func appendRow(_ row: String) {
        guard !isClosed else { return }
        buffer.append(row)
        buffer.append("\n")
        bufferedRowCount += 1
        if bufferedRowCount >= flushThreshold {
            flush()
        }
    }

    func flush() {
        guard !isClosed, !buffer.isEmpty else { return }
        if let data = buffer.data(using: .utf8) {
            try? fileHandle.write(contentsOf: data)
        }
        buffer = ""
        bufferedRowCount = 0
    }

    func close() {
        guard !isClosed else { return }
        flush()
        isClosed = true
        try? fileHandle.close()
    }

    deinit {
        close()
    }
}
