import Foundation
import Combine
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

/// Thread-safe one-way flag. Set once by the main thread at stop; read at the
/// top of every sensor callback so a sample already in flight when updates
/// were stopped cannot touch a closed writer or a tracker the main thread is
/// reading.
final class LockedFlag {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// Snapshot of one stream's integrity counters.
struct GapStats {
    var count = 0
    var largest: TimeInterval = 0
    var dropped = 0
    var nonMonotonic = 0
}

/// Thread-safe mirror of a stream's gap statistics. The GapTracker itself stays
/// confined to its sensor queue; this is what the main thread reads for the
/// periodic in-progress session.json writes, which would otherwise race the
/// sensor queue mutating the tracker.
final class LockedGapStats {
    private let lock = NSLock()
    private var stats = GapStats()

    func update(from tracker: GapTracker) {
        lock.lock()
        stats = GapStats(
            count: tracker.gapCount,
            largest: tracker.largestGapSeconds,
            dropped: tracker.droppedSampleEstimate,
            nonMonotonic: tracker.nonMonotonicCount)
        lock.unlock()
    }

    var current: GapStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }
}

/// Reasons a session refuses to start. Every one of these aborts the start
/// outright: a session that cannot record motion, or cannot keep itself alive
/// with the screen off, is worse than no session at all — it looks like a
/// successful run until the CSVs are opened on a laptop days later.
enum RecorderStartError: LocalizedError {
    case locationAccessDenied
    case deviceMotionUnavailable
    case accelerometerUnavailable

