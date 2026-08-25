// capability_decision.dart — 能力探测的**输出**(Blocker 04 任务 2)。
// 纯 Dart,零 Flutter 依赖。
//
// ── 一条降级路径,不是两套架构 ──────────────────────────────────────────
// 眼镜端已定用平台位姿(Android XR 应用层只拿位姿;Apple 需逐案审批 entitlement)。
// 手机端把「用平台位姿」做成 **fallback**。两端因此共用同一个 [CapabilityDecision]:
//
//   眼镜端  → CapabilityDecision.platformPoseByDesign()  → tier=degradeToPlatformPose
//   手机端  → CapabilityProbe.decide(evidence)           → tier=三选一
//
// 消费方只写**一个** switch,拿到的都是 [PoseSource]。眼镜端不是特例分支,
// 它只是把手机端的 fallback 当成常态。这是接口层面的约束,不是文档层面的约定。
//
// ── 三态判定的结构 ──────────────────────────────────────────────────────
// 判定被拆成两个**独立**的问题,而不是一条打分:
//   (a) 自研核靠不靠得住?  → 一组 [CapabilityBlocker]
//   (b) 平台位姿在不在?    → 一个 bool
// 于是:
//   无阻断                        → selfCoreOk
//   有阻断 且 平台位姿在          → degradeToPlatformPose
//   有阻断 且 平台位姿不在        → unusable
//
// 🔴 例外一条(而且是最重要的一条):[CapabilityBlocker.stabilizationActive] 带
//    [poseSourceIndependent] = true。防抖开着的时候画面像素本身已经被 warp,
//    换谁出位姿都救不回来 —— 连拍回来的图都会毒化后面的 SfM/MVS。
//    所以它**即使有平台位姿也判 unusable**。这条是 Apple 自己写在头文件里的
//    (AVCaptureDevice.h:2311「The extrinsicMatrix and camera intrinsics should only
//    be used when video stabilization is disabled.」),不是我们的推测。

/// 位姿由谁出。
enum PoseSource {
  /// 自研 VIO 核(xrslam)。
  selfVio,

  /// 平台位姿(iOS ARKit / Android ARCore / 眼镜端系统位姿)。
  platformVio,

  /// 没有可信来源。
  none,
}

/// 会话能力档位。
enum CapabilityTier {
  selfCoreOk,
  degradeToPlatformPose,
  unusable,
}

/// 阻断自研核的具体原因。**每一条都要能说出「为什么它是硬伤」。**
enum CapabilityBlocker {
  /// 图像与 IMU 不同时钟基,且偏移没测出来。两路数据根本无法融合。
  timebaseUnresolved,

  /// 偏移测出来了,但误差界大到会在手持转动下造成超过 1px 的重投影错位。
  /// 门限是**推导**的,不是拍的:见 [CapabilityThresholds.maxTimebaseUncertaintyNs]。
  timebaseUncertaintyTooLarge,

  /// IMU 样本太少,时序统计量不可信 —— 「不知道」不等于「没问题」。
  imuNotMeasured,

  /// 实测 IMU 速率低于下限。预积分在帧间没有足够内点。
  imuRateTooLow,

  /// IMU 成簇上报(硬件 batching)。一簇陀螺仪在加速度计队列排空之前整批到达,
  /// 会让 xrslam 的陀螺/加计交错退化(xrslam/src/xrslam/core/detail.cpp)。
  imuClusteredDelivery,

  /// 簇内时间戳等距到不可能的程度 —— HAL 造的,逐样本 dt 不是实测数据。
  imuTimestampsSynthetic,

  /// 拿不到内参。逐机型 yaml 已被否决,拿不到就是拿不到。
  intrinsicsUnavailable,

  /// 拿到了但不自洽(主点落在画面外)—— 参考分辨率带错了,比没有更危险。
  intrinsicsImplausible,

  /// 🔴 防抖确认开着。画面已被 warp,像素不再对应 IMU 的物理位姿。
  /// **与位姿来源无关**:平台位姿也救不了被 warp 的像素。
  stabilizationActive,

  /// 防抖状态读不回来。不等于关着。
  stabilizationUnverifiable,

  /// 帧间隔抖动过大(掉帧 / 热降频)。热稳定是硬约束。
  frameTimingUnstable,

  /// 卷帘读出时间报了个物理上不可能的值(≥ 一个帧间隔),说明该字段不可信。
  rollingShutterImplausible,

  /// 按设计就走平台位姿(眼镜端)。不是故障。
  platformPoseByDesign,
}

/// 这条阻断是不是**换位姿来源也救不了**。
bool isPoseSourceIndependent(CapabilityBlocker b) =>
    b == CapabilityBlocker.stabilizationActive;

/// 一条阻断 + 它的实测佐证。**必须带数字**,否则复盘时无从判断门限对不对。
class BlockerReason {
  const BlockerReason({
    required this.blocker,
    required this.detail,
    this.measured,
    this.threshold,
  });

  final CapabilityBlocker blocker;

  /// 人读的一句话。
  final String detail;

  /// 实测值(可选,单位见各 blocker)。
  final num? measured;

  /// 当时用的门限(可选)。
  final num? threshold;

  bool get poseSourceIndependent => isPoseSourceIndependent(blocker);

  @override
  String toString() {
    final StringBuffer b = StringBuffer(blocker.name)..write(': ')..write(detail);
    if (measured != null) b.write(' (measured=$measured');
    if (measured != null && threshold != null) b.write(', threshold=$threshold');
    if (measured != null) b.write(')');
    return b.toString();
  }
}

/// 探测结论。
class CapabilityDecision {
  const CapabilityDecision({
    required this.tier,
    required this.poseSource,
    required this.reasons,
    required this.platformPoseAvailable,
  });

  /// 眼镜端入口:按设计就走平台位姿。与手机端降级走**同一条**路径。
  factory CapabilityDecision.platformPoseByDesign() {
    return const CapabilityDecision(
      tier: CapabilityTier.degradeToPlatformPose,
      poseSource: PoseSource.platformVio,
      platformPoseAvailable: true,
      reasons: <BlockerReason>[
        BlockerReason(
          blocker: CapabilityBlocker.platformPoseByDesign,
          detail: 'Platform pose is the designated source on this device class '
              '(HMD). Not a fault.',
        ),
      ],
    );
  }

  final CapabilityTier tier;
  final PoseSource poseSource;
  final List<BlockerReason> reasons;
  final bool platformPoseAvailable;

  bool get canCapture => tier != CapabilityTier.unusable;

  Set<CapabilityBlocker> get blockers =>
      reasons.map((BlockerReason r) => r.blocker).toSet();

  bool hasBlocker(CapabilityBlocker b) => blockers.contains(b);

  /// 换位姿来源也救不了的那些原因。
  List<BlockerReason> get fatalReasons =>
      reasons.where((BlockerReason r) => r.poseSourceIndependent).toList();

  @override
  String toString() => 'CapabilityDecision(${tier.name} via ${poseSource.name}, '
      '${reasons.length} reason(s))\n'
      '${reasons.map((BlockerReason r) => '  - $r').join('\n')}';
}
