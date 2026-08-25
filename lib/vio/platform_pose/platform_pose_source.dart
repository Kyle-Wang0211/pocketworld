// platform_pose_source.dart — 平台位姿抽象(条目 14)。纯 Dart,零 Flutter 依赖。
//
// ── 一句话契约 ────────────────────────────────────────────────────────────
// 平台位姿(ARKit / ARCore / Android XR / 鸿蒙)只做三件事:
//   **初值(initialGuess) / 尺度先验(scalePrior) / 重力方向(gravityDirection)**。
// 它**永远不做 fixed constraint** —— 不把相机位姿钉死,不参与"这个位姿是真值"
// 这类语义。本文件用类型系统与数值下限把这条契约做成**机械不可违反**,
// 而不是写在注释里靠自觉。
//
// ── 为什么(一手实测,不是理论洁癖)────────────────────────────────────
// (1) 日方实测:把 ARCore 位姿当固定值喂 COLMAP,位姿误差局部中位 **4.0cm**
//     (「要求精度の約20倍粗い」),在图像上是 **18px** 偏移 ⇒
//     「対応点の実に98%をゴミ箱へ捨ててしまっていました」。
//     改成让 COLMAP 自己解位姿、最后只用 AR 位姿修尺度,才成。
//     ⇒ 固定平台位姿的代价不是"精度略降",是**把 98% 的对应点判成外点**。
//
// (2) 我们自己的 B1 实证(08-22):关掉 ARKit 位姿,solver 仍收敛 57/60,
//     共同部分 F@1cm=**95.16%**,旋转中位 **0.137°**、相机中心 **2.14mm**。
//     ⇒ 自研核**不需要**平台位姿也能解出几何。平台位姿是加速器,不是地基。
//     (勘误口径:B1 是 "solver pose-off",不是端到端 ARKit-off。)
//
// (3) 德国 HafenCity 大学(DGPF 2025):同一部 iPhone 15 Pro Max,两个都基于
//     ARKit 的 App,重建尺度**都错且错得不一样**(Polycam 1:2.8009、
//     Scaniverse 1:1.1536),缩放后距离仍「systematisch zu lang」。
//     ⇒ **同硬件 + 同底层框架 + 不同上层实现 = 不同尺度**。所以
//        「平台给的是米制真值」这个假设本身不成立,尺度先验必须带自己的 σ。
//
// ── 设计要点:不确定度必须**分自由度**,不能一个权重打天下 ──────────────
// 平台位姿的质量在不同自由度上差**两个数量级**:
//   • 旋转 / 重力方向:好。重力被加速度计直接观测,陀螺短时漂移极小。
//   • 平移:差。上面 (1) 的 4.0cm 就是它。
//   • 尺度:唯一来源,但自己也偏几个百分点,且**依实现而异**(上面 (3))。
// 下游若用同一个权重去信这三样,就会发生"为了迁就 4cm 的平移把 0.137° 的
// 旋转也一起拉歪",或者反过来"因为旋转很准就顺手相信了平移"。
// ⇒ [PoseUncertainty] 强制把四类 σ 分开填,没有"一个 σ"的构造函数。
//
// ── fixed constraint 是怎么偷偷溜进来的 ──────────────────────────────────
// 没有人会写 `usage = fixedConstraint`。它溜进来的方式是
// **σ 填一个很小的数** —— σ→0 等价于信息权重 →∞,数学上就是钉死。
// 所以本文件设了两道闸:
//   闸一:σ 必须有限且 > 0(构造时抛)⇒ 无法表达"无穷权重"。
//   闸二:provenance == platform 时,σ 不得低于[实测下限](见下)⇒
//         无法用"很小的 σ"伪装成固定约束。
// 两道闸都在构造函数里,绕不过去。

import 'dart:math' as math;

// ── 实测下限常量 ────────────────────────────────────────────────────────

/// 平台位姿**平移** σ 的下限 [m]。
///
/// 来源:日方一手实测的局部中位位姿误差 **4.0cm**(把 ARCore 位姿当固定值
/// 喂 COLMAP 时测得)。这是目前唯一公开的、针对"平台位姿当约束"这一具体
/// 失效模式的一手数字。
///
/// 🔴 声称比这更准,必须先有本机标定记录 —— 不是调小一个常量就行。
const double kPlatformTranslationSigmaFloorM = 0.040;

