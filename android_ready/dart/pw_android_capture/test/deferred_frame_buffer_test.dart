import 'package:pw_android_capture/pw_android_capture.dart';
import 'package:test/test.dart';

FrameMetadata frame(int n) => FrameMetadata(
      sensorTimestampNs: 1000000000 + n * 33333333,
      activeArrayHeight: 3000,
      exposureTimeNs: 8000000,
      rollingShutterSkewNs: 20000000,
      frameNumber: n,
    );

ClockOffset offsetOf(int ns) =>
    ClockOffset(offsetNs: ns, uncertaintyNs: 100, measuredAtBootNs: 0);

void main() {
  group('REALTIME devices never defer', () {
    test('every frame resolves immediately with no offset at all', () {
      final b = DeferredFrameBuffer(
          CameraTimeBase(timestampSource: TimestampSource.realtime));
      for (var i = 0; i < 50; i++) {
        expect(b.admit(frame(i)), isNotNull);
      }
      expect(b.pendingCount, 0);
      expect(b.highWaterMark, 0);
      expect(b.isConserving, isTrue);
    });
  });

  group('UNKNOWN devices defer and then lose nothing', () {
    test('100 frames admitted before the first fix all come back', () {
      final b = DeferredFrameBuffer(
          CameraTimeBase(timestampSource: TimestampSource.unknown));
      for (var i = 0; i < 100; i++) {
        expect(b.admit(frame(i)), isNull, reason: 'frame $i should be held');
      }
      expect(b.pendingCount, 100);
      expect(b.isConserving, isTrue);

      final drained = b.drain(offsetOf(555000000));
      expect(drained.length, 100);
      expect(b.pendingCount, 0);
      expect(b.admittedCount, 100);
      expect(b.resolvedCount, 100);
      expect(b.isConserving, isTrue);
      expect(drained.every((s) => s.isResolved), isTrue);
    });

    test('drained frames carry the same stamp as if they had never waited', () {
      final base = CameraTimeBase(timestampSource: TimestampSource.unknown);
      final o = offsetOf(777000000);
      final b = DeferredFrameBuffer(base);
      for (var i = 0; i < 10; i++) {
        b.admit(frame(i));
      }
      final drained = b.drain(o);
      for (var i = 0; i < 10; i++) {
        final direct = base.resolve(frame(i), offset: o);
        expect(drained[i].centreBootNs, direct.centreBootNs);
        expect(drained[i].firstRowStartBootNs, direct.firstRowStartBootNs);
        expect(drained[i].status, FrameStampStatus.converted);
      }
    });

    test('drain orders by frameNumber, not by arrival', () {
      final b = DeferredFrameBuffer(
          CameraTimeBase(timestampSource: TimestampSource.unknown));
      for (final n in <int>[5, 1, 4, 2, 3]) {
        b.admit(frame(n));
      }
      final drained = b.drain(offsetOf(1));
      expect(drained.map((s) => s.frameNumber).toList(), [1, 2, 3, 4, 5]);
    });

    test('frames after the fix resolve inline; the buffer stays empty', () {
      final b = DeferredFrameBuffer(
          CameraTimeBase(timestampSource: TimestampSource.unknown));
      b.admit(frame(0));
      b.drain(offsetOf(100));
      for (var i = 1; i < 20; i++) {
        expect(b.admit(frame(i), offset: offsetOf(100)), isNotNull);
      }
      expect(b.pendingCount, 0);
      expect(b.isConserving, isTrue);
      expect(b.admittedCount, 20);
      expect(b.resolvedCount, 20);
    });

    test('a suspend re-anchor resolves pending frames with the NEW offset', () {
      // Pending frames hold RAW metadata, so a suspend that invalidates the old
      // offset cannot leave a stale conversion behind.
      final e = ClockOffsetEstimator();
      e.ingest([const ClockProbe(monoBeforeNs: 0, bootNs: 1000, monoAfterNs: 100)]);
      final b = DeferredFrameBuffer(
          CameraTimeBase(timestampSource: TimestampSource.unknown));
      b.admit(frame(1)); // held: caller had not wired the offset through yet

      final u = e.ingest([
        const ClockProbe(
            monoBeforeNs: 0, bootNs: 4000000950, monoAfterNs: 100)
      ]);
      expect(u.verdict, ClockOffsetVerdict.suspendJump);
      expect(u.requiresReanchor, isTrue);

      final drained = b.drain(e.current!);
      expect(drained.single.firstRowStartBootNs,
          frame(1).sensorTimestampNs + e.current!.offsetNs);
    });

    test('an empty drain is a no-op, not an error', () {
      final b = DeferredFrameBuffer(
          CameraTimeBase(timestampSource: TimestampSource.unknown));
      expect(b.drain(offsetOf(1)), isEmpty);
      expect(b.isConserving, isTrue);
    });
  });

  group('pressure is reported, never relieved by dropping', () {
    test('highWaterMark records the peak and admission is never refused', () {
      final b = DeferredFrameBuffer(
          CameraTimeBase(timestampSource: TimestampSource.unknown));
      for (var i = 0; i < 5000; i++) {
        b.admit(frame(i));
      }
      expect(b.pendingCount, 5000);
      expect(b.highWaterMark, 5000);
      expect(b.isConserving, isTrue);
      expect(b.drain(offsetOf(1)).length, 5000);
      // The peak is remembered after the buffer empties, so the pressure is
      // still visible in the capture log.
      expect(b.highWaterMark, 5000);
    });
  });
}
