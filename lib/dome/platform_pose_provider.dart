// Platform-channel ARPoseProvider.
//
// Expects MethodChannel `aether_arkit` (registered by
// AetherARKitPlugin in ios/Runner) with:
//   `isAvailable`  → Bool
//   `startSession` → Void
//   `stopSession`  → Void
//   `lockOrigin`   → {originX, originY, originZ, worldYaw}
//
// EventChannel `aether_arkit/pose_stream` → JSON pose events:
//   {tx, ty, tz, qx, qy, qz, qw, extrinsic, intrinsicFxFyCxCy,
//    hasOrigin, worldOriginX, worldOriginY, worldOriginZ, worldYaw,
//    isTracking, trackingStateName, t}
//
// If neither iOS ARKit nor Android ARCore is available this provider
// transparently falls back to MockARPoseProvider.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

import '../capture/capture_format.dart';
import '../quality/quality_compute.dart';
import 'ar_pose.dart';
import 'mock_pose_provider.dart';

class PlatformARPoseProvider implements ARPoseProvider {
  static const _method = MethodChannel('aether_arkit');
  static const _poseEvents = EventChannel('aether_arkit/pose_stream');

  final MockARPoseProvider _fallback = MockARPoseProvider();
  bool _usingFallback = false;
  StreamSubscription<dynamic>? _nativeSub;
  final _controller = StreamController<ARPose>.broadcast();
  ARPose? _lastPose;

  @override
  ARPose? get lastPose => _lastPose;

  @override
  Stream<ARPose> start() {
    _tryStartNative();
    return _controller.stream;
  }

  Future<void> _tryStartNative() async {
    if (_usingFallback) return;
    try {
      final isAvailable = await _method.invokeMethod<bool>('isAvailable');
      if (isAvailable != true) {
        _switchToFallback();
        return;
      }
      // [E24 探针] PW_VIDEO_FORMAT: '4k'(默认,现行为)| 'default43'
      // (留系统默认 1920×1440 4:3,测其 out-of-band 静照分辨率)。
      await _method.invokeMethod('startSession', <String, dynamic>{
        'videoFormatMode': pwVideoFormat,
      });
      _nativeSub = _poseEvents.receiveBroadcastStream().listen(
        (event) => _onNativePose(event),
        onError: (Object _) => _switchToFallback(),
      );
    } on MissingPluginException {
      _switchToFallback();
    } on PlatformException {
      _switchToFallback();
    } catch (_) {
      _switchToFallback();
    }
  }

