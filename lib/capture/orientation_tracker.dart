// OrientationTracker — turns raw IMU streams into a (yaw, pitch) signal
// suitable for driving the dome's rotation, plus a derived motionScore
// (gyro RMS magnitude, normalized) used by the coverage map's quality
// gate.
//
// What this matches in the Aether3D iOS reference:
//   ObjectModeV2ARDomeCoordinator's `externalFeed(absoluteYaw:, pitch:,
//   ...)` is iOS Aether3D's contract for the non-ARKit path — caller
//   supplies an "absolute" yaw and a pitch, and the coordinator does
//   the rest. iOS satisfies that contract with `CMDeviceMotion.attitude
//   .yaw / .pitch` (the system's Kalman-filtered attitude). We can't
//   import CMDeviceMotion into Flutter without a per-platform bridge,
//   so on this side we run the open-source Madgwick AHRS filter (see
//   `fusion_ahrs.dart` for source + license + math).
//
// Why Madgwick instead of "gyro.y integration plus accel pitch":
//   The naive approach undercounts world-yaw whenever the phone is
//   tilted (gyro.y measures rotation around DEVICE-Y, not world-up).
//   For a typical "stand and shoot a low table object" scan the phone
//   sits at 20–40° forward tilt for the whole capture and yaw drifts
//   ~13–25 % off true; over 30 s the dome ends up visibly skewed and
//   the active cell drifts off-center. Feeding the full gyro+accel
//   vectors into Madgwick gives us a tilt-immune attitude quaternion
//   — same trick CMDeviceMotion does internally.

import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import 'fusion_ahrs.dart';

/// What we emit each tick. Yaw + pitch in radians, motionScore in [0, 1]
/// where 1 is dramatic hand wobble.
class OrientationSample {
  final double yaw;
  final double pitch;
  final double motionScore;
  const OrientationSample({
    required this.yaw,
    required this.pitch,
    required this.motionScore,
  });
}

class OrientationTracker {
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  final FusionAhrs _ahrs = FusionAhrs();

  /// Captured at session start so the yaw output is "rotation since
  /// start" rather than a Madgwick-internal arbitrary reference. Pitch
  /// is left absolute (it represents how much the user is looking up /
  /// down at the object, which matters for binning into elevation
  /// cells). Magnetometer would give us absolute yaw too, but we don't
  /// fuse one in.
  double _yawAtStart = 0.0;
  bool _yawOriginCaptured = false;

  /// Most recent fused yaw / pitch in radians. Yaw is delta-from-start;
  /// pitch is absolute (positive = phone tilted forward / looking down).
  double _yaw = 0;
  double _pitch = 0;

  /// Recent gyro magnitude squared, exponentially smoothed. Used to
  /// derive a [0..1] motionScore — 1.0 ≈ 4 rad/s of total angular
  /// velocity, which is fairly aggressive hand-wobble.
  double _gyroMagSqEMA = 0;

  /// Most recent accel reading. Cached so the next gyro tick's AHRS
  /// update pairs (gyro, accel) — sensors_plus emits the two streams
  /// independently and they can interleave at different rates.
  double _accelX = 0;
  double _accelY = -9.8;
  double _accelZ = 0;
  bool _haveAccel = false;

  // Clamp: gyro magnitude where motionScore saturates at 1.0.
  static const double _motionMagSat = 4.0; // rad/s

  // Skip ticks with absurdly long dt — usually means the app was
  // backgrounded or the sensor stream stalled.
  static const double _maxDtSec = 0.1;

  DateTime? _lastGyroTime;

  final StreamController<OrientationSample> _ctrl =
      StreamController<OrientationSample>.broadcast();
  Stream<OrientationSample> get stream => _ctrl.stream;

  /// Most recent reading — convenient for callers that want a sync read
  /// rather than subscribing.
  OrientationSample get current => OrientationSample(
        yaw: _yaw,
        pitch: _pitch,
        motionScore: _motionScore(),
      );

