# `android_ready/` — Android capture layer, written before the Android app exists

## Read this first

**There is no `android/` directory in this repository.** The Flutter Android
application has never been created. Nothing in this folder has run on an Android
device, and nothing in this folder *can* run on an Android device until someone
runs `flutter create --platforms=android .` and wires it up.

So this is not "the Android capture layer, untested". It is **ready-to-drop
source plus the checks that could be performed off-device**, and this README is
explicit about which is which.

| Layer | Location | Verified how |
|---|---|---|
| Algorithms (all judgement) | `dart/pw_android_capture/` | **88 unit tests, `dart test`, green.** 16 negative controls, each confirmed to turn the suite red. |
| Channel bridge | `dart/pw_android_capture_flutter/` | **6 tests, `flutter test`, green**, through a real `MethodChannel` with a mock handler. `flutter analyze` clean against the installed Flutter 3.47.1 / Dart 3.13.1. 2 negative controls confirmed red. |
| Platform glue | `kotlin/com/pocketworld/capture/` | **Never compiled.** No Android SDK, no `kotlinc` and no JRE on this machine. Every API used was checked against Google's published reference (see *API provenance*), but a typo would only surface at the first Gradle build. |
| Build config | `manifest/`, `gradle/` | **Never applied.** Snippets, not files. |
| 16 KB check | `scripts/` | **Run for real** against xrslam's actual Android arm64 output. Exit-code matrix exercised across four cases, including a deliberately sabotaged library. |

The split is deliberate: the Kotlin was kept as thin marshalling **because it
cannot be tested here**. Every threshold, every comparison and every fail-safe
decision lives in Dart, where it is covered. If you find yourself adding an `if`
to a `.kt` file in here, add it to the Dart package instead.

---

## What goes where

```
android_ready/
├── dart/pw_android_capture/          → keep as a package; add as a path dep
│   └── lib/src/
│       ├── clock_offset.dart              BOOTTIME↔MONOTONIC offset estimator
│       ├── camera_timebase.dart           frame instant in the IMU time base
│       ├── sensor_delivery_monitor.dart   achieved IMU rate + batching audit
│       ├── thermal_policy.dart            headroom governor + poll gating
│       ├── exit_triage.dart               ApplicationExitInfo attribution
│       ├── deferred_frame_buffer.dart     defer-without-loss for early frames
│       └── channel_codec.dart             platform-map decoding
│
├── dart/pw_android_capture_flutter/   → keep as a package; add as a path dep
│   └── lib/pw_android_capture_channel.dart   MethodChannel/EventChannel bridge
│
├── kotlin/com/pocketworld/capture/    → android/app/src/main/kotlin/com/pocketworld/capture/
│       PwClockProbe.kt          nanoTime ↔ elapsedRealtimeNanos probes
│       PwImuSource.kt           SensorManager registration, maxReportLatencyUs = 0
│       PwCameraProbe.kt         camera2 reads + EIS/OIS/distortion OFF
│       PwThermalWatch.kt        PowerManager thermal, 10 s poll guard
│       PwExitInfoReader.kt      getHistoricalProcessExitReasons marshalling
│       PwCapturePlugin.kt       FlutterPlugin wiring
│
├── manifest/AndroidManifest.snippet.xml   → merge into app/src/main/AndroidManifest.xml
├── gradle/app-build.gradle.kts.snippet    → merge into app/build.gradle.kts
├── gradle/settings.gradle.kts.snippet     → merge into android/settings.gradle.kts
└── scripts/
    ├── check_elf_align.py     pure-Python 16 KB ELF check (no Android SDK)
    └── verify_16kb.sh         (A) ELF alignment + (B) zipalign
```

### Requirements the drop-in imposes

* `minSdk = 24`, `compileSdk = 35`, `targetSdk = 35`.
  Everything above 24 is behind an explicit `Build.VERSION.SDK_INT` check:
  `DISTORTION_CORRECTION_MODE` (28), thermal status (29), `getThermalHeadroom`
  and `ApplicationExitInfo` (30), `getSubReason` (31).
* Permissions: `CAMERA` (runtime) and `HIGH_SAMPLING_RATE_SENSORS`
  (**normal** — install-time, no prompt).
* ABI: `arm64-v8a` only.
* AGP ≥ 8.5.1, NDK ≥ r28 (16 KB page sizes).