  void _onNativePose(dynamic event) {
    final map = (event as Map).cast<String, Object?>();
    final position = Vector3(
      (map['tx'] as num?)?.toDouble() ?? 0,
      (map['ty'] as num?)?.toDouble() ?? 0,
      (map['tz'] as num?)?.toDouble() ?? 0,
    );
    final orientation = Quaternion(
      (map['qx'] as num?)?.toDouble() ?? 0,
      (map['qy'] as num?)?.toDouble() ?? 0,
      (map['qz'] as num?)?.toDouble() ?? 0,
      (map['qw'] as num?)?.toDouble() ?? 1,
    );
    final hasOrigin = (map['hasOrigin'] as bool?) ?? false;
    final worldOrigin = Vector3(
      (map['worldOriginX'] as num?)?.toDouble() ?? 0,
      (map['worldOriginY'] as num?)?.toDouble() ?? 0,
      (map['worldOriginZ'] as num?)?.toDouble() ?? 0,
    );
    final worldYaw = (map['worldYaw'] as num?)?.toDouble() ?? 0;

    // Position-based azimuth / elevation per
    // ObjectModeV2ARDomeCoordinator.handleFrame:
    //   az = atan2(rel.z, rel.x) - worldYaw
    //   el = atan2(rel.y, max(horizDist, 0.001))
    double azimuth = 0;
    double elevation = 0;
    if (hasOrigin) {
      final relX = position.x - worldOrigin.x;
      final relY = position.y - worldOrigin.y;
      final relZ = position.z - worldOrigin.z;
      final horizDist = math.sqrt(relX * relX + relZ * relZ);
      azimuth = math.atan2(relZ, relX) - worldYaw;
      elevation = math.atan2(relY, horizDist < 0.001 ? 0.001 : horizDist);
    }

    final extrinsic = _decodeFloatList(map['extrinsic']);
    final intrinsic = _decodeFloatList(map['intrinsicFxFyCxCy']);
    final previewPoints = _decodePreviewPoints(map);

    // Optional quality block. Native ships a 128×128 grayscale Y-plane
    // thumbnail on the throttled (6 Hz) frames; we derive sharpness +
    // brightness + signature here in pure Dart. Cross-platform: every
    // platform's native bridge (iOS today, Android next, Web/HarmonyOS
    // mock) only has to ship the gray128 blob — the Laplacian / variance
    // / signature math is shared from lib/quality/quality_compute.dart.
    FrameQualityReport? quality;
    final grayRaw = map['q_gray128'];
    if (grayRaw is Uint8List &&
        grayRaw.length == kQualityGraySide * kQualityGraySide) {
      try {
        quality = computeFrameQualityFromGray128(grayRaw);
      } on ArgumentError {
        // Length mismatch — shouldn't happen since we just checked,
        // but defensively leave quality = null rather than crash the
        // pose stream.
        quality = null;
      }
    } else if (grayRaw is List &&
        grayRaw.length == kQualityGraySide * kQualityGraySide) {
      // Some MethodChannel codecs surface byte blobs as List<int>
      // depending on platform — paper over that here.
      try {
        quality = computeFrameQualityFromGray128(
          Uint8List.fromList(grayRaw.cast<int>()),
        );
      } on ArgumentError {
        quality = null;
      }
    }

    final pose = ARPose(
      position: position,
      orientation: orientation,
      azimuth: azimuth,
      elevation: elevation,
      isTracking: (map['isTracking'] as bool?) ?? true,
      timestamp: (map['t'] as num?)?.toDouble() ?? 0,
      hasOrigin: hasOrigin,
      worldOrigin: worldOrigin,
      worldYaw: worldYaw,
      extrinsic4x4: extrinsic,
      intrinsicFxFyCxCy: intrinsic,
      imageWidth: (map['imageWidth'] as num?)?.toInt() ?? 0,
      imageHeight: (map['imageHeight'] as num?)?.toInt() ?? 0,
      scaleAlignAnchorCount:
          (map['scaleAlignAnchorCount'] as num?)?.toInt() ?? 0,
      scaleAlignDepthSpanM:
          (map['scaleAlignDepthSpanM'] as num?)?.toDouble() ?? 0.0,
      scaleAlignReliabilityPrior:
          (map['scaleAlignReliabilityPrior'] as num?)?.toDouble() ?? 0.0,
      isAdjustingFocus: (map['isAdjustingFocus'] as bool?) ?? false,
      isAdjustingExposure: (map['isAdjustingExposure'] as bool?) ?? false,
      lensPosition: (map['lensPosition'] as num?)?.toDouble() ?? 0.0,
      exposureTargetOffset:
          (map['exposureTargetOffset'] as num?)?.toDouble() ?? 0.0,
      quality: quality,
      previewPoints: previewPoints,
      // ARKit reason string (iOS only). Null for any other backend
      // (ARCore plugin not yet registered on Android, HarmonyOS XR
      // Engine, WebXR) — PoseDriftTracker treats null as "normal" so
      // backends without a tracker classification don't poison the
      // health stats.
      trackingStateName: map['trackingStateName'] as String?,
    );
    _lastPose = pose;
    if (!_controller.isClosed) _controller.add(pose);
  }

  static List<double> _decodeFloatList(Object? raw) {
    if (raw is List) {
      return raw.map((v) => (v as num).toDouble()).toList(growable: false);
    }
    return const <double>[];
  }

