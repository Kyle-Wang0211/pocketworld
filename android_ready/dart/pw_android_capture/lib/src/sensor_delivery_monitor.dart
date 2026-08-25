// PocketWorld Android capture — IMU delivery auditor.
//
// PROBLEM
//   1. SensorManager.registerListener(l, s, samplingPeriodUs, maxReportLatencyUs)
//      accepts a *hint*, not a contract. The platform is explicitly allowed to
//      deliver at a different rate ("the delay you specify is only a
//      suggestion"), and Android 12+ (API 31) hard-caps every sensor at 200 Hz
//      unless the app holds HIGH_SAMPLING_RATE_SENSORS. There is no API that
//      returns the achieved rate.
//   2. maxReportLatencyUs > 0 turns on hardware batching. Batched delivery hands
//      a whole burst of samples to one callback, which is exactly the arrival
//      pattern that makes xrslam's gyro/accel interleave degenerate
//      (xrslam/src/xrslam/core/detail.cpp: a batch of gyro samples arriving
//      entirely before the queued accelerometers empties the buffer one sample
//      at a time). We register with maxReportLatencyUs = 0 — and then we VERIFY
//      at runtime that we actually got unbatched delivery, because that is also
//      only a request.
//   3. Some HALs synthesise evenly spaced timestamps inside a batch instead of
//      reporting the real sample instants. Perfectly uniform deltas inside a
//      burst are the fingerprint.
//
// MEASUREMENT
//   Every sample carries two stamps:
//     eventTsNs   — SensorEvent.timestamp, BOOTTIME, when the sample was taken.
//     arrivalTsNs — SystemClock.elapsedRealtimeNanos() read inside the callback.
//   Unbatched:  arrivalDelta ~= eventDelta.
//   Batched:    arrivalDelta ~= 0 while eventDelta stays at the nominal period.
//
// FAIL-SAFE CONTRACT
//   The monitor is a pure observer. It never drops, reorders or rewrites a
//   sample; `acceptedCount` is asserted equal to `offeredCount` in the tests.
//   It only raises flags for the caller to surface.

import 'dart:math' as math;

class SensorSample {
  const SensorSample({required this.eventTsNs, required this.arrivalTsNs});

  /// SensorEvent.timestamp — hardware instant, BOOTTIME base.
  final int eventTsNs;

  /// elapsedRealtimeNanos() sampled inside onSensorChanged.
  final int arrivalTsNs;
}

enum DeliveryFlag {
  /// Samples are arriving in bursts: hardware batching is on despite
  /// maxReportLatencyUs = 0.
  batched,

  /// Timestamps inside a burst are exactly equidistant — the HAL fabricated
  /// them, so per-sample dt is not measured data.
  syntheticTimestamps,

  /// eventTs went backwards. Never dropped, always surfaced.
  backwardsTimestamp,

  /// A gap far larger than the nominal period: upstream loss or a suspend.
  gap,
}

class DeliveryReport {
  const DeliveryReport({
    required this.sampleCount,
    required this.medianPeriodNs,
    required this.hz,
    required this.batchedFraction,
    required this.maxGapNs,
    required this.flags,
  });

  final int sampleCount;

  /// Median of consecutive event-timestamp deltas. Median, not mean: one
  /// suspend or one dropped block would move a mean by an arbitrary amount
  /// while leaving the true period untouched.
  final int? medianPeriodNs;

  /// Achieved rate reconstructed from timestamps. There is no public API for
  /// this; it must be measured.
  final double? hz;

  /// Fraction of consecutive pairs that arrived inside a burst.
  final double batchedFraction;

  final int? maxGapNs;

  final Set<DeliveryFlag> flags;

  bool get healthy => flags.isEmpty;

  @override
  String toString() => 'DeliveryReport(n=$sampleCount, '
      '${hz?.toStringAsFixed(2) ?? "?"}Hz, '
      'batched=${(batchedFraction * 100).toStringAsFixed(1)}%, '
      'flags=${flags.map((f) => f.name).join("|")})';
}

class SensorDeliveryMonitor {
  SensorDeliveryMonitor({
    this.window = 256,
    this.batchRatio = 4.0,
    this.batchedFractionThreshold = 0.25,
    this.gapRatio = 5.0,
    this.minBurstRunForSyntheticCheck = 3,
  })  : assert(window >= 8),
        assert(batchRatio > 1.0);

  /// Sliding window length in samples. 256 at 200 Hz is ~1.3 s: long enough for
  /// a stable median, short enough to notice a regime change during capture.
  final int window;

