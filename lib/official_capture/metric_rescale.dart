// metric_rescale.dart — 整体等比缩放(「量一段已知距离 ⇒ 全局重定尺」)机制层。
//
// 纯 Dart(dart:math + dart:typed_data + 一个零 Flutter 依赖的 VIO 质量类型),
// **无 UI、不接任何现有输出路径**。UX 由产品负责人定;本文件只提供机制、
// 契约与可测性。
//
// ── 为什么需要它 ────────────────────────────────────────────────────────
// 单目 VIO(XRSLAM / RD-VIO)的绝对尺度在不同录制上对 ARKit 差 0.2%–19%
// (2026-09-22 三场验收台架实测:0.22% / 5.21% / 17.85%),跨场不稳。产品
// 负责人定的容差是「估算型,真实尺寸 ±5%」,VIO 单独扛不住。
// 全行业在 VIO/SfM 之外的兜底是同一招:**让用户量一段已知距离,整体等比
// 缩放**(Polycam Rescale、KIRI Engine、RealityCapture 的 define distance、
// Agisoft Metashape 的 scale bar)。本文件就是那一招的机制部分。
// 永远不用 LiDAR。
//
// ── 语义出处:Open3D(MIT),不自研 ──────────────────────────────────────
// 缩放语义逐字照抄 Open3D `Geometry3D::ScalePoints`:
//     https://github.com/isl-org/Open3D/blob/main/cpp/open3d/geometry/Geometry3D.cpp
//     (ScalePoints,约 79-83 行)
//     void Geometry3D::ScalePoints(const double scale,
//                                  std::vector<Eigen::Vector3d>& points,
//                                  const Eigen::Vector3d& center) const {
//         for (auto& point : points) {
//             point = (point - center) * scale + center;
//         }
//     }
// Python 侧对应 `open3d.geometry.PointCloud.scale(scale, center)`:
//     https://www.open3d.org/docs/release/python_api/open3d.geometry.PointCloud.html
// 也就是说 center **必须显式给**,Open3D 不替调用方猜(常见取值是
// `get_center()` 或原点)。本文件保持同一约定:[center] 默认原点,而原点
// 正是本仓既有 [scaleAnchoredPoints] 的隐含 center —— 两者可直接串联。
// 许可:Open3D 为 MIT,可商用。
//
// ── 位姿怎么跟着走 ──────────────────────────────────────────────────────
// 相似变换、旋转不变。世界点 x' = s(x−c)+c;相机中心随之 C' = s(C−c)+c。
// COLMAP CamFromWorld 约定 p_cam = R·x + t、C = −Rᵀt,于是
//     R' = R,  t' = −R·C' = s·t + (s−1)·R·c
// c = 0 时退化为 t' = s·t —— 与本仓既有 [scaleAnchoredPosesPacked] 逐字一致
// (gravity_align.dart:329-341),所以这里是它的 center 推广版,不是替代品。
//
// ── provenance:为什么缩放必须留痕 ──────────────────────────────────────
// 抄两个建筑测量标准的**声明制**思想(抄思想,不抄文本):
//   * USIBD, "Level of Accuracy (LOA) Specification Guide"(C120):区分
//     **Measured Accuracy**(实地量到的)与 **Represented Accuracy**(模型里
//     画出来的),要求交付物写明两者及其来源。
//     https://usibd.org/
//   * ANSI Z765(Square Footage — Method for Calculating):面积必须声明
//     所用方法,数字本身不构成结论。
//     https://www.homeinnovation.com/services/standards/ansi_z765
// 对我们的含义:用户输入的那一段距离既是**输入**也是**唯一的米制权威**,
// 缩放后整个模型的尺寸都由它背书。所以 s 从哪来、量的是哪两点、量之前
// VIO 自己觉得尺度可不可信,必须随模型一起落盘 —— 否则事后无法回答
// 「这个 1.73 m 是谁说的」。[MetricRescaleProvenanceV1] 就是这条记录。
//
// 🔴 本文件不判断「准不准」。它只忠实记录「按谁的话缩的」。

import 'dart:math' as math;
import 'dart:typed_data';

