import Foundation

/// Tracks discontinuities in a sample stream by watching the delta between
/// consecutive sample timestamps. Any delta greater than 3x the expected
/// interval counts as a gap. Gap count and the largest gap are reported in
/// session.json and shown when the session ends — a session with gaps must
/// never silently make it into a week of downstream analysis.
///
/// Not internally synchronized: each tracker must only be touched from its
/// stream's serial delivery queue.
struct GapTracker {
    /// Requested sampling interval in seconds (e.g. 1/100 for 100 Hz).
    let expectedInterval: TimeInterval

    private(set) var gapCount = 0
    private(set) var largestGapSeconds: TimeInterval = 0
    private var previousTimestamp: TimeInterval?

    init(expectedInterval: TimeInterval) {
        self.expectedInterval = expectedInterval
    }

    /// Feed every sample's timestamp, in seconds on any consistent clock.
    mutating func record(timestamp: TimeInterval) {
        defer { previousTimestamp = timestamp }
        guard let previous = previousTimestamp else { return }
        let delta = timestamp - previous
        if delta > expectedInterval * 3 {
            gapCount += 1
            if delta > largestGapSeconds {
                largestGapSeconds = delta
            }
        }
    }
}
