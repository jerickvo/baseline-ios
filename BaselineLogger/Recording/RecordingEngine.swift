import Foundation
import CoreMotion
import CoreLocation
import UIKit

/// Owns the three capture streams (deviceMotion, raw accelerometer, GPS) and
/// their CSV writers for one recording session.
///
/// Threading contract: all public methods and @Published properties are main
/// thread only. Sensor callbacks run on dedicated serial background queues;
/// the shared stats are protected by `statsLock`.
final class RecordingEngine: NSObject, ObservableObject {

    // MARK: Published UI state (main thread only)

    @Published private(set) var isRecording = false
    /// Set when a session finishes. RecordView presents the summary sheet from
    /// this and nils it on dismiss.
    @Published var lastFinishedSession: SessionMetadata?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var startError: String?

    // MARK: Capture configuration

    static let motionTargetHz = 100.0
    static let accelTargetHz = 200.0

    // MARK: Sensors

    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()

    // Dedicated serial queues for sensor callbacks — never the main queue.
    // Sample handlers must not compete with UI work, or delivery stalls and
    // samples drop.
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.baselinelogger.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let accelQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.baselinelogger.accel"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: Per-session state

    /// Protects the stats below: written from the capture queues, read from
    /// the main thread for the live counters.
    private let statsLock = NSLock()
    private var motionStats = StreamStats(expectedInterval: 1.0 / RecordingEngine.motionTargetHz)
    private var accelStats = StreamStats(expectedInterval: 1.0 / RecordingEngine.accelTargetHz)
    private var gpsSampleCount = 0

    // Writer confinement: motionWriter -> motionQueue, accelWriter ->
    // accelQueue, gpsWriter -> main (where CLLocationManager delivers). The
    // references are only assigned before streams start and after their
    // queues drain on stop.
    private var motionWriter: CSVWriter?
    private var accelWriter: CSVWriter?
    private var gpsWriter: CSVWriter?

