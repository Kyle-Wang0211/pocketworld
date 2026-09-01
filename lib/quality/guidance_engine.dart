// Dart port of `App/ObjectModeV2/ObjectModeV2GuidanceEngine.swift`.
//
// VERBATIM port — every constant, threshold, helper formula, and hint
// string is intended to match the Swift source. Re-align after every
// upstream change. Last sync: 2026-04-30.
//
// Real-time per-frame audit + dome-guidance engine. Consumes a visual
// frame sample (Laplacian variance, brightness, texture signature) plus
// the target-zone anchor and produces:
//   • a GuidanceSnapshot with accepted-frame count, orbit completion,
//     hint text, stability score
//   • an AuditSummary rolled up to broker `pipelineAuditFields` at
//     scan-end so the cloud can cross-check the client's live audit.
//
// The hard-reject taxonomy mirrors the Swift source exactly:
//   HARD: blur / dark / bright / occupancy
//   SOFT: redundant / low_texture / weak_quality
//   HINT: recenter / new_angle / coverage
//
// **Important**: GuidanceEngine produces user-facing telemetry. It does
// NOT gate `DomeCoverageMap.ingest` — the dome's cell ingestion is a
// separate path keyed off the AR pose stream + Laplacian sharpness,
// matching iOS's two independent paths in
// `ObjectModeV2CaptureViewModel`.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'frame_quality_constants.dart';

class GuidanceSnapshot {
  final int acceptedFrames;
  final double orbitCompletion;
  final String hintText;
  final double stabilityScore;
  final double? lastAcceptedTimestamp;

  /// Plan G W2 P3 transient UI hint: tagged when this frame hit a HARD
  /// reject gate. Values:
  ///   'blur'   — laplacianVariance < blurThresholdLaplacian (手抖)
  ///   'dark'   — meanBrightness < darkThresholdBrightness  (光线不足)
  ///   'bright' — meanBrightness > brightThresholdBrightness (过曝)
  /// Null when no hard reject fired this frame. Capture-page UI shows
  /// a 3 s fading toast keyed on these values; the existing `hintText`
  /// stays as the long-form guidance line. Priority when multiple gates
  /// hit the same frame: blur > dark > bright (blur is most actionable).
  final String? hardRejectKind;

  const GuidanceSnapshot({
    required this.acceptedFrames,
    required this.orbitCompletion,
    required this.hintText,
    required this.stabilityScore,
    this.lastAcceptedTimestamp,
    this.hardRejectKind,
  });

  static const GuidanceSnapshot idle = GuidanceSnapshot(
    acceptedFrames: 0,
    orbitCompletion: 0,
    hintText: '将物体放在画面中央，开始后沿着主体缓慢绕一圈。',
    stabilityScore: 1,
  );
}

class GuidanceAuditSummary {
  int totalSamples;
  int hardRejectBlurCount;
  int hardRejectDarkCount;
  int hardRejectBrightCount;
  int hardRejectOccupancyCount;
  int softDowngradeRedundantCount;
  int softDowngradeLowTextureCount;
  int softDowngradeWeakQualityCount;
  int guidanceRecenterCount;
  int guidanceNewAngleCount;
  int guidanceCoverageCount;

  GuidanceAuditSummary({
    this.totalSamples = 0,
    this.hardRejectBlurCount = 0,
    this.hardRejectDarkCount = 0,
    this.hardRejectBrightCount = 0,
    this.hardRejectOccupancyCount = 0,
    this.softDowngradeRedundantCount = 0,
    this.softDowngradeLowTextureCount = 0,
    this.softDowngradeWeakQualityCount = 0,
    this.guidanceRecenterCount = 0,
    this.guidanceNewAngleCount = 0,
    this.guidanceCoverageCount = 0,
  });

  void reset() {
    totalSamples = 0;
    hardRejectBlurCount = 0;
    hardRejectDarkCount = 0;
    hardRejectBrightCount = 0;
    hardRejectOccupancyCount = 0;
    softDowngradeRedundantCount = 0;
    softDowngradeLowTextureCount = 0;
    softDowngradeWeakQualityCount = 0;
    guidanceRecenterCount = 0;
    guidanceNewAngleCount = 0;
    guidanceCoverageCount = 0;
  }
}