  static List<ARPreviewPoint> _decodePreviewPoints(Map<String, Object?> map) {
    final xyz = map['previewPointXYZ'];
    if (xyz is! List || xyz.length < 3) return const <ARPreviewPoint>[];
    final rgb = map['previewPointRGB'];
    final conf = map['previewPointConfidence'];
    final count = xyz.length ~/ 3;
    final out = <ARPreviewPoint>[];
    for (var i = 0; i < count; i++) {
      final base = i * 3;
      final r = rgb is List && rgb.length > base
          ? (rgb[base] as num).toInt().clamp(0, 255)
          : 190;
      final g = rgb is List && rgb.length > base + 1
          ? (rgb[base + 1] as num).toInt().clamp(0, 255)
          : 190;
      final b = rgb is List && rgb.length > base + 2
          ? (rgb[base + 2] as num).toInt().clamp(0, 255)
          : 190;
      final confidence = conf is List && conf.length > i
          ? (conf[i] as num).toDouble().clamp(0.0, 1.0)
          : 1.0;
      out.add(
        ARPreviewPoint(
          position: Vector3(
            (xyz[base] as num).toDouble(),
            (xyz[base + 1] as num).toDouble(),
            (xyz[base + 2] as num).toDouble(),
          ),
          r: r,
          g: g,
          b: b,
          confidence: confidence,
        ),
      );
    }
    return List.unmodifiable(out);
  }

  void _switchToFallback() {
    if (_usingFallback) return;
    _usingFallback = true;
    _fallback.start().listen((p) {
      _lastPose = p;
      if (!_controller.isClosed) _controller.add(p);
    });
  }

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async {
    final result = await saveCurrentFrame(
      ARFrameSaveSpec(
        frameID: 'legacy',
        cellIndex: -1,
        slotIndex: -1,
        jpegPath: jpegPath,
        metadataPath: metadataPath,
        targetTimestamp: targetTimestamp,
        maxTimestampDelta: maxTimestampDelta,
        quality: quality,
      ),
    );
    return result.saved;
  }

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async {
    if (_usingFallback) {
      return _fallback.saveCurrentFrame(spec);
    }
    try {
      final reply = await _method.invokeMethod<dynamic>(
        'saveCurrentFrameAsJpeg',
        spec.toMethodArgs(),
      );
      return ARFrameSaveResult(
        spec: spec,
        status: 'saved',
        sfmFrame: _sfmFrameFromSaveReply(reply),
      );
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print(
        '[PlatformARPoseProvider] saveCurrentFrameAsJpeg failed: ${e.message}',
      );
      return ARFrameSaveResult(
        spec: spec,
        status: 'failed',
        message: e.message,
      );
    } on MissingPluginException {
      return ARFrameSaveResult(spec: spec, status: 'unsupported');
    }
  }

