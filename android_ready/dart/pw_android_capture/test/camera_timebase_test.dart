import 'package:pw_android_capture/pw_android_capture.dart';
import 'package:test/test.dart';

const int kExposure60th = 16666667; // 1/60 s
const int kSkew20ms = 20000000;
const int kHeight = 3001; // odd, so (H-1)/2 is an exact row index

ClockOffset offsetOf(int ns) =>
    ClockOffset(offsetNs: ns, uncertaintyNs: 100, measuredAtBootNs: 0);

FrameMetadata meta({
  int ts = 5000000000,
  int? exposure = kExposure60th,
  int? skew = kSkew20ms,
  int height = kHeight,
  int frame = 1,
}) =>
    FrameMetadata(
      sensorTimestampNs: ts,
      activeArrayHeight: height,
      exposureTimeNs: exposure,
      rollingShutterSkewNs: skew,
      frameNumber: frame,
    );

void main() {
  group('time base selection', () {
    test('REALTIME devices need no offset and no conversion', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      expect(b.needsClockOffset, isFalse);
      final s = b.resolve(meta());
      expect(s.status, FrameStampStatus.nativeRealtime);
      expect(s.firstRowStartBootNs, 5000000000);
      expect(s.isResolved, isTrue);
    });

    test('UNKNOWN devices convert with the measured offset', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.unknown);
      expect(b.needsClockOffset, isTrue);
      final s = b.resolve(meta(), offset: offsetOf(777000000));
      expect(s.status, FrameStampStatus.converted);
      expect(s.firstRowStartBootNs, 5000000000 + 777000000);
    });

    test('UNKNOWN with no offset yet defers; it never guesses', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.unknown);
      final s = b.resolve(meta());
      expect(s.status, FrameStampStatus.deferred);
      expect(s.isResolved, isFalse);
      expect(s.firstRowStartBootNs, isNull);
      expect(s.centreBootNs, isNull);
      // The correction is still computed, so the buffered frame can be
      // resolved later without re-reading the CaptureResult.
      expect(s.appliedCorrectionNs, (kExposure60th + kSkew20ms) ~/ 2);
    });

    test('a deferred frame resolves identically once the offset lands', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.unknown);
      final m = meta();
      expect(b.resolve(m).isResolved, isFalse);
      final later = b.resolve(m, offset: offsetOf(123456));
      expect(later.isResolved, isTrue);
      expect(later.centreBootNs,
          5000000000 + 123456 + (kExposure60th + kSkew20ms) ~/ 2);
    });
  });

  group('the instant a VIO front end actually wants', () {
    test('centre = first-row start + (exposure + skew) / 2', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      final s = b.resolve(meta());
      expect(s.appliedCorrectionNs, 18333333);
      expect(s.centreBootNs, 5000000000 + 18333333);
      expect(s.degraded, isFalse);
    });

    test('the uncorrected stamp is early by ~18 ms at 1/60 s + 20 ms readout', () {
      // This is the number quoted in camera_timebase.dart, executed rather
      // than asserted in prose.
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      final s = b.resolve(meta());
      final biasMs = s.appliedCorrectionNs / 1e6;
      expect(biasMs, closeTo(18.3, 0.1));
      // At a hand-held 30 deg/s pan that is the quoted ~0.5 deg of
      // unmodelled rotation on every frame.
      expect(30.0 * biasMs / 1000.0, closeTo(0.55, 0.02));
    });

    test('the frame centre IS the average of the per-row centres', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      final s = b.resolve(meta());
      var sum = 0;
      for (var r = 0; r < kHeight; r++) {
        sum += CameraTimeBase.rowCentreBootNs(s, r, kHeight)! -
            s.firstRowStartBootNs!;
      }
      final meanOffset = sum / kHeight;
      final centreOffset = (s.centreBootNs! - s.firstRowStartBootNs!).toDouble();
      // Integer truncation in the per-row delay costs at most ~1 ns.
      expect(meanOffset, closeTo(centreOffset, 2.0));
    });

    test('row instants run from top to bottom across the readout', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      final s = b.resolve(meta());
      final top = CameraTimeBase.rowCentreBootNs(s, 0, kHeight)!;
      final mid =
          CameraTimeBase.rowCentreBootNs(s, (kHeight - 1) ~/ 2, kHeight)!;
      final bottom = CameraTimeBase.rowCentreBootNs(s, kHeight - 1, kHeight)!;
      expect(top, s.firstRowStartBootNs! + kExposure60th ~/ 2);
      expect(bottom, top + kSkew20ms);
      expect(mid, s.centreBootNs);
      expect(bottom - top, kSkew20ms);
    });

    test('rows outside the array clamp instead of extrapolating', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      final s = b.resolve(meta());
      expect(CameraTimeBase.rowCentreBootNs(s, -5, kHeight),
          CameraTimeBase.rowCentreBootNs(s, 0, kHeight));
      expect(CameraTimeBase.rowCentreBootNs(s, kHeight + 99, kHeight),
          CameraTimeBase.rowCentreBootNs(s, kHeight - 1, kHeight));
    });

    test('a deferred frame yields no row instants at all', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.unknown);
      final s = b.resolve(meta());
      expect(CameraTimeBase.rowCentreBootNs(s, 10, kHeight), isNull);
    });
  });

  group('optional keys degrade the correction, never the delivery', () {
    test('missing skew still delivers, flagged degraded', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      final s = b.resolve(meta(skew: null));
      expect(s.isResolved, isTrue);
      expect(s.degraded, isTrue);
      expect(s.skewNs, 0);
      expect(s.appliedCorrectionNs, kExposure60th ~/ 2);
      // With no skew known, every row shares the frame instant.
      expect(CameraTimeBase.rowCentreBootNs(s, 0, kHeight), s.centreBootNs);
      expect(
          CameraTimeBase.rowCentreBootNs(s, kHeight - 1, kHeight),
          s.centreBootNs);
    });

    test('missing exposure and skew falls back to the raw stamp', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      final s = b.resolve(meta(exposure: null, skew: null));
      expect(s.isResolved, isTrue);
      expect(s.degraded, isTrue);
      expect(s.appliedCorrectionNs, 0);
      expect(s.centreBootNs, s.firstRowStartBootNs);
    });

    test('a single-row array does not divide by zero', () {
      final b = CameraTimeBase(timestampSource: TimestampSource.realtime);
      final s = b.resolve(meta(height: 1));
      expect(CameraTimeBase.rowCentreBootNs(s, 0, 1),
          s.firstRowStartBootNs! + kExposure60th ~/ 2);
    });
  });
}