class VisualFrameSample {
  final double timestamp;
  final int signatureWidth;
  final int signatureHeight;
  final Uint8List signature;
  final double laplacianVariance;
  final double meanBrightness;
  final double globalVariance;

  const VisualFrameSample({
    required this.timestamp,
    required this.signatureWidth,
    required this.signatureHeight,
    required this.signature,
    required this.laplacianVariance,
    required this.meanBrightness,
    required this.globalVariance,
  });
}

class _TargetZoneMetrics {
  final double textureScore;
  final double contrastScore;
  const _TargetZoneMetrics(this.textureScore, this.contrastScore);
}

class GuidanceEngine {
  static const int _maxAcceptedFrames = 150;
  static const double _hardRejectTargetSignalThreshold = 0.10;
  static const double _softWarnTargetSignalThreshold = 0.16;

  void Function(GuidanceSnapshot)? onUpdate;

  GuidanceSnapshot _snapshot = GuidanceSnapshot.idle;
  DateTime? _recordingStartedAt;
  double? _lastAcceptedAt;
  Uint8List _lastAcceptedSignature = Uint8List(0);
  double _coverageCredits = 0;
  double _smoothedQuality = 0;
  final GuidanceAuditSummary _auditSummary = GuidanceAuditSummary();

  GuidanceAuditSummary get auditSummary => _auditSummary;
  GuidanceSnapshot get snapshot => _snapshot;

  void startMonitoring() => _publish(_snapshot);

  void stopMonitoring() {}

  void beginRecording() {
    _recordingStartedAt = DateTime.now();
    _lastAcceptedAt = null;
    _lastAcceptedSignature = Uint8List(0);
    _coverageCredits = 0;
    _smoothedQuality = 0;
    _auditSummary.reset();
    _publish(
      const GuidanceSnapshot(
        acceptedFrames: 0,
        orbitCompletion: 0,
        hintText: '很好，开始缓慢绕主体移动，系统会自动挑选有效帧。',
        stabilityScore: 1,
      ),
    );
  }

  void endRecording() {
    _recordingStartedAt = null;
    _publish(_snapshot);
  }

  /// Flat key/value payload that mirrors the Swift `pipelineAuditFields`
  /// output. Meant to be merged into the broker's job-start payload so
  /// the cloud can cross-check the client's live audit against the
  /// server-side audit.
  Map<String, String> pipelineAuditFields({
    required Offset targetZoneAnchor,
    required TargetZoneMode targetZoneMode,
  }) {
    return {
      'visual_policy_version': 'v2_unified_capture_audit',
      'visual_min_target_signal': _hardRejectTargetSignalThreshold
          .toStringAsFixed(4),
      'visual_warn_target_signal': _softWarnTargetSignalThreshold
          .toStringAsFixed(4),
      'visual_min_orb_features':
          '${FrameQualityConstants.minOrbFeaturesForSfm}',
      'visual_warn_orb_features':
          '${FrameQualityConstants.warnOrbFeaturesForSfm}',
      'target_zone_anchor_x': targetZoneAnchor.dx.toStringAsFixed(4),
      'target_zone_anchor_y': targetZoneAnchor.dy.toStringAsFixed(4),
      'target_zone_mode_runtime': targetZoneMode.rawValue,
      'client_live_total_samples': '${_auditSummary.totalSamples}',
      'client_live_hard_reject_blur_count':
          '${_auditSummary.hardRejectBlurCount}',
      'client_live_hard_reject_dark_count':
          '${_auditSummary.hardRejectDarkCount}',
      'client_live_hard_reject_bright_count':
          '${_auditSummary.hardRejectBrightCount}',
      'client_live_hard_reject_occupancy_count':
          '${_auditSummary.hardRejectOccupancyCount}',
      'client_live_soft_redundant_count':
          '${_auditSummary.softDowngradeRedundantCount}',
      'client_live_soft_low_texture_count':
          '${_auditSummary.softDowngradeLowTextureCount}',
      'client_live_soft_weak_quality_count':
          '${_auditSummary.softDowngradeWeakQualityCount}',
      'client_live_guidance_recenter_count':
          '${_auditSummary.guidanceRecenterCount}',
      'client_live_guidance_new_angle_count':
          '${_auditSummary.guidanceNewAngleCount}',
      'client_live_guidance_coverage_count':
          '${_auditSummary.guidanceCoverageCount}',
    };
  }

