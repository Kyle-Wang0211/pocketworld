// Pure-Dart interpretation of raw Android Camera2/Sensor facts.
// Kotlin owns API calls and transport only; every classification and portable
// calculation in this file is shared policy.

import 'capability_evidence.dart';
import '../timebase/android_boottime_bridge.dart';

bool _hasExactKeys(Map<Object?, Object?> wire, Set<String> expected) =>
    wire.length == expected.length &&
    wire.keys.every((Object? key) => key is String && expected.contains(key));

int? _int(Object? value) => value is int ? value : null;

int? _nullableNonNegativeInt(Object? value, {required bool present}) {
  if (!present || value == null) return null;
  return value is int && value >= 0 ? value : null;
}

List<int>? _intList(Object? value) {
  if (value is! List || value.any((Object? item) => item is! int)) return null;
  return List<int>.unmodifiable(value.cast<int>());
}

List<double>? _finiteVector(Object? value, int length) {
  if (value == null) return null;
  if (value is! List || value.length != length) return null;
  final List<double> result = <double>[];
  for (final Object? item in value) {
    if (item is! num || !item.isFinite) return null;
    result.add(item.toDouble());
  }
  return List<double>.unmodifiable(result);
}

class AndroidTimebaseRawEvidence {
  const AndroidTimebaseRawEvidence._({
    required this.schemaValid,
    required this.cameraTimestampSource,
    required this.clockProbe,
  });

  final bool schemaValid;
  final AndroidCameraTimestampSource cameraTimestampSource;
  final AndroidClockProbe? clockProbe;

  factory AndroidTimebaseRawEvidence.fromWire(Map<Object?, Object?> wire) {
    const Set<String> keys = <String>{
      'schema',
      'timestampSource',
      'monotonicBeforeNanos',
      'bootRealtimeNanos',
      'monotonicAfterNanos',
    };
    final int? source = _int(wire['timestampSource']);
    final int? before = _int(wire['monotonicBeforeNanos']);
    final int? boot = _int(wire['bootRealtimeNanos']);
    final int? after = _int(wire['monotonicAfterNanos']);
    final bool valid =
        _hasExactKeys(wire, keys) &&
        wire['schema'] == 'pw.vio.android.timebase-raw/1' &&
        source != null &&
        before != null &&
        boot != null &&
        after != null &&
        before >= 0 &&
        boot >= 0 &&
        after >= before;
    return AndroidTimebaseRawEvidence._(
      schemaValid: valid,
      cameraTimestampSource: AndroidCameraTimestampSource.fromPlatform(
        source ?? -1,
      ),
      clockProbe: valid
          ? AndroidClockProbe(
              monotonicBeforeNanos: before,
              bootRealtimeNanos: boot,
              monotonicAfterNanos: after,
            )
          : null,
    );
  }
}

enum AndroidLensPoseReference {
  primaryCamera(0),
  gyroscope(1),
  undefined(2),
  automotive(3);

  const AndroidLensPoseReference(this.platformValue);
  final int platformValue;
}

class AndroidExtrinsicsRawEvidence {
  const AndroidExtrinsicsRawEvidence._({
    required this.schemaValid,
    required this.poseReference,
    required this.translationMeters,
    required this.rotationXyzw,
  });

  final bool schemaValid;
  final int? poseReference;
  final List<double>? translationMeters;
  final List<double>? rotationXyzw;

  bool get directCameraGyroscopeCalibrationAvailable =>
      schemaValid &&
      poseReference == AndroidLensPoseReference.gyroscope.platformValue &&
      translationMeters != null &&
      rotationXyzw != null;

  factory AndroidExtrinsicsRawEvidence.fromWire(Map<Object?, Object?> wire) {
    const Set<String> keys = <String>{
      'schema',
      'poseReference',
      'translationMeters',
      'rotationXyzw',
    };
    final Object? rawReference = wire['poseReference'];
    final int? reference = rawReference == null ? null : _int(rawReference);
    final List<double>? translation = _finiteVector(
      wire['translationMeters'],
      3,
    );
    final List<double>? rotation = _finiteVector(wire['rotationXyzw'], 4);
    final bool valid =
        _hasExactKeys(wire, keys) &&
        wire['schema'] == 'pw.vio.android.extrinsics-raw/1' &&
        (rawReference == null || reference != null) &&
        (wire['translationMeters'] == null || translation != null) &&
        (wire['rotationXyzw'] == null || rotation != null);
    return AndroidExtrinsicsRawEvidence._(
      schemaValid: valid,
      poseReference: reference,
      translationMeters: translation,
      rotationXyzw: rotation,
    );
  }
}

class AndroidRollingShutterRawEvidence {
  const AndroidRollingShutterRawEvidence._({
    required this.schemaValid,
    required this.skewNs,
    required this.activeArrayHeight,
    required this.outputRowsCoveringActiveArray,
  });

  final bool schemaValid;
  final int? skewNs;
  final int? activeArrayHeight;
  final int? outputRowsCoveringActiveArray;