### `pubspec.yaml` stanza

```yaml
dependencies:
  pw_android_capture:
    path: android_ready/dart/pw_android_capture
  pw_android_capture_flutter:
    path: android_ready/dart/pw_android_capture_flutter
```

Do **not** add this until an Android app exists — it is dead weight on the iOS
build and the packages are self-contained and testable where they stand.

### `MainActivity.kt`

```kotlin
override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.plugins.add(com.pocketworld.capture.PwCapturePlugin())
}
```

---

## The five problems this solves, and why each one is not obvious

### 1. Two clocks that are not the same clock

`SensorEvent.timestamp` is `CLOCK_BOOTTIME`. `CaptureResult.SENSOR_TIMESTAMP`
is only `CLOCK_BOOTTIME` when
`CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE == REALTIME`. When it is
`UNKNOWN`, the platform says the stamp is *"monotonic but not comparable to
timestamps from other subsystems"* — in practice `CLOCK_MONOTONIC`, which stops
during suspend. Fusing the two without measuring the offset is silently wrong,
and it is wrong by however long the device has been asleep.

The estimator is Cristian's algorithm: read `mono, boot, mono`, take the
midpoint, keep the probe with the smallest window out of N. **Averaging is
wrong** — a probe that was descheduled between its two reads carries an
arbitrarily large one-sided error, and the mean lets that error in.

`offset = BOOTTIME − MONOTONIC` is accumulated suspend time, so it is
non-decreasing. A measured *decrease* is physically impossible; the estimator
reports it and **keeps the old offset**, rather than adopting a value it knows
is corrupt.

A null `SENSOR_INFO_TIMESTAMP_SOURCE` is read as `UNKNOWN`, never as
`REALTIME`. Guessing `REALTIME` on a device that never said so is the one
mistake with no downstream symptom.

### 2. `SENSOR_TIMESTAMP` is not the time the picture was taken

It is documented as the *first row* exposure *start*. The photometric centre of
the frame is

```
t_centre = t_first_row_start + exposure/2 + rolling_shutter_skew/2
```

At 1/60 s exposure with a 20 ms readout that is **18.3 ms**. It is a constant,
signed bias on every frame — at a hand-held 30 °/s pan, ~0.55° of unmodelled
rotation per frame that no amount of averaging removes. `camera_timebase.dart`
also exposes per-row instants, since a rolling-shutter-aware front end wants the
instant of the row a feature actually sits on. The test suite asserts the frame
centre *is* the mean of the per-row centres, so the two are consistent by
construction.

`SENSOR_EXPOSURE_TIME` and `SENSOR_ROLLING_SHUTTER_SKEW` are **optional** camera2
keys. A device that omits them gets a partially corrected instant flagged
`degraded` — the frame is still delivered, and the shortfall is auditable rather
than believed.

### 3. `registerListener` is a suggestion, not a contract

Two independent problems:

* **Rate.** The delay you pass is a hint; the platform decides. Android 12+
  (API 31) hard-caps motion sensors at 200 Hz unless the manifest declares
  `HIGH_SAMPLING_RATE_SENSORS`. **There is no API that returns the achieved
  rate.** `SensorDeliveryMonitor` reconstructs it from the timestamps — median,
  not mean, so a single suspend or dropped block cannot move it.
* **Batching.** `maxReportLatencyUs > 0` enables hardware FIFO batching, which
  hands a whole burst to one callback — the arrival pattern that degenerates
  xrslam's gyro/accel interleave (`xrslam/src/xrslam/core/detail.cpp`). We pass
  `0`. That is also only a request, so the monitor verifies it: unbatched
  delivery has `arrivalΔ ≈ eventΔ`, batched delivery has `arrivalΔ ≈ 0` while
  `eventΔ` stays at the nominal period. The two populations are ~3 orders of
  magnitude apart; the test sweeps the discriminating ratio over `[2, 20]` and
  asserts the verdict does not move, so the threshold is a divider between
  clusters rather than a tuned constant.

The monitor also flags perfectly equidistant timestamps *inside* a burst — the
fingerprint of a HAL synthesising sample instants instead of reporting them.

### 4. Thermal, without a quality slider

