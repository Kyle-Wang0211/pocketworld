import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/capability/android_capability_adapter.dart';
import 'package:pocketworld_flutter/vio/capability/capability_evidence.dart';
import 'package:pocketworld_flutter/vio/timebase/android_boottime_bridge.dart';

void main() {
  test('Dart parses the exact Android raw clock sandwich', () {
    final AndroidTimebaseRawEvidence evidence =
        AndroidTimebaseRawEvidence.fromWire(<String, Object?>{
          'schema': 'pw.vio.android.timebase-raw/1',
          'timestampSource': 0,
          'monotonicBeforeNanos': 1_000_000_000,
          'bootRealtimeNanos': 4_000_000_000,
          'monotonicAfterNanos': 1_000_002_000,
        });

    expect(evidence.schemaValid, isTrue);
    expect(
      evidence.cameraTimestampSource,
      AndroidCameraTimestampSource.unknown,
    );
    final AndroidTimebaseBridge bridge = AndroidTimebaseBridge(
      cameraTimestampSource: evidence.cameraTimestampSource,
    )..ingest(evidence.clockProbe!);
    expect(bridge.latestOffset!.offsetSeconds, closeTo(2.999999, 1e-9));
    expect(bridge.state()!.cameraComparability.name, 'approximate');
  });

  test('unknown Android timebase keys and reversed clocks fail closed', () {
    final Map<String, Object?> wire = <String, Object?>{
      'schema': 'pw.vio.android.timebase-raw/1',
      'timestampSource': 1,
      'monotonicBeforeNanos': 20,
      'bootRealtimeNanos': 30,
      'monotonicAfterNanos': 10,
    };
    expect(AndroidTimebaseRawEvidence.fromWire(wire).schemaValid, isFalse);
    wire
      ..['monotonicAfterNanos'] = 40
      ..['nativeVerdict'] = 'unified';
    expect(AndroidTimebaseRawEvidence.fromWire(wire).schemaValid, isFalse);
  });

  test('only a gyroscope-referenced calibrated pose is directly usable', () {
    Map<String, Object?> wire(int reference) => <String, Object?>{
      'schema': 'pw.vio.android.extrinsics-raw/1',
      'poseReference': reference,
      'translationMeters': <double>[0.01, 0.02, 0.03],
      'rotationXyzw': <double>[0, 0, 0, 1],
    };

    expect(
      AndroidExtrinsicsRawEvidence.fromWire(
        wire(AndroidLensPoseReference.gyroscope.platformValue),
      ).directCameraGyroscopeCalibrationAvailable,
      isTrue,
    );
    expect(
      AndroidExtrinsicsRawEvidence.fromWire(
        wire(AndroidLensPoseReference.primaryCamera.platformValue),
      ).directCameraGyroscopeCalibrationAvailable,
      isFalse,
    );
    expect(
      AndroidExtrinsicsRawEvidence.fromWire(
        wire(AndroidLensPoseReference.undefined.platformValue),
      ).directCameraGyroscopeCalibrationAvailable,
      isFalse,
    );
  });

  test('Dart alone scales Android rolling-shutter readout', () {
    final AndroidRollingShutterRawEvidence raw =
        AndroidRollingShutterRawEvidence.fromWire(<String, Object?>{
          'schema': 'pw.vio.android.rolling-shutter-raw/1',
          'skewNs': 20_000_000,
          'activeArrayHeight': 4000,
          'outputRowsCoveringActiveArray': 2000,
        });
    expect(raw.schemaValid, isTrue);
    expect(raw.toFacts().readoutNs, 10_000_000);

    final AndroidRollingShutterRawEvidence invalid =
        AndroidRollingShutterRawEvidence.fromWire(<String, Object?>{
          'schema': 'pw.vio.android.rolling-shutter-raw/1',
          'skewNs': 20_000_000,
          'activeArrayHeight': 4000,
          'outputRowsCoveringActiveArray': 5000,
        });
    expect(invalid.schemaValid, isTrue);
    expect(invalid.toFacts().isKnown, isFalse);
  });

  test('Dart selects and classifies raw Android stabilization modes', () {
    final AndroidStabilizationRawEvidence raw =
        AndroidStabilizationRawEvidence.fromWire(<String, Object?>{
          'schema': 'pw.vio.android.stabilization-raw/1',
          'availableElectronicModes': <int>[0, 1],
          'availableOpticalModes': <int>[0],
          'requestedElectronicMode': 0,
          'requestedOpticalMode': 0,
          'actualElectronicMode': 0,
          'actualOpticalMode': 0,
        });
    expect(raw.schemaValid, isTrue);
    expect(raw.request.electronicMode, 0);
    expect(raw.request.opticalMode, 0);
    expect(raw.toFacts().electronic, StabilizationState.off);
    expect(raw.toFacts().optical, StabilizationState.absent);
    expect(raw.toFacts().allConfirmedOff, isTrue);
  });
}