  RollingShutterFacts toFacts() {
    final int? skew = skewNs;
    final int? height = activeArrayHeight;
    final int? rows = outputRowsCoveringActiveArray;
    if (!schemaValid ||
        skew == null ||
        height == null ||
        rows == null ||
        skew <= 0 ||
        height <= 0 ||
        rows <= 0 ||
        rows > height) {
      return const RollingShutterFacts.unknown();
    }
    return RollingShutterFacts(readoutNs: (skew * rows) ~/ height);
  }

  factory AndroidRollingShutterRawEvidence.fromWire(
    Map<Object?, Object?> wire,
  ) {
    const Set<String> keys = <String>{
      'schema',
      'skewNs',
      'activeArrayHeight',
      'outputRowsCoveringActiveArray',
    };
    final int? skew = _nullableNonNegativeInt(
      wire['skewNs'],
      present: wire.containsKey('skewNs'),
    );
    final int? height = _nullableNonNegativeInt(
      wire['activeArrayHeight'],
      present: wire.containsKey('activeArrayHeight'),
    );
    final int? rows = _nullableNonNegativeInt(
      wire['outputRowsCoveringActiveArray'],
      present: wire.containsKey('outputRowsCoveringActiveArray'),
    );
    bool validNullable(Object? raw, int? parsed) =>
        raw == null || parsed != null;
    final bool valid =
        _hasExactKeys(wire, keys) &&
        wire['schema'] == 'pw.vio.android.rolling-shutter-raw/1' &&
        validNullable(wire['skewNs'], skew) &&
        validNullable(wire['activeArrayHeight'], height) &&
        validNullable(wire['outputRowsCoveringActiveArray'], rows);
    return AndroidRollingShutterRawEvidence._(
      schemaValid: valid,
      skewNs: skew,
      activeArrayHeight: height,
      outputRowsCoveringActiveArray: rows,
    );
  }
}

class AndroidStabilizationRequest {
  const AndroidStabilizationRequest({
    required this.electronicMode,
    required this.opticalMode,
  });

  final int? electronicMode;
  final int? opticalMode;
}

class AndroidStabilizationRawEvidence {
  const AndroidStabilizationRawEvidence._({
    required this.schemaValid,
    required this.availableElectronicModes,
    required this.availableOpticalModes,
    required this.requestedElectronicMode,
    required this.requestedOpticalMode,
    required this.actualElectronicMode,
    required this.actualOpticalMode,
  });

  static const int off = 0;

  final bool schemaValid;
  final List<int> availableElectronicModes;
  final List<int> availableOpticalModes;
  final int? requestedElectronicMode;
  final int? requestedOpticalMode;
  final int? actualElectronicMode;
  final int? actualOpticalMode;

  AndroidStabilizationRequest get request => AndroidStabilizationRequest(
    electronicMode: availableElectronicModes.contains(off) ? off : null,
    opticalMode: availableOpticalModes.contains(off) ? off : null,
  );

  StabilizationFacts toFacts() {
    if (!schemaValid) return const StabilizationFacts.allUnknown();
    final bool opticalAbsent =
        availableOpticalModes.length == 1 &&
        availableOpticalModes.single == off;
    StabilizationState state(int? actual) => actual == null
        ? StabilizationState.unknown
        : actual == off
        ? StabilizationState.off
        : StabilizationState.on;
    return StabilizationFacts(
      electronic: state(actualElectronicMode),
      optical: opticalAbsent
          ? StabilizationState.absent
          : state(actualOpticalMode),
      electronicControllable: availableElectronicModes.contains(off),
      opticalControllable:
          availableOpticalModes.contains(off) && !opticalAbsent,
    );
  }

  factory AndroidStabilizationRawEvidence.fromWire(Map<Object?, Object?> wire) {
    const Set<String> keys = <String>{
      'schema',
      'availableElectronicModes',
      'availableOpticalModes',
      'requestedElectronicMode',
      'requestedOpticalMode',
      'actualElectronicMode',
      'actualOpticalMode',
    };
    final List<int>? eis = _intList(wire['availableElectronicModes']);
    final List<int>? ois = _intList(wire['availableOpticalModes']);
    int? nullableMode(String key) => wire[key] == null ? null : _int(wire[key]);
    final int? requestedEis = nullableMode('requestedElectronicMode');
    final int? requestedOis = nullableMode('requestedOpticalMode');
    final int? actualEis = nullableMode('actualElectronicMode');
    final int? actualOis = nullableMode('actualOpticalMode');
    bool validMode(String key, int? parsed) =>
        wire[key] == null || parsed != null;
    final bool valid =
        _hasExactKeys(wire, keys) &&
        wire['schema'] == 'pw.vio.android.stabilization-raw/1' &&
        eis != null &&
        ois != null &&
        validMode('requestedElectronicMode', requestedEis) &&
        validMode('requestedOpticalMode', requestedOis) &&
        validMode('actualElectronicMode', actualEis) &&
        validMode('actualOpticalMode', actualOis);
    return AndroidStabilizationRawEvidence._(
      schemaValid: valid,
      availableElectronicModes: eis ?? const <int>[],
      availableOpticalModes: ois ?? const <int>[],
      requestedElectronicMode: requestedEis,
      requestedOpticalMode: requestedOis,
      actualElectronicMode: actualEis,
      actualOpticalMode: actualOis,
    );
  }
}