  /// Parses the optional streaming-SfM feed off the `saveCurrentFrameAsJpeg`
  /// reply. Best-effort: any missing/malformed field → null (JPEG save is
  /// authoritative; SfM feeding is an enhancement, never a failure source).
  static SfmFrameFeed? _sfmFrameFromSaveReply(dynamic reply) {
    if (reply is! Map) return null;
    final grayRaw = reply['sfm_gray'];
    final Uint8List? gray = grayRaw is Uint8List
        ? grayRaw
        : (grayRaw is List ? Uint8List.fromList(grayRaw.cast<int>()) : null);
    final grayW = (reply['sfm_gray_w'] as num?)?.toInt() ?? 0;
    final grayH = (reply['sfm_gray_h'] as num?)?.toInt() ?? 0;
    final imageW = (reply['image_w'] as num?)?.toInt() ?? 0;
    final imageH = (reply['image_h'] as num?)?.toInt() ?? 0;
    final intrinsicsRaw = reply['intrinsics_fxfycxcy'];
    final intrinsics = intrinsicsRaw is List
        ? intrinsicsRaw.map((e) => (e as num).toDouble()).toList()
        : const <double>[];
    final extrinsicRaw = reply['extrinsic'];
    final extrinsic = extrinsicRaw is List
        ? extrinsicRaw.map((e) => (e as num).toDouble()).toList()
        : const <double>[];
    if (gray == null ||
        grayW <= 0 ||
        grayH <= 0 ||
        gray.length < grayW * grayH ||
        imageW <= 0 ||
        imageH <= 0 ||
        intrinsics.length < 4) {
      return null;
    }
    return SfmFrameFeed(
      gray: gray,
      grayW: grayW,
      grayH: grayH,
      imageW: imageW,
      imageH: imageH,
      intrinsicFxFyCxCy: intrinsics,
      extrinsic4x4: extrinsic.length == 16 ? extrinsic : const <double>[],
      timestamp: (reply['t'] as num?)?.toDouble() ?? 0.0,
    );
  }

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
    bool feedSfm = false,
    double? maxTimestampDelta,
  }) async {
    if (_usingFallback) {
      return _fallback.captureHighResolutionStill(
        highresPath: highresPath,
        previewPath: previewPath,
        triggerTimestamp: triggerTimestamp,
        quality: quality,
        saveSpec: saveSpec,
        feedSfm: feedSfm,
        maxTimestampDelta: maxTimestampDelta,
      );
    }
    try {
      final args = <String, dynamic>{
        'highresPath': highresPath,
        'previewPath': previewPath,
        'quality': quality,
        'feedSfm': feedSfm,
      };
      if (triggerTimestamp != null) {
        args['triggerTimestamp'] = triggerTimestamp;
      }
      if (saveSpec != null) {
        args['dartSaveContract'] = saveSpec.toJson();
        args['metadataSchemaVersion'] = saveSpec.metadataSchemaVersion;
        args['metadataPath'] = saveSpec.metadataPath;
        args['maxTimestampDelta'] = saveSpec.maxTimestampDelta;
      }
      // 显式参数最后写,压过 saveSpec 的默认值。
      if (maxTimestampDelta != null) {
        args['maxTimestampDelta'] = maxTimestampDelta;
      }
      final result = await _method.invokeMapMethod<String, dynamic>(
        'captureHighResolutionStill',
        args,
      );
      if (result == null) return null;
      final grayRaw = result['q_gray128'];
      Uint8List? gray;
      if (grayRaw is Uint8List) {
        gray = grayRaw;
      } else if (grayRaw is List) {
        gray = Uint8List.fromList(grayRaw.cast<int>());
      }
      final gray1024Raw = result['q_gray1024'];
      Uint8List? gray1024;
      if (gray1024Raw is Uint8List) {
        gray1024 = gray1024Raw;
      } else if (gray1024Raw is List) {
        gray1024 = Uint8List.fromList(gray1024Raw.cast<int>());
      }
      return HighResolutionStillCapture(
        highresPath: (result['highresPath'] as String?) ?? highresPath,
        previewPath: (result['previewPath'] as String?) ?? previewPath,
        timestamp: (result['timestamp'] as num?)?.toDouble() ?? 0,
        imageWidth: (result['imageWidth'] as num?)?.toInt() ?? 0,
        imageHeight: (result['imageHeight'] as num?)?.toInt() ?? 0,
        cameraTransform: _decodeFloatList(result['cameraTransform']),
        intrinsics: _decodeFloatList(result['intrinsics']),
        gray128: gray,
        gray1024: gray1024,
        captureKind:
            (result['captureKind'] as String?) ?? 'arkit_high_res_still',
        poseSyncQuality:
            (result['poseSyncQuality'] as String?) ??
            'ar_session_high_res_frame',
        trackingStateName: result['trackingStateName'] as String?,
        sfmGray: result['sfm_gray'] is Uint8List
            ? result['sfm_gray'] as Uint8List
            : null,
        sfmGrayW: (result['sfm_gray_w'] as num?)?.toInt(),
        sfmGrayH: (result['sfm_gray_h'] as num?)?.toInt(),
      );
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print(
        '[PlatformARPoseProvider] captureHighResolutionStill failed: ${e.message}',
      );
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async {
    if (_usingFallback) {
      return _fallback.lockOrigin(distanceMeters: distanceMeters);
    }
    try {
      final result = await _method.invokeMapMethod<String, dynamic>(
        'lockOrigin',
        <String, dynamic>{'distanceMeters': distanceMeters},
      );
      if (result == null) return null;
      return ARLockResult(
        worldOrigin: Vector3(
          (result['originX'] as num?)?.toDouble() ?? 0,
          (result['originY'] as num?)?.toDouble() ?? 0,
          (result['originZ'] as num?)?.toDouble() ?? 0,
        ),
        worldYaw: (result['worldYaw'] as num?)?.toDouble() ?? 0,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    await _nativeSub?.cancel();
    _nativeSub = null;
    await _fallback.stop();
    try {
      await _method.invokeMethod('stopSession');
    } catch (_) {
      /* best effort */
    }
  }
}