  /// A pair counts as "delivered inside a burst" when
  /// arrivalDelta * batchRatio < eventDelta.
  ///
  /// Provenance: unbatched delivery has arrivalDelta ~= eventDelta (ratio ~1,
  /// jitter well inside 2x); batched delivery has arrivalDelta of a few
  /// microseconds against a 5 ms event delta (ratio ~1000). The two populations
  /// are three orders of magnitude apart, so any cut inside roughly [2, 20]
  /// yields the same verdict. `sensor_delivery_monitor_test.dart` sweeps that
  /// range and asserts the verdict does not move — the threshold is a divider
  /// between two well-separated clusters, not a tuned constant.
  final double batchRatio;

  /// With maxReportLatencyUs = 0 the expected burst fraction is exactly 0.
  /// 0.25 is slack for occasional scheduler coalescing on loaded devices.
  final double batchedFractionThreshold;

  /// eventDelta > gapRatio * median is reported as a gap.
  final double gapRatio;

  final int minBurstRunForSyntheticCheck;

  final List<SensorSample> _buf = <SensorSample>[];
  int _offered = 0;

  /// Samples handed to the monitor.
  int get offeredCount => _offered;

  /// Samples the monitor kept in its window. Always <= offered; the difference
  /// is window eviction only — the caller's own stream is never touched.
  int get windowCount => _buf.length;

  void add(SensorSample s) {
    _offered++;
    _buf.add(s);
    if (_buf.length > window) {
      _buf.removeAt(0);
    }
  }

  DeliveryReport report() {
    final n = _buf.length;
    if (n < 2) {
      return DeliveryReport(
        sampleCount: n,
        medianPeriodNs: null,
        hz: null,
        batchedFraction: 0.0,
        maxGapNs: null,
        flags: const <DeliveryFlag>{},
      );
    }

    final eventDeltas = <int>[];
    final arrivalDeltas = <int>[];
    for (var i = 1; i < n; i++) {
      eventDeltas.add(_buf[i].eventTsNs - _buf[i - 1].eventTsNs);
      arrivalDeltas.add(_buf[i].arrivalTsNs - _buf[i - 1].arrivalTsNs);
    }

    final flags = <DeliveryFlag>{};

    final positive = eventDeltas.where((d) => d > 0).toList()..sort();
    if (positive.length != eventDeltas.length) {
      flags.add(DeliveryFlag.backwardsTimestamp);
    }
    if (positive.isEmpty) {
      return DeliveryReport(
        sampleCount: n,
        medianPeriodNs: null,
        hz: null,
        batchedFraction: 0.0,
        maxGapNs: null,
        flags: flags,
      );
    }

    final median = _median(positive);

    // Burst membership.
    final isBurstMember = List<bool>.filled(eventDeltas.length, false);
    var burstCount = 0;
    for (var i = 0; i < eventDeltas.length; i++) {
      final ed = eventDeltas[i];
      final ad = arrivalDeltas[i];
      if (ed > 0 && ad >= 0 && ad * batchRatio < ed) {
        isBurstMember[i] = true;
        burstCount++;
      }
    }
    final batchedFraction = burstCount / eventDeltas.length;
    if (batchedFraction > batchedFractionThreshold) {
      flags.add(DeliveryFlag.batched);
    }

    // Synthetic timestamps: inside a run of burst members, exactly uniform
    // event deltas mean the HAL generated them.
    var runStart = -1;
    for (var i = 0; i <= isBurstMember.length; i++) {
      final inRun = i < isBurstMember.length && isBurstMember[i];
      if (inRun && runStart < 0) {
        runStart = i;
      } else if (!inRun && runStart >= 0) {
        final len = i - runStart;
        if (len >= minBurstRunForSyntheticCheck) {
          final first = eventDeltas[runStart];
          var uniform = true;
          for (var k = runStart; k < i; k++) {
            if (eventDeltas[k] != first) {
              uniform = false;
              break;
            }
          }
          if (uniform) flags.add(DeliveryFlag.syntheticTimestamps);
        }
        runStart = -1;
      }
    }

    var maxGap = 0;
    for (final d in eventDeltas) {
      if (d > maxGap) maxGap = d;
    }
    if (maxGap > gapRatio * median) {
      flags.add(DeliveryFlag.gap);
    }

    return DeliveryReport(
      sampleCount: n,
      medianPeriodNs: median,
      hz: 1e9 / median,
      batchedFraction: batchedFraction,
      maxGapNs: maxGap,
      flags: flags,
    );
  }

  static int _median(List<int> sorted) {
    final m = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[m];
    return (sorted[m - 1] + sorted[m]) ~/ 2;
  }

  /// Nearest standard Android sampling period, for logging only.
  static int nominalPeriodUsForHz(double hz) => (1e6 / math.max(hz, 1e-9)).round();
}