/// 平台位姿**旋转 / 重力方向** σ 的下限 [rad]。
///
/// 来源:B1(08-22)测到的旋转中位差 **0.137°** —— 这是我们迄今在两个
/// 相互独立的解之间量到的**最紧**一致性。任何比它更小的 σ 都超出了我们
/// 已有的分辨能力,属于无据自信。0.137° = 0.0023911... rad。
const double kPlatformRotationSigmaFloorRad = 0.137 * math.pi / 180.0;

/// 平台**尺度**先验相对 σ 的下限(无量纲,相对值)。
///
/// 推导:既有交付链 `scaleAnchorFactor` 对 |s−1| > **0.15** 直接拒收
/// (lib/official_capture/gravity_align.dart)。把"拒收线"读作 ~3σ,
/// 得 σ ≈ 0.05。这与 35-run 实测的 ±4% gauge 漂移同量级,互相印证。
/// 🔴 注意这是**我们相对 ARKit** 的漂移,不是 ARKit 相对真实世界的误差;
///    后者按 HafenCity 的结果可以差得多,且依实现而异。所以 0.05 是下限
///    不是典型值 —— 典型值应当由本机标定给出,见 [PlatformPoseDefaults]。
const double kPlatformScaleSigmaFloorRel = 0.05;

// ── 来源与角色 ──────────────────────────────────────────────────────────

/// 位姿的出处。下游**必须**据此分别配权,不允许合并成一个权重。
enum PoseProvenance {
  /// 平台框架给的(ARKit / ARCore / Android XR / 鸿蒙)。受本文件两道闸约束。
  platform,

  /// 自研 VIO 核解出来的。
  selfSolvedVio,

  /// 离线 SfM / BA 解出来的(权威解)。
  selfSolvedSfm,
}

/// 平台位姿**被允许**的用途。
///
/// 🔴 这个枚举里**故意没有** fixedConstraint / groundTruth / anchor 之类的成员。
/// 缺席本身就是契约:类型系统里根本不存在"把平台位姿钉死"这个选项。
/// 想加成员的人请先读本文件顶部的 (1)(2)(3) 三条实测。
enum PlatformPoseRole {
  /// 初值:给 solver 一个起点,solver 自己解、自己收敛,结果可以离初值任意远。
  initialGuess,

  /// 尺度先验:单目重投影对全局 scale 严格不可观测,平台是唯一米制来源。
  scalePrior,

  /// 重力方向:让 +Y 朝天。平台在这一项上质量最好。
  gravityDirection,
}

/// 平台侧自报的跟踪状态。各平台名字不同,这里归一成三档。
enum PlatformTrackingState {
  /// 平台明确表示跟踪正常。
  normal,

  /// 平台明确表示受限(初始化中 / 快速运动 / 特征不足 / 重定位中)。
  limited,

  /// 平台明确表示不可用,或平台**根本不提供**这个字段(如 Android XR)。
  /// 🔴 "不提供" 与 "不可用" 合并成同一档是**刻意**的保守选择:
  ///    拿不到状态时不许假设它是好的。
  unavailable,
}

// ── 不确定度 ────────────────────────────────────────────────────────────

/// 分自由度的位姿不确定度。**没有**"一个 σ 打天下"的构造函数。
///
/// 构造时执行两道闸(见文件头):σ 必须有限且 > 0;provenance == platform
/// 时还必须 ≥ 各自的实测下限。违反直接抛 [ArgumentError] —— 这是本文件把
/// "不做 fixed constraint" 变成机械约束的地方。
class PoseUncertainty {
  PoseUncertainty({
    required this.provenance,
    required this.rotationSigmaRad,
    required this.translationSigmaM,
    required this.gravitySigmaRad,
    this.scaleSigmaRel,
  }) {
    _requirePositiveFinite(rotationSigmaRad, 'rotationSigmaRad');
    _requirePositiveFinite(translationSigmaM, 'translationSigmaM');
    _requirePositiveFinite(gravitySigmaRad, 'gravitySigmaRad');
    final s = scaleSigmaRel;
    if (s != null) _requirePositiveFinite(s, 'scaleSigmaRel');

    if (provenance == PoseProvenance.platform) {
      _requireFloor(
        rotationSigmaRad,
        kPlatformRotationSigmaFloorRad,
        'rotationSigmaRad',
      );
      _requireFloor(
        translationSigmaM,
        kPlatformTranslationSigmaFloorM,
        'translationSigmaM',
      );
      _requireFloor(
        gravitySigmaRad,
        kPlatformRotationSigmaFloorRad,
        'gravitySigmaRad',
      );
      if (s != null) {
        _requireFloor(s, kPlatformScaleSigmaFloorRel, 'scaleSigmaRel');
      }
    }
  }

