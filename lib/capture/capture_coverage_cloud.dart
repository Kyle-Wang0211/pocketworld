// capture_coverage_cloud.dart — RS-style capture-coverage cloud POLICY.
//
// The product semantic (per RealityScan's capture UX): the colored cloud is
// what the algorithm has RECEIVED — it must be empty before the first
// shutter, grow only when photos are committed, and color each point by how
// many captured photos actually saw it (1 ≈ red/orange, 2-3 ≈ yellow,
// ≥5 ≈ green). Tracker persistence alone must never light anything up.
//
// Per the algorithm-executor boundary (ARFrameSaveSpec.dartOwns: "coverage
// logic"), ALL of that policy lives here in Dart — shared verbatim across
// iOS/Android/HarmonyOS. Platform executors only:
//   • feed VIO points (ARPose.previewPoints — already crossing on the pose
//     stream on iOS; ARCore/AREngine equivalents feed the same call), and
//   • render the packed xyz+rgb this class emits (iOS: the dumb
//     `setCoveragePointCloud` SceneKit executor).
//
// Data flow:
//   poseStream → [ingestPose]  — voxel-hash VIO points (position upkeep)
//   sfmFrameStream (per committed shutter, the SAME frame-exact
//   pose+intrinsics feed that drives streaming SfM) → [markCapture]
//   — frustum-test every voxel, bump its photo-coverage count → [packed]
//   → platform renderer.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' show Vector3;
import 'package:vector_math/vector_math_64.dart' as vm;

import '../dome/ar_pose.dart' show ARPose, SfmFrameFeed;

/// Packed render payload for the platform's dumb point renderer.
class CoverageCloudPacked {
  const CoverageCloudPacked(this.xyz, this.rgb);
  final Float32List xyz; // 3 floats per point, world space
  final Uint8List rgb; // 3 bytes per point
  int get count => xyz.length ~/ 3;
}

class _CoverageVoxel {
  _CoverageVoxel(this.position);
  Vector3 position; // refreshed by the tracker (ingestPose)
  int photoCoverage = 0; // bumped by markCapture — THE product signal
  int seen = 1; // tracker persistence, pruning tie-breaker only

  /// 首次被照片拍到时的视线方向(单位向量,相机中心→体素,世界系)。
  Vector3? firstViewDir;

  /// 历次观测视线与首观测视线的最大夹角(度)——该体素累计到的视差基线。
  /// 视差背景一句话:"双墙"真身=低视差深度噪声壳,视差角是厚/薄的判别因子。
  double maxParallaxDeg = 0;
}

class CaptureCoverageCloud {
  CaptureCoverageCloud({
    this.voxelSizeM = 0.04,
    this.maxVoxels = 6000,
    this.coverageSaturation = 5,
    this.parallaxMinDeg = 8.0,
  });

  /// Single-scale voxel edge — coarse enough to stay cheap, fine enough to
  /// read as a surface fog (RS-like density).
  final double voxelSizeM;
  final int maxVoxels;

  /// Photos needed for full "green".
  final int coverageSaturation;

  /// 转绿所需的最小视差角(度)。观测次数达标但 maxParallaxDeg 低于此值的
  /// 体素停在黄色——纯计数会把"原地连拍"误报成绿,而低视差正是"双墙"
  /// (深度噪声壳)的成因。阈值 8°:真机实测厚区(双墙壳)5.2° vs 薄区
  /// (干净表面)11.4°,取中偏严。
  final double parallaxMinDeg;

  final Map<int, _CoverageVoxel> _voxels = <int, _CoverageVoxel>{};
  int _capturesMarked = 0;

  int get capturesMarked => _capturesMarked;
  int get coveredVoxelCount =>
      _voxels.values.where((v) => v.photoCoverage > 0).length;

  int _key(Vector3 p) {
    final x = (p.x / voxelSizeM).floor();
    final y = (p.y / voxelSizeM).floor();
    final z = (p.z / voxelSizeM).floor();
    // 21-bit lanes, offset to keep negatives in range (±1,048,576 voxels
    // ≈ ±42 km at 4 cm — far beyond any capture volume).
    return ((x + 0x100000) << 42) |
        ((y + 0x100000) << 21) |
        (z + 0x100000);
  }

  /// Tracker tick: keep voxel positions fresh. Never lights anything up.
  void ingestPose(ARPose pose) {
    if (pose.previewPoints.isEmpty) return;
    for (final point in pose.previewPoints) {
      final k = _key(point.position);
      final v = _voxels[k];
      if (v != null) {
        v.position = point.position.clone();
        v.seen = math.min(v.seen + 1, 60);
      } else {
        _voxels[k] = _CoverageVoxel(point.position.clone());
      }
    }
    if (_voxels.length > maxVoxels) {
      // Covered voxels are the product signal — evict uncovered,
      // least-tracked ones first.
      final entries = _voxels.entries.toList()
        ..sort((a, b) {
          final c = b.value.photoCoverage.compareTo(a.value.photoCoverage);
          if (c != 0) return c;
          return b.value.seen.compareTo(a.value.seen);
        });
      _voxels
        ..clear()
        ..addEntries(entries.take(maxVoxels));
    }
  }

