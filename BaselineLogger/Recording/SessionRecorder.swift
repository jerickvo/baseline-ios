import Foundation
import CoreMotion
import CoreLocation
import UIKit

/// Thread-safe sample counter. Incremented on the sensor queues, read by the
/// UI refresh timer on the main thread.
final class LockedCounter {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Records one session: 100 Hz deviceMotion, 200 Hz raw accelerometer, and
/// ~1 Hz GPS, each streamed to its own CSV through a buffered writer.
///
/// Data continuity is the whole point of this app. The recording pipeline is
/// arranged so nothing between a sensor callback and the disk buffer touches
/// the main thread, and so the app keeps executing with the screen off (see
/// configureLocationForRecording()).
final class SessionRecorder: NSObject, ObservableObject {

    static let motionHz = 100.0
    static let accelHz = 200.0

    // MARK: - Published UI state (main thread only)

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var motionSampleCount = 0
    @Published private(set) var accelSampleCount = 0
    @Published private(set) var gpsSampleCount = 0
    @Published private(set) var liveMotionHz: Double = 0
    @Published private(set) var locationAuthWarning: String?
    @Published private(set) var lastError: String?
    /// Set when a session finishes; drives the end-of-session summary sheet.
    @Published var finishedSession: SessionMetadata?

    // MARK: - Capture plumbing

    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()

    /// Dedicated serial queues for sensor delivery. NEVER the main queue: the
    /// main thread stalls on UI and app lifecycle work, and every stall there
    /// would be dropped samples. maxConcurrentOperationCount = 1 keeps rows
    /// ordered and lets the writer and gap tracker go unsynchronized.
    private let motionQueue = SessionRecorder.makeSensorQueue(name: "motion")
    private let accelQueue = SessionRecorder.makeSensorQueue(name: "accel-raw")

    private var active: ActiveSession?
    private var uiTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        // Created on the main thread, so delegate callbacks (auth changes and
        // ~1 Hz location fixes) arrive on the main run loop.
        locationManager.delegate = self
    }