  /// Subscribe to sensor streams and reset accumulators.
  void start() {
    _yaw = 0;
    _pitch = 0;
    _yawAtStart = 0;
    _yawOriginCaptured = false;
    _gyroMagSqEMA = 0;
    _lastGyroTime = null;
    _haveAccel = false;
    _ahrs.restart();
    // sensors_plus default sampling period is `normalInterval` (200ms,
    // i.e. 5 Hz) — that's "is the user walking" speed, way too slow for
    // a real-time orientation tracker. The dome would update only every
    // 200ms which feels like "not moving at all" when you actually wave
    // the phone around.
    //
    //   gyro  → gameInterval (≈20ms / 50Hz). 50Hz is the standard game-
    //           controller rate and gives smooth dome rotation while
    //           keeping CPU low.
    //   accel → same. The Madgwick filter wants both at comparable
    //           rates; matching periods avoids one stream starving the
    //           other.
    _gyroSub ??= gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_onGyro);
    _accelSub ??= accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_onAccel);
  }

  /// Cancel sensor subscriptions but don't close the broadcast stream —
  /// callers can `start()` again later.
  void stop() {
    _gyroSub?.cancel();
    _accelSub?.cancel();
    _gyroSub = null;
    _accelSub = null;
    _lastGyroTime = null;
  }

  /// Zero out yaw + pitch in place. Use when the user re-anchors the
  /// object midway through a session — the dome should now show all
  /// future motion relative to "this exact pose".
  void resetOrigin() {
    _yawAtStart = _ahrs.yawRad;
    _yaw = 0;
    _pitch = 0;
  }

  /// Cancel sensor subscriptions AND close the controller. After this,
  /// the tracker is dead.
  void dispose() {
    stop();
    _ctrl.close();
  }

  // ─── Sensor handlers ─────────────────────────────────────────────────

  void _onGyro(GyroscopeEvent e) {
    final now = DateTime.now();
    final last = _lastGyroTime;
    _lastGyroTime = now;
    if (last == null) return; // first sample establishes baseline
    final dt = now.difference(last).inMicroseconds / 1e6;
    if (dt <= 0 || dt > _maxDtSec) return;

    // Step the Madgwick filter forward with the most recent paired
    // (gyro, accel) reading. accel may not have arrived yet on the
    // very first tick — pass zeros to skip the gravity-correction
    // step (gyro-only integration for that single frame).
    _ahrs.update(
      gyroX: e.x,
      gyroY: e.y,
      gyroZ: e.z,
      accelX: _haveAccel ? _accelX : 0.0,
      accelY: _haveAccel ? _accelY : 0.0,
      accelZ: _haveAccel ? _accelZ : 0.0,
      dt: dt,
    );

    // Capture the AHRS yaw as our session origin once the startup ramp
    // is done — this way the dome reads yaw=0 at the moment the filter
    // has settled, not at some arbitrary pre-warmup pose. After that,
    // _yaw is the unwrapped delta yaw since the filter settled.
    if (!_yawOriginCaptured && !_ahrs.isWarmingUp) {
      _yawAtStart = _ahrs.yawRad;
      _yawOriginCaptured = true;
    }

    // Unwrap the delta around ±π. Without this, walking past the ±π
    // boundary makes the smoothed dome rotation whip the long way
    // around.
    var dYaw = _ahrs.yawRad - _yawAtStart;
    if (dYaw > math.pi) dYaw -= 2 * math.pi;
    if (dYaw < -math.pi) dYaw += 2 * math.pi;
    _yaw = dYaw;
    _pitch = _ahrs.pitchRad;

    // Motion-score EMA from current angular speed² — used by the
    // coverage map's quality gate to reject blurry frames.
    final mag2 = e.x * e.x + e.y * e.y + e.z * e.z;
    _gyroMagSqEMA = 0.8 * _gyroMagSqEMA + 0.2 * mag2;

    _emit();
  }

  void _onAccel(AccelerometerEvent e) {
    _accelX = e.x;
    _accelY = e.y;
    _accelZ = e.z;
    _haveAccel = true;
    // We DON'T step the AHRS here — `_onGyro` does the unified update
    // with the most recent cached accel. Stepping twice (once per
    // sensor) would double the integration period.
    _emit();
  }

  double _motionScore() {
    final mag = _gyroMagSqEMA <= 0 ? 0.0 : math.sqrt(_gyroMagSqEMA);
    return (mag / _motionMagSat).clamp(0.0, 1.0);
  }

  /// EMA-smoothed gyro magnitude in rad/s. Same value `_motionScore`
  /// derives from, but exposed in physical units so the dome ingest
  /// gate can match Aether3D iOS's `angularVelocityLimit = 2.0 rad/s`
  /// without rescaling.
  double get angularVelocityRadPerSec =>
      _gyroMagSqEMA <= 0 ? 0.0 : math.sqrt(_gyroMagSqEMA);

  void _emit() {
    if (_ctrl.isClosed) return;
    _ctrl.add(OrientationSample(
      yaw: _yaw,
      pitch: _pitch,
      motionScore: _motionScore(),
    ));
  }
}
