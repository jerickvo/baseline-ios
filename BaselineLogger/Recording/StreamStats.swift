import Foundation

/// Per-stream sample accounting: count, achieved rate, and gap detection.
///
/// A gap is any delta between consecutive sample timestamps greater than 3x
/// the expected interval. Gaps mean iOS suspended or throttled delivery and
/// the session has holes the analysis side must know about.
struct StreamStats {
    let expectedInterval: TimeInterval

    private(set) var sampleCount = 0
    private(set) var firstTimestamp: TimeInterval?
    private(set) var lastTimestamp: TimeInterval?
    private(set) var gapCount = 0
    private(set) var largestGapSeconds: Double = 0

    init(expectedInterval: TimeInterval) {
        self.expectedInterval = expectedInterval
    }

    mutating func register(timestamp t: TimeInterval) {
        if firstTimestamp == nil {
            firstTimestamp = t
        }
        if let last = lastTimestamp {
            let delta = t - last
            if delta > expectedInterval * 3 {
                gapCount += 1
                if delta > largestGapSeconds {
                    largestGapSeconds = delta
                }
            }
        }
        lastTimestamp = t
        sampleCount += 1
    }

    /// Average delivered rate over the span actually covered by samples.
    var achievedHz: Double {
        guard let first = firstTimestamp, let last = lastTimestamp,
              sampleCount > 1, last > first else { return 0 }
        return Double(sampleCount - 1) / (last - first)
    }
}