`getThermalHeadroom` returns `NaN` if called too often. **Google's two sources
disagree, and this is worth knowing**: the `android.os.PowerManager` reference
says NaN comes from calling *"significantly faster than once per second"*, while
the ADPF thermal guide says *"You shouldn't call it more than once every 10
seconds."* We obey the **stricter** one (10 s), because violating it costs the
signal entirely. That floor is an `assert` in the constructor, so a violating
configuration cannot be written.

`NaN` on the very first call means the device has no thermal HAL — permanent,
stop polling, steer on `getCurrentThermalStatus()` alone. `NaN` after a good
reading means *stale*: the last real value stays in force. **`NaN` is never read
as `0.0`**, which would make an overheating device look cold.

The action vocabulary is `proceed | shed | defer` and deliberately contains no
"drop" and no quality tier: fail-safe may postpone, never discard, and the
product has no user-visible quality knob to fall back to. Hysteresis bands are
0.10 wide because the sample interval is 10 s and a governor that flaps on the
edge is itself a thermal load.

### 5. The death that leaves no trace

Android 17 enforces per-app memory limits. Google, verbatim
(Android Developers Blog, 2026-06):

> "If an app exceeds those limits, Android will kill the process with no
> associated stack trace."

> "call `getDescription()` within `ApplicationExitInfo`. If the system applied a
> limit, the exit reason is reported as `REASON_OTHER` and the description
> string will contain `MemoryLimiter:AnonSwap`"

Two consequences drive `exit_triage.dart`:

1. The reason code is `REASON_OTHER` (13) — the same bucket as ordinary
   uninteresting system kills. **The description substring is the only
   discriminator.** Classifying on the reason code alone is useless; the tests
   pin both directions (code without substring ⇒ not it; substring under a
   different code ⇒ not it).
2. There is no crash, no ANR and no tombstone. A native VIO map is anonymous
   memory, which is exactly what `AnonSwap` accounts, so this is the most likely
   way a long capture dies on Android 17 — and if it is not read at the *next*
   launch it is invisible forever.

Delivery is watermark-based: records are replayed oldest-first and the watermark
advances **only** on confirmed persistence. A crash between read and persist
re-delivers; it never skips.

> ⚠️ One caveat on the brief this was written from: secondary coverage disputes
> the "no stack trace" framing, noting that `ApplicationExitInfo` *does* record
> the exit and that Android 17 adds anomaly-triggered heap capture
> (`TRIGGER_TYPE_ANOMALY`). Both are true and not in conflict — there is no
> *stack trace*, but there is a *record*. Reading that record is precisely what
> `PwExitInfoReader` + `ExitTriage` do. The anomaly profiling API is **not**
> used here: its exact surface was not verified, so it is a note, not code.

---

## 16 KB page sizes — the date, and the check nobody runs

**February 1, 2027**, verbatim from `developer.android.com/guide/practices/page-sizes`:

> "Starting February 1, 2027, if your app updates don't support 16 KB memory
> page sizes, you won't be able to release these updates."

(The widely repeated 2025-11-01 was an earlier, narrower milestone. 2027-02-01
is the one that governs app updates targeting Android 15 / API 35+.)

Two independent properties must both hold, and they fail independently:

| | What | Produced by | Checked by |
|---|---|---|---|
| **A** | every `PT_LOAD` segment in every `.so` aligned to 16 KB | the **NDK** that compiled it (r28+) | `scripts/check_elf_align.py` |
| **B** | uncompressed `.so` on 16 KB boundaries in the zip | **AGP** 8.5.1+ and `extractNativeLibs="false"` | `zipalign -c -P 16 -v 4 app.apk` |

Google's documented command only covers **B**. A library built by an old NDK
passes `zipalign` and still cannot be mapped on a 16 KB device — and **A** is
the one that catches *prebuilts*: xrslam's `libxrslam.so`, OpenCV's
`libopencv_java*.so`, every Flutter plugin's `.so`. One 4 KB-aligned prebuilt
fails the whole APK and nothing in the build warns you.

`check_elf_align.py` is pure Python — no Android SDK, no `readelf` — so the
prebuilt audit runs in CI and on a laptop. It reads only the ELF header and the
program-header table, a few hundred bytes, so it is safe to point at a directory
of large libraries.

### Measured today, against real artefacts