import '../vio/quality/scale_observability.dart'
    show ScaleObservabilitySample;

/// provenance 记录的结构版本。改字段语义必须进号,否则旧盘上的记录会被
/// 新代码按新含义读。
const int kMetricRescaleProvenanceSchemaVersion = 1;

/// s 相对 1 的最大允许偏离。超过就**拒绝**,不静默施加。
///
/// 取 0.50(±50%)而不是 ±5%:±5% 是**交付容差**,而本函数是**修复手段**——
/// 用户来量尺寸,正是因为 VIO 已经偏了。既有 SCALE-ANCHOR 臂的带外门是 15%
/// (gravity_align.dart:`reasonOutOfBand`),那是「ARKit 自动估的 s,可疑就
/// 别用」;这里是用户亲手量的,权威更高,所以门放宽 —— 但仍要有门:>50%
/// 几乎只能是**单位搞错**(厘米当米、英寸当米)或点选错,让它静默通过会
/// 把一个录入错误变成整模型的永久损坏。
const double kMetricRescaleMaxRelativeDeviation = 0.50;

/// s 的来源。目前只有一种;留成枚举是因为 provenance 的读方要能分辨
/// 「用户量的」和日后可能出现的「标定物自动识别的」。
enum MetricRescaleSource {
  /// 用户在 UI 上选两点、手输真实距离。
  userEnteredDistance,
}

/// 缩放被拒。`code` 是稳定的机器可读标识,调用方按它分支;`message` 只给人看。
class MetricRescaleException implements Exception {
  const MetricRescaleException(this.code, this.message, {this.value});

  /// 点缓冲区长度不是 3 的倍数。
  static const String malformedPointBuffer = 'malformed_point_buffer';

  /// 位姿缓冲区长度不是 9 的倍数。
  static const String malformedPosesBuffer = 'malformed_poses_buffer';

  /// 两点索引越界。
  static const String pointIndexOutOfRange = 'point_index_out_of_range';

  /// 点坐标不是 3 个分量,或含非有限值。
  static const String malformedAnchorPoint = 'malformed_anchor_point';

  /// center 不是 3 个分量,或含非有限值。
  static const String malformedCenter = 'malformed_center';

  /// 用户输入的真实距离 ≤ 0 或非有限。
  static const String invalidRealDistance = 'invalid_real_distance';

  /// 两点在模型里几乎重合 —— 量得的距离 ≤ 0 或非有限,s 无定义。
  static const String degenerateMeasuredDistance = 'degenerate_measured_distance';

  /// s 非有限(NaN / ±Inf)。
  static const String nonFiniteScale = 'non_finite_scale';

  /// s ≤ 0。
  static const String nonPositiveScale = 'non_positive_scale';

  /// |s − 1| 超过 [kMetricRescaleMaxRelativeDeviation]。
  static const String scaleOutOfBand = 'scale_out_of_band';

  final String code;
  final String message;

  /// 触发拒绝的那个数(s、距离……),便于上报时带证据。可能为 null。
  final double? value;

  @override
  String toString() => 'MetricRescaleException($code): $message'
      '${value == null ? '' : ' [value=$value]'}';
}

/// 一次整体等比缩放的完整来源记录。**跟着模型一起落盘。**
class MetricRescaleProvenanceV1 {
  const MetricRescaleProvenanceV1({
    required this.scaleFactor,
    required this.source,
    required this.anchorPointA,
    required this.anchorPointB,
    required this.center,
    required this.measuredDistance,
    required this.realDistance,
    required this.pointCount,
    required this.poseCount,
    required this.timestampUtc,
    required this.vioScaleVerdict,
    required this.vioRelativeScaleSigma,
    required this.vioSampleTSec,
  });

  int get schemaVersion => kMetricRescaleProvenanceSchemaVersion;

  /// s = 真实距离 / 量得距离。
  final double scaleFactor;

  final MetricRescaleSource source;

  /// **缩放前**的两点坐标(模型坐标系)。记缩放前是因为它们和
  /// [measuredDistance] 必须自洽:‖A−B‖ == measuredDistance。
  final List<double> anchorPointA;
  final List<double> anchorPointB;

