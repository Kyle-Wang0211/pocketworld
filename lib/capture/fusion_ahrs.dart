// FusionAhrs — Dart port of Sebastian Madgwick's open-source AHRS
// algorithm.
//
// Source: https://github.com/xioTechnologies/Fusion (1.6 k stars, MIT
// license, written by Madgwick — same algorithm cited in his 2010
// paper "An efficient orientation filter for inertial and inertial/
// magnetic sensor arrays" and shipped in the x-IMU3 commercial IMU).
// We port the IMU-only (no magnetometer) update path here because the
// PocketWorld capture pipeline doesn't have a calibrated magnetometer
// in scope; mag fusion adds drift correction around world-vertical
// but isn't load-bearing for a 1–2 minute scan.
//
// Why this exists in PocketWorld:
//   sensors_plus only emits raw gyro/accel/mag — no fused attitude.
//   iOS Aether3D delegates to CMDeviceMotion (Apple's closed-source
//   Kalman filter); we can't import that into Flutter without a
//   per-platform native bridge. The Madgwick filter is the de-facto
//   open-source replacement, used in research and industrial AHRS
//   alike, and its IMU-only path is small enough to translate
//   line-by-line into pure Dart.
//
// The translation is deliberately mechanical — same variable names,
// same control flow, same constants — so anyone can `diff` this file
// against `Fusion/FusionAhrs.c` + `Fusion/FusionMath.h` in the
// upstream repo and verify nothing was reinterpreted. The only
// deviations:
//   • gyro is supplied in rad/s instead of deg/s (saves a conversion
//     since sensors_plus reports rad/s natively).
//   • Magnetometer support / acceleration-rejection / recovery-trigger
//     features are stripped — they require state that isn't useful for
//     our short scans and would add ~150 LoC.
//   • Coordinate convention is hard-coded to NWU (matches what
//     CMDeviceMotion exposes on iOS via `attitude.yaw / pitch`).

import 'dart:math' as math;

/// Attitude filter input/output. Quaternion stored as `(w, x, y, z)`,
/// identity = `(1, 0, 0, 0)` (no rotation). Yaw / pitch / roll are
/// extracted in radians via Tait-Bryan ZYX conversion (matches
/// `FusionQuaternionToEuler` in the C source).
class FusionAhrs {
  // ─── State ──────────────────────────────────────────────────────────

  /// Quaternion components, identity at construction.
  double _qw = 1.0, _qx = 0.0, _qy = 0.0, _qz = 0.0;

  /// Steady-state feedback gain (proportional weight of accelerometer
  /// correction onto gyro integration). Madgwick's default: 0.5.
  /// Higher → faster gravity correction but more accel noise leaks
  /// through. Lower → smoother but slower drift correction.
  final double gain;

  /// Startup ramp constants — mirror `STARTUP_GAIN` / `STARTUP_PERIOD`
  /// in `FusionAhrs.c`. The 10× initial gain pulls the quaternion to
  /// a sensible attitude within the first second even if the phone is
  /// held tilted at session start.
  static const double _startupGain = 10.0;
  static const double _startupPeriod = 3.0; // seconds

  bool _startup = true;
  late double _rampedGain = _startupGain;
  late final double _rampedGainStep = (_startupGain - gain) / _startupPeriod;

  FusionAhrs({this.gain = 0.5});

  /// Reset to identity. Re-enters the startup ramp so the quaternion
  /// re-locks to gravity over the next ~3 s of accelerometer feedback.
  void restart() {
    _qw = 1.0;
    _qx = 0.0;
    _qy = 0.0;
    _qz = 0.0;
    _startup = true;
    _rampedGain = _startupGain;
  }

  // ─── Update ─────────────────────────────────────────────────────────

