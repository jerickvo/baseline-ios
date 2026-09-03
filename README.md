# BaselineLogger

A raw sensor data collection tool for iOS 16+, written in Swift and SwiftUI.

BaselineLogger records device motion, raw accelerometer, and GPS streams to
CSV files during a run, with the phone locked in a running belt at the lower
back. The CSVs are pulled onto a laptop and analyzed in Python later. That is
the entire scope: **no analysis, no charts, no metrics, no step detection, no
filtering happen on the phone.** Raw values only — nothing is smoothed,
resampled, or interpolated on write.

Data continuity is the top priority. The app tracks inter-sample gaps, samples
dropped below the gap threshold, duplicated or reordered samples, and rows
that never reached disk, and reports all of them prominently, because a
session with missing samples is worthless.

> **Build status.** The changes from the September 2026 audit (integrity
> counters, marker timing, stale-fix filtering, write-failure surfacing,
> the stop-race guard, GPS accuracy columns) were made by static review on a
> machine with no Swift toolchain. They have not been compiled or run on a
> device. Build in Xcode and do a locked-screen test run before trusting a
> long session.

## Project layout

```
BaselineLogger.xcodeproj/
BaselineLogger/
  BaselineLoggerApp.swift        App entry point
  Info.plist                     Permissions, background mode, file sharing
  Models/SessionMetadata.swift   session.json schema + display formatting
  Recording/CSVWriter.swift      Buffered FileHandle CSV writer (flat memory)
                                 500-row buffer on the high-rate streams;
                                 GPS uses 10 (see "Buffering" below)
  Recording/GapTracker.swift     Gap detection vs measured (not requested) rate
  Recording/SessionRecorder.swift  The capture engine (motion / accel / GPS)
  Storage/SessionStore.swift     Scans Documents for recorded sessions
  Storage/SessionArchive.swift   Session folder -> zip for the share sheet
  Views/RootView.swift           Tab container
  Views/RecordView.swift         Label field, start/stop, live counters, Mark Event
  Views/SessionSummaryView.swift End-of-session summary (gaps shown here)
  Views/SessionListView.swift    All sessions, warning icon when gaps > 0
  Views/SessionDetailView.swift  Full metadata + zip export
```

## Building

1. Open `BaselineLogger.xcodeproj` in Xcode 15 or later.
2. In **Signing & Capabilities**, pick your team and change the bundle
   identifier (`com.example.BaselineLogger`) to something in your namespace.
3. Build to a physical device. Sensors and background execution do not work
   in the simulator.

### Capabilities and Info.plist

Everything required is already configured in `BaselineLogger/Info.plist`;
nothing needs to be added by hand. For reference:

| Key | Why |
| --- | --- |
| `NSMotionUsageDescription` | Motion data usage string. |
| `NSLocationWhenInUseUsageDescription` | First step of the permission ladder. |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | Always access — requested so capture does not depend on the session having been started in the foreground. See the note on When-In-Use below. |
| `UIBackgroundModes = [location]` | **Do not remove.** CoreMotion has no background mode of its own. The active background location session is the only thing that keeps the app running — and motion callbacks flowing — once the screen locks. Removing this silently kills every recording at screen-off. |
| `UIFileSharingEnabled` | Exposes Documents in Finder device file sharing. |
| `LSSupportsOpeningDocumentsInPlace` | Exposes Documents in the Files app. |

The **Background Modes → Location updates** capability in Signing &
Capabilities is just a UI over `UIBackgroundModes`; it should show as enabled
when you open the project.

### How background capture works

With the screen off, iOS suspends apps and motion updates stop **with no
error**. BaselineLogger stays alive by:

1. Requesting **Always** location authorization (two-step ladder: When-In-Use
   first, then Always).
2. Starting a continuous location session (`kCLLocationAccuracyBest`,
   `allowsBackgroundLocationUpdates = true`,
   `pausesLocationUpdatesAutomatically = false`) **before** motion updates,
   and keeping it running for the full session.
