// PocketWorld Android capture — platform-channel decoding.
//
// Everything the Kotlin side sends arrives as Map<Object?, Object?> with values
// typed by Flutter's StandardMessageCodec. Three failure modes are worth naming,
// because all three surface on a device and none of them at compile time:
//
//   * A key the platform omitted arrives as null, not as a missing key.
//     SENSOR_EXPOSURE_TIME and SENSOR_ROLLING_SHUTTER_SKEW are OPTIONAL camera2
//     keys, so null is a normal device, not a fault.
//   * StandardMessageCodec has no 32-bit float wire type. Kotlin must widen
//     every FloatArray to Double; `asDouble` still accepts an int in case some
//     path sends an integral value, because a ClassCastException at this seam
//     costs the whole session.
//   * Java `long` and `int` both land as Dart `int`, so nothing is lost there,
//     but a JSON round trip anywhere in the chain would turn a large ns
//     timestamp into a double. `asInt` refuses a non-integral double rather
//     than truncating a timestamp silently.
//
// Decoding NEVER throws on a value that is merely absent or optional; it throws
// only when a field the algorithm cannot run without is missing, so the caller
// can surface a broken platform contract instead of computing on a zero.

import 'camera_timebase.dart';
import 'clock_offset.dart';
import 'exit_triage.dart';
import 'sensor_delivery_monitor.dart';
import 'thermal_policy.dart';

class ChannelDecodeException implements Exception {
  ChannelDecodeException(this.field, this.value);

  final String field;
  final Object? value;

  @override
  String toString() =>
      'ChannelDecodeException: field "$field" was ${value.runtimeType} ($value)';
}

Map<Object?, Object?> _asMap(Object? raw, String what) {
  if (raw is Map) return raw;
  throw ChannelDecodeException(what, raw);
}

int asInt(Object? v, String field) {
  if (v is int) return v;
  if (v is double) {
    if (v == v.roundToDouble() && v.isFinite) return v.toInt();
    throw ChannelDecodeException(field, v);
  }
  throw ChannelDecodeException(field, v);
}

int? asIntOrNull(Object? v, String field) =>
    v == null ? null : asInt(v, field);

double asDouble(Object? v, String field) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  throw ChannelDecodeException(field, v);
}

String asString(Object? v) => v is String ? v : '';

class ChannelCodec {
  const ChannelCodec._();

  /// `probeClocks` -> a list of [ClockProbe].
  ///
  /// A structurally broken entry is dropped rather than thrown, because the
  /// estimator is best-of-N: one bad entry must not cost the whole batch. The
  /// count of dropped entries is returned so it can still be surfaced.
  static (List<ClockProbe>, int malformed) decodeClockProbes(Object? raw) {
    if (raw is! List) throw ChannelDecodeException('clockProbes', raw);
    final out = <ClockProbe>[];
    var bad = 0;
    for (final e in raw) {
      if (e is! Map) {
        bad++;
        continue;
      }
      final a = e['monoBeforeNs'];
      final b = e['bootNs'];
      final c = e['monoAfterNs'];
      if (a is! int || b is! int || c is! int) {
        bad++;
        continue;
      }
      out.add(ClockProbe(monoBeforeNs: a, bootNs: b, monoAfterNs: c));
    }
    return (out, bad);
  }

  /// `cameraCharacteristics` -> the time base to resolve frames with.
  ///
  /// A null SENSOR_INFO_TIMESTAMP_SOURCE is read as UNKNOWN, never as REALTIME:
  /// assuming REALTIME on a device that did not say so fuses two unrelated
  /// clocks and the error is silent.
  static CameraTimeBase decodeCameraTimeBase(Object? raw) {
    final m = _asMap(raw, 'cameraCharacteristics');
    final wasNull = m['timestampSourceWasNull'] == true;
    final src = m['timestampSource'];
    if (wasNull || src == null) {
      return CameraTimeBase(timestampSource: TimestampSource.unknown);
    }
    return CameraTimeBase(
        timestampSource: asInt(src, 'timestampSource'));
  }