  /// Step the filter forward one frame.
  ///
  /// • [gyroX/Y/Z] — angular rate in **rad/s** in the device frame.
  ///   sensors_plus's `GyroscopeEvent` reports in this unit natively.
  /// • [accelX/Y/Z] — linear acceleration in any consistent unit
  ///   (m/s² is what sensors_plus emits). The vector is normalized
  ///   internally; magnitude doesn't matter, only direction. Pass
  ///   zeros to skip accelerometer correction (gyro-only step).
  /// • [dt] — time since the last update, in seconds.
  void update({
    required double gyroX,
    required double gyroY,
    required double gyroZ,
    required double accelX,
    required double accelY,
    required double accelZ,
    required double dt,
  }) {
    // Ramp gain down from 10× → steady-state during startup.
    if (_startup) {
      _rampedGain -= _rampedGainStep * dt;
      if (_rampedGain < gain) {
        _rampedGain = gain;
        _startup = false;
      }
    }

    // ── Accelerometer feedback (NWU convention: third column of
    //    transposed rotation matrix, scaled by 0.5; matches HalfGravity
    //    in FusionAhrs.c). ──
    final hgx = _qx * _qz - _qw * _qy;
    final hgy = _qy * _qz + _qw * _qx;
    final hgz = _qw * _qw - 0.5 + _qz * _qz;

    var feedX = 0.0, feedY = 0.0, feedZ = 0.0;
    final accelNormSq = accelX * accelX + accelY * accelY + accelZ * accelZ;
    if (accelNormSq > 0.0) {
      // Normalize accelerometer into a unit gravity-direction estimate.
      final invMag = 1.0 / math.sqrt(accelNormSq);
      final ax = accelX * invMag;
      final ay = accelY * invMag;
      final az = accelZ * invMag;

      // Cross product accel × halfGravity (mirrors `Feedback`).
      var cx = ay * hgz - az * hgy;
      var cy = az * hgx - ax * hgz;
      var cz = ax * hgy - ay * hgx;

      // If error >90° (dot product negative), normalize the cross so
      // we still feed back a unit-magnitude correction.
      final dot = ax * hgx + ay * hgy + az * hgz;
      if (dot < 0.0) {
        final cMag = math.sqrt(cx * cx + cy * cy + cz * cz);
        if (cMag > 0.0) {
          final inv = 1.0 / cMag;
          cx *= inv;
          cy *= inv;
          cz *= inv;
        }
      }
      feedX = cx;
      feedY = cy;
      feedZ = cz;
    }

    // ── Gyroscope integration with feedback. ──
    // Half-gyro = gyro × 0.5 (already in rad/s, no deg→rad conversion
    // needed; this is the only deviation from the upstream C).
    final hgyroX = gyroX * 0.5;
    final hgyroY = gyroY * 0.5;
    final hgyroZ = gyroZ * 0.5;

    // Apply accel feedback to gyro rate (proportional, scaled by gain).
    final adjX = hgyroX + feedX * _rampedGain;
    final adjY = hgyroY + feedY * _rampedGain;
    final adjZ = hgyroZ + feedZ * _rampedGain;

    // Quaternion derivative: dq/dt = q ⊗ (0, ω) (vector ω treated as
    // pure quaternion). Integrated by `q += dq * dt`.
    final vx = adjX * dt;
    final vy = adjY * dt;
    final vz = adjZ * dt;

    // Quaternion-vector product `q ⊗ v` (= FusionQuaternionVectorProduct).
    final dw = -_qx * vx - _qy * vy - _qz * vz;
    final dx = _qw * vx + _qy * vz - _qz * vy;
    final dy = _qw * vy - _qx * vz + _qz * vx;
    final dz = _qw * vz + _qx * vy - _qy * vx;

    _qw += dw;
    _qx += dx;
    _qy += dy;
    _qz += dz;

    // Renormalize to avoid drift away from unit norm.
    final nSq = _qw * _qw + _qx * _qx + _qy * _qy + _qz * _qz;
    if (nSq > 0.0) {
      final inv = 1.0 / math.sqrt(nSq);
      _qw *= inv;
      _qx *= inv;
      _qy *= inv;
      _qz *= inv;
    }
  }

  // ─── Output ─────────────────────────────────────────────────────────

  /// Yaw (rotation around world-Z), radians. Tait-Bryan ZYX convention,
  /// matches `FusionQuaternionToEuler`'s yaw output.
  double get yawRad =>
      math.atan2(_qx * _qy + _qw * _qz, _qw * _qw + _qx * _qx - 0.5);

  /// Pitch (rotation around world-Y), radians. Clamped at ±π/2 to
  /// dodge the asin-domain NaN at gimbal lock.
  double get pitchRad {
    final v = 2.0 * (_qw * _qy - _qx * _qz);
    if (v <= -1.0) return -math.pi / 2;
    if (v >= 1.0) return math.pi / 2;
    return math.asin(v);
  }

  /// Roll (rotation around world-X), radians. Provided for completeness
  /// — the dome doesn't currently use it but a future "phone-held-
  /// sideways" warning HUD might.
  double get rollRad => math.atan2(
        _qy * _qz + _qw * _qx,
        _qw * _qw + _qz * _qz - 0.5,
      );

  /// True until the startup gain ramp finishes (~3 s after init/reset).
  /// Useful for a "warming up" indicator in the UI.
  bool get isWarmingUp => _startup;
}