  final PoseProvenance provenance;

  /// 旋转 1σ [rad]。
  final double rotationSigmaRad;

  /// 平移 1σ [m]。
  final double translationSigmaM;

  /// 重力方向 1σ [rad]。与 [rotationSigmaRad] **分开**填:重力是被加速度计
  /// 直接观测的,绕重力轴的偏航(yaw)则不是 —— 两者质量本来就不同。
  final double gravitySigmaRad;

  /// 尺度先验的**相对** 1σ(无量纲)。null = 该来源不携带米制尺度
  /// (纯单目 SfM 就是 null:全局 scale 是 gauge 自由度,不是测量)。
  final double? scaleSigmaRel;

  /// 该来源是否携带可用的米制尺度。
  bool get carriesMetricScale => scaleSigmaRel != null;

  /// 信息权重 1/σ²。**按构造有限** —— σ > 0 已在构造时强制,
  /// 所以这里不可能返回 infinity,也就不可能表达 fixed constraint。
  double informationWeightRotation() =>
      1.0 / (rotationSigmaRad * rotationSigmaRad);

  double informationWeightTranslation() =>
      1.0 / (translationSigmaM * translationSigmaM);

  double informationWeightGravity() =>
      1.0 / (gravitySigmaRad * gravitySigmaRad);

  /// null 当且仅当该来源不带米制尺度。
  double? informationWeightScale() {
    final s = scaleSigmaRel;
    if (s == null) return null;
    return 1.0 / (s * s);
  }

  static void _requirePositiveFinite(double v, String name) {
    if (!v.isFinite || v <= 0) {
      throw ArgumentError.value(
        v,
        name,
        'sigma must be finite and > 0; sigma<=0 means an infinite information '
        'weight, i.e. a fixed constraint, which this API does not express',
      );
    }
  }

  static void _requireFloor(double v, double floor, String name) {
    if (v < floor) {
      throw ArgumentError.value(
        v,
        name,
        'platform-provenance sigma is below the measured floor $floor; a '
        'sigma this small is a fixed constraint in disguise. Lowering it '
        'requires an on-device calibration record, not a smaller constant',
      );
    }
  }

  @override
  String toString() =>
      'PoseUncertainty(${provenance.name}, rot=${rotationSigmaRad}rad, '
      'trans=${translationSigmaM}m, grav=${gravitySigmaRad}rad, '
      'scale=$scaleSigmaRel)';
}

/// 保守默认值。**不是标定值** —— 是"在标定之前不至于说谎"的值。
///
/// 每一项都取实测下限的若干倍,方向一律偏保守(σ 偏大 = 权重偏小 =
/// 更不信平台)。真机标定计划见交付说明。
abstract final class PlatformPoseDefaults {
  /// ARKit(iOS)。旋转/重力取下限的 4 倍(≈0.55°),平移取下限的 1 倍
  /// (4.0cm,日方实测值本身),尺度取下限的 1 倍(0.05)。
  static PoseUncertainty arkitUncalibrated() => PoseUncertainty(
    provenance: PoseProvenance.platform,
    rotationSigmaRad: kPlatformRotationSigmaFloorRad * 4,
    gravitySigmaRad: kPlatformRotationSigmaFloorRad * 4,
    translationSigmaM: kPlatformTranslationSigmaFloorM,
    scaleSigmaRel: kPlatformScaleSigmaFloorRel,
  );

  /// Android XR / ARCore for Jetpack XR。
  /// 🔴 比 ARKit 更保守,原因是**实测的信息缺口**而非猜测:
  ///    `ArDevice.state.value.devicePose` 只给 translation + rotation,
  ///    **既无时间戳、也无跟踪状态/置信度字段**(官方文档 device-pose 页,
  ///    2026-08 核对)。没有时间戳 ⇒ 位姿与相机帧的对应关系无法核验,
  ///    存在未知延迟;没有跟踪状态 ⇒ 无法在受限时降权。
  ///    两项都直接放大有效不确定度,所以平移取下限 2 倍。
  static PoseUncertainty androidXrUncalibrated() => PoseUncertainty(
    provenance: PoseProvenance.platform,
    rotationSigmaRad: kPlatformRotationSigmaFloorRad * 8,
    gravitySigmaRad: kPlatformRotationSigmaFloorRad * 8,
    translationSigmaM: kPlatformTranslationSigmaFloorM * 2,
    scaleSigmaRel: kPlatformScaleSigmaFloorRel * 2,
  );
}