    var errorDescription: String? {
        switch self {
        case .locationAccessDenied:
            return "Recording needs location access. The background location session is the only thing that keeps motion capture running once the screen locks — without it iOS suspends the app and the recording silently stops. Enable location access for BaselineLogger in Settings (While Using is sufficient)."
        case .deviceMotionUnavailable:
            return "Device motion is not available on this device, so there would be no motion.csv."
        case .accelerometerUnavailable:
            return "The raw accelerometer is not available on this device, so there would be no accel_raw.csv."
        }
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
    /// Label of a start parked waiting on the authorization prompt.
    private var pendingStartLabel: String?
    /// UI timer ticks since the last in-progress session.json refresh.
    private var ticksSinceMetadataWrite = 0
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

        /// Queue-safe mirrors of the two trackers above, for the periodic
        /// in-progress metadata writes on the main thread.
        let motionGapStats = LockedGapStats()
        let accelGapStats = LockedGapStats()

        let motionCounter = LockedCounter()
        let accelCounter = LockedCounter()
        let gpsCounter = LockedCounter()
        /// Cached fixes stamped before the session started, not written.
        let gpsStaleSkipped = LockedCounter()

        /// Set at the top of stopSession, before the sensor queues are
        /// drained. Any callback that was already in flight sees it and
        /// returns without touching the writers or trackers.
        let stopped = LockedFlag()

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
            // The 500-row buffer exists to keep memory flat on the high-rate
            // streams (it flushes every 5 s at 100 Hz, every 2.5 s at 200 Hz).
            // GPS arrives at ~1 Hz, so 500 rows would mean 8+ minutes of fixes
            // sitting unflushed — a pure data-loss window if iOS jetsams the
            // app mid-run, with no memory benefit to show for it. 3,600 rows
            // is the whole session; 10 caps the exposure at ~10 seconds.
            // speedAccuracy and verticalAccuracy are what make `speed` and
            // `altitude` interpretable: both are negative when the value is
            // invalid, and a pace model needs to know how much to trust
            // each fix.
            self.gpsWriter = try CSVWriter(
                url: folderURL.appendingPathComponent("gps.csv"),
                header: "t,latitude,longitude,speed,horizontalAccuracy,altitude,speedAccuracy,verticalAccuracy",
                flushThreshold: 10)
        }
    }

    // MARK: - Permissions

    /// Two-step ladder: When-In-Use first, then escalate to Always (the
    /// escalation happens in locationManagerDidChangeAuthorization). Always is
    /// requested so capture does not depend on a foreground start; When-In-Use
    /// plus the location background mode keeps a foreground-started session
    /// alive after the screen locks (see updateAuthWarning and the README).
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
            // With the location background mode and
            // allowsBackgroundLocationUpdates, a session started in the
            // foreground keeps its location updates -- and so the motion
            // streams -- after the screen locks, with the system location
            // indicator showing. Always is still requested because it
            // removes that dependency on the foreground start; it is not
            // known to be strictly required on iOS 16, and that has not
            // been verified on a device here.
            warning = "Location is \"While Using\" only. Recording should keep running after the screen locks (iOS shows the location indicator), but grant Always in Settings for the most reliable capture, and verify a locked-screen test run before trusting a long session."
        case .denied, .restricted:
            warning = "Location access is denied. Recording will NOT survive the screen locking. Enable location for BaselineLogger in Settings."
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

    /// Gate on location authorization before anything is created on disk.
    ///
    /// Recording without location access is not a degraded session, it is a
    /// dead one: iOS suspends the app shortly after the screen locks and the
    /// motion streams stop with no error and no callback. Refusing loudly here
    /// is the only signal the user can act on — a warning banner is useless on
    /// a screen that is off, and the failure itself is invisible until the
    /// CSVs are opened days later.
    func startSession(label: String) {
        guard !isRecording else { return }
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            pendingStartLabel = nil
            lastError = RecorderStartError.locationAccessDenied.localizedDescription
            return
        case .notDetermined:
            // Do not start into an unknown state. Park the request and resume
            // from locationManagerDidChangeAuthorization once the user answers.
            // If a start is already parked -- the prompt was dismissed
            // without an answer, or never appeared -- re-request rather than
            // swallowing the tap, and keep the newest label.
            lastError = nil
            pendingStartLabel = label
            locationManager.requestWhenInUseAuthorization()
            return
        default:
            break
        }
        pendingStartLabel = nil
        beginSession(label: label)
    }

    /// Resume a start that was waiting on the authorization prompt. Called from
    /// the authorization delegate; a no-op unless a start is parked.
    private func resumePendingStartIfNeeded() {
        guard let label = pendingStartLabel else { return }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return  // prompt still up; wait for the user
        case .denied, .restricted:
            pendingStartLabel = nil
            lastError = RecorderStartError.locationAccessDenied.localizedDescription
        default:
            // When-In-Use is enough to begin; the ladder keeps trying for
            // Always and updateAuthWarning() flags the difference.
            pendingStartLabel = nil
            beginSession(label: label)
        }
    }

    private func beginSession(label: String) {
        lastError = nil
        // Held outside the do block so the catch can still delete a folder
        // created before a later step threw. Reading it back off `active` does
        // not work: `active` is assigned only after the last throwing call, so
        // it is always nil by the time the catch runs.
        var createdFolder: URL?
        do {
            // Read both clocks back to back, BEFORE any disk I/O. motion/accel
            // `t` is measured from startUptime and GPS `t` from startDate, so
            // anything between these two lines (creating the folder and three
            // files takes milliseconds) becomes a fixed skew between the
            // streams that nothing downstream can recover.
            let startDate = Date()
            let startUptime = ProcessInfo.processInfo.systemUptime
            let folderURL = try Self.makeSessionFolder(startDate: startDate)
            createdFolder = folderURL
            let session = try ActiveSession(
                label: label,
                folderURL: folderURL,
                startDate: startDate,
                startUptime: startUptime)

            // Write session.json before anything starts, marked in-progress, so
            // a run killed mid-session still leaves readable metadata and shows
            // up in the session list. If this fails the disk is in no state to
            // record, so let it abort the start.
            try writeMetadata(
                metadataSnapshot(for: session,
                                 endDate: session.startDate,
                                 duration: 0,
                                 motionGaps: GapStats(),
                                 accelGaps: GapStats(),
                                 rowsLost: 0,
                                 inProgress: true),
                to: session.folderURL)

            active = session

            // Secondary fallback only — see beginBackgroundAssertion().
            beginBackgroundAssertion()

            // ORDER MATTERS: location starts BEFORE motion and stays running
            // for the entire session. The active location session is what
            // keeps the process alive (and CoreMotion callbacks flowing) once
            // the screen locks.
            configureLocationForRecording()
            locationManager.startUpdatingLocation()

            // Throwing here aborts the whole start through the catch below:
            // a session missing either high-rate stream must never look like
            // it is recording.
            try startMotionCapture(into: session)
            try startAccelCapture(into: session)

            isRecording = true
            elapsedSeconds = 0
            motionSampleCount = 0
            accelSampleCount = 0
            gpsSampleCount = 0
            liveMotionHz = 0
            ticksSinceMetadataWrite = 0
            startUITimer()
        } catch {
            lastError = "Could not start session: \(error.localizedDescription)"
            cleanupAfterFailedStart(folderURL: createdFolder)
        }
    }

    func stopSession() {
        guard isRecording, let session = active else { return }
        let endDate = Date()
        let endUptime = ProcessInfo.processInfo.systemUptime

        // Raise the flag BEFORE stopping updates: CoreMotion does not promise
        // that no callback is still queued when stop returns, and a straggler
        // must find the flag already set.
        session.stopped.set()
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

        // The queues are drained and the flag is up, so the trackers
        // themselves are the authoritative final values; the locked mirrors
        // exist for the mid-session writes.
        let motionStats = GapStats(
            count: session.motionGaps.gapCount,
            largest: session.motionGaps.largestGapSeconds,
            dropped: session.motionGaps.droppedSampleEstimate,
            nonMonotonic: session.motionGaps.nonMonotonicCount)
        let accelStats = GapStats(
            count: session.accelGaps.gapCount,
            largest: session.accelGaps.largestGapSeconds,
            dropped: session.accelGaps.droppedSampleEstimate,
            nonMonotonic: session.accelGaps.nonMonotonicCount)
        let failures = [session.motionWriter, session.accelWriter, session.gpsWriter]
            .map { $0.failureState }
        let rowsLost = failures.reduce(0) { $0 + $1.rowsLost }

        let metadata = metadataSnapshot(
            for: session,
            endDate: endDate,
            duration: duration,
            motionGaps: motionStats,
            accelGaps: accelStats,
            rowsLost: rowsLost,
            inProgress: false)

        // Rewrite session.json in full, clearing the in-progress flag written
        // at start.
        do {
            try writeMetadata(metadata, to: session.folderURL)
        } catch {
            lastError = "Failed to write session.json: \(error.localizedDescription)"
        }

        if failures.contains(where: { $0.writeFailed }) || rowsLost > 0 {
            lastError = "CSV writes failed — \(rowsLost) row(s) never reached disk. This session's files are truncated."
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

    /// Seconds since session start right now, on the motion CSV timeline, or
    /// nil when not recording. The Record screen reads this at the instant
    /// Mark Event is tapped, so the marker is stamped before the note is
    /// typed -- typing a note can take ten seconds, and a lap boundary
    /// stamped ten seconds late is a lap boundary in the wrong place.
    func currentSessionTime() -> TimeInterval? {
        guard isRecording, let session = active else { return nil }
        return ProcessInfo.processInfo.systemUptime - session.startUptime
    }

    /// Append a marker (lap boundary, condition change) at `t`, a value from
    /// `currentSessionTime()` captured when the user tapped Mark Event.
    func markEvent(at t: TimeInterval, note: String) {
        guard isRecording, let session = active else { return }
        session.eventMarkers.append(EventMarker(t: t, note: note))
    }

    /// `folderURL` is the session folder if one was created before the failure
    /// — e.g. a CSVWriter init threw on a full disk, leaving the directory and
    /// possibly a zero-byte motion.csv behind. Remove it: Documents is exposed
    /// through Files and Finder, so a stub folder there reads like a real
    /// session that lost its data.
    private func cleanupAfterFailedStart(folderURL: URL?) {
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopAccelerometerUpdates()
        locationManager.stopUpdatingLocation()
        endBackgroundAssertion()
        if let folderURL {
            try? FileManager.default.removeItem(at: folderURL)
        }
        pendingStartLabel = nil
        active = nil
    }

    // MARK: - Sensor streams

    private func startMotionCapture(into session: ActiveSession) throws {
        guard motionManager.isDeviceMotionAvailable else {
            throw RecorderStartError.deviceMotionUnavailable
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
            guard let motion, !session.stopped.value else { return }
            session.motionGaps.record(timestamp: motion.timestamp)
            session.motionGapStats.update(from: session.motionGaps)
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

    private func startAccelCapture(into session: ActiveSession) throws {
        guard motionManager.isAccelerometerAvailable else {
            throw RecorderStartError.accelerometerUnavailable
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
            guard let data, !session.stopped.value else { return }
            session.accelGaps.record(timestamp: data.timestamp)
            session.accelGapStats.update(from: session.accelGaps)
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

        // A failed flush drops 500 rows and the writer keeps going, so the
        // counters above would keep climbing over a truncated file. Surface
        // it the moment it happens, not at Stop.
        if lastError == nil {
            let lost = [session.motionWriter, session.accelWriter, session.gpsWriter]
                .map { $0.failureState }
            if lost.contains(where: { $0.writeFailed }) {
                let rows = lost.reduce(0) { $0 + $1.rowsLost }
                lastError = "A CSV write failed — \(rows) row(s) lost so far. Disk may be full; this session is truncated."
            }
        }

        // Refresh the in-progress session.json every 30 s so a run killed
        // mid-session leaves metadata no more than 30 s stale.
        ticksSinceMetadataWrite += 1
        if ticksSinceMetadataWrite >= Self.metadataWriteTicks {
            ticksSinceMetadataWrite = 0
            writeInProgressMetadata(for: session, elapsed: elapsed)
        }
    }

    /// UI timer is 0.5 s, so 60 ticks is 30 s.
    private static let metadataWriteTicks = 60

    private func writeInProgressMetadata(for session: ActiveSession, elapsed: TimeInterval) {
        let rowsLost = [session.motionWriter, session.accelWriter, session.gpsWriter]
            .reduce(0) { $0 + $1.failureState.rowsLost }
        let metadata = metadataSnapshot(
            for: session,
            endDate: session.startDate.addingTimeInterval(elapsed),
            duration: elapsed,
            motionGaps: session.motionGapStats.current,
            accelGaps: session.accelGapStats.current,
            rowsLost: rowsLost,
            inProgress: true)
        do {
            try writeMetadata(metadata, to: session.folderURL)
        } catch {
            if lastError == nil {
                lastError = "Failed to update session.json: \(error.localizedDescription)"
            }
        }
    }

    /// Builds the metadata record. `endDate`/`duration` are "as of now" for an
    /// in-progress write and final at stop.
    private func metadataSnapshot(for session: ActiveSession,
                                  endDate: Date,
                                  duration: TimeInterval,
                                  motionGaps: GapStats,
                                  accelGaps: GapStats,
                                  rowsLost: Int,
                                  inProgress: Bool) -> SessionMetadata {
        let motionCount = session.motionCounter.current
        let accelCount = session.accelCounter.current
        return SessionMetadata(
            id: session.id,
            label: session.label,
            startTime: session.startDate,
            endTime: endDate,
            durationSeconds: duration,
            motionSampleCount: motionCount,
            accelSampleCount: accelCount,
            gpsSampleCount: session.gpsCounter.current,
            // Whole-session rate, start-up latency included. The Python side
            // re-derives the rate from the per-sample timestamps; this is
            // the coarse "did the stream keep up" number.
            achievedMotionHz: duration > 0 ? Double(motionCount) / duration : 0,
            achievedAccelHz: duration > 0 ? Double(accelCount) / duration : 0,
            deviceModel: Self.deviceModelIdentifier,
            iosVersion: UIDevice.current.systemVersion,
            motionGapCount: motionGaps.count,
            accelGapCount: accelGaps.count,
            largestGapSeconds: max(motionGaps.largest, accelGaps.largest),
            eventMarkers: session.eventMarkers,
            inProgress: inProgress,
            motionDroppedSampleEstimate: motionGaps.dropped,
            accelDroppedSampleEstimate: accelGaps.dropped,
            motionNonMonotonicCount: motionGaps.nonMonotonic,
            accelNonMonotonicCount: accelGaps.nonMonotonic,
            csvRowsLost: rowsLost,
            gpsStaleFixesSkipped: session.gpsStaleSkipped.current)
    }

    private func writeMetadata(_ metadata: SessionMetadata, to folderURL: URL) throws {
        let data = try SessionMetadata.encoder().encode(metadata)
        try data.write(
            to: folderURL.appendingPathComponent(SessionMetadata.jsonFileName),
            options: .atomic)
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
        // Escalate When-In-Use to Always as soon as it is granted. Always is
        // not what keeps a foreground-started session alive after lock (the
        // background location session does that under When-In-Use); it
        // removes the dependency on a foreground start.
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        updateAuthWarning()
        resumePendingStartIfNeeded()
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
            // CoreLocation commonly hands over its last cached fix first,
            // stamped minutes or hours before the session began. That is a
            // fix from before the session, not a filtered value, so it is
            // skipped (and counted) rather than written with a negative t.
            guard t >= 0 else {
                session.gpsStaleSkipped.increment()
                continue
            }
            let coordinate = location.coordinate
            session.gpsWriter.appendRow(String(
                // Six decimals of latitude/longitude is ~0.1 m, finer than
                // any GPS fix and all a pace model could use; eight was
                // ~1 mm of a track that starts and ends at the runner's door.
                format: "%.6f,%.6f,%.6f,%.3f,%.2f,%.2f,%.3f,%.2f",
                t,
                coordinate.latitude,
                coordinate.longitude,
                location.speed,
                location.horizontalAccuracy,
                location.altitude,
                location.speedAccuracy,
                location.verticalAccuracy))
            session.gpsCounter.increment()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        reportCaptureError(stream: "location", error: error)
    }
}
