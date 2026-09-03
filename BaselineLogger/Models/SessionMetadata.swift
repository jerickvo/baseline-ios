import Foundation

/// One timestamped marker dropped during a session (lap boundary, condition
/// change, etc.). `t` is seconds since session start, on the same timeline as
/// the `t` column in motion.csv / accel_raw.csv.
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
}

extension SessionMetadata {
    static let jsonFileName = "session.json"

    /// Total gaps across both high-rate streams. Anything above zero means the
    /// session has discontinuities and the user needs to know before they
    /// build analysis on it.
    var totalGapCount: Int { motionGapCount + accelGapCount }

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
