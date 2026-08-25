// PocketWorld Android capture — camera frame instant, in the IMU's time base.
//
// PROBLEM
//   A VIO front end needs ONE number per frame: the instant, on the same clock
//   as the gyro, that the image "happened". Android gives us three ingredients
//   and no such number.
//
//   1. CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE  (Key<Integer>)
//        SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME (1)
//          CaptureResult.SENSOR_TIMESTAMP is already on
//          SystemClock.elapsedRealtimeNanos() — the same base as
//          SensorEvent.timestamp. Nothing to do.
//        SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN (0)
//          "monotonic but not comparable to timestamps from other subsystems".
//          In practice CLOCK_MONOTONIC. Must be shifted by the measured
//          BOOTTIME-MONOTONIC offset before it can be fused with IMU.
//
//   2. CaptureResult.SENSOR_TIMESTAMP  (Key<Long>, ns) is documented as the
//      "Image sensor active array FIRST ROW exposure START time". It is neither
//      the middle of the exposure nor the middle of the frame.
//
//   3. CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW (Key<Long>, ns) is the
//      "Duration between exposure start of first and last row", and
//      CaptureResult.SENSOR_EXPOSURE_TIME (Key<Long>, ns) is the per-pixel
//      integration time. Both are optional keys; a device may report neither.
//
// THE INSTANT
//   Row r of H starts integrating at   t0 + skew * r / (H - 1)
//   and its exposure is centred at     t0 + skew * r / (H - 1) + exposure / 2.
//   Averaging over all rows puts the frame's photometric centre at
//
//       t_centre = t0 + exposure / 2 + skew / 2
//
//   Feeding t0 straight to a VIO front end therefore biases every frame EARLY
//   by (exposure + skew) / 2. That is not a rounding error: on a phone at
//   1/60 s exposure with a 20 ms readout it is about 18 ms, which at a hand-held
//   30 deg/s pan is roughly 0.5 deg of unmodelled rotation on every single
//   frame — a constant, systematic lever arm, not noise that averages out.
//
//   Per-row instants are also exposed, because a rolling-shutter-aware
//   front end wants the instant of the row a feature sits on, not the frame
//   average.
//
// FAIL-SAFE CONTRACT
//   When the time base cannot be established yet (source == UNKNOWN and no
//   clock offset has been fixed), `resolve` returns `deferred` WITH the raw
//   stamp preserved. The caller buffers the frame and re-resolves once the
//   offset lands. It never guesses an offset and never drops the frame.
//   Missing optional keys degrade the correction, never the delivery.

import 'clock_offset.dart';

/// CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_* — platform values.
class TimestampSource {
  static const int unknown = 0;
  static const int realtime = 1;
}

/// Raw per-frame metadata pulled out of a CaptureResult.
class FrameMetadata {
  const FrameMetadata({
    required this.sensorTimestampNs,
    required this.activeArrayHeight,
    this.exposureTimeNs,
    this.rollingShutterSkewNs,
    this.frameNumber = 0,
  });

  /// CaptureResult.SENSOR_TIMESTAMP, in whatever base the device uses.
  final int sensorTimestampNs;

  /// Row count of the region SENSOR_TIMESTAMP refers to (the active array).
  final int activeArrayHeight;

  /// CaptureResult.SENSOR_EXPOSURE_TIME. Null when the device omits the key.
  final int? exposureTimeNs;

  /// CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW. Null when omitted.
  final int? rollingShutterSkewNs;

  final int frameNumber;
}

enum FrameStampStatus {
  /// Device reports REALTIME: the stamp was already in the IMU base.
  nativeRealtime,

  /// Device reports UNKNOWN and a clock offset was in force: converted.
  converted,

  /// Device reports UNKNOWN and no offset has been fixed yet. The frame is
  /// NOT resolvable right now and MUST be buffered.
  deferred,
}

class FrameStamp {
  const FrameStamp({
    required this.status,
    required this.frameNumber,
    this.firstRowStartBootNs,
    this.centreBootNs,
    required this.exposureNs,
    required this.skewNs,
    required this.appliedCorrectionNs,
    required this.degraded,
  });

  final FrameStampStatus status;
  final int frameNumber;

  /// SENSOR_TIMESTAMP moved into the BOOTTIME base. Null iff deferred.
  final int? firstRowStartBootNs;

  /// The instant to hand a VIO front end: photometric centre of the frame,
  /// BOOTTIME base. Null iff deferred.
  final int? centreBootNs;

  /// Values actually used (0 when the device omitted the key).
  final int exposureNs;
  final int skewNs;

  /// centreBootNs - firstRowStartBootNs. Exactly (exposure + skew) ~/ 2.
  final int appliedCorrectionNs;

  /// True when at least one of exposure/skew was unavailable, so the centre is
  /// only partially corrected. The frame is still delivered; the flag exists so
  /// the correction can be audited rather than silently believed.
  final bool degraded;

  bool get isResolved => status != FrameStampStatus.deferred;
}

class CameraTimeBase {
  CameraTimeBase({required this.timestampSource});

  /// From CameraCharacteristics.get(SENSOR_INFO_TIMESTAMP_SOURCE).
  final int timestampSource;

  bool get needsClockOffset => timestampSource != TimestampSource.realtime;

  /// [offset] may be null; it is required only when [needsClockOffset].
  FrameStamp resolve(FrameMetadata m, {ClockOffset? offset}) {
    final exposure = m.exposureTimeNs ?? 0;
    final skew = m.rollingShutterSkewNs ?? 0;
    final degraded = m.exposureTimeNs == null || m.rollingShutterSkewNs == null;
    final correction = (exposure + skew) ~/ 2;

    if (needsClockOffset && offset == null) {
      return FrameStamp(
        status: FrameStampStatus.deferred,
        frameNumber: m.frameNumber,
        firstRowStartBootNs: null,
        centreBootNs: null,
        exposureNs: exposure,
        skewNs: skew,
        appliedCorrectionNs: correction,
        degraded: degraded,
      );
    }

    final firstRow = needsClockOffset
        ? offset!.monotonicToBoot(m.sensorTimestampNs)
        : m.sensorTimestampNs;

    return FrameStamp(
      status: needsClockOffset
          ? FrameStampStatus.converted
          : FrameStampStatus.nativeRealtime,
      frameNumber: m.frameNumber,
      firstRowStartBootNs: firstRow,
      centreBootNs: firstRow + correction,
      exposureNs: exposure,
      skewNs: skew,
      appliedCorrectionNs: correction,
      degraded: degraded,
    );
  }

  /// Exposure-centre instant of image row [row] (0-based, top row = 0) of an
  /// active array [height] rows tall, in the BOOTTIME base.
  ///
  /// Returns null when [stamp] is deferred — a caller must never fabricate a
  /// row instant from an unresolved frame.
  static int? rowCentreBootNs(FrameStamp stamp, int row, int height) {
    final t0 = stamp.firstRowStartBootNs;
    if (t0 == null) return null;
    if (height <= 1) return t0 + stamp.exposureNs ~/ 2;
    final clamped = row < 0 ? 0 : (row > height - 1 ? height - 1 : row);
    final rowDelay = (stamp.skewNs * clamped) ~/ (height - 1);
    return t0 + rowDelay + stamp.exposureNs ~/ 2;
  }
}
