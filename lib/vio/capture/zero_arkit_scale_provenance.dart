// zero_arkit_scale_provenance.dart —— 开关 ON 时**米制尺度从哪来**。
//
// ══ 问题 ═══════════════════════════════════════════════════════════════════
// 生产的米制尺度靠 **SCALE-ANCHOR**(`gravity_align.dart:215` 的
// `scaleAnchorFactor`):把 BA 出来的模型按**相对 ARKit** 的质心距比重锚。
// 开关 ON 时**没有 ARKit 可锚** —— 那条路在结构上不可用,不是「效果差一点」。
//
// ⇒ 这条臂的尺度只有两个可能状态:
//   ① **未锚定**:VIO 自己的尺度。实测相对 ARKit 偏 0.22% / 5.21% / 17.85%
//      (09-22 三场验收),跨场不稳 ⇒ **不能报绝对尺寸**。
//   ② **用户量过一段已知距离**:走 `metric_rescale.dart` 的
//      `rescaleToKnownDistance`(全行业在 VIO/SfM 之外的同一招:Polycam
//      Rescale / KIRI / RealityCapture define distance / Metashape scale bar)。
//
// ══ 🔴 本文件只留入口与 provenance,**不做 UI** ════════════════════════════
// 选哪两个点、怎么输距离,是 UX,由产品负责人定。这里只保证:
//   · 没有用户输入之前,provenance 一定是 [kScaleProvenanceVioUnanchored],
//     且 `mayReportAbsoluteDimensions == false`;
//   · 有了用户输入之后,provenance 换成 [kScaleProvenanceUserDistance],
//     并把 `metric_rescale` 的那份 `MetricRescaleProvenanceV1` 原样带上。
// **不自己发明第三种来源,也不在没输入时假装有尺度。**

import 'dart:typed_data';

import '../../official_capture/metric_rescale.dart';
import '../quality/scale_observability.dart' show ScaleObservabilitySample;

/// 尺度未锚定 —— VIO 自己那把尺子,**不可报绝对尺寸**。
const String kScaleProvenanceVioUnanchored = 'vio_unanchored';

/// 尺度来自用户量的一段已知距离。
const String kScaleProvenanceUserDistance = 'user_measured_distance';

/// 生产 ARKit 臂用的那一档(本文件不产出它,列在这里是为了让三种取值
/// 在一个地方看得全,读回执的人不用翻三个文件)。
const String kScaleProvenanceArkitAnchor = 'arkit_scale_anchor';

/// 一次采集的尺度状态。
class ZeroArkitScaleState {
  const ZeroArkitScaleState({
    required this.provenance,
    required this.mayReportAbsoluteDimensions,
    this.rescale,
  });

  /// 未锚定的初始状态。**每条零 ARKit 采集都从这里开始。**
  static const ZeroArkitScaleState unanchored = ZeroArkitScaleState(
    provenance: kScaleProvenanceVioUnanchored,
    mayReportAbsoluteDimensions: false,
  );

  final String provenance;

  /// 🔴 未锚定时恒 `false`。这是 fail-safe 方向:宁可少报一个尺寸,
  /// 也不报一个自己都不知道偏了多少的尺寸。
  final bool mayReportAbsoluteDimensions;

  /// 用户输入那一路的完整 provenance(未锚定时为 `null`)。
  final MetricRescaleProvenanceV1? rescale;

  Map<String, Object?> toJson() => <String, Object?>{
        'schema_version': 'pw.vio.zero_arkit_scale/1',
        'scale': provenance,
        'may_report_absolute_dimensions': mayReportAbsoluteDimensions,
        'rescale': rescale?.toJson(),
      };

  @override
  String toString() => 'ZeroArkitScaleState(scale=$provenance, '
      'absDims=$mayReportAbsoluteDimensions)';
}

/// 用户量了一段已知距离 ⇒ 整体等比缩放,并把尺度状态推进到「已锚定」。
///
/// 这是 [ZeroArkitScaleState.unanchored] 的**唯一**出口。直接转调
/// `metric_rescale.dart`(另一条分支落地的机制,`145d8a6`),本文件
/// **一行缩放数学都不写** —— 写了就是第二份实现,两份迟早会漂。
///
/// 抛 `MetricRescaleException`(输入畸形 / 距离非法 / 两点重合 / s 越界)。
/// 🔴 **抛出时尺度状态不变**,仍是未锚定 —— 调用方不要在 catch 里把
/// `mayReportAbsoluteDimensions` 打开。
({MetricRescaleResult result, ZeroArkitScaleState state})
    anchorScaleByUserDistance({
  required Float32List xyz,
  required List<double> pointA,
  required List<double> pointB,
  required double realDistanceMeters,
  Float64List? posesPacked,
  List<double>? center,
  ScaleObservabilitySample? vioScaleConfidence,
  DateTime? timestampUtc,
}) {
  final MetricRescaleResult r = rescaleToKnownDistance(
    xyz: xyz,
    pointA: pointA,
    pointB: pointB,
    realDistanceMeters: realDistanceMeters,
    posesPacked: posesPacked,
    center: center,
    vioScaleConfidence: vioScaleConfidence,
    timestampUtc: timestampUtc,
  );
  return (
    result: r,
    state: ZeroArkitScaleState(
      provenance: kScaleProvenanceUserDistance,
      mayReportAbsoluteDimensions: true,
      rescale: r.provenance,
    ),
  );
}