  /// Active-array row count SENSOR_TIMESTAMP and the skew refer to.
  /// Absent means we cannot place a feature on a row; 0 is returned and the
  /// caller must treat per-row instants as unavailable.
  static int decodeActiveArrayHeight(Object? raw) {
    final m = _asMap(raw, 'cameraCharacteristics');
    return asIntOrNull(m['activeArrayHeight'], 'activeArrayHeight') ?? 0;
  }

  static FrameMetadata decodeFrameMetadata(Object? raw) {
    final m = _asMap(raw, 'frameMetadata');
    final ts = m['sensorTimestampNs'];
    if (ts == null) {
      // SENSOR_TIMESTAMP is mandatory on every camera2 device. Its absence is
      // a broken platform contract, not an optional-key case.
      throw ChannelDecodeException('sensorTimestampNs', ts);
    }
    return FrameMetadata(
      sensorTimestampNs: asInt(ts, 'sensorTimestampNs'),
      activeArrayHeight:
          asIntOrNull(m['activeArrayHeight'], 'activeArrayHeight') ?? 0,
      exposureTimeNs: asIntOrNull(m['exposureTimeNs'], 'exposureTimeNs'),
      rollingShutterSkewNs:
          asIntOrNull(m['rollingShutterSkewNs'], 'rollingShutterSkewNs'),
      frameNumber: asIntOrNull(m['frameNumber'], 'frameNumber') ?? 0,
    );
  }

  static SensorSample decodeSensorSample(Object? raw) {
    final m = _asMap(raw, 'sensorSample');
    return SensorSample(
      eventTsNs: asInt(m['eventTsNs'], 'eventTsNs'),
      arrivalTsNs: asInt(m['arrivalTsNs'], 'arrivalTsNs'),
    );
  }

  /// `thermalSample`. A locally throttled call, an API-unavailable device and a
  /// genuine NaN all decode to NaN — `ThermalPolicy` is the one place that
  /// distinguishes them, and it does so from history, not from this flag.
  static ThermalSample decodeThermalSample(Object? raw) {
    final m = _asMap(raw, 'thermalSample');
    final h = m['headroom'];
    return ThermalSample(
      atMs: asInt(m['atMs'], 'atMs'),
      headroom: h == null ? double.nan : asDouble(h, 'headroom'),
      status: asIntOrNull(m['status'], 'status') ?? ThermalStatus.none,
    );
  }

  /// `exitInfo`. getDescription() is nullable on the platform; a null decodes
  /// to '' which cannot match the MemoryLimiter tag, so a missing description
  /// can never manufacture a false positive.
  static List<ExitRecord> decodeExitRecords(Object? raw) {
    if (raw is! List) throw ChannelDecodeException('exitInfo', raw);
    return raw.map((e) {
      final m = _asMap(e, 'exitInfo[]');
      return ExitRecord(
        timestampMs: asInt(m['timestampMs'], 'timestampMs'),
        pid: asIntOrNull(m['pid'], 'pid') ?? 0,
        reason: asIntOrNull(m['reason'], 'reason') ?? ExitReason.unknown,
        description: asString(m['description']),
        subReason: asIntOrNull(m['subReason'], 'subReason') ?? 0,
        status: asIntOrNull(m['status'], 'status') ?? 0,
        importance: asIntOrNull(m['importance'], 'importance') ?? 0,
        rssKb: asIntOrNull(m['rssKb'], 'rssKb') ?? 0,
        pssKb: asIntOrNull(m['pssKb'], 'pssKb') ?? 0,
        processName: asString(m['processName']),
      );
    }).toList();
  }

  /// LENS_INTRINSIC_CALIBRATION = [f_x, f_y, c_x, c_y, s], in pixels of the
  /// PRE-CORRECTION active array since API 28. Returns null when the device
  /// omits the optional key — which is normal, and means self-calibration.
  static List<double>? decodeIntrinsics(Object? raw) {
    final m = _asMap(raw, 'cameraCharacteristics');
    final v = m['intrinsicCalibration'];
    if (v is! List || v.length < 5) return null;
    return <double>[
      for (var i = 0; i < 5; i++) asDouble(v[i], 'intrinsicCalibration[$i]')
    ];
  }
}
