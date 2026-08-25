import 'package:pw_android_capture/pw_android_capture.dart';
import 'package:test/test.dart';

/// Build a probe whose true offset is [offsetNs] and whose mono window is
/// [windowNs] wide, centred so the midpoint estimate is exact.
ClockProbe probeAt({
  required int monoNs,
  required int offsetNs,
  required int windowNs,
}) =>
    ClockProbe(
      monoBeforeNs: monoNs - windowNs ~/ 2,
      bootNs: monoNs + offsetNs,
      monoAfterNs: monoNs + windowNs ~/ 2,
    );

void main() {
  group('ClockProbe arithmetic', () {
    test('recovers the offset exactly when the window is symmetric', () {
      final p = probeAt(monoNs: 1000000000, offsetNs: 42000000, windowNs: 400);
      expect(p.offsetNs, 42000000);
      expect(p.uncertaintyNs, 200);
      expect(p.isWellFormed, isTrue);
    });

    test('a preempted probe is still well formed but wide', () {
      final p = probeAt(monoNs: 1000, offsetNs: 5, windowNs: 3000000);
      expect(p.uncertaintyNs, 1500000);
    });

    test('mono running backwards is malformed', () {
      const p = ClockProbe(monoBeforeNs: 500, bootNs: 600, monoAfterNs: 400);
      expect(p.isWellFormed, isFalse);
    });
  });

  group('best-of-N selection', () {
    test('picks the narrowest probe, not the average', () {
      // Two wide probes biased in the same direction plus one tight probe.
      // A mean would land near the biased pair; min-uncertainty must not.
      final e = ClockOffsetEstimator();
      final u = e.ingest([
        probeAt(monoNs: 1000000, offsetNs: 90000000, windowNs: 180000),
        probeAt(monoNs: 1000100, offsetNs: 95000000, windowNs: 160000),
        probeAt(monoNs: 1000200, offsetNs: 50000000, windowNs: 300),
      ]);
      expect(u.verdict, ClockOffsetVerdict.firstFix);
      expect(u.offset!.offsetNs, 50000000);
      expect(u.offset!.uncertaintyNs, 150);
      expect(u.rejectedProbes, 0);
    });

    test('rejects every probe wider than the cap and keeps the old offset', () {
      final e = ClockOffsetEstimator();
      e.ingest([probeAt(monoNs: 0, offsetNs: 7000, windowNs: 200)]);
      final before = e.current!.offsetNs;

      final u = e.ingest([
        probeAt(monoNs: 10, offsetNs: 999999999, windowNs: 5000000),
        const ClockProbe(monoBeforeNs: 9, bootNs: 9, monoAfterNs: 1),
      ]);
      expect(u.verdict, ClockOffsetVerdict.noUsableProbe);
      expect(u.rejectedProbes, 2);
      expect(u.totalProbes, 2);
      // Deferral, not adoption of garbage.
      expect(e.current!.offsetNs, before);
      expect(u.offset!.offsetNs, before);
    });

    test('empty probe list before any fix leaves conversion unavailable', () {
      final e = ClockOffsetEstimator();
      final u = e.ingest(const <ClockProbe>[]);
      expect(u.verdict, ClockOffsetVerdict.noUsableProbe);
      expect(u.offset, isNull);
      // Callers must buffer rather than guess.
      expect(e.monotonicToBoot(123), isNull);
    });
  });

  group('offset dynamics', () {
    test('small movement is stable and does not demand a re-anchor', () {
      final e = ClockOffsetEstimator();
      e.ingest([probeAt(monoNs: 0, offsetNs: 1000000, windowNs: 200)]);
      final u = e.ingest([probeAt(monoNs: 1, offsetNs: 1000300, windowNs: 200)]);
      expect(u.verdict, ClockOffsetVerdict.stable);
      expect(u.deltaNs, 300);
      expect(u.requiresReanchor, isFalse);
      expect(u.requiresHumanAttention, isFalse);
    });

    test('a suspend shows up as a forward jump that demands a re-anchor', () {
      final e = ClockOffsetEstimator();
      e.ingest([probeAt(monoNs: 0, offsetNs: 1000000, windowNs: 200)]);
      // 4 s of suspend.
      final u =
          e.ingest([probeAt(monoNs: 1, offsetNs: 5000000000, windowNs: 200)]);
      expect(u.verdict, ClockOffsetVerdict.suspendJump);
      expect(u.requiresReanchor, isTrue);
      expect(e.current!.offsetNs, 5000000000);
    });

    test('backwards motion is impossible: surfaced, old offset retained', () {
      final e = ClockOffsetEstimator();
      e.ingest([probeAt(monoNs: 0, offsetNs: 9000000, windowNs: 200)]);
      final u = e.ingest([probeAt(monoNs: 1, offsetNs: 8000000, windowNs: 200)]);
      expect(u.verdict, ClockOffsetVerdict.anomalyBackwards);
      expect(u.requiresHumanAttention, isTrue);
      expect(u.deltaNs, -1000000);
      // The corrupt value must NOT become the working offset.
      expect(e.current!.offsetNs, 9000000);
    });

    test('a backwards step inside the combined error bound is just noise', () {
      final e = ClockOffsetEstimator();
      e.ingest([probeAt(monoNs: 0, offsetNs: 9000000, windowNs: 200)]);
      // -150 ns against a combined bound of 100 + 100 = 200 ns.
      final u =
          e.ingest([probeAt(monoNs: 1, offsetNs: 8999850, windowNs: 200)]);
      expect(u.verdict, ClockOffsetVerdict.stable);
      expect(e.current!.offsetNs, 8999850);
    });
  });

  group('conversion', () {
    test('round-trips and lands a monotonic stamp in the boot base', () {
      final e = ClockOffsetEstimator();
      e.ingest([probeAt(monoNs: 0, offsetNs: 123456789, windowNs: 100)]);
      final o = e.current!;
      expect(o.monotonicToBoot(1000), 1000 + 123456789);
      expect(o.bootToMonotonic(o.monotonicToBoot(1000)), 1000);
      expect(e.monotonicToBoot(1000), 1000 + 123456789);
    });
  });
}