    private static func makeSensorQueue(name: String) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "BaselineLogger.\(name)"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }

    // MARK: - Per-session state

    /// Everything owned by one recording. The motion writer and gap tracker
    /// are touched only on motionQueue, the accel pair only on accelQueue, the
    /// GPS writer and event markers only on the main thread.
    private final class ActiveSession {
        let id = UUID().uuidString
        let label: String
        let folderURL: URL
        let startDate: Date
        /// Uptime at session start. CMLogItem.timestamp is on the same
        /// "seconds since boot" clock, so `sample.timestamp - startUptime` is
        /// the CSV `t` column directly.
        let startUptime: TimeInterval

        let motionWriter: CSVWriter
        let accelWriter: CSVWriter
        let gpsWriter: CSVWriter

        var motionGaps = GapTracker(expectedInterval: 1.0 / SessionRecorder.motionHz)
        var accelGaps = GapTracker(expectedInterval: 1.0 / SessionRecorder.accelHz)

        let motionCounter = LockedCounter()
        let accelCounter = LockedCounter()
        let gpsCounter = LockedCounter()

        var eventMarkers: [EventMarker] = []

        init(label: String, folderURL: URL, startDate: Date, startUptime: TimeInterval) throws {
            self.label = label
            self.folderURL = folderURL
            self.startDate = startDate
            self.startUptime = startUptime
            self.motionWriter = try CSVWriter(
                url: folderURL.appendingPathComponent("motion.csv"),
                header: "t,ax,ay,az,gx,gy,gz,rx,ry,rz,qw,qx,qy,qz")
            self.accelWriter = try CSVWriter(
                url: folderURL.appendingPathComponent("accel_raw.csv"),
                header: "t,ax,ay,az")
            self.gpsWriter = try CSVWriter(
                url: folderURL.appendingPathComponent("gps.csv"),
                header: "t,latitude,longitude,speed,horizontalAccuracy,altitude")
        }
    }

    // MARK: - Permissions

    /// Two-step ladder: When-In-Use first, then escalate to Always (the
    /// escalation happens in locationManagerDidChangeAuthorization). Always is
    /// required for capture to survive the screen locking mid-run.
    func requestPermissions() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        updateAuthWarning()
    }

    private func updateAuthWarning() {
        var warning: String?
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .notDetermined:
            warning = nil
        case .authorizedWhenInUse:
            warning = "Location is \"While Using\" only. Grant Always in Settings, or recording stops when the screen locks."
        case .denied, .restricted:
            warning = "Location access is denied. Recording will NOT survive the screen locking. Enable Always location in Settings."
        @unknown default:
            warning = nil
        }
        if locationManager.accuracyAuthorization == .reducedAccuracy {
            let precise = "Precise Location is off; GPS rows will be coarse."
            warning = warning.map { "\($0) \(precise)" } ?? precise
        }
        let resolved = warning
        DispatchQueue.main.async {
            self.locationAuthWarning = resolved
        }
    }

    // MARK: - Session lifecycle

    func startSession(label: String) {
        guard !isRecording else { return }
        lastError = nil
        do {
            let startDate = Date()
            let folderURL = try Self.makeSessionFolder(startDate: startDate)
            let session = try ActiveSession(
                label: label,
                folderURL: folderURL,
                startDate: startDate,
                startUptime: ProcessInfo.processInfo.systemUptime)
            active = session

            // Secondary fallback only — see beginBackgroundAssertion().
            beginBackgroundAssertion()

            // ORDER MATTERS: location starts BEFORE motion and stays running
            // for the entire session. The active location session is what
            // keeps the process alive (and CoreMotion callbacks flowing) once
            // the screen locks.
            configureLocationForRecording()
            locationManager.startUpdatingLocation()

            startMotionCapture(into: session)
            startAccelCapture(into: session)

            isRecording = true
            elapsedSeconds = 0
            motionSampleCount = 0
            accelSampleCount = 0
            gpsSampleCount = 0
            liveMotionHz = 0
            startUITimer()
        } catch {
            lastError = "Could not start session: \(error.localizedDescription)"
            cleanupAfterFailedStart()
        }
    }

    func stopSession() {
        guard isRecording, let session = active else { return }
        let endDate = Date()
        let endUptime = ProcessInfo.processInfo.systemUptime

        motionManager.stopDeviceMotionUpdates()
        motionManager.stopAccelerometerUpdates()
        locationManager.stopUpdatingLocation()

        uiTimer?.invalidate()
        uiTimer = nil

        // Drain both sensor queues so every already-delivered sample lands in
        // its buffer, then flush + close. The waits also provide the memory
        // ordering needed to read the queue-confined gap trackers from here.
        motionQueue.waitUntilAllOperationsAreFinished()
        accelQueue.waitUntilAllOperationsAreFinished()
        session.motionWriter.close()
        session.accelWriter.close()
        session.gpsWriter.close()

        let duration = max(endUptime - session.startUptime, 0)
        let motionCount = session.motionCounter.current
        let accelCount = session.accelCounter.current
        let gpsCount = session.gpsCounter.current

        let metadata = SessionMetadata(
            id: session.id,
            label: session.label,
            startTime: session.startDate,
            endTime: endDate,
            durationSeconds: duration,
            motionSampleCount: motionCount,
            accelSampleCount: accelCount,
            gpsSampleCount: gpsCount,
            achievedMotionHz: duration > 0 ? Double(motionCount) / duration : 0,
            achievedAccelHz: duration > 0 ? Double(accelCount) / duration : 0,
            deviceModel: Self.deviceModelIdentifier,
            iosVersion: UIDevice.current.systemVersion,
            motionGapCount: session.motionGaps.gapCount,
            accelGapCount: session.accelGaps.gapCount,
            largestGapSeconds: max(session.motionGaps.largestGapSeconds,
                                   session.accelGaps.largestGapSeconds),
            eventMarkers: session.eventMarkers)

        do {
            let data = try SessionMetadata.encoder().encode(metadata)
            try data.write(
                to: session.folderURL.appendingPathComponent(SessionMetadata.jsonFileName),
                options: .atomic)
        } catch {
            lastError = "Failed to write session.json: \(error.localizedDescription)"
        }

        if session.motionWriter.writeFailed
            || session.accelWriter.writeFailed
            || session.gpsWriter.writeFailed {
            lastError = "One or more CSV writes failed — this session's files may be truncated."
        }

        endBackgroundAssertion()
        active = nil
        isRecording = false

        motionSampleCount = motionCount
        accelSampleCount = accelCount
        gpsSampleCount = gpsCount
        liveMotionHz = metadata.achievedMotionHz
        elapsedSeconds = duration
        finishedSession = metadata
    }

    /// Append a timestamped marker (lap boundary, condition change). `t` is on
    /// the same timeline as the motion CSV.
    func markEvent(note: String) {
        guard isRecording, let session = active else { return }
        let t = ProcessInfo.processInfo.systemUptime - session.startUptime
        session.eventMarkers.append(EventMarker(t: t, note: note))
    }

    private func cleanupAfterFailedStart() {
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopAccelerometerUpdates()
        locationManager.stopUpdatingLocation()
        endBackgroundAssertion()
        if let folderURL = active?.folderURL {
            try? FileManager.default.removeItem(at: folderURL)
        }
        active = nil
    }

    // MARK: - Sensor streams

    private func startMotionCapture(into session: ActiveSession) {
        guard motionManager.isDeviceMotionAvailable else {
            lastError = "Device motion is not available on this device."
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / Self.motionHz
        // .xArbitraryZVertical: gravity pins Z, X is arbitrary, and no
        // magnetometer is involved — stable for a body-mounted phone.
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) {
            [weak self] motion, error in
            // Runs on motionQueue (serial). Raw values only: nothing here may
            // smooth, resample, or interpolate.
            if let error {
                self?.reportCaptureError(stream: "deviceMotion", error: error)
                return
            }
            guard let motion else { return }
            session.motionGaps.record(timestamp: motion.timestamp)
            let t = motion.timestamp - session.startUptime
            let a = motion.userAcceleration      // g, gravity already removed
            let g = motion.gravity               // g
            let r = motion.rotationRate          // rad/s
            let q = motion.attitude.quaternion
            session.motionWriter.appendRow(String(
                format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
                t, a.x, a.y, a.z, g.x, g.y, g.z, r.x, r.y, r.z, q.w, q.x, q.y, q.z))
            session.motionCounter.increment()
        }
    }

    private func startAccelCapture(into session: ActiveSession) {
        guard motionManager.isAccelerometerAvailable else {
            lastError = "The raw accelerometer is not available on this device."
            return
        }
        // 200 Hz requested for impact rise-time content that 100 Hz
        // deviceMotion smooths out. Some devices will not sustain 200 Hz —
        // that is fine: record whatever arrives, and the achieved rate is
        // reported in session.json.
        motionManager.accelerometerUpdateInterval = 1.0 / Self.accelHz
        motionManager.startAccelerometerUpdates(to: accelQueue) { [weak self] data, error in
            // Runs on accelQueue (serial). Unfused, includes gravity — used
            // only for impact shape, so that is fine.
            if let error {
                self?.reportCaptureError(stream: "accelerometer", error: error)
                return
            }
            guard let data else { return }
            session.accelGaps.record(timestamp: data.timestamp)
            let t = data.timestamp - session.startUptime
            let a = data.acceleration            // g, gravity included
            session.accelWriter.appendRow(String(
                format: "%.6f,%.6f,%.6f,%.6f", t, a.x, a.y, a.z))
            session.accelCounter.increment()
        }
    }

    // ========================================================================
    // WHY LOCATION IS NON-NEGOTIABLE HERE
    //
    // The "location" background mode plus an ACTIVE location session is the
    // only thing that keeps this app executing — and therefore CoreMotion
    // callbacks flowing — once the screen turns off and the phone locks.
    // CoreMotion has no background mode of its own: without live location
    // updates, iOS suspends the process shortly after lock and motion updates
    // simply stop. No error, no callback — just a dead stream and a worthless
    // session discovered an hour later.
    //
    // So: do NOT remove the location background mode from Info.plist thinking
    // it is unused, do NOT stop location updates mid-session, and always start
    // location BEFORE motion. The idle timer is left alone on purpose — the
    // screen is supposed to turn off.
    // ========================================================================
    private func configureLocationForRecording() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .fitness
        // Keep delivering fixes with the app backgrounded and never let the
        // system pause them — a paused location session would let iOS suspend
        // the app, killing the motion streams with it.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Background task assertion

    /// Secondary fallback only: a background task assertion buys roughly 30
    /// seconds of execution on its own. It papers over the transition into the
    /// background; the location session above is what actually keeps the
    /// recording alive for the full run.
    private func beginBackgroundAssertion() {
        endBackgroundAssertion()
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "BaselineLogger.recording") { [weak self] in
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Live UI refresh

    /// The sensor callbacks never touch @Published state (that would bounce
    /// 300 updates/sec through the main thread). Instead a 2 Hz timer polls
    /// the locked counters.
    private func startUITimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshLiveStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    private func refreshLiveStats() {
        guard isRecording, let session = active else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - session.startUptime
        elapsedSeconds = elapsed
        motionSampleCount = session.motionCounter.current
        accelSampleCount = session.accelCounter.current
        gpsSampleCount = session.gpsCounter.current
        liveMotionHz = elapsed > 1 ? Double(motionSampleCount) / elapsed : 0
    }

    private func reportCaptureError(stream: String, error: Error) {
        DispatchQueue.main.async {
            if self.lastError == nil {
                self.lastError = "\(stream) error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Session folder / device info

    private static func makeSessionFolder(startDate: Date) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // ISO 8601 basic format (e.g. 20260828T134502Z): still ISO 8601, but
        // without the ":" characters that Files/Finder handle badly in names.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = formatter.string(from: startDate)
        var url = documents.appendingPathComponent(base, isDirectory: true)
        var attempt = 1
        while FileManager.default.fileExists(atPath: url.path) {
            attempt += 1
            url = documents.appendingPathComponent("\(base)-\(attempt)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Hardware identifier like "iPhone15,2" — more useful downstream than the
    /// marketing name.
    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = Mirror(reflecting: systemInfo.machine).children.reduce(into: "") {
            result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}

// MARK: - CLLocationManagerDelegate

extension SessionRecorder: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Escalate When-In-Use to Always as soon as it is granted; Always is
        // what lets the session keep recording after the screen locks.
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        updateAuthWarning()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Delivered on the main run loop (the manager was created there).
        // ~1 Hz, so writing from here is fine.
        guard isRecording, let session = active else { return }
        for location in locations {
            // GPS `t` uses the fix's wall-clock timestamp relative to session
            // start; fixes can be delivered late, and the fix time is what
            // aligns with reality.
            let t = location.timestamp.timeIntervalSince(session.startDate)
            let coordinate = location.coordinate
            session.gpsWriter.appendRow(String(
                format: "%.6f,%.8f,%.8f,%.3f,%.2f,%.2f",
                t,
                coordinate.latitude,
                coordinate.longitude,
                location.speed,
                location.horizontalAccuracy,
                location.altitude))
            session.gpsCounter.increment()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        reportCaptureError(stream: "location", error: error)
    }
}