  /// Open3D 语义里的 center。原点为 `[0,0,0]`。
  final List<double> center;

  /// 缩放前模型里量到的两点距离(模型单位)。
  final double measuredDistance;

  /// 用户输入的真实距离(米)。
  final double realDistance;

  final int pointCount;
  final int poseCount;

  /// UTC。落盘用 ISO8601。
  final DateTime timestampUtc;

  /// 缩放**之前** VIO 自己对尺度的可信度结论
  /// ([ScaleObservabilityVerdict] 的 name)。调用方没喂则为 null。
  ///
  /// 为什么要记:如果 VIO 当时自评 `sufficient` 而用户仍然量出了 20% 的
  /// 修正,那要么用户量错了,要么我们的可观测性判据在撒谎 —— 两种都必须
  /// 能事后查出来。
  final String? vioScaleVerdict;

  /// 同上,σ_s/s。匀速段为 [double.infinity]。
  final double? vioRelativeScaleSigma;

  /// 该 VIO 结论的会话内时刻(秒)。
  final double? vioSampleTSec;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': schemaVersion,
    'scale_factor': scaleFactor,
    'source': source.name,
    'anchor_point_a': anchorPointA,
    'anchor_point_b': anchorPointB,
    'center': center,
    'measured_distance': measuredDistance,
    'real_distance': realDistance,
    'point_count': pointCount,
    'pose_count': poseCount,
    'timestamp_utc': timestampUtc.toUtc().toIso8601String(),
    'vio_scale_verdict': vioScaleVerdict,
    'vio_relative_scale_sigma': _jsonNum(vioRelativeScaleSigma),
    'vio_sample_t_sec': vioSampleTSec,
  };

  /// JSON 不认 Infinity/NaN。匀速段的 σ 正是 Infinity,不能丢,转成字符串。
  static Object? _jsonNum(double? v) {
    if (v == null) return null;
    if (v.isFinite) return v;
    return v.isNaN ? 'nan' : (v.isNegative ? '-inf' : 'inf');
  }
}

/// 缩放结果:新几何 + 来源记录。输入缓冲区**不被修改**(返回新副本,
/// 与 [scaleAnchoredPoints] 的既有约定一致)。
class MetricRescaleResult {
  const MetricRescaleResult({
    required this.xyz,
    required this.posesPacked,
    required this.provenance,
  });

  /// 缩放后的点(3 float/点)。
  final Float32List xyz;

  /// 缩放后的位姿(9 double/帧;调用方没给位姿则为 null)。
  final Float64List? posesPacked;

  final MetricRescaleProvenanceV1 provenance;
}

/// 两点之间的欧氏距离。
double _distance(List<double> a, List<double> b) => math.sqrt(
  math.pow(a[0] - b[0], 2) +
      math.pow(a[1] - b[1], 2) +
      math.pow(a[2] - b[2], 2),
).toDouble();

void _requireXyzTriple(List<double> p, String what) {
  if (p.length != 3) {
    throw MetricRescaleException(
      MetricRescaleException.malformedAnchorPoint,
      '$what 必须是 3 个分量,实际 ${p.length} 个',
    );
  }
  for (final v in p) {
    if (!v.isFinite) {
      throw MetricRescaleException(
        MetricRescaleException.malformedAnchorPoint,
        '$what 含非有限分量',
        value: v,
      );
    }
  }
}

/// 从点云里按索引取第 [index] 个点的坐标。
List<double> anchorPointAt(Float32List xyz, int index) {
  if (xyz.length % 3 != 0) {
    throw const MetricRescaleException(
      MetricRescaleException.malformedPointBuffer,
      '点缓冲区长度不是 3 的倍数',
    );
  }
  final count = xyz.length ~/ 3;
  if (index < 0 || index >= count) {
    throw MetricRescaleException(
      MetricRescaleException.pointIndexOutOfRange,
      '点索引 $index 越界(共 $count 点)',
      value: index.toDouble(),
    );
  }
  return <double>[xyz[index * 3], xyz[index * 3 + 1], xyz[index * 3 + 2]];
}

