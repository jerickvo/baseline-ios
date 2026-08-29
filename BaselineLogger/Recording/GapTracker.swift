import Foundation

/// Tracks discontinuities in a sample stream by watching the delta between
/// consecutive sample timestamps. A delta greater than 3x the interval the
/// stream is *actually* delivering counts as a gap.
///
/// The threshold is measured, not assumed. Anchoring it to the requested rate
/// (1/200 s for the raw accelerometer) means any device that cannot sustain
/// that rate reports every single sample as a gap: at 60 Hz every delta is
/// 16.7 ms, past the 15 ms that 3x the requested interval implies. That turns
/// the one number used to decide whether a session is trustworthy into noise,
/// on exactly the devices the app is supposed to tolerate. So after a warm-up
/// window the tracker takes the median observed delta and uses 3x that,
/// recalibrating as the session proceeds. A rate merely lower than requested
/// is reported by achievedAccelHz; this counts breaks in delivery.
///
/// Not internally synchronized: each tracker must only be touched from its
/// stream's serial delivery queue.
struct GapTracker {
    /// Requested sampling interval in seconds (e.g. 1/100 for 100 Hz). Used
    /// only as the fallback threshold before the achieved rate is known.
    let expectedInterval: TimeInterval

    private(set) var gapCount = 0
    private(set) var largestGapSeconds: TimeInterval = 0

    /// Deltas observed before the first calibration. They are held rather than
    /// classified, then classified retroactively once the threshold is known,
    /// so warm-up samples are measured by the same rule as everything else.
    private static let warmupDeltas = 128
    /// Bounded so memory stays flat: 256 Doubles (~2 KB) per stream, whatever
    /// the session length.
    private static let windowSize = 256
    private static let recalibrateEvery = 128

    private var previousTimestamp: TimeInterval?
    private var window: [TimeInterval] = []
    private var windowNext = 0
    private var deltasSeen = 0
    private var calibrated = false
    private var thresholdSeconds: TimeInterval

    init(expectedInterval: TimeInterval) {
        self.expectedInterval = expectedInterval
        self.thresholdSeconds = expectedInterval * 3
        self.window.reserveCapacity(Self.windowSize)
    }

    /// Feed every sample's timestamp, in seconds on any consistent clock.
    mutating func record(timestamp: TimeInterval) {
        defer { previousTimestamp = timestamp }
        guard let previous = previousTimestamp else { return }
        let delta = timestamp - previous
        remember(delta)

        guard calibrated else {
            // Still warming up. Classify nothing yet — the requested-rate
            // fallback is exactly the threshold that misfires on a slow
            // device — then sweep the held deltas once the rate is measured.
            if deltasSeen >= Self.warmupDeltas {
                calibrate()
                for held in window {
                    classify(held)
                }
            }
            return
        }

        classify(delta)
        if deltasSeen % Self.recalibrateEvery == 0 {
            calibrate()
        }
    }

    /// Append to a fixed-capacity ring of recent deltas.
    private mutating func remember(_ delta: TimeInterval) {
        deltasSeen += 1
        if window.count < Self.windowSize {
            window.append(delta)
        } else {
            window[windowNext] = delta
            windowNext = (windowNext + 1) % Self.windowSize
        }
    }

    /// Median, not mean, is the point: a handful of genuine gaps in the window
    /// leaves it untouched, so gaps cannot inflate the threshold that is
    /// supposed to detect them.
    private mutating func calibrate() {
        guard !window.isEmpty else { return }
        let median = window.sorted()[window.count / 2]
        guard median > 0 else { return }
        thresholdSeconds = median * 3
        calibrated = true
    }

    private mutating func classify(_ delta: TimeInterval) {
        guard delta > thresholdSeconds else { return }
        gapCount += 1
        if delta > largestGapSeconds {
            largestGapSeconds = delta
        }
    }
}
