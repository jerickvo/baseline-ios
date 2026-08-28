import Foundation

/// One timestamped marker dropped by the user mid-session, e.g. at a lap
/// boundary or a condition change during a validation protocol.
struct EventMarker: Codable, Hashable {
    /// Seconds since session start.
    var t: Double
    var note: String
}

/// The contents of session.json — everything the Python side needs to
/// interpret the CSVs sitting next to it.
struct SessionMetadata: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var startTime: String
    var endTime: String
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

    var totalGapCount: Int { motionGapCount + accelGapCount }
    var hasGaps: Bool { totalGapCount > 0 }

    var startDate: Date? { Self.isoParser.date(from: startTime) }

    private static let isoParser = ISO8601DateFormatter()
}
