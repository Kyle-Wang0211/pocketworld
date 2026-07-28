import 'dart:convert';
import 'dart:io';

import 'photo_bundle_quality_service.dart';

final class PhotoBundleFrameDraft {
  const PhotoBundleFrameDraft({
    required this.id,
    required this.highresFilename,
    required this.timestamp,
    required this.triggerTimestamp,
    required this.azimuth,
    required this.elevation,
    required this.captureKind,
    required this.poseSyncQuality,
    required this.imageWidth,
    required this.imageHeight,
    required this.quality,
    required this.cameraTransform,
    required this.intrinsics,
    this.cameraRadiusM,
    this.radiusShellID,
    this.poseSource,
    this.focusStable,
    this.trackingState,
    this.cellID,
    this.previewFilename,
  });

  final String id;
  final String highresFilename;
  final String? previewFilename;
  final double timestamp;
  final double triggerTimestamp;
  final double azimuth;
  final double elevation;
  final String captureKind;
  final String poseSyncQuality;
  final int imageWidth;
  final int imageHeight;
  final PhotoBundleStillQuality quality;
  final List<double> cameraTransform;
  final List<double> intrinsics;
  final double? cameraRadiusM;
  final String? radiusShellID;
  final String? poseSource;
  final bool? focusStable;
  final String? trackingState;
  final String? cellID;

  Map<String, Object?> toJson() => {
        'id': id,
        'highresFilename': highresFilename,
        if (previewFilename != null && previewFilename!.isNotEmpty)
          'previewFilename': previewFilename,
        'timestamp': timestamp,
        'triggerTimestamp': triggerTimestamp,
        'azimuth': azimuth,
        'elevation': elevation,
        'captureKind': captureKind,
        'poseSyncQuality': poseSyncQuality,
        'imageWidth': imageWidth,
        'imageHeight': imageHeight,
        'quality': quality.toJson(),
        'cameraTransform': cameraTransform,
        'intrinsics': intrinsics,
        if (cameraRadiusM != null) 'cameraRadiusM': cameraRadiusM,
        if (radiusShellID != null) 'radiusShellID': radiusShellID,
        if (poseSource != null) 'poseSource': poseSource,
        if (focusStable != null) 'focusStable': focusStable,
        if (trackingState != null) 'trackingState': trackingState,
        if (cellID != null) 'cellID': cellID,
      };
}

final class PhotoBundleManifestService {
  const PhotoBundleManifestService();

  Map<String, Object?> buildManifest({
    required Iterable<PhotoBundleFrameDraft> frames,
    int captureVersion = 3,
    DateTime? createdAt,
    String sourceKind = 'arkit_high_res_still',
    String photosHighresDir = 'photos_highres',
    String? previewsDir,
    PhotoBundleStillQualityPolicy stillQualityPolicy =
        const PhotoBundleStillQualityPolicy(),
    int rejectedStillCount = 0,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    return <String, Object?>{
      'schemaVersion': 'aether_photo_bundle_v1',
      'captureVersion': captureVersion,
      'createdAt': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
      'sourceKind': sourceKind,
      'photosHighresDir': photosHighresDir,
      if (previewsDir != null && previewsDir.isNotEmpty)
        'previewsDir': previewsDir,
      'stillQualityPolicy': stillQualityPolicy.toJson(),
      'rejectedStillCount': rejectedStillCount,
      ...extra,
      // Route identity is owned by this physically independent service copy.
      // Keep it after [extra] so callers cannot accidentally relabel an
      // official capture as the self-developed route.
      'pipeline_kind': 'official',
      'frames': frames.map((frame) => frame.toJson()).toList(growable: false),
    };
  }

  Future<void> writeManifest({
    required Directory bundleDirectory,
    required Iterable<PhotoBundleFrameDraft> frames,
    int captureVersion = 3,
    DateTime? createdAt,
    String sourceKind = 'arkit_high_res_still',
    String photosHighresDir = 'photos_highres',
    String? previewsDir,
    PhotoBundleStillQualityPolicy stillQualityPolicy =
        const PhotoBundleStillQualityPolicy(),
    int rejectedStillCount = 0,
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    final manifest = buildManifest(
      frames: frames,
      captureVersion: captureVersion,
      createdAt: createdAt,
      sourceKind: sourceKind,
      photosHighresDir: photosHighresDir,
      previewsDir: previewsDir,
      stillQualityPolicy: stillQualityPolicy,
      rejectedStillCount: rejectedStillCount,
      extra: extra,
    );
    await bundleDirectory.create(recursive: true);
    await File(_join(bundleDirectory.path, 'official_photo_bundle.json'))
        .writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );
  }
}

String _join(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) return '$left$right';
  return '$left${Platform.pathSeparator}$right';
}