  /// One committed shutter = one coverage pass: project every voxel into the
  /// captured frame (frame-exact camera-to-world + full-res intrinsics from
  /// the SfmFrameFeed) and bump the ones the photo saw. Returns true when
  /// any voxel's coverage changed (i.e. the render payload is stale).
  bool markCapture(SfmFrameFeed feed) {
    if (feed.extrinsic4x4.length != 16 ||
        feed.intrinsicFxFyCxCy.length < 4 ||
        feed.imageW <= 0 ||
        feed.imageH <= 0) {
      return false;
    }
    final c2w = vm.Matrix4.fromList(feed.extrinsic4x4);
    final rW2c = c2w.getRotation()..transpose();
    final tC2w = c2w.getTranslation();
    final fx = feed.intrinsicFxFyCxCy[0];
    final fy = feed.intrinsicFxFyCxCy[1];
    final cx = feed.intrinsicFxFyCxCy[2];
    final cy = feed.intrinsicFxFyCxCy[3];
    final w = feed.imageW.toDouble();
    final h = feed.imageH.toDouble();

    var changed = false;
    for (final v in _voxels.values) {
      // Camera space (ARKit convention: -z forward, +y up).
      final pc = rW2c.transform(v.position - tC2w);
      final depth = -pc.z;
      if (depth < 0.05 || depth > 40) continue;
      // Image pixels: origin top-left, +y down → flip camera-space y.
      final u = fx * (pc.x / depth) + cx;
      final vpx = fy * (-pc.y / depth) + cy;
      if (u < 0 || u >= w || vpx < 0 || vpx >= h) continue;
      // 视差累计:记录首观测视线(相机中心→体素,世界系单位向量),此后
      // 每次命中都用当前视线与首视线的夹角刷新 maxParallaxDeg。
      final viewDir = v.position - tC2w;
      final viewLen = viewDir.length;
      if (viewLen > 1e-6) {
        viewDir.scale(1.0 / viewLen);
        final first = v.firstViewDir;
        if (first == null) {
          v.firstViewDir = viewDir;
        } else {
          final cosAng = first.dot(viewDir).clamp(-1.0, 1.0);
          final angDeg = math.acos(cosAng) * 180.0 / math.pi;
          if (angDeg > v.maxParallaxDeg) v.maxParallaxDeg = angDeg;
        }
      }
      v.photoCoverage++;
      changed = true;
    }
    _capturesMarked++;
    return changed;
  }

  /// Packs only photo-covered voxels (0 captures ⇒ empty payload ⇒ the
  /// renderer clears). Ramp: 1 photo → red/orange, 2-3 → yellow,
  /// ≥[coverageSaturation] → green.
  ///
  /// 低视差压黄策略(信号1):观测次数达标但 maxParallaxDeg <
  /// [parallaxMinDeg] 的体素把 ramp 参数封在 0.5(纯黄),不给绿——
  /// 二进制布局(xyz 3×f32 + rgb 3×u8,逐点同序)绝不改变,只改颜色值。
  CoverageCloudPacked packed() {
    final covered =
        _voxels.values.where((v) => v.photoCoverage > 0).toList();
    final xyz = Float32List(covered.length * 3);
    final rgb = Uint8List(covered.length * 3);
    for (var i = 0; i < covered.length; i++) {
      final v = covered[i];
      final o = i * 3;
      xyz[o] = v.position.x;
      xyz[o + 1] = v.position.y;
      xyz[o + 2] = v.position.z;
      var t = math.min(v.photoCoverage / coverageSaturation, 1.0);
      // 低视差不给绿:停在黄(t=0.5)。低视差=深度噪声壳("双墙")高危区。
      if (t > 0.5 && v.maxParallaxDeg < parallaxMinDeg) t = 0.5;
      final r = t < 0.5 ? 1.0 : (1.0 - (t - 0.5) * 2.0);
      final g = t < 0.5 ? (t * 2.0) : 1.0;
      rgb[o] = (r * 255).round();
      rgb[o + 1] = (g * 255).round();
      rgb[o + 2] = 20;
    }
    return CoverageCloudPacked(xyz, rgb);
  }

  /// UI 访问器(信号1):查询 [worldPos] 所在体素累计到的最大视差角(度)。
  /// 该位置没有体素、或还没被任何照片拍到时返回 null。
  double? parallaxDegAt(Vector3 worldPos) {
    final v = _voxels[_key(worldPos)];
    if (v == null || v.photoCoverage == 0) return null;
    return v.maxParallaxDeg;
  }

  /// UI 访问器(信号1):观测次数已达标(≥[coverageSaturation])但视差
  /// 不足(<[parallaxMinDeg])而被压在黄色的体素数。>0 时 UI 应提示
  /// "换角度再拍此区域"(RS 式引导)。
  int get parallaxStarvedVoxelCount => _voxels.values
      .where((v) =>
          v.photoCoverage >= coverageSaturation &&
          v.maxParallaxDeg < parallaxMinDeg)
      .length;

  void reset() {
    _voxels.clear();
    _capturesMarked = 0;
  }
}