  /// Per-frame processing. Consumed at the camera-stream rate
  /// (≈ 6 Hz after the outer CaptureSession throttle).
  void processVisualSample(
    VisualFrameSample sample, {
    required Offset targetZoneAnchor,
    required TargetZoneMode targetZoneMode,
  }) {
    final startedAt = _recordingStartedAt;
    if (startedAt == null) return;

    final targetMetrics = _targetZoneMetrics(
      sample,
      anchor: targetZoneAnchor,
      mode: targetZoneMode,
    );
    final sharpnessScore = _clamp01(
      sample.laplacianVariance /
          (FrameQualityConstants.blurThresholdLaplacian * 1.35),
    );
    final brightnessScore = _normalizedBrightnessScore(sample.meanBrightness);
    final occupancyScore = _clamp01(
      targetMetrics.textureScore * 0.55 + targetMetrics.contrastScore * 0.45,
    );
    final noveltyScore = _novelty(
      current: sample.signature,
      previous: _lastAcceptedSignature,
    );
    final similarityScore = _clamp01(1 - noveltyScore);
    final targetSignal =
        targetMetrics.textureScore * 0.55 + targetMetrics.contrastScore * 0.45;
    final qualityScore = _clamp01(
      sharpnessScore * 0.58 + brightnessScore * 0.18 + occupancyScore * 0.24,
    );
    _smoothedQuality = _smoothedQuality == 0
        ? qualityScore
        : _smoothedQuality * 0.72 + qualityScore * 0.28;

    final now = sample.timestamp;
    final recordingAge =
        DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
    final enoughTimePassed = _lastAcceptedAt == null
        ? true
        : (now - _lastAcceptedAt!) > 0.28;
    final qualityThreshold = _acceptanceThreshold(_snapshot.acceptedFrames);
    final maxSimilarity = _maximumSimilarity(targetZoneMode);
    final lowTexture =
        sample.globalVariance <
        FrameQualityConstants.minLocalVarianceForTexture;

    int accepted = _snapshot.acceptedFrames;
    bool acceptedNew = false;
    _auditSummary.totalSamples += 1;

    // Plan G W2 P3: capture which HARD reject gate this frame tripped
    // (if any) so the UI can show a 3 s toast hint. Priority blur >
    // dark > bright since blur is most actionable to the user.
    String? hardRejectKindLocal;
    if (sample.laplacianVariance <
        FrameQualityConstants.blurThresholdLaplacian) {
      _auditSummary.hardRejectBlurCount += 1;
      hardRejectKindLocal ??= 'blur';
    }
    if (sample.meanBrightness < FrameQualityConstants.darkThresholdBrightness) {
      _auditSummary.hardRejectDarkCount += 1;
      hardRejectKindLocal ??= 'dark';
    }
    if (sample.meanBrightness >
        FrameQualityConstants.brightThresholdBrightness) {
      _auditSummary.hardRejectBrightCount += 1;
      hardRejectKindLocal ??= 'bright';
    }
    if (targetSignal < _hardRejectTargetSignalThreshold) {
      _auditSummary.hardRejectOccupancyCount += 1;
    }
    if (similarityScore > maxSimilarity) {
      _auditSummary.softDowngradeRedundantCount += 1;
      _auditSummary.guidanceNewAngleCount += 1;
    }
    if (lowTexture) {
      _auditSummary.softDowngradeLowTextureCount += 1;
    }
    if (qualityScore < qualityThreshold) {
      _auditSummary.softDowngradeWeakQualityCount += 1;
    }
    if (targetSignal < _softWarnTargetSignalThreshold) {
      _auditSummary.guidanceRecenterCount += 1;
    }
    if (_orbitCompletionHint(accepted, _coverageCredits) < 0.70) {
      _auditSummary.guidanceCoverageCount += 1;
    }

    if (accepted == 0) {
      if (recordingAge > 0.35 &&
          sharpnessScore > 0.20 &&
          brightnessScore > 0.32 &&
          occupancyScore > 0.10) {
        accepted = 1;
        acceptedNew = true;
      }
    } else if (accepted < _maxAcceptedFrames &&
        enoughTimePassed &&
        sharpnessScore > 0.24 &&
        brightnessScore > 0.28 &&
        occupancyScore > 0.10 &&
        similarityScore <= maxSimilarity &&
        qualityScore >= qualityThreshold) {
      accepted += 1;
      acceptedNew = true;
    }

    if (acceptedNew) {
      _lastAcceptedAt = now;
      _lastAcceptedSignature = sample.signature;
      _coverageCredits = math.min(
        1,
        _coverageCredits + math.max(0.06, math.min(noveltyScore * 1.8, 0.16)),
      );
    }

    final orbitCompletion = _orbitCompletionHint(accepted, _coverageCredits);

    final String hintText;
    if (accepted >= _maxAcceptedFrames) {
      hintText = '已达到当前模式的关键帧上限，可以结束生成。';
    } else if (sharpnessScore < 0.22) {
      hintText = '画面有些模糊，放慢一点并稳住手机。';
    } else if (brightnessScore < 0.28) {
      hintText = '当前光线不太理想，尽量让主体更亮、更清楚。';
    } else if (occupancyScore < 0.12) {
      hintText = '让主体继续留在锁定目标区里，再补一个更明确的角度。';
    } else if (accepted == 0) {
      hintText = '已经开始取证，继续围绕主体缓慢移动，很快会挑到第一帧。';
    } else if (similarityScore > maxSimilarity) {
      hintText = '继续移动到新的角度，避免一直停在同一面。';
    } else if (orbitCompletion < 0.25) {
      hintText = '先补正面和侧面，保持主体始终在目标区附近。';
    } else if (orbitCompletion < 0.70) {
      hintText = '很好，继续补背面和边缘角度，尽量绕满一圈。';
    } else if (accepted < 20) {
      hintText = '快完成一圈了，再补一些新角度就能生成 HQ 成品。';
    } else if (accepted < 40) {
      hintText = '已经够做成品，继续补顶部和边缘细节会更稳。';
    } else {
      hintText = '质量已经不错，可以结束，也可以继续补更细节的角度。';
    }

    _publish(
      GuidanceSnapshot(
        acceptedFrames: accepted,
        orbitCompletion: orbitCompletion,
        hintText: hintText,
        stabilityScore: _smoothedQuality,
        lastAcceptedTimestamp: acceptedNew ? now : null,
        hardRejectKind: hardRejectKindLocal,
      ),
    );
  }