```
$ scripts/check_elf_align.py <xrslam android build output>
PASS  aarch64  build-and-hard/xrslam-interface/libxrslam.so    min PT_LOAD align=0x4000 (16 KB)
PASS  aarch64  build-android-probe/libxrslam-stripped.so       min PT_LOAD align=0x4000 (16 KB)
PASS  aarch64  OpenCV-android-sdk/.../arm64-v8a/libopencv_java5.so  min PT_LOAD align=0x4000 (16 KB)
FAIL  arm      OpenCV-android-sdk/.../armeabi-v7a/libopencv_java5.so  min PT_LOAD align=0x1000 (4 KB)  [32-bit ABI]
```

**xrslam's Android arm64 output and its OpenCV dependency already satisfy (A).**
The only failure is the 32-bit ABI, which is not subject to the requirement and
which `gradle/app-build.gradle.kts.snippet` excludes via `abiFilters`.

`verify_16kb.sh` never reports a pass for a check it did not perform: a missing
`zipalign` yields exit **2 / INCOMPLETE**, and a genuine ELF failure (exit 1)
outranks it. The exit-code matrix was exercised on four synthetic archives.

---

## API provenance

Every platform symbol used was checked against Google's published reference
rather than recalled. The load-bearing ones:

| Symbol | API | Note |
|---|---|---|
| `CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE` | 22 | `Key<Integer>`; values `..._UNKNOWN` / `..._REALTIME` on `CameraMetadata` |
| `CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW` | 21 | `Key<Long>`, ns — a **CaptureResult** key, *not* a CameraCharacteristics one |
| `CaptureResult.SENSOR_EXPOSURE_TIME` | 21 | `Key<Long>`, optional |
| `CameraCharacteristics.LENS_INTRINSIC_CALIBRATION` | 23 | `Key<float[]>`, optional; pre-correction active array pixels since 28 |
| `CameraCharacteristics.LENS_DISTORTION` | 28 | replaces the deprecated `LENS_RADIAL_DISTORTION` |
| `CaptureRequest.DISTORTION_CORRECTION_MODE` | 28 | gated on `DISTORTION_CORRECTION_AVAILABLE_MODES` |
| `CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE` | 21 | gated on `CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES` |
| `CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE` | 21 | gated on `LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION` |
| `SensorManager.registerListener(l, s, periodUs, maxLatencyUs, handler)` | 19 | `maxLatencyUs` pinned to 0 |
| `android.permission.HIGH_SAMPLING_RATE_SENSORS` | 31 | **normal** protection level |
| `PowerManager.addThermalStatusListener` / `getCurrentThermalStatus` | 29 | |
| `PowerManager.getThermalHeadroom(int)` | 30 | NaN when unsupported or called too often |
| `ActivityManager.getHistoricalProcessExitReasons(pkg, pid, maxNum)` | 30 | |
| `ApplicationExitInfo.getRss()` / `getPss()` | 30 | documented **in kB**; 0 when never sampled |
| `ApplicationExitInfo.getSubReason()` | 31 | guarded |

**Marshalling trap, found while writing the codec and fixed:** Flutter's
`StandardMessageCodec` has no wire type for a 32-bit float. `FloatArray.toList()`
produces a `List<Float>` that **fails to encode at runtime on the device**, not
at compile time. Every `FloatArray` crossing the channel is widened with
`.map { it.toDouble() }`.

---

## Running the checks

```bash
cd android_ready/dart/pw_android_capture         && dart analyze && dart test
cd android_ready/dart/pw_android_capture_flutter && flutter analyze && flutter test
android_ready/scripts/verify_16kb.sh <dir-of-.so | app.apk>
```

## What is still not done

* **No Kotlin has ever been compiled.** No Android SDK, no `kotlinc`, no JRE on
  this machine. Treat the first Gradle build as the real review.
* **Nothing has run on an Android device.** There is no Android device here and
  no Android app to install.
* No CameraX/`SurfaceTexture` plumbing, no session configuration, no preview —
  `PwCameraProbe` reads characteristics and tunes a `CaptureRequest.Builder`
  that someone else must build and submit.
* No IMU↔camera extrinsics and no time-offset *calibration* (only time-base
  *normalisation*). `LENS_POSE_ROTATION` / `LENS_POSE_TRANSLATION` are read and
  passed through, not used.
* `TRIGGER_TYPE_ANOMALY` heap capture is described above but not implemented;
  its API surface was not verified.
