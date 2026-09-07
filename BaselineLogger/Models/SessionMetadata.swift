import Foundation

/// One timestamped marker dropped during a session (lap boundary, condition
/// change, etc.). `t` is seconds since session start, on the same timeline as
/// the `t` column in motion.csv / accel_raw.csv, captured at the moment the
/// Mark Event button was tapped -- not when the note was finished.
struct EventMarker: Codable {
    var t: Double
    var note: String
}

/// Contents of session.json — everything the downstream Python needs to
/// sanity-check a session before trusting its CSVs.
struct SessionMetadata: Codable, Identifiable {
    var id: String
    var label: String
    var startTime: Date
    var endTime: Date
    var durationSeconds: Double
    var motionSampleCount: Int
    var accelSampleCount: Int
    var gpsSampleCount: Int
    var achievedMotionHz: Double
    var achievedAccelHz: Double
    var deviceModel: String
    var iosVersion: String
    var motionGapCount: Int
    var accelGapCount: Int
    var largestGapSeconds: Double
    var eventMarkers: [EventMarker]
    /// True while the session is still recording. session.json is written once
    /// at start and refreshed every 30 s, so a run killed mid-session still
    /// leaves readable metadata; stop rewrites the file with this cleared.
    ///
    /// Optional on purpose: the synthesized decoder treats a missing key as
    /// nil, so session.json files written before this field existed still
    /// decode — and they are complete by definition.
    var inProgress: Bool?

    // Integrity counters that a gap count cannot express. All optional for
    // the same reason as `inProgress`: older session.json files lack them.

    /// Samples estimated missing from intervals that were long but below the
    /// gap threshold (one dropped sample is a 2x interval; the gap rule needs
    /// 3x). Zero gaps with a non-zero estimate here is a stream that is
    /// quietly shedding samples.
    var motionDroppedSampleEstimate: Int?
    var accelDroppedSampleEstimate: Int?
    /// Duplicated or reordered samples (zero or negative timestamp delta).
    var motionNonMonotonicCount: Int?
    var accelNonMonotonicCount: Int?
    /// Rows the sample counters credited that never reached disk: a failed
    /// flush discards its whole buffer, and a sample delivered after the
    /// writer closed has nowhere to go.
    var csvRowsLost: Int?
    /// Cached CoreLocation fixes stamped before the session started and
    /// therefore not written to gps.csv.
    var gpsStaleFixesSkipped: Int?
}

extension SessionMetadata {
    static let jsonFileName = "session.json"

    /// Total gaps across both high-rate streams.
    var totalGapCount: Int { motionGapCount + accelGapCount }

    /// Total estimated dropped samples across both high-rate streams.
    var totalDroppedSampleEstimate: Int {
        (motionDroppedSampleEstimate ?? 0) + (accelDroppedSampleEstimate ?? 0)
    }

    var totalNonMonotonicCount: Int {
        (motionNonMonotonicCount ?? 0) + (accelNonMonotonicCount ?? 0)
    }

    /// The session can be treated as continuous: no gaps, no dropped
    /// samples the gap rule missed, no reordered samples, and every row that
    /// was counted was written. Anything else means the user needs to know
    /// before they build analysis on it.
    var isContinuous: Bool {
        totalGapCount == 0
            && totalDroppedSampleEstimate == 0
            && totalNonMonotonicCount == 0
            && (csvRowsLost ?? 0) == 0
    }

    /// One-line integrity statement for the summary and list screens.
    var integritySummary: String {
        if isContinuous {
            return "Continuous — no gaps, dropped samples, or lost rows detected."
        }
        var parts: [String] = []
        if totalGapCount > 0 {
            parts.append("\(totalGapCount) gap(s), largest \(SessionFormat.seconds(largestGapSeconds))")
        }
        if totalDroppedSampleEstimate > 0 {
            parts.append("~\(totalDroppedSampleEstimate) dropped sample(s) below the gap threshold")
        }
        if totalNonMonotonicCount > 0 {
            parts.append("\(totalNonMonotonicCount) duplicated/reordered sample(s)")
        }
        if let lost = csvRowsLost, lost > 0 {
            parts.append("\(lost) row(s) never written to disk")
        }
        return parts.joined(separator: "; ") + ". Treat this session with suspicion."
    }

    /// The session's metadata was never finalized — the app was killed or
    /// crashed mid-run. Counts, duration and gaps are as of the last periodic
    /// write (up to 30 s stale), and the CSVs end wherever the app died.
    var isIncomplete: Bool { inProgress == true }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Small display formatters shared by the views.
enum SessionFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func hz(_ value: Double) -> String {
        String(format: "%.1f Hz", value)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.3f s", value)
    }
}
