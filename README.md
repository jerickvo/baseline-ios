# BaselineLogger

A raw sensor data collection tool for iOS (16+), built with Swift and SwiftUI.
It records device motion, raw accelerometer, and GPS streams to CSV during runs
— phone in a running belt at the lower back, screen off, phone locked — and
exports the files for analysis in Python.

This is deliberately **not** a finished product. There is no analysis, no
charting, no step detection, no filtering, no backend, and no third-party
dependencies. Foundation, SwiftUI, CoreMotion, and CoreLocation only. Raw
values are written exactly as the OS delivers them: nothing is smoothed,
resampled, or interpolated.

## Project layout

```
BaselineLogger.xcodeproj/
BaselineLogger/
  BaselineLoggerApp.swift        App entry point
  Info.plist                     Permissions, background mode, file sharing
  Models/SessionMetadata.swift   session.json model + event markers
  Recording/CSVWriter.swift      Buffered FileHandle CSV writer
  Recording/StreamStats.swift    Sample counting, achieved Hz, gap detection
  Recording/RecordingEngine.swift  The three capture streams + session lifecycle
  Storage/SessionStore.swift     Session list from Documents
  Export/SessionExporter.swift   Folder → zip via NSFileCoordinator
  Views/                         Record, Summary, Session list, Session detail
```

## Capabilities and Info.plist setup

Everything is already configured in `BaselineLogger/Info.plist`; if you
recreate the project, these are the keys that matter:

| Key | Value | Why |
| --- | --- | --- |
| `NSMotionUsageDescription` | text | Motion data access |
| `NSLocationWhenInUseUsageDescription` | text | GPS while app is open |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | text | GPS with the phone locked |
| `UIBackgroundModes` | `location` | **Keeps the whole app — including CoreMotion — alive with the screen off.** |
| `UIFileSharingEnabled` | `true` | Session folders visible in Finder |
| `LSSupportsOpeningDocumentsInPlace` | `true` | Session folders visible in the Files app |

In Xcode's *Signing & Capabilities* tab this appears as **Background Modes →
Location updates**. Do not remove it: CoreMotion has no background mode of its
own. The active location session is the only thing preventing iOS from
suspending the app when the phone locks; if it goes, motion updates stop
silently mid-run and the session is worthless. The app also takes a
`UIApplication` background task assertion as a secondary fallback, but that
alone only buys about 30 seconds.

To build: open `BaselineLogger.xcodeproj`, select your development team under
Signing & Capabilities, and run on a device (sensors do not exist in the
simulator).

On first recording the app asks for location permission. **Choose "Always"**
(the app escalates the request; you can also set it later in Settings →
BaselineLogger → Location). With only "While Using", recording dies the moment
the phone locks. The screen is supposed to turn off during a run — the idle
timer is deliberately left alone.

## Recording behavior

- Start a session on the Record screen, optionally with a label
  (e.g. `normal 3mi`, `heel lift left 3mi`).
- Location updates start **before** motion updates and run for the whole
  session (that ordering is what keeps background delivery alive).
- Mark Event appends a timestamped marker with an optional note (e.g. lap
  boundaries) to `session.json`.
- On stop, a summary shows duration, sample counts, achieved rates, gap count,
  and largest gap. **If gap count is above zero, samples were dropped** —
  check the session before building analysis on it. Sessions with gaps get a
  warning icon in the session list.

A gap is a delta between consecutive sample timestamps greater than 3× the
expected interval (motion: 10 ms expected, accel: 5 ms expected).

## Data output

One folder per session in the app's Documents directory, named with an
ISO 8601 basic-format UTC timestamp (`20260828T143005Z` — no colons, so the
names survive Finder and every filesystem the data gets copied to). Contents:

```
motion.csv       ~100 Hz fused device motion
accel_raw.csv    ~200 Hz raw accelerometer (unfused, includes gravity)
gps.csv          ~1 Hz location
session.json     Session metadata
```

Rows are flushed to disk every 500 rows through a buffered `FileHandle`;
memory stays flat for arbitrarily long sessions and a crash can lose at most
the last flush window.

### Timebase

`t` in every CSV is **seconds since session start**, 6 decimal places.
For motion and accel rows, `t` comes from the sample's own CoreMotion
timestamp (the boot-time clock), i.e. capture time, not delivery time. GPS `t`
comes from the fix's wall-clock timestamp relative to session start.

### motion.csv (CMMotionManager deviceMotion, `.xArbitraryZVertical`, 100 Hz target)

| Column | Meaning | Units |
| --- | --- | --- |
| `t` | Seconds since session start | s |
| `ax ay az` | `userAcceleration` — gravity already removed | g |
| `gx gy gz` | `gravity` vector | g |
| `rx ry rz` | `rotationRate` | rad/s |
| `qw qx qy qz` | `attitude.quaternion` | unitless |

### accel_raw.csv (raw accelerometer, 200 Hz target)

| Column | Meaning | Units |
| --- | --- | --- |
| `t` | Seconds since session start | s |
| `ax ay az` | Raw acceleration — unfused, **includes gravity** | g |

This stream exists because impact rise time lives in high-frequency content
that 100 Hz fused deviceMotion smooths out. Some devices will not sustain
200 Hz; whatever arrives is recorded and the achieved rate is reported in
`session.json` (`achievedAccelHz`).

### gps.csv (CLLocationManager, `kCLLocationAccuracyBest`, ~1 Hz)

| Column | Meaning | Units |
| --- | --- | --- |
| `t` | Seconds since session start | s |
| `latitude`, `longitude` | Coordinate | degrees |
| `speed` | Ground speed (**-1 when invalid** — recorded raw) | m/s |
| `horizontalAccuracy` | Radius of uncertainty (negative = invalid fix) | m |
| `altitude` | Altitude above sea level | m |

### session.json

```json
{
  "id": "UUID",
  "label": "normal 3mi",
  "startTime": "2026-08-28T14:30:05Z",
  "endTime": "2026-08-28T15:02:11Z",
  "durationSeconds": 1926.0,
  "motionSampleCount": 192600,
  "accelSampleCount": 385200,
  "gpsSampleCount": 1926,
  "achievedMotionHz": 100.0,
  "achievedAccelHz": 200.0,
  "deviceModel": "iPhone15,2",
  "iosVersion": "17.5",
  "motionGapCount": 0,
  "accelGapCount": 0,
  "largestGapSeconds": 0,
  "eventMarkers": [ { "t": 421.5, "note": "lap 1" } ]
}
```

`achieved*Hz` is sample count over the timestamp span the stream actually
covered. `largestGapSeconds` is the largest gap across the motion and accel
streams.

## Pulling data off the device

Three ways, no share sheet required for the first two:

1. **Finder (macOS)** — connect the phone, select it in Finder, open the
   *Files* tab, expand *BaselineLogger*, and drag session folders out.
2. **Files app (on the phone)** — On My iPhone › BaselineLogger; copy folders
   to iCloud Drive or anywhere else.
3. **Share sheet** — Sessions tab › session › *Export Zip* zips the session
   folder and opens the share sheet (AirDrop, Save to Files, …).

These work because `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`
are set, which expose the app's Documents directory.