// ── 样本 ────────────────────────────────────────────────────────────────

/// 一帧的平台位姿样本。
///
/// 约定与既有管线**逐字一致**(lib/official_capture/gravity_align.dart):
/// 四元数是 CamFromWorld(world→camera),顺序 [w,x,y,z];平移是同一
/// CamFromWorld 的 t,相机中心 C = −Rᵀt。
class PlatformPoseSample {
  PlatformPoseSample({
    required this.frameId,
    required this.quatWxyz,
    required this.uncertainty,
    required this.tracking,
    this.translation,
    this.timestampSeconds,
  }) {
    if (quatWxyz.length != 4) {
      throw ArgumentError.value(quatWxyz, 'quatWxyz', 'must have 4 elements');
    }
    final t = translation;
    if (t != null && t.length != 3) {
      throw ArgumentError.value(t, 'translation', 'must have 3 elements');
    }
  }

  final int frameId;

  /// CamFromWorld 旋转 [w,x,y,z]。
  final List<double> quatWxyz;

  /// CamFromWorld 平移 [tx,ty,tz]。null = 该来源只给朝向。
  final List<double>? translation;

  /// 平台自报的时间戳 [s]。**null 是合法值**且必须被下游正视:
  /// Android XR 的 devicePose 就不带时间戳。null ⇒ 帧对应关系不可核验。
  final double? timestampSeconds;

  final PoseUncertainty uncertainty;
  final PlatformTrackingState tracking;

  /// 相机中心 C = −Rᵀt。没有平移时返回 null。
  ///
  /// 与 lib/capture/true_parallax.dart 的 cameraCenterFromCamFromWorld 同一
  /// 公式(此处不 import,保持本目录零跨层依赖;数值一致性由单测钉住)。
  List<double>? cameraCenterWorld() {
    final t = translation;
    if (t == null) return null;
    final w = quatWxyz[0], x = quatWxyz[1], y = quatWxyz[2], z = quatWxyz[3];
    final n2 = w * w + x * x + y * y + z * z;
    if (!n2.isFinite || n2 < 1e-12) return null;
    final r00 = 1 - 2 * (y * y + z * z) / n2,
        r01 = 2 * (x * y - z * w) / n2,
        r02 = 2 * (x * z + y * w) / n2;
    final r10 = 2 * (x * y + z * w) / n2,
        r11 = 1 - 2 * (x * x + z * z) / n2,
        r12 = 2 * (y * z - x * w) / n2;
    final r20 = 2 * (x * z - y * w) / n2,
        r21 = 2 * (y * z + x * w) / n2,
        r22 = 1 - 2 * (x * x + y * y) / n2;
    final tx = t[0], ty = t[1], tz = t[2];
    // C = -R^T t;R^T 的行 = R 的列。
    return [
      -(r00 * tx + r10 * ty + r20 * tz),
      -(r01 * tx + r11 * ty + r21 * tz),
      -(r02 * tx + r12 * ty + r22 * tz),
    ];
  }
}

// ── 来源接口 ────────────────────────────────────────────────────────────

/// 平台位姿来源。**眼镜端(Android XR / 鸿蒙)与手机端降级路径共用它。**
///
/// 实现方只负责"把平台的东西搬过来并如实标注不确定度";用途裁决由
/// [PlatformPoseGate] 统一做,实现方无权自行放宽。
abstract class PlatformPoseSource {
  /// 稳定标识,进遥测用(如 'arkit', 'android_xr', 'harmony')。
  String get platformId;

  /// 该来源是否给时间戳。false ⇒ 帧对应不可核验(Android XR 当前为 false)。
  bool get providesTimestamps;

  /// 该来源是否给跟踪状态。false ⇒ [PlatformPoseSample.tracking] 恒为
  /// [PlatformTrackingState.unavailable]。
  bool get providesTrackingState;

  /// 取某帧的样本;无则 null。
  PlatformPoseSample? sampleForFrame(int frameId);
}

