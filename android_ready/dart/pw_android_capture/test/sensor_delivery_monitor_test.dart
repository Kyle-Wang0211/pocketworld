import 'dart:math';

import 'package:pw_android_capture/pw_android_capture.dart';
import 'package:test/test.dart';

const int nominal200HzNs = 5000000; // 5 ms

/// Delivery as it looks with maxReportLatencyUs = 0: one callback per sample,
/// so arrival tracks the hardware instant.
List<SensorSample> unbatchedStream({
  int n = 200,
  int periodNs = nominal200HzNs,
  int seed = 7,
  double jitter = 0.2,
}) {
  final rnd = Random(seed);
  final out = <SensorSample>[];
  var event = 1000000000;
  var arrival = 1000000000;
  for (var i = 0; i < n; i++) {
    out.add(SensorSample(eventTsNs: event, arrivalTsNs: arrival));
    final j = ((rnd.nextDouble() * 2 - 1) * jitter * periodNs).round();
    event += periodNs;
    arrival += periodNs + j;
  }
  return out;
}

/// Delivery as it looks when the HAL batched despite maxReportLatencyUs = 0:
/// [burst] hardware samples handed over inside one callback, microseconds
/// apart in arrival, while their event stamps stay a full period apart.
List<SensorSample> batchedStream({
  int bursts = 25,
  int burst = 8,
  int periodNs = nominal200HzNs,
  int intraBurstArrivalNs = 2000,
  bool syntheticEventStamps = true,
  int seed = 11,
}) {
  final rnd = Random(seed);
  final out = <SensorSample>[];
  var event = 1000000000;
  var arrival = 1000000000;
  for (var b = 0; b < bursts; b++) {
    for (var i = 0; i < burst; i++) {
      out.add(SensorSample(eventTsNs: event, arrivalTsNs: arrival));
      final wobble = syntheticEventStamps
          ? 0
          : ((rnd.nextDouble() * 2 - 1) * 0.05 * periodNs).round();
      event += periodNs + wobble;
      arrival += intraBurstArrivalNs;
    }
    // Next callback lands one whole batch later.
    arrival += periodNs * burst - intraBurstArrivalNs * burst;
  }
  return out;
}

SensorDeliveryMonitor feed(List<SensorSample> s, {double? batchRatio}) {
  final m = SensorDeliveryMonitor(
    window: 4096,
    batchRatio: batchRatio ?? 4.0,
  );
  for (final x in s) {
    m.add(x);
  }
  return m;
}

void main() {
  group('rate reconstruction (there is no API for this)', () {
    test('recovers 200 Hz from timestamps alone', () {
      final r = feed(unbatchedStream()).report();
      expect(r.medianPeriodNs, nominal200HzNs);
      expect(r.hz, closeTo(200.0, 0.001));
    });

    test('recovers a non-standard rate a HAL actually delivered', () {
      // Xperia-class device delivering 423 Hz when 200 Hz was requested.
      const p = 2364066; // 1e9 / 423
      final r = feed(unbatchedStream(periodNs: p)).report();
      expect(r.hz, closeTo(423.0, 0.5));
    });

    test('median survives an outlier that would wreck a mean', () {
      final s = unbatchedStream(n: 100, jitter: 0.0);
      // Splice in a 2 s hole, as a suspend would produce.
      final spliced = <SensorSample>[];
      for (var i = 0; i < s.length; i++) {
        final shift = i >= 50 ? 2000000000 : 0;
        spliced.add(SensorSample(
          eventTsNs: s[i].eventTsNs + shift,
          arrivalTsNs: s[i].arrivalTsNs + shift,
        ));
      }
      final r = feed(spliced).report();
      expect(r.medianPeriodNs, nominal200HzNs);
      expect(r.hz, closeTo(200.0, 0.001));
      expect(r.flags, contains(DeliveryFlag.gap));
    });
  });

  group('batching detection', () {
    test('unbatched delivery is healthy', () {
      final r = feed(unbatchedStream()).report();
      expect(r.flags, isEmpty, reason: r.toString());
      expect(r.healthy, isTrue);
      expect(r.batchedFraction, 0.0);
    });

    test('batched delivery is caught even though the rate looks perfect', () {
      final r = feed(batchedStream()).report();
      // The rate is indistinguishable from healthy...
      expect(r.hz, closeTo(200.0, 0.001));
      // ...but the arrival pattern is not.
      expect(r.flags, contains(DeliveryFlag.batched));
      expect(r.batchedFraction, greaterThan(0.8));
    });

    test('synthetic in-burst timestamps are called out separately', () {
      final synth = feed(batchedStream(syntheticEventStamps: true)).report();
      expect(synth.flags, contains(DeliveryFlag.syntheticTimestamps));

      final real = feed(batchedStream(syntheticEventStamps: false)).report();
      expect(real.flags, contains(DeliveryFlag.batched));
      expect(real.flags, isNot(contains(DeliveryFlag.syntheticTimestamps)));
    });

    test('batchRatio is a divider between two clusters, not a tuned knob', () {
      // The comment in sensor_delivery_monitor.dart claims any cut inside
      // roughly [2, 20] gives the same verdict. This is that claim, executed.
      final clean = unbatchedStream();
      final dirty = batchedStream();
      for (final ratio in <double>[2, 3, 4, 5, 8, 12, 16, 20]) {
        expect(feed(clean, batchRatio: ratio).report().flags,
            isNot(contains(DeliveryFlag.batched)),
            reason: 'unbatched stream flagged at batchRatio=$ratio');
        expect(feed(dirty, batchRatio: ratio).report().flags,
            contains(DeliveryFlag.batched),
            reason: 'batched stream missed at batchRatio=$ratio');
      }
    });
  });

  group('anomalies are surfaced, never swallowed', () {
    test('a backwards event timestamp raises a flag', () {
      final s = unbatchedStream(n: 40, jitter: 0.0).toList();
      s[20] = SensorSample(
        eventTsNs: s[20].eventTsNs - 3 * nominal200HzNs,
        arrivalTsNs: s[20].arrivalTsNs,
      );
      final r = feed(s).report();
      expect(r.flags, contains(DeliveryFlag.backwardsTimestamp));
    });

    test('an all-backwards stream degrades without throwing', () {
      final m = SensorDeliveryMonitor(window: 16);
      for (var i = 0; i < 10; i++) {
        m.add(SensorSample(eventTsNs: 1000 - i, arrivalTsNs: 1000 + i));
      }
      final r = m.report();
      expect(r.flags, contains(DeliveryFlag.backwardsTimestamp));
      expect(r.hz, isNull);
      expect(r.medianPeriodNs, isNull);
    });
  });

  group('observer contract', () {
    test('every offered sample is counted; the window only evicts', () {
      final m = SensorDeliveryMonitor(window: 32);
      final s = unbatchedStream(n: 500);
      for (final x in s) {
        m.add(x);
      }
      expect(m.offeredCount, 500);
      expect(m.windowCount, 32);
    });

    test('fewer than two samples yields a null-rate report, not a crash', () {
      final m = SensorDeliveryMonitor(window: 8);
      expect(m.report().sampleCount, 0);
      m.add(const SensorSample(eventTsNs: 1, arrivalTsNs: 1));
      final r = m.report();
      expect(r.sampleCount, 1);
      expect(r.hz, isNull);
      expect(r.flags, isEmpty);
    });

    test('nominalPeriodUsForHz maps the standard rates', () {
      expect(SensorDeliveryMonitor.nominalPeriodUsForHz(200), 5000);
      expect(SensorDeliveryMonitor.nominalPeriodUsForHz(100), 10000);
    });
  });
}