    private var sessionID = UUID()
    private var sessionLabel = ""
    private var sessionFolderURL: URL?
    private var startDate = Date()
    private var startUptime: TimeInterval = 0
    private var eventMarkers: [EventMarker] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationAuthorization = locationManager.authorizationStatus
    }

    // MARK: Authorization

    func requestLocationAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Always authorization is required for updates to keep flowing
            // after the phone locks; When In Use alone dies with the screen.
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: Session control

    func start(label: String) {
        guard !isRecording else { return }
        startError = nil

        let start = Date()
        do {
            let folder = try Self.makeSessionFolder(startedAt: start)
            motionWriter = try CSVWriter(
                url: folder.appendingPathComponent("motion.csv"),
                header: "t,ax,ay,az,gx,gy,gz,rx,ry,rz,qw,qx,qy,qz")
            accelWriter = try CSVWriter(
                url: folder.appendingPathComponent("accel_raw.csv"),
                header: "t,ax,ay,az")
            gpsWriter = try CSVWriter(
                url: folder.appendingPathComponent("gps.csv"),
                header: "t,latitude,longitude,speed,horizontalAccuracy,altitude")
            sessionFolderURL = folder
        } catch {
            startError = "Could not create session files: \(error.localizedDescription)"
            discardWriters()
            return
        }

        sessionID = UUID()
        sessionLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        startDate = start
        startUptime = ProcessInfo.processInfo.systemUptime
        eventMarkers = []

        statsLock.lock()
        motionStats = StreamStats(expectedInterval: 1.0 / RecordingEngine.motionTargetHz)
        accelStats = StreamStats(expectedInterval: 1.0 / RecordingEngine.accelTargetHz)
        gpsSampleCount = 0
        statsLock.unlock()

        beginBackgroundTaskAssertion()

        // Location must start BEFORE motion and stay running for the whole
        // session — see the comment in startLocationUpdates().
        startLocationUpdates()
        startMotionUpdates()
        startAccelerometerUpdates()

        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        motionManager.stopDeviceMotionUpdates()
        motionManager.stopAccelerometerUpdates()
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false

        // Close each writer on its own queue so it lands behind any in-flight
        // sample callbacks (the queues are serial), then wait for both queues
        // to drain. Late callbacks that slip in after close are dropped by the
        // writer's isClosed guard.
        let flushGroup = DispatchGroup()
        flushGroup.enter()
        motionQueue.addOperation { [self] in
            motionWriter?.close()
            flushGroup.leave()
        }
        flushGroup.enter()
        accelQueue.addOperation { [self] in
            accelWriter?.close()
            flushGroup.leave()
        }
        _ = flushGroup.wait(timeout: .now() + 5)
        gpsWriter?.close()

        let endDate = Date()
        let duration = ProcessInfo.processInfo.systemUptime - startUptime

        statsLock.lock()
        let motion = motionStats
        let accel = accelStats
        let gps = gpsSampleCount
        statsLock.unlock()

        let metadata = SessionMetadata(
            id: sessionID.uuidString,
            label: sessionLabel,
            startTime: Self.iso8601Formatter.string(from: startDate),
            endTime: Self.iso8601Formatter.string(from: endDate),
            durationSeconds: Self.rounded(duration, places: 6),
            motionSampleCount: motion.sampleCount,
            accelSampleCount: accel.sampleCount,
            gpsSampleCount: gps,
            achievedMotionHz: Self.rounded(motion.achievedHz, places: 2),
            achievedAccelHz: Self.rounded(accel.achievedHz, places: 2),
            deviceModel: Self.deviceModelIdentifier,
            iosVersion: UIDevice.current.systemVersion,
            motionGapCount: motion.gapCount,
            accelGapCount: accel.gapCount,
            largestGapSeconds: Self.rounded(max(motion.largestGapSeconds, accel.largestGapSeconds), places: 6),
            eventMarkers: eventMarkers)

        if let folder = sessionFolderURL {
            Self.writeMetadata(metadata, to: folder)
        }

        discardWriters()
        endBackgroundTaskAssertion()
        lastFinishedSession = metadata
    }

    /// Appends a timestamped marker (lap boundary, condition change, ...) to
    /// the session metadata. Main thread only.
    func markEvent(note: String) {
        guard isRecording else { return }
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        eventMarkers.append(EventMarker(
            t: Self.rounded(t, places: 6),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)))
        objectWillChange.send()
    }

    var markerCount: Int { eventMarkers.count }

    // MARK: Live counters

    struct LiveStats {
        var elapsedSeconds: TimeInterval = 0
        var motionSampleCount = 0
        var accelSampleCount = 0
        var gpsSampleCount = 0
        var motionGapCount = 0
        var accelGapCount = 0
    }

    /// Snapshot of the live counters for the Record screen. Main thread only.
    func liveStats() -> LiveStats {
        statsLock.lock()
        let motion = motionStats
        let accel = accelStats
        let gps = gpsSampleCount
        statsLock.unlock()
        return LiveStats(
            elapsedSeconds: isRecording ? ProcessInfo.processInfo.systemUptime - startUptime : 0,
            motionSampleCount: motion.sampleCount,
            accelSampleCount: accel.sampleCount,
            gpsSampleCount: gps,
            motionGapCount: motion.gapCount,
            accelGapCount: accel.gapCount)
    }

    // MARK: Stream startup

    private func startLocationUpdates() {
        // KEEP THIS RUNNING: the "location" entry in UIBackgroundModes plus an
        // active CLLocationManager session is the ONLY thing that keeps this
        // app alive once the screen turns off and the phone locks. CoreMotion
        // has no background mode of its own — if location updates stop, iOS
        // suspends the process and deviceMotion/accelerometer callbacks stop
        // silently, with no error, leaving an unrecoverable hole in the
        // session. That is why the location background mode is enabled, why
        // location starts before motion, and why it runs for the entire
        // session. Do not remove either thinking it is unused.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.startUpdatingLocation()
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            startError = "Device motion is not available on this device."
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / RecordingEngine.motionTargetHz
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // CMLogItem.timestamp is seconds since boot, the same clock as
            // ProcessInfo.systemUptime — the sample's own capture time, not
            // the jittery delivery time. Written raw, no resampling.
            let t = motion.timestamp - self.startUptime
            guard t >= 0 else { return }
            let ua = motion.userAcceleration
            let g = motion.gravity
            let r = motion.rotationRate
            let q = motion.attitude.quaternion
            let row = String(
                format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
                t,
                ua.x, ua.y, ua.z,
                g.x, g.y, g.z,
                r.x, r.y, r.z,
                q.w, q.x, q.y, q.z)
            self.motionWriter?.appendRow(row)
            self.statsLock.lock()
            self.motionStats.register(timestamp: t)
            self.statsLock.unlock()
        }
    }

    private func startAccelerometerUpdates() {
        guard motionManager.isAccelerometerAvailable else { return }
        // 200Hz requested; some devices deliver less. Whatever arrives is
        // recorded as-is and the achieved rate lands in session.json.
        motionManager.accelerometerUpdateInterval = 1.0 / RecordingEngine.accelTargetHz
        motionManager.startAccelerometerUpdates(to: accelQueue) { [weak self] data, _ in
            guard let self, let data else { return }
            let t = data.timestamp - self.startUptime
            guard t >= 0 else { return }
            let a = data.acceleration
            let row = String(format: "%.6f,%.6f,%.6f,%.6f", t, a.x, a.y, a.z)
            self.accelWriter?.appendRow(row)
            self.statsLock.lock()
            self.accelStats.register(timestamp: t)
            self.statsLock.unlock()
        }
    }

    // MARK: Background task assertion

    private func beginBackgroundTaskAssertion() {
        // Secondary fallback only: a background task assertion buys roughly
        // 30 seconds on its own. The location background mode above is what
        // actually keeps the session alive; this just covers scheduling
        // hiccups around the moment the screen locks.
        endBackgroundTaskAssertion()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BaselineLogger.recording") { [weak self] in
            self?.endBackgroundTaskAssertion()
        }
    }

    private func endBackgroundTaskAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Files

    private static func makeSessionFolder(startedAt date: Date) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // ISO 8601 basic format (no colons) so the folder name survives
        // Finder, the Files app, and every filesystem the CSVs get copied to.
        let base = folderTimestampFormatter.string(from: date)
        var name = base
        var attempt = 2
        while FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path) {
            name = "\(base)-\(attempt)"
            attempt += 1
        }
        let folder = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func discardWriters() {
        motionWriter = nil
        accelWriter = nil
        gpsWriter = nil
    }

    private static func writeMetadata(_ metadata: SessionMetadata, to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(metadata)
            try data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        } catch {
            // A metadata failure must not take the session down; the CSVs are
            // already on disk at this point.
        }
    }

    // MARK: Identifiers and formatting

    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let folderTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { rawBuffer -> String in
            let bytes = Data(rawBuffer.prefix(while: { $0 != 0 }))
            return String(data: bytes, encoding: .utf8) ?? ""
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }
}

// MARK: - CLLocationManagerDelegate

extension RecordingEngine: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorization = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse {
            // Escalate to Always so recording survives the phone locking.
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CLLocationManager delivers on the thread it was created on (main);
        // at ~1Hz that is harmless. gpsWriter is confined to this thread.
        guard isRecording, let writer = gpsWriter else { return }
        for location in locations {
            let t = location.timestamp.timeIntervalSince(startDate)
            // The first fix can be a cached one from before the session began.
            guard t >= 0 else { continue }
            let coordinate = location.coordinate
            let row = String(
                format: "%.6f,%.8f,%.8f,%.3f,%.2f,%.2f",
                t,
                coordinate.latitude,
                coordinate.longitude,
                location.speed,
                location.horizontalAccuracy,
                location.altitude)
            writer.appendRow(row)
            statsLock.lock()
            gpsSampleCount += 1
            statsLock.unlock()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient location errors (e.g. no fix yet in a stairwell) are
        // expected; motion capture continues regardless.
    }
}