/// 用户量了一段已知距离 ⇒ 整体等比缩放。
///
/// s = [realDistanceMeters] / ‖[pointA] − [pointB]‖,然后按 Open3D
/// `ScalePoints` 语义 x' = s(x−center)+center 作用到点上,按
/// t' = s·t + (s−1)·R·center 作用到位姿平移上(R 不动)。
///
/// 抛 [MetricRescaleException]:输入畸形、真实距离非法、两点重合、
/// s 非有限 / ≤0 / 偏离 1 超过 [maxRelativeDeviation]。
MetricRescaleResult rescaleToKnownDistance({
  required Float32List xyz,
  required List<double> pointA,
  required List<double> pointB,
  required double realDistanceMeters,
  Float64List? posesPacked,
  List<double>? center,
  ScaleObservabilitySample? vioScaleConfidence,
  DateTime? timestampUtc,
  double maxRelativeDeviation = kMetricRescaleMaxRelativeDeviation,
}) {
  if (xyz.length % 3 != 0) {
    throw const MetricRescaleException(
      MetricRescaleException.malformedPointBuffer,
      '点缓冲区长度不是 3 的倍数',
    );
  }
  if (posesPacked != null && posesPacked.length % 9 != 0) {
    throw const MetricRescaleException(
      MetricRescaleException.malformedPosesBuffer,
      '位姿缓冲区长度不是 9 的倍数',
    );
  }
  _requireXyzTriple(pointA, 'pointA');
  _requireXyzTriple(pointB, 'pointB');

  final c = center ?? const <double>[0.0, 0.0, 0.0];
  if (c.length != 3 || c.any((v) => !v.isFinite)) {
    throw const MetricRescaleException(
      MetricRescaleException.malformedCenter,
      'center 必须是 3 个有限分量',
    );
  }

  if (!realDistanceMeters.isFinite || realDistanceMeters <= 0.0) {
    throw MetricRescaleException(
      MetricRescaleException.invalidRealDistance,
      '用户输入的真实距离必须是有限正数',
      value: realDistanceMeters,
    );
  }

  final measured = _distance(pointA, pointB);
  if (!measured.isFinite || measured <= 0.0) {
    throw MetricRescaleException(
      MetricRescaleException.degenerateMeasuredDistance,
      '两点在模型里重合,量得距离为 $measured,尺度无定义',
      value: measured,
    );
  }

  final s = realDistanceMeters / measured;
  if (!s.isFinite) {
    throw MetricRescaleException(
      MetricRescaleException.nonFiniteScale,
      '解出的尺度因子非有限',
      value: s,
    );
  }
  if (s <= 0.0) {
    throw MetricRescaleException(
      MetricRescaleException.nonPositiveScale,
      '解出的尺度因子 ≤ 0',
      value: s,
    );
  }
  if ((s - 1.0).abs() > maxRelativeDeviation) {
    throw MetricRescaleException(
      MetricRescaleException.scaleOutOfBand,
      '尺度因子 $s 偏离 1 超过 '
      '${(maxRelativeDeviation * 100).toStringAsFixed(0)}% —— '
      '多半是单位搞错或点选错,拒绝施加',
      value: s,
    );
  }

  return MetricRescaleResult(
    xyz: scalePointsAbout(xyz, s, c),
    posesPacked: posesPacked == null
        ? null
        : scalePosesPackedAbout(posesPacked, s, c),
    provenance: MetricRescaleProvenanceV1(
      scaleFactor: s,
      source: MetricRescaleSource.userEnteredDistance,
      anchorPointA: List<double>.unmodifiable(pointA),
      anchorPointB: List<double>.unmodifiable(pointB),
      center: List<double>.unmodifiable(c),
      measuredDistance: measured,
      realDistance: realDistanceMeters,
      pointCount: xyz.length ~/ 3,
      poseCount: posesPacked == null ? 0 : posesPacked.length ~/ 9,
      timestampUtc: (timestampUtc ?? DateTime.now()).toUtc(),
      vioScaleVerdict: vioScaleConfidence?.verdict.name,
      vioRelativeScaleSigma: vioScaleConfidence?.relativeScaleSigma,
      vioSampleTSec: vioScaleConfidence?.tSec,
    ),
  );
}

