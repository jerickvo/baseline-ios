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
/// Three things are counted, because a gap count of zero was never proof of
/// continuity:
///
/// - `gapCount` / `largestGapSeconds`: deltas beyond 3x the median.
/// - `droppedSampleEstimate`: samples missing from deltas that are long but
///   *below* the gap threshold. One dropped sample makes a 2x delta and two
///   make exactly 3x -- the gap rule counts neither, so a stream could shed a
///   sample every few seconds and still read "no gaps". Any delta beyond
///   1.5x the median contributes round(delta / median) - 1 here.
/// - `nonMonotonicCount`: zero or negative deltas -- a duplicated or
///   reordered sample. These never enter the median window and do not
///   advance the reference timestamp, so one cannot manufacture a fake gap
///   on the sample after it.
///
/// Not internally synchronized: each tracker must only be touched from its
/// stream's serial delivery queue.
struct GapTracker {
    /// Requested sampling interval in seconds (e.g. 1/100 for 100 Hz). Used
    /// only as the fallback threshold before the achieved rate is known.
    let expectedInterval: TimeInterval

    private(set) var gapCount = 0
    private(set) var largestGapSeconds: TimeInterval = 0
    private(set) var droppedSampleEstimate = 0
    private(set) var nonMonotonicCount = 0

    /// Deltas observed before the first calibration. They are held rather than
    /// classified, then classified retroactively once the threshold is known,
    /// so warm-up samples are measured by the same rule as everything else.
    private static let warmupDeltas = 128
    /// Bounded so memory stays flat: 256 Doubles (~2 KB) per stream, whatever
    /// the session length.
    private static let windowSize = 256
    private static let recalibrateEvery = 128
    /// Multiples of the median interval: beyond `gapMultiple` is a gap;
    /// beyond `droppedMultiple` samples are estimated missing. 1.5 sits
    /// halfway between a normal interval (1x plus a few percent of jitter)
    /// and one dropped sample (2x).
    private static let gapMultiple: Double = 3
    private static let droppedMultiple: Double = 1.5

    private var previousTimestamp: TimeInterval?
    private var window: [TimeInterval] = []
    private var windowNext = 0
    private var deltasSeen = 0
    private var calibrated = false
    private var medianInterval: TimeInterval
    private var thresholdSeconds: TimeInterval

    init(expectedInterval: TimeInterval) {
        self.expectedInterval = expectedInterval
        self.medianInterval = expectedInterval
        self.thresholdSeconds = expectedInterval * Self.gapMultiple
        self.window.reserveCapacity(Self.windowSize)
    }

    /// Feed every sample's timestamp, in seconds on any consistent clock.
    mutating func record(timestamp: TimeInterval) {
        guard let previous = previousTimestamp else {
            previousTimestamp = timestamp
            return
        }
        let delta = timestamp - previous
        // A duplicated or reordered sample: count it and keep the reference
        // where it was, so the next genuine sample is measured against the
        // last genuine one rather than against a timestamp that went
        // backwards.
        guard delta > 0 else {
            nonMonotonicCount += 1
            return
        }
        previousTimestamp = timestamp
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
        medianInterval = median
        thresholdSeconds = median * Self.gapMultiple
        calibrated = true
    }

    private mutating func classify(_ delta: TimeInterval) {
        if delta > Self.droppedMultiple * medianInterval {
            droppedSampleEstimate += max(Int((delta / medianInterval).rounded()) - 1, 0)
        }
        guard delta > thresholdSeconds else { return }
        gapCount += 1
        if delta > largestGapSeconds {
            largestGapSeconds = delta
        }
    }
}