  // ─── Helpers (verbatim port) ───────────────────────────────────────

  double _clamp01(double v) => v.clamp(0.0, 1.0);

  double _acceptanceThreshold(int acceptedFrames) {
    if (acceptedFrames < 8) return 0.30;
    if (acceptedFrames < 20) return 0.36;
    return 0.42;
  }

  double _maximumSimilarity(TargetZoneMode targetZoneMode) {
    switch (targetZoneMode) {
      case TargetZoneMode.subject:
        return FrameQualityConstants.maxFrameSimilarity;
      case TargetZoneMode.group:
        return math.max(
          FrameQualityConstants.minFrameSimilarity,
          FrameQualityConstants.maxFrameSimilarity - 0.04,
        );
    }
  }

  double _orbitCompletionHint(int acceptedFrames, double coverageCredits) {
    return math.max(coverageCredits, math.min(acceptedFrames / 20.0, 1.0));
  }

  double _normalizedBrightnessScore(double brightness) {
    final dark = FrameQualityConstants.darkThresholdBrightness;
    final bright = FrameQualityConstants.brightThresholdBrightness;
    if (brightness < dark) {
      return math.max(0, brightness / dark);
    }
    if (brightness > bright) {
      final overflow = math.max(0, brightness - bright);
      return math.max(0, 1 - overflow / math.max(1, 255 - bright));
    }
    return 1;
  }

  double _novelty({required Uint8List current, required Uint8List previous}) {
    if (previous.isEmpty || previous.length != current.length) return 1.0;
    if (current.isEmpty) return 0.0;
    double difference = 0.0;
    for (int i = 0; i < current.length; i++) {
      difference += (current[i] - previous[i]).abs() / 255.0;
    }
    return difference / current.length;
  }

