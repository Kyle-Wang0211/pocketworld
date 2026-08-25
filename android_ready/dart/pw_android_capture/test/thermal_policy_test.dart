import 'package:pw_android_capture/pw_android_capture.dart';
import 'package:test/test.dart';

ThermalSample cool(int atMs) =>
    ThermalSample(atMs: atMs, headroom: 0.20, status: ThermalStatus.none);

void main() {
  group('poll gating (the documented precondition for a non-NaN answer)', () {
    test('first poll is legal immediately, then 10 s apart', () {
      final p = ThermalPolicy();
      expect(p.shouldPoll(0), isTrue);
      p.ingest(cool(0));
      expect(p.shouldPoll(0), isFalse);
      expect(p.shouldPoll(9999), isFalse);
      expect(p.msUntilNextPoll(9999), 1);
      expect(p.shouldPoll(10000), isTrue);
      expect(p.msUntilNextPoll(10000), 0);
    });

    test('a sub-10 s interval cannot even be configured', () {
      expect(() => ThermalPolicy(minPollIntervalMs: 1000),
          throwsA(isA<AssertionError>()));
    });

    test('inverted or overlapping hysteresis bands are rejected', () {
      expect(
          () => ThermalPolicy(
              enterShedHeadroom: 0.70, exitShedHeadroom: 0.80),
          throwsA(isA<AssertionError>()));
    });
  });

  group('NaN handling', () {
    test('NaN on the very first call means unsupported, forever', () {
      final p = ThermalPolicy();
      final v = p.ingest(ThermalSample(
          atMs: 0, headroom: double.nan, status: ThermalStatus.none));
      expect(v.headroomState, HeadroomState.unsupported);
      expect(v.effectiveHeadroom, isNull);
      expect(v.action, ThermalAction.proceed);
      // We stop burning calls on an API this device does not implement.
      expect(p.shouldPoll(1000000), isFalse);
    });

    test('NaN is never read as 0.0 (that would look like a cold device)', () {
      final p = ThermalPolicy();
      p.ingest(
          ThermalSample(atMs: 0, headroom: 0.97, status: ThermalStatus.none));
      expect(p.action, ThermalAction.defer);

      final v = p.ingest(ThermalSample(
          atMs: 10000, headroom: double.nan, status: ThermalStatus.none));
      expect(v.headroomState, HeadroomState.stale);
      expect(v.effectiveHeadroom, 0.97);
      // The hot verdict is held, not reset by the absence of a reading.
      expect(v.action, ThermalAction.defer);
      expect(v.reason, 'headroom-stale-hold');
    });

    test('a real value after staleness resumes live steering', () {
      final p = ThermalPolicy();
      p.ingest(
          ThermalSample(atMs: 0, headroom: 0.97, status: ThermalStatus.none));
      p.ingest(ThermalSample(
          atMs: 10000, headroom: double.nan, status: ThermalStatus.none));
      final v = p.ingest(
          ThermalSample(atMs: 20000, headroom: 0.30, status: ThermalStatus.none));
      expect(v.headroomState, HeadroomState.live);
      expect(v.action, ThermalAction.proceed);
    });
  });

  group('headroom band', () {
    test('cold proceeds, warm sheds, hot defers', () {
      expect(
          ThermalPolicy()
              .ingest(ThermalSample(
                  atMs: 0, headroom: 0.10, status: ThermalStatus.none))
              .action,
          ThermalAction.proceed);
      expect(
          ThermalPolicy()
              .ingest(ThermalSample(
                  atMs: 0, headroom: 0.88, status: ThermalStatus.none))
              .action,
          ThermalAction.shed);
      expect(
          ThermalPolicy()
              .ingest(ThermalSample(
                  atMs: 0, headroom: 0.99, status: ThermalStatus.none))
              .action,
          ThermalAction.defer);
    });

    test('does not flap when headroom sits on the entry edge', () {
      // 20 samples oscillating across 0.85 by +/-0.05. Without a hysteresis
      // gap this toggles on every single sample; the toggling itself is load.
      final p = ThermalPolicy();
      var transitions = 0;
      var previous = p.action;
      var t = 0;
      for (var i = 0; i < 20; i++) {
        final h = i.isEven ? 0.80 : 0.90;
        final v = p.ingest(
            ThermalSample(atMs: t, headroom: h, status: ThermalStatus.none));
        if (v.action != previous) transitions++;
        previous = v.action;
        t += 10000;
      }
      expect(transitions, lessThanOrEqualTo(1),
          reason: 'governor flapped $transitions times across the edge');
      expect(previous, ThermalAction.shed);
    });

    test('recovery needs a real cool-down, not a one-sample dip', () {
      final p = ThermalPolicy();
      p.ingest(
          ThermalSample(atMs: 0, headroom: 0.90, status: ThermalStatus.none));
      expect(p.action, ThermalAction.shed);
      // 0.78 is below the entry edge but above the exit edge: still shedding.
      p.ingest(ThermalSample(
          atMs: 10000, headroom: 0.78, status: ThermalStatus.none));
      expect(p.action, ThermalAction.shed);
      p.ingest(ThermalSample(
          atMs: 20000, headroom: 0.70, status: ThermalStatus.none));
      expect(p.action, ThermalAction.proceed);
    });

    test('defer steps down through shed on the way out', () {
      final p = ThermalPolicy();
      p.ingest(
          ThermalSample(atMs: 0, headroom: 0.99, status: ThermalStatus.none));
      expect(p.action, ThermalAction.defer);
      p.ingest(ThermalSample(
          atMs: 10000, headroom: 0.82, status: ThermalStatus.none));
      expect(p.action, ThermalAction.shed);
      p.ingest(ThermalSample(
          atMs: 20000, headroom: 0.60, status: ThermalStatus.none));
      expect(p.action, ThermalAction.proceed);
    });
  });

  group('status floor', () {
    test('SEVERE forces defer even when headroom still reads cold', () {
      final v = ThermalPolicy().ingest(ThermalSample(
          atMs: 0, headroom: 0.05, status: ThermalStatus.severe));
      expect(v.action, ThermalAction.defer);
      expect(v.reason, 'status-floor');
    });

    test('MODERATE forces at least shed', () {
      final v = ThermalPolicy().ingest(ThermalSample(
          atMs: 0, headroom: 0.05, status: ThermalStatus.moderate));
      expect(v.action, ThermalAction.shed);
    });

    test('status can only raise severity, never lower it', () {
      final v = ThermalPolicy().ingest(ThermalSample(
          atMs: 0, headroom: 0.99, status: ThermalStatus.none));
      expect(v.action, ThermalAction.defer);
    });

    test('an unsupported-headroom device still steers on status alone', () {
      final p = ThermalPolicy();
      p.ingest(ThermalSample(
          atMs: 0, headroom: double.nan, status: ThermalStatus.none));
      final v = p.ingest(ThermalSample(
          atMs: 10000, headroom: double.nan, status: ThermalStatus.critical));
      expect(v.headroomState, HeadroomState.unsupported);
      expect(v.action, ThermalAction.defer);
    });
  });

  test('no action in the vocabulary discards work', () {
    // The enum is the contract: postponement only, no drop/downgrade tier.
    expect(ThermalAction.values.map((a) => a.name).toList(),
        <String>['proceed', 'shed', 'defer']);
  });
}
