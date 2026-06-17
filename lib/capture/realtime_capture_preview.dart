import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';

import '../dome/ar_pose.dart';

/// Capture-time preview phase. The UI stays visually consistent while
/// the data source graduates from AR feature points to draft alignment.
enum CapturePreviewPhase {
  veryRoughPreview,
  initializingAlignment,
  qualityPointCloud,
  review,
}

extension CapturePreviewPhaseText on CapturePreviewPhase {
  String get shortLabel {
    switch (this) {
      case CapturePreviewPhase.veryRoughPreview:
        return '建立空间';
      case CapturePreviewPhase.initializingAlignment:
        return '初始化/分析中';
      case CapturePreviewPhase.qualityPointCloud:
        return '质量点云';
      case CapturePreviewPhase.review:
        return 'Review Scan';
    }
  }

  double get displayConfidence {
    switch (this) {
      case CapturePreviewPhase.veryRoughPreview:
        return 0.34;
      case CapturePreviewPhase.initializingAlignment:
        return 0.62;
      case CapturePreviewPhase.qualityPointCloud:
      case CapturePreviewPhase.review:
        return 1.0;
    }
  }
}

class CapturePreviewVoxel {
  final Vector3 position;
  final int r;
  final int g;
  final int b;
  final int observations;
  final double confidence;
  final double quality;
  final double lastTimestamp;

  const CapturePreviewVoxel({
    required this.position,
    required this.r,
    required this.g,
    required this.b,
    required this.observations,
    required this.confidence,
    required this.quality,
    required this.lastTimestamp,
  });
}

class CapturePreviewCameraSample {
  final Vector3 position;
  final Quaternion orientation;
  final int photoCount;

  const CapturePreviewCameraSample({
    required this.position,
    required this.orientation,
    required this.photoCount,
  });
}

class RealtimeCapturePreviewModel extends ChangeNotifier {
  static const int maxStoredVoxels = 60000;
  static const int maxCameraSamples = 420;

  final Map<String, _MutablePreviewVoxel> _voxels =
      <String, _MutablePreviewVoxel>{};
  final List<CapturePreviewCameraSample> _cameraSamples =
      <CapturePreviewCameraSample>[];

  ARPose? _lastPose;
  int _photoCount = 0;
  int _lastCameraPhotoCount = 0;
  CapturePreviewPhase _phase = CapturePreviewPhase.veryRoughPreview;

  ARPose? get lastPose => _lastPose;
  int get photoCount => _photoCount;
  CapturePreviewPhase get phase => _phase;
  List<CapturePreviewCameraSample> get cameraSamples =>
      List.unmodifiable(_cameraSamples);

  List<CapturePreviewVoxel> get voxels {
    final out = _voxels.values.map((v) => v.snapshot(_phase)).toList();
    out.sort((a, b) {
      final obs = b.observations.compareTo(a.observations);
      if (obs != 0) return obs;
      return b.lastTimestamp.compareTo(a.lastTimestamp);
    });
    return out;
  }

  void reset() {
    _voxels.clear();
    _cameraSamples.clear();
    _lastPose = null;
    _photoCount = 0;
    _lastCameraPhotoCount = 0;
    _phase = CapturePreviewPhase.veryRoughPreview;
    notifyListeners();
  }

  void updateFromPose(ARPose pose, {required int photoCount}) {
    _lastPose = pose;
    _photoCount = photoCount;
    _phase = _phaseForPhotoCount(photoCount);
    if (photoCount > _lastCameraPhotoCount) {
      _lastCameraPhotoCount = photoCount;
      _cameraSamples.add(
        CapturePreviewCameraSample(
          position: pose.position.clone(),
          orientation: pose.orientation.clone(),
          photoCount: photoCount,
        ),
      );
      if (_cameraSamples.length > maxCameraSamples) {
        _cameraSamples.removeRange(0, _cameraSamples.length - maxCameraSamples);
      }
    }

    for (final point in pose.previewPoints) {
      final distance = (point.position - pose.position).length;
      final level = _voxelLevelForDistance(distance);
      final size = _voxelSizeForLevel(level);
      final key = _voxelKey(point.position, level: level, size: size);
      final voxel = _voxels.putIfAbsent(
        key,
        () => _MutablePreviewVoxel(point.position, level: level),
      );
      voxel.add(point, pose.timestamp);
    }

    if (_voxels.length > maxStoredVoxels) {
      _pruneVoxels(maxStoredVoxels);
    }
    notifyListeners();
  }

