import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:pw_android_capture/pw_android_capture.dart';
import 'package:pw_android_capture_flutter/pw_android_capture_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('pocketworld/android_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;

  void mock(Object? Function(MethodCall call) reply) {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(method, null));

  test('probeClocks marshals a real platform payload into ClockProbes', () {
    mock((_) => <Object?>[
          <Object?, Object?>{
            'monoBeforeNs': 1000,
            'bootNs': 501000,
            'monoAfterNs': 1200,
          },
          <Object?, Object?>{
            'monoBeforeNs': 2000,
            'bootNs': 502000,
            'monoAfterNs': 2020,
          },
        ]);

    return PwAndroidCaptureChannel().probeClocks(count: 2).then((r) {
      final (probes, malformed) = r;
      expect(malformed, 0);
      expect(calls.single.method, 'probeClocks');
      expect((calls.single.arguments as Map)['count'], 2);

      // The estimator must pick the 20 ns probe, not the 200 ns one.
      final e = ClockOffsetEstimator();
      final u = e.ingest(probes);
      expect(u.verdict, ClockOffsetVerdict.firstFix);
      expect(u.offset!.uncertaintyNs, 10);
      expect(u.offset!.offsetNs, 500000 - 10);
    });
  });

  test('startImu forwards the period and never offers a batch latency knob',
      () async {
    mock((_) => <Object?>['LSM6DSO Gyroscope Uncalibrated']);
    final names = await PwAndroidCaptureChannel().startImu();
    expect(names, ['LSM6DSO Gyroscope Uncalibrated']);
    final args = calls.single.arguments as Map;
    expect(args['samplingPeriodUs'], 0);
    // maxReportLatencyUs is pinned to 0 natively and is deliberately not part
    // of the Dart surface, so it cannot be set by accident.
    expect(args.containsKey('maxReportLatencyUs'), isFalse);
  });

  test('thermalSample survives a NaN headroom crossing the channel', () async {
    mock((_) => <Object?, Object?>{
          'atMs': 12345,
          'headroom': double.nan,
          'status': 2,
          'throttledLocally': false,
        });
    final s = await PwAndroidCaptureChannel().thermalSample();
    expect(s.headroom.isNaN, isTrue);
    expect(s.status, 2);
    expect(s.atMs, 12345);
  });

  test('exitInfo carries an Android 17 AnonSwap kill through unchanged',
      () async {
    mock((_) => <Object?>[
          <Object?, Object?>{
            'timestampMs': 1755900000000,
            'pid': 4211,
            'reason': 13,
            'description': 'MemoryLimiter:AnonSwap',
            'rssKb': 812345,
            'processName': 'com.pocketworld.app',
          },
        ]);
    final records = await PwAndroidCaptureChannel().exitInfo();
    expect(records.length, 1);
    final findings = ExitTriage().unreported(records);
    expect(findings.single.exitClass, ExitClass.memoryLimiterAnonSwap);
    expect(findings.single.capturePipelineSuspect, isTrue);
  });

  test('a null description from the platform cannot crash the decode',
      () async {
    mock((_) => <Object?>[
          <Object?, Object?>{'timestampMs': 1, 'pid': 2, 'reason': 4},
        ]);
    final records = await PwAndroidCaptureChannel().exitInfo();
    expect(records.single.description, '');
    expect(ExitTriage.classify(records.single), ExitClass.managedCrash);
  });

  test('imu events decode into the shape SensorDeliveryMonitor consumes', () {
    final e = PwImuEvent.fromChannel(<Object?, Object?>{
      'type': 16,
      'eventTsNs': 1000000000,
      'arrivalTsNs': 1000050000,
      'values': <Object?>[0.1, -0.2, 9.8],
    });
    expect(e.sensorType, 16);
    expect(e.values, [0.1, -0.2, 9.8]);
    final m = SensorDeliveryMonitor()..add(e.sample);
    expect(m.offeredCount, 1);
  });
}
