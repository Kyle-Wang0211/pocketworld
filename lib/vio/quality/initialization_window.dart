// initialization_window.dart — VIO 初始化窗口闸门(条目 10 的第 2 条)。
// 纯 Dart,零 Flutter 依赖。
//
// ── 为什么存在 ────────────────────────────────────────────────────────────
// NAVER LABS:「세션 초반에 지도가 충분히 만들어지지 않은 경우, 센서 정보만을
// 이용해서 6DOF를 계산하기 때문에 정확도가 다소 떨어질 수 있습니다」。
// 🔴 这条对我们特别贵:产品形态是 C_journal 渐进预览,用户按下开始就立刻要看到
//    点云 —— 而那一段恰恰是纯 IMU 外推、位姿最差的窗口。那段点如果直接进交付,
//    就是在成品里埋一层「一开始那几秒的鬼点」。
//
// ── 🔑 产品级约定:分开「帧」和「点」,这是本文件全部的设计要点 ────────────
// 铁律是「交付绝对无损,永久缺帧绝对禁止,fail-safe 只许推迟不许丢数据」。
// 初始化窗口的问题**不是帧坏了,是位姿坏了**。原始帧一直是好的:
//
//   • **帧**:恒定保留、恒定进交付。本文件没有任何 API 能丢帧。
//     [VioFrameDisposition.frameRetained] 恒为 true,单测
//     `gate never discards a frame` 钉这条。离线管线拿到好位姿之后会把这些帧
//     重新算一遍 —— 这就是「只许推迟不许丢数据」在这里的具体形式。
//   • **点**:初始化窗口内**由实时位姿**生成的点只做视觉反馈,不进交付。
//     [VioFrameDisposition.cloudPreviewOnly] 为 true 即此意。
//
// 所以这不是一个过滤器,是一个**标注器**。它决定的是「这一帧的实时点云能不能
// 被信任」,不是「这一帧要不要留」。
//
// ── 收敛判据(三条同时满足)────────────────────────────────────────────
// 初始化要的是「地图刚性可信」,**不是**「米制尺度可信」—— 后者是
// scale_observability.dart 那条完全独立的线(见下「与尺度闸门的关系」)。所以:
//
//   1. 连续 [VioInitPolicy.minConsecutiveTexturedFrames] 帧纹理充分。
//      纹理不够 ⇒ 地图根本建不起来(条目 10 的正文)。用 texture_sufficiency.dart
//      的 [TextureSample.isSufficient],**不新造尺子**。
//   2. 见过 baseline/depth ≥ [VioInitPolicy.minInitBaselineOverDepth]。
//      🔑 默认值 = 0.0873 = 覆盖云现行 parallaxMinDeg = 5° 的等价 b/d
//      ([baselineOverDepthFromTriangulationDeg] 换算),**直接复用既有尺子**。
//      这里刻意**不**用尺度侧的 0.30:初始化只需要「能三角化出结构」,而 0.30
//      是「能报绝对尺寸」的门 —— 两者差 3.4 倍基线,混用会让初始化白等。
//   3. 至少经过 [VioInitPolicy.minInitSeconds]。纯保险:前两条都满足但只过了
//      两帧,统计量不足以支撑「收敛」这个结论。
//
// ── 与尺度闸门的关系:两个闸门,不许互相顶替 ────────────────────────────
//   本文件的闸门     → 「这一帧的实时点能不能进交付」(几何是否可信)
//   ScaleObservabilityLedger → 「成品能不能标绝对尺寸」(米制是否可信)
//   一个会话完全可能 converged 但 mayReportAbsoluteDimensions = false
//   (整段都在自动步道上匀速走):几何交付照常,尺寸不许标。
//   [VioSessionAdmission] 把两者并排放在一起,就是为了让调用方不会拿其中一个
//   冒充另一个。
//
// ── 丢失重定位 ──────────────────────────────────────────────────────────
// VIO 跟丢并重置之后,地图重新开始建 —— 这在语义上就是一次新的初始化。
// [markTrackingLost] 重开窗口,后续帧重新回到 previewOnly,直到再次收敛。
// 已经收敛过的历史**不会**让新窗口白捡通过(单测 `relocalization reopens the
// window` 钉这条)。

import 'scale_observability.dart'
    show ScaleObservabilitySample, baselineOverDepthFromTriangulationDeg;
import 'texture_sufficiency.dart' show TextureSample;

/// 覆盖云 parallaxMinDeg = 5° 的等价 b/d。初始化只要求「可三角化」。
final double kInitMinBaselineOverDepth = baselineOverDepthFromTriangulationDeg(
  5.0,
);

enum VioInitPhase {
  /// 刚开始 / 刚重定位:地图还没建起来,位姿主要来自 IMU 外推。
  bootstrapping,

  /// 判据部分满足,还在攒。
  converging,

  /// 三条判据都满足。此后的帧点云可进交付。
  converged,
}

/// 单帧结论。
class VioFrameDisposition {
  const VioFrameDisposition({
    required this.phase,
    required this.cloudPreviewOnly,
    required this.texturedStreak,
    required this.bestBaselineOverDepth,
    required this.elapsedSeconds,
  });

  final VioInitPhase phase;

  /// true ⇒ 本帧由实时位姿生成的点**只做视觉反馈,不进交付**。
  final bool cloudPreviewOnly;

  /// 🔒 恒为 true。本文件不丢帧 —— 见文件头铁律段。这是一个常量而不是字段,
  /// 是为了让「有人把它改成 false」这件事必须先改这行代码。
  bool get frameRetained => true;

  final int texturedStreak;
  final double bestBaselineOverDepth;
  final double elapsedSeconds;

  bool get deliverable => !cloudPreviewOnly;