/// [rescaleToKnownDistance] 的「两点索引」入口 —— UI 上点中的是点云里的点,
/// 拿到的自然是索引而不是坐标。
MetricRescaleResult rescaleToKnownDistanceByIndex({
  required Float32List xyz,
  required int indexA,
  required int indexB,
  required double realDistanceMeters,
  Float64List? posesPacked,
  List<double>? center,
  ScaleObservabilitySample? vioScaleConfidence,
  DateTime? timestampUtc,
  double maxRelativeDeviation = kMetricRescaleMaxRelativeDeviation,
}) => rescaleToKnownDistance(
  xyz: xyz,
  pointA: anchorPointAt(xyz, indexA),
  pointB: anchorPointAt(xyz, indexB),
  realDistanceMeters: realDistanceMeters,
  posesPacked: posesPacked,
  center: center,
  vioScaleConfidence: vioScaleConfidence,
  timestampUtc: timestampUtc,
  maxRelativeDeviation: maxRelativeDeviation,
);

/// Open3D `Geometry3D::ScalePoints` 的逐字移植:x' = (x − center)·s + center。
///
/// center == 原点时与本仓既有 `scaleAnchoredPoints(xyz, s)`
/// (gravity_align.dart:343)数值等价。
Float32List scalePointsAbout(Float32List xyz, double s, List<double> center) {
  final cx = center[0], cy = center[1], cz = center[2];
  final out = Float32List(xyz.length);
  for (var i = 0; i < xyz.length; i += 3) {
    out[i] = (xyz[i] - cx) * s + cx;
    out[i + 1] = (xyz[i + 1] - cy) * s + cy;
    out[i + 2] = (xyz[i + 2] - cz) * s + cz;
  }
  return out;
}

/// 相似变换作用到 CamFromWorld 位姿:R 不动,t' = s·t + (s−1)·R·center。
///
/// 推导见文件头。center == 原点时退化成 t' = s·t,与既有
/// `scaleAnchoredPosesPacked`(gravity_align.dart:331)逐字一致。
/// 未注册帧(`packed[i+1] == 0`)原样透传 —— 同既有契约。
///
/// 布局(同 SfmLiveSnapshot.posesPacked,9 double/帧):
///   [0] frameId, [1] registered, [2..5] 四元数 wxyz(CamFromWorld), [6..8] t
Float64List scalePosesPackedAbout(
  Float64List posesPacked,
  double s,
  List<double> center,
) {
  final cx = center[0], cy = center[1], cz = center[2];
  final out = Float64List.fromList(posesPacked);
  final atOrigin = cx == 0.0 && cy == 0.0 && cz == 0.0;
  for (var i = 0; i < out.length; i += 9) {
    if (out[i + 1] == 0) continue; // unregistered: leave verbatim
    if (atOrigin) {
      out[i + 6] *= s;
      out[i + 7] *= s;
      out[i + 8] *= s;
      continue;
    }
    final w = out[i + 2], x = out[i + 3], y = out[i + 4], z = out[i + 5];
    // R·center,R 由 wxyz 给出(与 rotatePointsByQuatWxyz 同一展开)。
    final r00 = 1 - 2 * (y * y + z * z),
        r01 = 2 * (x * y - z * w),
        r02 = 2 * (x * z + y * w);
    final r10 = 2 * (x * y + z * w),
        r11 = 1 - 2 * (x * x + z * z),
        r12 = 2 * (y * z - x * w);
    final r20 = 2 * (x * z - y * w),
        r21 = 2 * (y * z + x * w),
        r22 = 1 - 2 * (x * x + y * y);
    final rcx = r00 * cx + r01 * cy + r02 * cz;
    final rcy = r10 * cx + r11 * cy + r12 * cz;
    final rcz = r20 * cx + r21 * cy + r22 * cz;
    out[i + 6] = s * out[i + 6] + (s - 1.0) * rcx;
    out[i + 7] = s * out[i + 7] + (s - 1.0) * rcy;
    out[i + 8] = s * out[i + 8] + (s - 1.0) * rcz;
  }
  return out;
}
