import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'lib/vio/capability/android/PwVioCapability.kt',
  ).readAsStringSync();

  test('Android timebase adapter exports an unclassified clock sandwich', () {
    expect(source, contains('pw.vio.android.timebase-raw/1'));
    for (final String key in <String>[
      'timestampSource',
      'monotonicBeforeNanos',
      'bootRealtimeNanos',
      'monotonicAfterNanos',
    ]) {
      expect(source, contains('"$key"'));
    }
    expect(source, contains('System.nanoTime()'));
    expect(source, contains('SystemClock.elapsedRealtimeNanos()'));
    expect(source, isNot(contains('measuredOffsetUncertaintyNs')));
    expect(source, isNot(contains('offsetUncertaintyNs')));
    expect(source, isNot(contains('TB_UNIFIED')));
    expect(source, isNot(contains('TB_OFFSET_MEASURED')));
    expect(source, isNot(contains('TB_UNRELATED')));
    expect(source, isNot(contains('SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME')));
  });

  test('Android extrinsics adapter exports raw optional platform values', () {
    expect(source, contains('pw.vio.android.extrinsics-raw/1'));
    for (final String key in <String>[
      'poseReference',
      'translationMeters',
      'rotationXyzw',
    ]) {
      expect(source, contains('"$key"'));
    }
    expect(source, isNot(contains('referenceIsGyroscope')));
    expect(source, isNot(contains('val usable')));
    expect(source, isNot(contains('"reason"')));
    expect(source, isNot(contains('LENS_POSE_REFERENCE_GYROSCOPE')));
    expect(source, isNot(contains('LENS_POSE_REFERENCE_PRIMARY_CAMERA')));
  });

  test('Android rolling-shutter adapter never scales or substitutes skew', () {
    expect(source, contains('pw.vio.android.rolling-shutter-raw/1'));
    for (final String key in <String>[
      'skewNs',
      'activeArrayHeight',
      'outputRowsCoveringActiveArray',
    ]) {
      expect(source, contains('"$key"'));
    }
    expect(source, isNot(contains('"readoutNs"')));
    expect(source, isNot(contains('val scaled')));
    expect(source, isNot(contains('skew * n / h')));
    expect(source, isNot(contains('outputRowsCoveringActiveArray ?:')));
  });

  test('Dart supplies stabilization modes and Kotlin only sets and echoes', () {
    expect(source, contains('pw.vio.android.stabilization-raw/1'));
    for (final String key in <String>[
      'availableElectronicModes',
      'availableOpticalModes',
      'requestedElectronicMode',
      'requestedOpticalMode',
      'actualElectronicMode',
      'actualOpticalMode',
    ]) {
      expect(source, contains('"$key"'));
    }
    expect(source, isNot(contains('STAB_OFF')));
    expect(source, isNot(contains('STAB_ON')));
    expect(source, isNot(contains('STAB_UNKNOWN')));
    expect(source, isNot(contains('STAB_ABSENT')));
    expect(source, isNot(contains('electronicControllable')));
    expect(source, isNot(contains('opticalControllable')));
    expect(source, isNot(contains('requestStabilizationOff')));
    expect(source, isNot(contains('STABILIZATION_MODE_OFF')));
    expect(source, contains('fun applyStabilizationModes('));
  });

  test('hardware level and bounded IMU accounting stay raw and exact', () {
    expect(source, contains('pw.vio.android.hardware-level-raw/1'));
    expect(source, contains('"hardwareLevel"'));
    expect(source, isNot(contains('hardwareLevelName')));

    expect(source, contains('pw.vio.imu-arrivals.raw.v1'));
    for (final String key in <String>[
      'available',
      'sampleTsNs',
      'deliveryTsNs',
      'attemptedCount',
      'retainedCount',
      'overwrittenCount',
      'capacity',
    ]) {
      expect(source, contains('"$key"'));
    }
    expect(source, isNot(contains('highSamplingRatePermissionRelevant')));
    expect(source, isNot(contains('fun imuWire(')));
    expect(source, contains('class PwVioImuArrivalRing'));
    expect(source, contains('attemptedCount - retainedCount.toLong()'));
  });

  test(
    'draft declares runtime API guards instead of claiming drop-in parity',
    () {
      expect(source, contains('Build.VERSION.SDK_INT'));
      expect(source, contains('Build.VERSION_CODES'));
      expect(source, isNot(contains('除 package 行外不需要任何改动')));
    },
  );
}
