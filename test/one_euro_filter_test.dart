// Behavioural tests for the One-Euro display-smoothing core.
//
// These assert the three properties the AR-smooth layer actually relies on, on
// synthetic signals that mimic what the streaming point cloud does:
//   1. At rest with high-freq jitter → output variance collapses (suppress jitter).
//   2. A step (a global-BA checkpoint moving a point) → output SLIDES, not jumps,
//      and converges (no permanent offset).
//   3. Fast ramp (cloud shifting quickly) → output tracks with bounded lag.
// Plus fail-open guards (dt<=0, NaN) that must never freeze or NaN the display.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import 'package:pocketworld_flutter/official_capture/one_euro_filter.dart';

double _stddev(List<double> xs) {
  final mean = xs.reduce((a, b) => a + b) / xs.length;
  final v =
      xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
      xs.length;
  return math.sqrt(v);
}

void main() {
  const dt = 1.0 / 60.0; // 60 Hz display

  test('suppresses high-frequency jitter at rest', () {
    // Resting point at 0 with +-5mm zero-mean jitter (deterministic PRNG).
    final rng = math.Random(20260805);
    final f = OneEuroFilter(minCutoff: 1.0, beta: 0.007);
    final rawTail = <double>[];
    final outTail = <double>[];
    for (var i = 0; i < 600; i++) {
      final raw = (rng.nextDouble() - 0.5) * 0.010; // +-5mm
      final out = f.filter(raw, dt);
      if (i >= 300) {
        rawTail.add(raw);
        outTail.add(out);
      }
    }
    final rawSd = _stddev(rawTail);
    final outSd = _stddev(outTail);
    // At rest, low cutoff must cut jitter hard: at least 4x reduction.
    expect(
      outSd,
      lessThan(rawSd / 4.0),
      reason: 'raw sd=$rawSd out sd=$outSd — jitter not suppressed',
    );
  });

  test('a step input slides smoothly and converges (no snap, no offset)', () {
    // Simulate a global-BA checkpoint moving a point from 0 to 1.0 in one frame.
    final f = OneEuroFilter(minCutoff: 1.0, beta: 0.007);
    for (var i = 0; i < 60; i++) {
      f.filter(0.0, dt); // settle at 0
    }
    final firstAfterStep = f.filter(1.0, dt);
    // Must NOT jump the whole way in the first frame (that would be a visible snap).
    expect(
      firstAfterStep,
      lessThan(0.6),
      reason: 'stepped $firstAfterStep in one frame — that is a snap',
    );
    expect(firstAfterStep, greaterThan(0.0), reason: 'must move toward target');
    // Must converge to the new position within ~1s (no permanent lag/offset).
    double last = firstAfterStep;
    for (var i = 0; i < 120; i++) {
      last = f.filter(1.0, dt);
    }
    expect(
      (last - 1.0).abs(),
      lessThan(0.01),
      reason: 'did not converge to target: $last',
    );
  });

  test('tracks fast motion with bounded lag (beta raises cutoff)', () {
    // A cloud shifting at 1.0 unit/s for 1s. With a reasonable beta the output
    // should trail the input by only a small fraction at the end.
    final f = OneEuroFilter(minCutoff: 1.0, beta: 0.5);
    double x = 0.0;
    double out = 0.0;
    for (var i = 0; i < 60; i++) {
      x += 1.0 * dt; // ramp
      out = f.filter(x, dt);
    }
    final lag = x - out;
    expect(lag, greaterThan(0.0), reason: 'some lag is expected on a ramp');
    expect(
      lag,
      lessThan(0.15),
      reason: 'lag $lag too large — beta not tracking fast motion',
    );
  });

  test('fail-open: dt<=0 and NaN never freeze or NaN the output', () {
    final f = OneEuroFilter(minCutoff: 1.0, beta: 0.007);
    expect(f.filter(1.0, dt).isFinite, isTrue);
    expect(f.filter(2.0, 0.0).isFinite, isTrue); // dt==0 → return last good
    expect(f.filter(2.0, -1.0).isFinite, isTrue); // dt<0
    expect(f.filter(double.nan, dt).isFinite, isTrue); // NaN input
    expect(f.filter(3.0, dt).isFinite, isTrue); // recovers
  });

  test('Vector3 filter smooths each axis independently and stays finite', () {
    final f = OneEuroFilter3(minCutoff: 1.0, beta: 0.007);
    final rng = math.Random(11);
    late vm.Vector3 out;
    for (var i = 0; i < 200; i++) {
      final v = vm.Vector3(
        1.0 + (rng.nextDouble() - 0.5) * 0.01,
        -2.0 + (rng.nextDouble() - 0.5) * 0.01,
        0.5 + (rng.nextDouble() - 0.5) * 0.01,
      );
      out = f.filter(v, dt);
    }
    expect(out.x.isFinite && out.y.isFinite && out.z.isFinite, isTrue);
    // Converged near the axis means, not smeared across axes.
    expect((out.x - 1.0).abs(), lessThan(0.02));
    expect((out.y + 2.0).abs(), lessThan(0.02));
    expect((out.z - 0.5).abs(), lessThan(0.02));
  });
}