3. Holding a `UIApplication` background task assertion as a secondary
   fallback (worth ~30 seconds on its own; the location session does the real
   work).

The idle timer is deliberately not disabled — the screen is supposed to turn
off. On first run, grant location access, and when iOS later asks to upgrade
to "Always Allow", accept.

**On When-In-Use vs Always.** With the location background mode and
`allowsBackgroundLocationUpdates = true`, a location session started while
the app is in the foreground continues after the screen locks under
When-In-Use authorization alone, with the system location indicator showing.
Always is therefore not believed to be strictly required on iOS 16 for the
way this app starts sessions; it is requested because it removes that
dependency on a foreground start and costs nothing. This has not been
verified on a device by the audit that wrote this paragraph. Do one
locked-screen test run under each authorization level and check
`achievedMotionHz` in `session.json` before relying on either.

**Recording refuses to start without location access.** If authorization is
denied or restricted, Start does nothing except show an error: there is no
useful degraded mode, because iOS suspends the app shortly after the screen
locks and the motion streams stop with no error and no callback. A warning
banner would be useless on a screen that is off, so the app refuses up front
rather than handing you a run that dies ten minutes in. If authorization has
not been decided yet, Start waits for your answer to the prompt instead of
beginning in an unknown state. A session also refuses to start if device
motion or the raw accelerometer is unavailable — a session with no motion.csv
must never look like it is recording.

### Buffering and what a crash costs you

Rows are built into a string buffer and flushed to disk through a
`FileHandle`; the buffer is reused, so memory stays flat regardless of session
length. Nothing is ever held for the whole session — a 60 minute run is
360,000 motion rows and 720,000 raw accel rows.

The flush threshold is 500 rows on the two high-rate streams, which is what
keeps their memory flat: that is a flush every 5 s at 100 Hz and every 2.5 s
at 200 Hz. GPS is the exception, at 10 rows. At ~1 Hz a 500-row buffer would
hold 8+ minutes of fixes in memory, so if iOS jetsams the app mid-run you
would lose 8 minutes of GPS — all downside, and no memory saving to show for
it, since the entire session is only ~3,600 GPS rows. Ten rows caps the
exposure at ~10 seconds. If you want it uniform, it is the one
`flushThreshold: 10` argument in `SessionRecorder.ActiveSession.init`.

On an unexpected termination the CSVs keep whatever was flushed, and
`session.json` keeps whatever the last periodic write recorded — it is written
at session start and refreshed every 30 s, so the session still appears in the
Sessions list, marked **INCOMPLETE**, rather than vanishing. Its counts,
duration and gaps are up to 30 s stale and the CSVs end wherever the app died.

## Recording protocol

- Type a session label before starting (e.g. `normal 3mi`,
  `heel lift left 3mi`). Labels drive the downstream validation protocol.
- **Mark Event** appends a timestamped marker with an optional note — drop
  markers at lap boundaries. The marker is stamped **at the moment you tap
  Mark Event**, not when you finish typing the note, so take your time with
  the note. Markers land in `session.json`, on the same timeline as the CSV
  `t` column.
- When you stop, a summary shows duration, sample counts, achieved rates,
  and the four integrity counters. **If the summary says anything other
  than "Continuous", distrust the session** before building analysis on it.

## Pulling data off the device

One folder per session in the app's Documents directory, named with an ISO
8601 basic-format UTC timestamp (e.g. `20260828T134502Z` — the basic format
avoids `:` characters, which file systems and Finder handle badly). Each
folder contains `motion.csv`, `accel_raw.csv`, `gps.csv`, `session.json`.

Three ways to get the folders:

1. **Finder (macOS):** connect the phone, select it in the sidebar, open the
   **Files** tab, expand **BaselineLogger**, and drag session folders out.
2. **Files app (on the phone):** On My iPhone → BaselineLogger. Useful for
   quick checks or copying to iCloud Drive.
