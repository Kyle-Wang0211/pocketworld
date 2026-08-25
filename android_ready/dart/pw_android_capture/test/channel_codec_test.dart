import 'package:pw_android_capture/pw_android_capture.dart';
import 'package:test/test.dart';

void main() {
  group('clock probes', () {
    test('decodes a well-formed batch', () {
      final (probes, bad) = ChannelCodec.decodeClockProbes([
        {'monoBeforeNs': 10, 'bootNs': 1010, 'monoAfterNs': 30},
        {'monoBeforeNs': 40, 'bootNs': 1050, 'monoAfterNs': 60},
      ]);
      expect(bad, 0);
      expect(probes.length, 2);
      expect(probes.first.offsetNs, 990);
    });

    test('one broken entry does not cost the whole batch', () {
      // best-of-N only needs one good probe; throwing here would throw it away.
      final (probes, bad) = ChannelCodec.decodeClockProbes([
        {'monoBeforeNs': 10, 'bootNs': null, 'monoAfterNs': 30},
        'not a map',
        {'monoBeforeNs': 40, 'bootNs': 1050, 'monoAfterNs': 60},
      ]);
      expect(bad, 2);
      expect(probes.length, 1);
    });

    test('a non-list payload is a broken contract, not a soft failure', () {
      expect(() => ChannelCodec.decodeClockProbes({'a': 1}),
          throwsA(isA<ChannelDecodeException>()));
    });
  });

  group('camera characteristics', () {
    test('REALTIME decodes to a base that needs no offset', () {
      final b = ChannelCodec.decodeCameraTimeBase(
          {'timestampSource': 1, 'timestampSourceWasNull': false});
      expect(b.needsClockOffset, isFalse);
    });

    test('a null timestamp source is read as UNKNOWN, never as REALTIME', () {
      for (final m in <Map<Object?, Object?>>[
        {'timestampSource': null},
        {'timestampSource': 1, 'timestampSourceWasNull': true},
        <Object?, Object?>{},
      ]) {
        expect(ChannelCodec.decodeCameraTimeBase(m).needsClockOffset, isTrue,
            reason: '$m');
      }
    });

    test('intrinsics decode as doubles and tolerate an integral value', () {
      final v = ChannelCodec.decodeIntrinsics({
        'intrinsicCalibration': [1200, 1200.5, 960.0, 540.0, 0.0]
      });
      expect(v, [1200.0, 1200.5, 960.0, 540.0, 0.0]);
    });

    test('a missing or short intrinsics array is null, not a zeroed array', () {
      expect(ChannelCodec.decodeIntrinsics(<Object?, Object?>{}), isNull);
      expect(
          ChannelCodec.decodeIntrinsics({
            'intrinsicCalibration': [1.0, 2.0]
          }),
          isNull);
    });
  });

  group('frame metadata', () {
    test('optional camera2 keys survive as nulls', () {
      final m = ChannelCodec.decodeFrameMetadata({
        'frameNumber': 7,
        'sensorTimestampNs': 5000000000,
        'exposureTimeNs': null,
        'rollingShutterSkewNs': null,
        'activeArrayHeight': 3000,
      });
      expect(m.exposureTimeNs, isNull);
      expect(m.rollingShutterSkewNs, isNull);
      final s = CameraTimeBase(timestampSource: TimestampSource.realtime)
          .resolve(m);
      expect(s.isResolved, isTrue);
      expect(s.degraded, isTrue);
    });

    test('a missing SENSOR_TIMESTAMP is a broken platform contract', () {
      expect(
          () => ChannelCodec.decodeFrameMetadata({'frameNumber': 1}),
          throwsA(isA<ChannelDecodeException>()));
    });

    test('a non-integral double timestamp is refused, not truncated', () {
      expect(
          () => ChannelCodec
              .decodeFrameMetadata({'sensorTimestampNs': 5000000000.5}),
          throwsA(isA<ChannelDecodeException>()));
      // An integral double (a JSON round trip somewhere) is still accepted.
      expect(
          ChannelCodec
              .decodeFrameMetadata({'sensorTimestampNs': 5000000000.0})
              .sensorTimestampNs,
          5000000000);
    });
  });

  group('thermal', () {
    test('a null headroom decodes to NaN, never to 0.0', () {
      final s = ChannelCodec
          .decodeThermalSample({'atMs': 5, 'headroom': null, 'status': 0});
      expect(s.headroom.isNaN, isTrue);
    });

    test('an int headroom widens rather than throwing', () {
      final s = ChannelCodec
          .decodeThermalSample({'atMs': 5, 'headroom': 1, 'status': 2});
      expect(s.headroom, 1.0);
      expect(s.status, 2);
    });
  });

  group('exit info', () {
    test('a null description decodes to empty and cannot false-positive', () {
      final r = ChannelCodec.decodeExitRecords([
        {'timestampMs': 10, 'pid': 3, 'reason': 13, 'description': null},
      ]);
      expect(r.single.description, '');
      expect(ExitTriage.classify(r.single), ExitClass.otherOrUnknown);
    });

    test('the AnonSwap record survives the round trip intact', () {
      final r = ChannelCodec.decodeExitRecords([
        {
          'timestampMs': 99,
          'pid': 4,
          'reason': 13,
          'description': 'MemoryLimiter:AnonSwap',
          'rssKb': 812000,
        },
      ]);
      expect(ExitTriage.classify(r.single), ExitClass.memoryLimiterAnonSwap);
      expect(r.single.rssKb, 812000);
    });

    test('absent optional fields default without throwing', () {
      final r = ChannelCodec.decodeExitRecords([
        {'timestampMs': 1, 'reason': 6},
      ]);
      expect(r.single.pid, 0);
      expect(r.single.subReason, 0);
      expect(ExitTriage.classify(r.single), ExitClass.anr);
    });
  });
}