  @override
  String toString() =>
      'VioFrameDisposition(${phase.name}, previewOnly=$cloudPreviewOnly, '
      'streak=$texturedStreak, bd=${bestBaselineOverDepth.toStringAsFixed(3)})';
}

/// 收敛政策。**产品政策 + 一条复用的既有几何门**,分别标注,不假装都是推导。
class VioInitPolicy {
  VioInitPolicy({
    this.minConsecutiveTexturedFrames = 10,
    double? minInitBaselineOverDepth,
    this.minInitSeconds = 0.5,
  }) : minInitBaselineOverDepth =
           minInitBaselineOverDepth ?? kInitMinBaselineOverDepth,
       assert(minConsecutiveTexturedFrames >= 1),
       assert(minInitSeconds >= 0);

  /// 政策。10 帧 @30 Hz ≈ 0.33 s 的连续好纹理。
  final int minConsecutiveTexturedFrames;

  /// 几何门,默认复用覆盖云 5° ⇒ b/d = 0.0873。见文件头判据 2。
  final double minInitBaselineOverDepth;

  /// 政策。
  final double minInitSeconds;
}

/// 会话级并排结论 —— 防止调用方拿几何闸门冒充尺度闸门。见文件头。
class VioSessionAdmission {
  const VioSessionAdmission({
    required this.initPhase,
    required this.cloudDeliverable,
    required this.mayReportAbsoluteDimensions,
    required this.previewOnlyFrames,
    required this.totalFrames,
  });

  final VioInitPhase initPhase;

  /// 当前是否允许把实时点收进交付(= 已收敛)。
  final bool cloudDeliverable;

  /// 是否允许标绝对尺寸。来自 ScaleObservabilityLedger,**与上一条独立**。
  final bool mayReportAbsoluteDimensions;

  /// 被标成 previewOnly 的帧数。**这些帧本身一帧不少地留着**。
  final int previewOnlyFrames;
  final int totalFrames;

  Map<String, String> toTelemetry() => <String, String>{
    'vio_init_phase': initPhase.name,
    'vio_init_cloud_deliverable': cloudDeliverable ? '1' : '0',
    'vio_init_preview_only_frames': '$previewOnlyFrames',
    'vio_init_total_frames': '$totalFrames',
    'vio_may_report_dims': mayReportAbsoluteDimensions ? '1' : '0',
  };
}

/// 初始化窗口闸门。纯累加,无 IO,无计时器。
class VioInitializationGate {
  VioInitializationGate({VioInitPolicy? policy})
    : policy = policy ?? VioInitPolicy();

  final VioInitPolicy policy;

  VioInitPhase _phase = VioInitPhase.bootstrapping;
  int _streak = 0;
  double _bestBd = 0.0;
  double? _windowStartSec;
  int _previewOnly = 0;
  int _total = 0;

  VioInitPhase get phase => _phase;
  int get previewOnlyFrames => _previewOnly;
  int get totalFrames => _total;
  double get bestBaselineOverDepth => _bestBd;

  /// 喂一帧。[texture] 缺席(VIO 没报健康信息)按「不充分」算 —— fail-safe。
  /// [scale] 只用来取 baselineOverDepth,**不看它的 verdict** —— 尺度可观测性
  /// 是另一条独立的线,见文件头。
  VioFrameDisposition admit({
    required double tSec,
    TextureSample? texture,
    ScaleObservabilitySample? scale,
  }) {
    _total++;
    _windowStartSec ??= tSec;

    if (texture != null && texture.isSufficient) {
      _streak++;
    } else {
      _streak = 0;
    }

    final bd = scale?.baselineOverDepth;
    if (bd != null && bd.isFinite && bd > _bestBd) _bestBd = bd;

    final elapsed = tSec - _windowStartSec!;

    if (_phase != VioInitPhase.converged) {
      final textureOk = _streak >= policy.minConsecutiveTexturedFrames;
      final parallaxOk = _bestBd >= policy.minInitBaselineOverDepth;
      final timeOk = elapsed >= policy.minInitSeconds;
      if (textureOk && parallaxOk && timeOk) {
        _phase = VioInitPhase.converged;
      } else if (_streak > 0 || _bestBd > 0) {
        _phase = VioInitPhase.converging;
      } else {
        _phase = VioInitPhase.bootstrapping;
      }
    }

    final previewOnly = _phase != VioInitPhase.converged;
    if (previewOnly) _previewOnly++;

    return VioFrameDisposition(
      phase: _phase,
      cloudPreviewOnly: previewOnly,
      texturedStreak: _streak,
      bestBaselineOverDepth: _bestBd,
      elapsedSeconds: elapsed,
    );
  }

  /// VIO 跟丢并重置 ⇒ 语义上是一次新的初始化。重开窗口。
  /// **不清 [totalFrames] / [previewOnlyFrames]** —— 那是会话级账,要留着。
  void markTrackingLost({double? tSec}) {
    _phase = VioInitPhase.bootstrapping;
    _streak = 0;
    _bestBd = 0.0;
    _windowStartSec = tSec;
  }

  /// 与尺度闸门并排出结论。[mayReportAbsoluteDimensions] 由调用方从
  /// ScaleObservabilityLedger.report() 取,本类不代它做主。
  VioSessionAdmission admission({
    required bool mayReportAbsoluteDimensions,
  }) => VioSessionAdmission(
    initPhase: _phase,
    cloudDeliverable: _phase == VioInitPhase.converged,
    mayReportAbsoluteDimensions: mayReportAbsoluteDimensions,
    previewOnlyFrames: _previewOnly,
    totalFrames: _total,
  );

  void reset() {
    _phase = VioInitPhase.bootstrapping;
    _streak = 0;
    _bestBd = 0.0;
    _windowStartSec = null;
    _previewOnly = 0;
    _total = 0;
  }
}