3. **Share sheet:** Sessions tab → session → **Export Session Zip** — zips
   the folder and hands it to AirDrop / Mail / etc.

## CSV column definitions

All three files share the `t` column: seconds since session start, printed
with 6 decimal places. For `motion.csv` and `accel_raw.csv`, `t` comes from
the sample's own hardware timestamp (seconds-since-boot clock), so
inter-sample deltas are exact. For `gps.csv`, `t` is derived from the fix's
wall-clock timestamp relative to session start — fixes are timestamped at
measurement, not delivery. The two origins (`Date()` and `systemUptime`) are
read back to back before any file is created, so the streams share a `t = 0`
to within microseconds. A mid-session NTP clock adjustment could still shift
GPS `t` slightly; it can never shift motion/accel `t`, which ride the
monotonic clock.

### motion.csv — fused device motion, requested at 100 Hz

`CMMotionManager.startDeviceMotionUpdates`, reference frame
`.xArbitraryZVertical` (gravity pins Z; X arbitrary; no magnetometer).

**Frames.** `ax..az`, `gx..gz` and `rx..rz` are all expressed in the
**device (body) frame** — the phone's own axes, whatever way it is mounted.
The reference frame named above applies **only** to the quaternion, which
rotates device coordinates into it. That is what the downstream pipeline
needs: it resolves the anatomical frame from `gx..gz` itself. (Sanity check
for any consumer: rotating `g` by the quaternion must give approximately
`(0, 0, -1)`.)

| Column | Meaning | Units |
| --- | --- | --- |
| `t` | Seconds since session start | s |
| `ax ay az` | `userAcceleration` — gravity already removed, device frame | g |
| `gx gy gz` | `gravity` vector, device frame | g |
| `rx ry rz` | `rotationRate` (bias-corrected), device frame | rad/s |
| `qw qx qy qz` | `attitude` quaternion (device → reference frame) | unitless |

### accel_raw.csv — raw accelerometer, requested at 200 Hz

Unfused and **includes gravity**. Exists because impact rise time lives in
high-frequency content that 100 Hz device motion smooths out; used only for
impact shape. Some devices will not sustain 200 Hz — the stream records
whatever arrives, and the achieved rate is in `session.json`. **Check it:**
if `achievedAccelHz` is not well above 100, this file carries no more
bandwidth than `motion.csv` and its reason for existing is unmet on that
device. Whether any iPhone actually delivers 200 Hz through
`CMMotionManager` has not been verified here.

| Column | Meaning | Units |
| --- | --- | --- |
| `t` | Seconds since session start | s |
| `ax ay az` | Raw acceleration, gravity included | g |

### gps.csv — CLLocationManager, best accuracy, ~1 Hz

| Column | Meaning | Units |
| --- | --- | --- |
| `t` | Seconds since session start (fix timestamp) | s |
| `latitude` / `longitude` | WGS-84 coordinate | degrees |
| `speed` | Instantaneous ground speed; **-1 when invalid** (raw, unfiltered) | m/s |
| `horizontalAccuracy` | Radius of uncertainty; negative when invalid | m |
| `altitude` | Above mean sea level | m |
| `speedAccuracy` | 1-sigma uncertainty of `speed`; **negative when `speed` is invalid** | m/s |
| `verticalAccuracy` | Uncertainty of `altitude`; **negative when `altitude` is invalid** | m |

CoreLocation usually delivers its last *cached* fix first, stamped minutes or
hours before the session began. Those fixes are skipped (they would carry a
negative `t`) and counted in `session.json` as `gpsStaleFixesSkipped`, so
`t` in this file is never negative. Files written before the two accuracy
columns existed have six columns; load by column name.

### session.json