/// 用途闸。**唯一**允许消费平台位姿的入口。
///
/// 这里做的事很小但是不可省:把"这一帧、这个角色、这个来源"三者一起过一遍
/// 硬条件,拒绝时给出可进遥测的原因字符串。下游只要走这个闸,就不可能
/// 拿到一个"被当成真值"的平台位姿。
abstract final class PlatformPoseGate {
  static const String reasonNoSample = 'no_sample';
  static const String reasonTrackingNotNormal = 'tracking_not_normal';
  static const String reasonNoTranslation = 'no_translation';
  static const String reasonNoMetricScale = 'no_metric_scale';
  static const String reasonNotPlatformProvenance = 'not_platform_provenance';

  /// 判定 [sample] 能否用于 [role]。通过返回 null,否则返回拒绝原因。
  ///
  /// 规则:
  ///   • 任何角色都要求 tracking == normal。平台自己说受限时还去信它,
  ///     是把 (1) 里那 98% 外点的坑再挖一遍。
  ///   • scalePrior 额外要求:有平移、且不确定度带米制尺度。
  ///   • gravityDirection 只要旋转,不要求平移 —— 这是平台最可靠的一项,
  ///     不应被"没有平移"连坐。
  static String? rejectionReason(
    PlatformPoseSample? sample,
    PlatformPoseRole role,
  ) {
    if (sample == null) return reasonNoSample;
    if (sample.uncertainty.provenance != PoseProvenance.platform) {
      return reasonNotPlatformProvenance;
    }
    if (sample.tracking != PlatformTrackingState.normal) {
      return reasonTrackingNotNormal;
    }
    switch (role) {
      case PlatformPoseRole.gravityDirection:
        return null;
      case PlatformPoseRole.initialGuess:
        if (sample.translation == null) return reasonNoTranslation;
        return null;
      case PlatformPoseRole.scalePrior:
        if (sample.translation == null) return reasonNoTranslation;
        if (!sample.uncertainty.carriesMetricScale) return reasonNoMetricScale;
        return null;
    }
  }

  static bool allows(PlatformPoseSample? sample, PlatformPoseRole role) =>
      rejectionReason(sample, role) == null;
}

// ── 与既有管线的对接(零改动扩展)──────────────────────────────────────
//
// 既有交付链已经是"COLMAP 自己解位姿,事后用 ARKit 修重力与尺度" —— 方向
// 与条目 14 一致。下面两个适配器把 [PlatformPoseSource] 直接变成既有两个
// 纯函数已经接受的回调签名,**不改既有函数一个字**:
//   • gravityAlignQuatWxyz(arkitQuatWxyzOf: ...)
//   • scaleAnchorFactor(arkitCenterWorldOf: ...)

/// 适配 `gravityAlignQuatWxyz` 的 `arkitQuatWxyzOf` 回调。
///
/// 过 [PlatformPoseRole.gravityDirection] 闸;不过闸的帧返回 null,既有实现
/// 会自然跳过该帧(它本来就按 null 跳过)⇒ **fail-open 语义不变,不丢数据**。
List<double>? Function(int frameId) gravityQuatLookupOf(
  PlatformPoseSource source, {
  void Function(int frameId, String reason)? onReject,
}) {
  return (int frameId) {
    final s = source.sampleForFrame(frameId);
    final reason = PlatformPoseGate.rejectionReason(
      s,
      PlatformPoseRole.gravityDirection,
    );
    if (reason != null) {
      onReject?.call(frameId, reason);
      return null;
    }
    return s!.quatWxyz;
  };
}

/// 适配 `scaleAnchorFactor` 的 `arkitCenterWorldOf` 回调。
///
/// 过 [PlatformPoseRole.scalePrior] 闸,并把 CamFromWorld 换算成相机中心。
/// 不过闸返回 null ⇒ 既有实现少一个配对,配对 <3 时它自己会放弃缩放
/// (fail-open,保持现状交付)。
List<double>? Function(int frameId) scaleCenterLookupOf(
  PlatformPoseSource source, {
  void Function(int frameId, String reason)? onReject,
}) {
  return (int frameId) {
    final s = source.sampleForFrame(frameId);
    final reason = PlatformPoseGate.rejectionReason(
      s,
      PlatformPoseRole.scalePrior,
    );
    if (reason != null) {
      onReject?.call(frameId, reason);
      return null;
    }
    return s!.cameraCenterWorld();
  };
}
