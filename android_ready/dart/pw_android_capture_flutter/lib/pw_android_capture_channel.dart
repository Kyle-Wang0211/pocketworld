// PocketWorld Android capture — platform-channel bridge.
//
// THIS FILE IS THE ONLY UNTESTED DART IN android_ready/.
// It contains no arithmetic, no thresholds and no judgement: it moves bytes
// between MethodChannel/EventChannel and the pure `pw_android_capture` package,
// which has 88 unit tests behind it. If you are about to add an `if` to this
// file, add it to the package instead.
//
// Drop location:  lib/capture/android/pw_android_capture_channel.dart
// Requires:       pw_android_capture as a path dependency in pubspec.yaml
//                 (see android_ready/README.md for the exact stanza).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:pw_android_capture/pw_android_capture.dart';

class PwAndroidCaptureChannel {
  PwAndroidCaptureChannel({
    MethodChannel? method,
    EventChannel? imu,
  })  : _method = method ?? const MethodChannel('pocketworld/android_capture'),
        _imu = imu ?? const EventChannel('pocketworld/android_capture/imu');

  final MethodChannel _method;
  final EventChannel _imu;

  /// One round of clock probes. Feed the result straight to
  /// [ClockOffsetEstimator.ingest]; it does the best-of-N selection.
  Future<(List<ClockProbe>, int malformed)> probeClocks({int count = 9}) async {
    final raw = await _method.invokeMethod<List<Object?>>(
      'probeClocks',
      <String, Object?>{'count': count},
    );
    return ChannelCodec.decodeClockProbes(raw);
  }

  Future<Map<Object?, Object?>> cameraCharacteristics({String? cameraId}) async {
    final raw = await _method.invokeMethod<Map<Object?, Object?>>(
      'cameraCharacteristics',
      <String, Object?>{'cameraId': cameraId},
    );
    return raw ?? const <Object?, Object?>{};
  }

  Future<Map<Object?, Object?>> describeImu() async =>
      await _method.invokeMethod<Map<Object?, Object?>>('describeImu') ??
      const <Object?, Object?>{};

  /// samplingPeriodUs 0 == SENSOR_DELAY_FASTEST. The native side always passes
  /// maxReportLatencyUs = 0; there is deliberately no parameter for it.
  Future<List<String>> startImu({int samplingPeriodUs = 0}) async {
    final raw = await _method.invokeMethod<List<Object?>>(
      'startImu',
      <String, Object?>{'samplingPeriodUs': samplingPeriodUs},
    );
    return (raw ?? const <Object?>[]).cast<String>();
  }

  Future<void> stopImu() => _method.invokeMethod<void>('stopImu');

  /// Raw IMU stream. Every event carries the sensor type, the BOOTTIME hardware
  /// instant and the BOOTTIME arrival instant; feed both stamps to
  /// [SensorDeliveryMonitor] to find out what rate you actually got and whether
  /// the HAL batched despite maxReportLatencyUs = 0.
  Stream<PwImuEvent> imuStream() =>
      _imu.receiveBroadcastStream().map(PwImuEvent.fromChannel);

  /// Call only when [ThermalPolicy.shouldPoll] says so. Calling sooner is what
  /// makes getThermalHeadroom return NaN.
  Future<ThermalSample> thermalSample() async {
    final raw =
        await _method.invokeMethod<Map<Object?, Object?>>('thermalSample');
    return ChannelCodec.decodeThermalSample(raw ?? <Object?, Object?>{});
  }

  Future<void> startThermalStatus(void Function(int status) onStatus) async {
    _method.setMethodCallHandler((call) async {
      if (call.method == 'onThermalStatus') {
        final args = call.arguments;
        if (args is Map) {
          final s = args['status'];
          if (s is int) onStatus(s);
        }
      }
      return null;
    });
    await _method.invokeMethod<void>('startThermalStatus');
  }

  Future<void> stopThermalStatus() =>
      _method.invokeMethod<void>('stopThermalStatus');

  /// Read at launch, BEFORE starting a capture: this is where an Android 17
  /// MemoryLimiter:AnonSwap kill from the previous session shows up, and it is
  /// the only trace such a kill leaves.
  Future<List<ExitRecord>> exitInfo({int maxNum = 32}) async {
    final raw = await _method.invokeMethod<List<Object?>>(
      'exitInfo',
      <String, Object?>{'maxNum': maxNum},
    );
    return ChannelCodec.decodeExitRecords(raw ?? const <Object?>[]);
  }
}

class PwImuEvent {
  const PwImuEvent({
    required this.sensorType,
    required this.sample,
    required this.values,
  });

  factory PwImuEvent.fromChannel(Object? raw) {
    final m = raw is Map ? raw : const <Object?, Object?>{};
    final v = m['values'];
    return PwImuEvent(
      sensorType: asIntOrNull(m['type'], 'type') ?? 0,
      sample: ChannelCodec.decodeSensorSample(m),
      values: v is List
          ? <double>[for (final x in v) asDouble(x, 'values[]')]
          : const <double>[],
    );
  }

  /// android.hardware.Sensor.TYPE_*
  final int sensorType;
  final SensorSample sample;
  final List<double> values;
}