  CapturePreviewPhase _phaseForPhotoCount(int count) {
    if (count < 5) return CapturePreviewPhase.veryRoughPreview;
    if (count < 20) return CapturePreviewPhase.initializingAlignment;
    return CapturePreviewPhase.qualityPointCloud;
  }

  int _voxelLevelForDistance(double meters) {
    if (meters < 1.25) return 0;
    if (meters < 3.5) return 1;
    return 2;
  }

  double _voxelSizeForLevel(int level) {
    switch (level) {
      case 0:
        return 0.035;
      case 1:
        return 0.075;
      default:
        return 0.16;
    }
  }

  String _voxelKey(Vector3 p, {required int level, required double size}) {
    final ix = (p.x / size).floor();
    final iy = (p.y / size).floor();
    final iz = (p.z / size).floor();
    return '$level:$ix:$iy:$iz';
  }

  void _pruneVoxels(int targetCount) {
    final ranked = _voxels.entries.toList()
      ..sort((a, b) {
        final obs = a.value.observations.compareTo(b.value.observations);
        if (obs != 0) return obs;
        return a.value.lastTimestamp.compareTo(b.value.lastTimestamp);
      });
    final removeCount = math.max(0, ranked.length - targetCount);
    for (var i = 0; i < removeCount; i++) {
      _voxels.remove(ranked[i].key);
    }
  }
}

class _MutablePreviewVoxel {
  Vector3 position;
  double r;
  double g;
  double b;
  double confidence;
  int observations;
  double lastTimestamp;
  final int level;

  _MutablePreviewVoxel(Vector3 initial, {required this.level})
    : position = initial.clone(),
      r = 0,
      g = 0,
      b = 0,
      confidence = 0,
      observations = 0,
      lastTimestamp = 0;

  void add(ARPreviewPoint point, double timestamp) {
    observations += 1;
    final n = observations.toDouble();
    position = position.scaled((n - 1) / n)..add(point.position.scaled(1 / n));
    r = _runningAverage(r, point.r.toDouble(), n);
    g = _runningAverage(g, point.g.toDouble(), n);
    b = _runningAverage(b, point.b.toDouble(), n);
    confidence = _runningAverage(confidence, point.confidence, n);
    lastTimestamp = timestamp;
  }

  CapturePreviewVoxel snapshot(CapturePreviewPhase phase) {
    final obsScore = (observations / 7.0).clamp(0.0, 1.0);
    final quality = switch (phase) {
      CapturePreviewPhase.veryRoughPreview =>
        (confidence * 0.25 + obsScore * 0.15).clamp(0.0, 0.45),
      CapturePreviewPhase.initializingAlignment =>
        (confidence * 0.35 + obsScore * 0.35).clamp(0.0, 0.72),
      CapturePreviewPhase.qualityPointCloud || CapturePreviewPhase.review =>
        (confidence * 0.36 + obsScore * 0.64).clamp(0.0, 1.0),
    };
    return CapturePreviewVoxel(
      position: position.clone(),
      r: r.round().clamp(0, 255),
      g: g.round().clamp(0, 255),
      b: b.round().clamp(0, 255),
      observations: observations,
      confidence: confidence.clamp(0.0, 1.0),
      quality: quality,
      lastTimestamp: lastTimestamp,
    );
  }

  static double _runningAverage(double oldValue, double newValue, double n) {
    return oldValue + (newValue - oldValue) / n;
  }
}