  _TargetZoneMetrics _targetZoneMetrics(
    VisualFrameSample sample, {
    required Offset anchor,
    required TargetZoneMode mode,
  }) {
    final pixels = sample.signature;
    final width = sample.signatureWidth;
    final height = sample.signatureHeight;
    if (width <= 4 || height <= 4 || pixels.length != width * height) {
      return const _TargetZoneMetrics(0, 0);
    }

    final zoneWidthFraction = mode == TargetZoneMode.subject ? 0.24 : 0.38;
    final zoneHeightFraction = mode == TargetZoneMode.subject ? 0.28 : 0.34;
    final rect = _normalizedRect(
      anchor: anchor,
      widthFraction: zoneWidthFraction,
      heightFraction: zoneHeightFraction,
      imageWidth: width,
      imageHeight: height,
    );
    final ringRect = _expandedRect(
      rect,
      padding: mode == TargetZoneMode.subject ? 3 : 4,
      maxWidth: width,
      maxHeight: height,
    );

    final zoneValues = _pixelValues(rect: rect, width: width, pixels: pixels);
    final ringValues = _pixelValues(
      rect: ringRect,
      width: width,
      pixels: pixels,
      excluding: rect,
    );

    final zoneVariance = _variance(zoneValues);
    final zoneMean = _mean(zoneValues);
    final ringMean = _mean(ringValues);

    final textureScore = math.min(zoneVariance / 420.0, 1.0);
    final contrastScore = math.min((zoneMean - ringMean).abs() / 28.0, 1.0);
    return _TargetZoneMetrics(textureScore, contrastScore);
  }

  Rect _normalizedRect({
    required Offset anchor,
    required double widthFraction,
    required double heightFraction,
    required int imageWidth,
    required int imageHeight,
  }) {
    final width = math.max(4, (imageWidth * widthFraction).round());
    final height = math.max(4, (imageHeight * heightFraction).round());
    final centerX = (anchor.dx * imageWidth).round();
    final centerY = (anchor.dy * imageHeight).round();
    final x = math.min(
      math.max(centerX - width ~/ 2, 0),
      math.max(imageWidth - width, 0),
    );
    final y = math.min(
      math.max(centerY - height ~/ 2, 0),
      math.max(imageHeight - height, 0),
    );
    return Rect.fromLTWH(
      x.toDouble(),
      y.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
  }

  Rect _expandedRect(
    Rect rect, {
    required int padding,
    required int maxWidth,
    required int maxHeight,
  }) {
    final x = math.max(rect.left.toInt() - padding, 0);
    final y = math.max(rect.top.toInt() - padding, 0);
    final maxX = math.min(rect.right.toInt() + padding, maxWidth);
    final maxY = math.min(rect.bottom.toInt() + padding, maxHeight);
    return Rect.fromLTWH(
      x.toDouble(),
      y.toDouble(),
      math.max(maxX - x, 1).toDouble(),
      math.max(maxY - y, 1).toDouble(),
    );
  }

  List<double> _pixelValues({
    required Rect rect,
    required int width,
    required Uint8List pixels,
    Rect? excluding,
  }) {
    final minX = rect.left.toInt();
    final maxX = rect.right.toInt();
    final minY = rect.top.toInt();
    final maxY = rect.bottom.toInt();
    final values = <double>[];
    for (int y = minY; y < maxY; y++) {
      for (int x = minX; x < maxX; x++) {
        if (excluding != null &&
            excluding.contains(Offset(x.toDouble(), y.toDouble()))) {
          continue;
        }
        final index = y * width + x;
        if (index < 0 || index >= pixels.length) continue;
        values.add(pixels[index].toDouble());
      }
    }
    return values;
  }

  double _mean(List<double> values) {
    if (values.isEmpty) return 0;
    double sum = 0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  double _variance(List<double> values) {
    if (values.length <= 1) return 0;
    final m = _mean(values);
    double sumSq = 0;
    for (final v in values) {
      final delta = v - m;
      sumSq += delta * delta;
    }
    return sumSq / values.length;
  }

  void _publish(GuidanceSnapshot s) {
    _snapshot = s;
    final cb = onUpdate;
    if (cb != null) cb(s);
  }
}