| Field | Meaning |
| --- | --- |
| `id` | UUID for the session |
| `label` | The label typed on the Record screen |
| `startTime` / `endTime` | ISO 8601 wall-clock timestamps |
| `durationSeconds` | Measured on the monotonic clock |
| `motionSampleCount` / `accelSampleCount` / `gpsSampleCount` | Rows written per CSV |
| `achievedMotionHz` / `achievedAccelHz` | sample count / duration — compare against 100 / 200 |
| `deviceModel` | Hardware identifier, e.g. `iPhone15,2` |
| `iosVersion` | e.g. `17.5.1` |
| `motionGapCount` / `accelGapCount` | Number of gaps per stream (see below) |
| `largestGapSeconds` | Largest single gap across both streams |
| `eventMarkers` | Array of `{t, note}` on the CSV `t` timeline |
| `inProgress` | `true` while a session is unfinalized. session.json is written at start and refreshed every 30 s, so a run killed mid-session still leaves metadata; stop rewrites the file with this `false`. Absent in files written before this field existed — those are complete. |
| `motionDroppedSampleEstimate` / `accelDroppedSampleEstimate` | Samples estimated missing from intervals that were long but **below** the gap threshold. See "Gap definition". |
| `motionNonMonotonicCount` / `accelNonMonotonicCount` | Duplicated or reordered samples (zero or negative timestamp delta). |
| `csvRowsLost` | Rows the sample counters credited that never reached disk (a failed flush discards its whole buffer). |
| `gpsStaleFixesSkipped` | Cached fixes stamped before session start, not written to gps.csv. |

The last four are absent from files written before they existed. The
Python loader treats a session as clean only when all four are zero.

**Gap definition:** any delta between consecutive sample timestamps greater
than **3x the interval the stream is actually delivering** counts as one gap.
The threshold is measured, not assumed: after a 128-delta warm-up the tracker
takes the median observed delta and uses 3x that, recalibrating every 128
deltas (warm-up deltas are classified retroactively, so nothing is missed).

**A gap count of zero was never proof of continuity.** One dropped sample
makes a 2x interval and two consecutive dropped samples make exactly 3x — the
gap rule counts neither. So the tracker also converts any interval beyond
1.5x the median into an estimate of samples missing (`round(delta / median)
- 1`) and reports that separately. A stream can shed a sample every few
seconds with `gapCount = 0`; it cannot do so with
`droppedSampleEstimate = 0`. During a genuine rate change the estimate
counts the transition until the threshold recalibrates (at most 128
deltas), which is an honest upper bound rather than a false gap.

This matters because the threshold is deliberately *not* anchored to the
requested rate. At 3x the requested 1/200 s accel interval, any device
delivering below ~66 Hz would report every single sample as a gap — turning
the one number you use to decide whether a session is trustworthy into noise,
on exactly the devices the app is meant to tolerate. **A rate merely lower
than requested is reported by `achievedAccelHz`; `accelGapCount` counts breaks
in delivery.** Median rather than mean is also deliberate: a handful of real
gaps in the window cannot inflate the threshold meant to detect them.

Gap counts and the largest gap are shown on screen the moment a session ends
and flagged with a warning icon in the session list.

Loading in Python — use the analysis repo's loader rather than reading the
CSV directly. It measures the sample rate from `t`, recomputes gaps and
dropped samples independently of `session.json`, drops invalid GPS rows, and
runs the quality gate:

```python
from src import pipeline           # jerickvo/baseline-analysis
result = pipeline.run_session("20260828T134502Z")
print(result["quality"]["verdict"])   # "ok" | "partial" | "insufficient"
```

or from a shell: `python scripts/run_session.py 20260828T134502Z`.

## Constraints (by design)

- No analysis, charts, gait metrics, step detection, or filtering.
- No backend, no network calls, no accounts.
- No third-party dependencies: Foundation, SwiftUI, CoreMotion, CoreLocation
  only. (Zip export uses `NSFileCoordinator`'s `.forUploading` — the one
  folder-to-zip facility built into Foundation.)
- Raw values on write, always.
