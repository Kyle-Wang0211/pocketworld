import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'ios/Runner/PwVioCapability.swift',
  ).readAsStringSync();
  final String dartSource = File(
    'lib/vio/capability/capability_probe.dart',
  ).readAsStringSync();

  test('iOS frame capability wire is bounded raw evidence only', () {
    expect(source, isNot(contains('enum PwVioStats')));
    expect(source, isNot(contains('"medianIntervalNs"')));
    expect(source, isNot(contains('"p95IntervalNs"')));
    expect(source, isNot(contains('intervalsNs.append')));

    expect(source, contains('pw.vio.frame-arrivals.raw.v1'));
    expect(source, contains('private static let capacity = 512'));
    expect(source, contains('private var arrivalHostTsNs'));
    expect(source, contains('"arrivalHostTsNs"'));
    for (final String key in <String>[
      'attemptedCount',
      'retainedCount',
      'overwrittenCount',
      'capacity',
    ]) {
      expect(source, contains('"$key"'));
    }
  });

  test('iOS IMU capability wire is bounded and request is exact', () {
    expect(source, contains('public func start(requestedHz: Double) -> Bool'));
    expect(source, isNot(contains('requestedHz: Double =')));
    expect(source, isNot(contains('max(requestedHz')));
    expect(source, contains('requestedHz.isFinite'));
    expect(source, contains('requestedHz > 0'));
    expect(source, contains('1.0 / requestedHz'));

    expect(source, contains('pw.vio.imu-arrivals.raw.v1'));
    expect(source, contains('private static let capacity = 4096'));
    expect(source, contains('private var imuArrivalRing'));
    expect(source, contains('"available": motion.isGyroAvailable'));
    expect(
      source,
      isNot(contains('"available": motion.isDeviceMotionAvailable')),
    );
  });

  test('iOS capability adapter exposes no native timebase verdict', () {
    expect(source, isNot(contains('TimebaseRelation')));
    expect(source, isNot(contains('offsetMeasured')));
    expect(source, isNot(contains('unrelatedUnmeasured')));
    expect(source, isNot(contains('timebaseRelation')));
  });

  test('iOS FOV adapter exports raw platform facts without focal math', () {
    expect(source, isNot(contains('fromFieldOfView(')));
    expect(source, isNot(contains('tan(half)')));
    expect(source, contains('fieldOfViewWire('));
    expect(source, contains('"videoFieldOfViewDegrees"'));
    expect(
      source,
      contains('"geometricDistortionCorrectedVideoFieldOfViewDegrees"'),
    );
    expect(source, contains('"referenceWidth"'));
    expect(source, contains('"referenceHeight"'));
  });

  test('iOS stabilization adapter only sets a Dart-selected raw request', () {
    expect(source, isNot(contains('enum StabilizationState')));
    expect(source, isNot(contains('PwVioStabilizationReport')));
    expect(source, isNot(contains('disableAndVerify')));
    expect(source, isNot(contains('preferredVideoStabilizationMode = .off')));
    expect(source, isNot(contains('electronicControllable')));
    expect(source, isNot(contains('opticalControllable')));

    expect(source, contains('pw.vio.ios.stabilization-raw/1'));
    expect(source, contains('requestedPreferredModeRawValue: Int'));
    expect(source, contains('AVCaptureVideoStabilizationMode('));
    for (final String key in <String>[
      'videoStabilizationSupported',
      'requestedPreferredModeRawValue',
      'requestedPreferredModeRecognized',
      'preferredModeAssignmentPerformed',
      'activeVideoStabilizationModeRawValue',
      'geometricDistortionCorrectionSupported',
      'geometricDistortionCorrectionEnabled',
      'opticalImageStabilizationPublicApiAvailable',
    ]) {
      expect(source, contains('"$key"'));
    }

    expect(dartSource, contains('iosVideoStabilizationModeOffRawValue = 0'));
    expect(dartSource, contains("'pw.vio.ios.stabilization-raw/1'"));
  });
}
