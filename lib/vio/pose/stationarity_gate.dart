// stationarity_gate.dart —— 「设备是否静止」的判定门。纯 Dart,三端同一份。
//
// ══ 🔴 先读这段:本门在当前架构下**永远返回 refuse**,这是已知且预期的 ══════
//
// 2026-09-19 真机实证:`init=refuse` 从头到尾,原因是下面这一行:
//     if (disparityOlderPixels == null || disparityNewerPixels == null) {
//       return verdict(Stationarity.unknown, InitDecision.refuse, '无视差输入');
// ⇒ **没有视差输入,门就无法下结论。** 而视差输入我们拿不到:
//
//   · 本门复刻自 **OpenVINS**,**不是 XRSLAM 的一部分** —— 是我们嫁接上来的。
//     OpenVINS 能算视差,是因为**它自己做特征跟踪**,有一个保存每个特征跨时间
//     观测历史的 feature database。
//   · 我们的架构里跟踪在 **XRSLAM 内部**。而 XRSLAM 的公开 API(头文件里
//     一共 20 个)**没有任何一个给 2D 特征观测**:
//       - `XRSLAMGetLandmarks/Ex` 给的是 **3D xyz**,flags 只有 TRIANGULATED 一位;
//       - `XRSLAMGetResult(XRSLAM_RESULT_FEATURES)` 在上游源码里写着
//         `// NOT IMPLEMENTED,只置空`(XRSLAMInternal.cpp:134);
//       - 出货档实测只导出 **5 个** C 符号(nm 核过,与 receipt 的 exported_abi
//         一致):Create / Destroy / GetResult / PushSensorData / RunOneFrame。
//   · XRSLAM 内部**确实有**一个等价量:`feature_tracker` 每帧算 70 分位残差角
//     `misalignment`,低于阈值就打 `FT_NO_TRANSLATION` 标签(map/frame.cpp:126-143)。
//     但 —— **上游自己的 `Initializer` 从不读它**,而且它只写进
//     `InspectionSupport` 那个调试全局表,**没有 C ABI 取值器**。
//
// ⇒ 要喂活这个门,必须写一个上游没有的接口。那是**自研,不是复刻**,已被否决。
//
// ══ 那这是不是缺陷?不是。产品上不需要它 ════════════════════════════════════
// 本门存在的目的是"静止时也能先给个 3DOF 朝向"。但:
//   · **ARKit 静止时也做不到**(苹果文档:起步 `.notAvailable`,要设备移动),
//     它的做法是降级到 `AROrientationTrackingConfiguration` 只报朝向;
//   · 而我们生产端**在那段时间根本不让用户拍** ——
//     `ar_capture_page.dart` 有 `_arWarmupComplete` 闸,注释写着 ARKit 冷启动
//     `tracking == .normal` 要 **1-2 秒**,兜底等待 `_warmupFallbackDuration`
//     = **1800 ms**,期间快门是灰的;
//   · 我们台架实测首位姿 **2.689 s**(1920×1440 全分辨率 + 生产求解器预算),
//     与那段暖机高度重叠。
// ⇒ 这个门要解决的问题,**在我们的产品流程里不存在**。
//
// 🔴 **所以:不要再把 `refuse` 当成"接线漏了"去补第四次。**
//    它是架构结论,不是 TODO。要改变它,先改变的应该是"XRSLAM 不给 2D 观测"
//    这个前提,而那需要产品层面的决定,不是补一根线。
//
// ══ 出处:判据形式来自 XR-VIO 正文,判据结构与参数来自 OpenVINS 源码 ════════
//
// **XR-VIO**(arXiv:2502.01297, 2025-02,Zhai/Wang/Wang/Chen/Xie —— 与
// XRSLAM/RD-VIO 同一批作者,**我们这条血统自己的后续工作**)第 3 节原文:
//
//   "We employ two initialization methods depending on the motion states,
//    namely static and motion. To determine the current state, we consider
//    the **average displacement of sparse features** and the **standard
//    deviation of acceleration and angular velocity**. If both the average
//    displacement and standard deviation are below specific thresholds, we
//    perform static initialization **similar to OpenVINS**; otherwise, we
//    proceed with motion initialization."
//
// 它把静止初始化指向 OpenVINS。于是判据的**结构**必须照 OpenVINS 读,
// 已逐行读过 master 分支两个文件:
//   ov_init/src/static/StaticInitializer.cpp:48-117
//   ov_init/src/init/InertialInitializer.cpp:91-137
//
// 🔴 **OpenVINS 是 GPL-3。本文件不含它的任何代码** —— 读源码是为了把**算法
//    口径**弄准(哪两个窗、开不开方、除 N 还是 N−1、比较方向),这些是事实不是
//    代码。判据形式取自 XR-VIO 的文字(那篇不是 GPL),数值取自配置文件。
//
// ══ 🔴 三处我原先写错、靠读源码才改正的地方 ═══════════════════════════════
//
// 我第一版(commit c4f63c0)是「一个 2.0 秒窗、算均方偏差、和阈值比」。
// 三处都不对:
//
// ① **比较的是标准差,不是方差。** StaticInitializer.cpp:82 是
//        a_var_1to0 = sqrt( Σ‖aᵢ − ā‖² / (N−1) )
//    变量名叫 `a_var_*`、配置注释也写 "variance",但**值是开了方的**。
//    ⇒ `init_imu_thresh: 1.5` 的单位是 **m/s²**,不是 (m/s²)²。
//    我原先拿未开方的量去比 1.5,是**量纲错**。
//    (向量口径我原先猜对了:是对**窗均值向量**的偏差、三轴点积求和。)
//
// ② **是 N−1 不是 N**(同行,Bessel)。N≈100 时只差 0.5%,不改判定,
//    但复刻就该一样。
//
// ③ **窗要劈成两半,两半都得过 —— 不是整窗一个数。**
//    StaticInitializer.cpp:57-64,以 `newest − 0.5·T` 为界:
//        window_1to0 = (newest − 0.5·T, newest]         ← **新**的一半
//        window_2to1 = (newest − 1.0·T, newest − 0.5·T] ← **老**的一半
//    非 jerk 路径(就是我们要的那条)在 :115 处否决:
//        if ((a_var_1to0 > thresh || a_var_2to1 > thresh) && !wait_for_jerk)
//    即**两半都要低于阈值**。这不是实现细节:整窗取一个均值,末尾 0.3 秒的
//    抖动会被前面 1.7 秒的静止稀释掉;劈两半才咬得住。
//
//    视差那一半同构(InertialInitializer.cpp:112-130):
//        newest_time_allowed = newest_cam − 0.5·T
//        avg_disp0 = disparity(…, 到 newest_time_allowed)      ← 老的一半
//        avg_disp1 = disparity(…, newest_cam, newest_time_allowed) ← 新的一半
//        is_still  = (avg_disp0 ≤ thresh) && (avg_disp1 ≤ thresh)
//    两半比的是**同一个** `init_max_disparity`。
//
// ══ 🔴 角速度:两个出处**不一致**,摆出来不替它们选 ═════════════════════════
// XR-VIO 正文说的是 "standard deviation of acceleration **and angular
// velocity**"。而 OpenVINS 源码里**根本没有角速度阈值** —— 通读
// StaticInitializer.cpp 只有 `a_var_*` 与 `init_imu_thresh` 比较;陀螺只在
// :91 算了个 `w_avg_2to1`,那是拿去初始化零偏的,不参与判定。
// ⇒ 本文件把角速度标准差**算出来、报出去**,但阈值**可选、默认不参与**
//   (与 OpenVINS 一致)。要用的话得自己给阈值,并且知道那一步没有 OpenVINS
//   的出处背书。
//
// ══ 🔴 阈值不是普适常数 —— 上游发布的 **14 份**配置全表 ═══════════════════
//
// 🔴 我上一版写的是「OpenVINS 自己三份配置三个值」「窗长恒为 2.0 秒(设计值,
//    可直接抄)」。**两句都错**:我只翻了三份就下判词。全表如下(2026-09-18
//    逐份核过 master 的 `config/*/estimator_config.yaml`):
//
//   配置                window  imu_th  max_disp  max_feat  try_zupt  zupt_disp
//   euroc_mav(无人机)    2.0     1.5     10.0       50      false      0.5
//   kaist(车)            2.0     0.5      1.5       50      **true**   0.4
//   kaist_vio            2.0     0.60     5.0       50      false      0.20
//   rpng_aruco           2.0     1.2      2.0       50      false      0.5
//   rpng_ironsides       2.0     0.5      1.5       50      **true**   0.4
//   rpng_plane           2.0     0.5      4.0       50      false      1.5
//   rpng_sim             2.0     1.0      1.5       15      false      0
//   rs_d455 / rs_t265    2.0     1.5     10.0       50      false      0.5
//   **tum_vi(手持)**   **1.5**  0.45    15.0       50      false      2.0
//   uzhfpv ×4(竞速机)   2.0     0.30     2.0       50      false      0.5
//
//   ⇒ 窗长**不是**恒为 2.0:**tum_vi 是 1.5**。2.0 只是 13/14 的取值。
//   ⇒ 视差阈值跨度 1.5–15.0,注释自认 "dependent on resolution";而且
//     512×512 给 15.0、752×480 给 10.0,**本身就没有干净的换算规律**。
//
// 🔴 **我们要抄的是 `tum_vi`** —— 14 份里唯一的**手持**场景,最贴近手机。
//   见 [kTumViHandheld]。
//
// ⇒ 阈值在本文件做成**必填、无默认**:普适常数不存在,必须由调用方指名道姓
//   地选一份已发布配置(或说明为何偏离)。设默认值就是假装有普适常数。
//
// 量级佐证(**两场独立静止采集**,iPhone 平放桌上,100 Hz × 30 s):
//     第一场 p50 1.301e-2  max 2.523e-2   第二场 p50 1.189e-2  max 1.271e-2
// 取最坏的 2.523e-2 对 tum_vi 的 0.45 ⇒ **富余 17.7 倍**。
// ⇒ IMU 那一半**极其宽松**,它不是用来要求"纹丝不动"的,防的是急动
//   (注释原文 "detect a jerk")。**它不是卡住静止初始化的那道闸。**

// ══ 🔴 真正的闸:`try_zupt` —— 默认关,关着就"越静止越起不来" ═════════════
//
// `VioManagerHelper.cpp:104-107`,上游自己的注释:
//   "We will wait for a jerk if we do not have the zero velocity update
//    enabled. Otherwise we can initialize right away as the zero velocity
//    will handle the stationary case"
//   bool wait_for_jerk = (updaterZUPT == nullptr);
// 而 `VioManagerOptions.h:83` 是 **`bool try_zupt = false;`**,
// 且上表 **14 份里只有 2 份**(kaist / rpng_ironsides)把它打开。
//
// 后果:`wait_for_jerk == true` 时 `StaticInitializer.cpp:101` 会因为
// **新半窗太安静**而主动否决 —— 也就是**静止时根本不初始化,非等你动一下**。
// 社区实证 rpng/open_vins#373 的日志:
//     disparity is 0.215,0.254 (10.00 thresh)   ← 视差判静止,富余 46 倍
//     failed static init: no accel jerk detected ← 仍然拒绝
//
// ⇒ 本文件把这个开关**建成必填参数** [zeroVelocityUpdateEnabled],
//   并把最终走向报成 [InitDecision]。上一版只实现了 `!wait_for_jerk` 那一支,
//   等于**默默假设了 try_zupt=true**,把真正的闸藏掉了。
//
// 排第二的闸是**特征数**(两个半跨度各自 ≥ 15,`InertialInitializer.cpp:121`):
// 社区里报得最多的就是 `not enough feats to compute disp: 0,0 < 15`
// (rpng/open_vins#373、#511、introlab/rtabmap#1144)。那是纹理/跟踪管线
// 的问题,调阈值解决不了。
//
// ⚠️ 本文件**不含** GLRT/SHOE 检测器(`zero_velocity_detector.dart`)。
// 那一条是把 IMU 判据按噪声 σ 归一化的严格形式,出处是 Skog 一脉;但**我们
// 这条血统用的不是它**,XR-VIO 与 OpenVINS 用的都是原始统计量。保留为备选,
// 不接进这个门。

import 'dart:math' as math;

import 'gravity_attitude.dart' show ImuSample;

/// 判定结果。**三态**,不是布尔 —— "还不知道"和"在动"是两件事。
enum Stationarity {
  /// 四个量(两半窗 × {IMU, 视差})全部低于阈值。
  stationary,

  /// 至少一个量超阈值。
  moving,

  /// 数据不足以判断:窗没满、某半窗样本 < 2、没有视差输入、或某半窗
  /// 跟踪到的特征 < 15。**不要当成 moving。**
  ///
  /// 对应 OpenVINS 在这些情形下 `return false`(不初始化)。我们多一个
  /// 状态,是因为调用方需要分得清"在动"和"没数据"——前者要等,后者要修。
  unknown,
}

/// 初始化最终走哪条路。照 `InertialInitializer.cpp:133-147` 的分支。
enum InitDecision {
  /// `has_jerk && wait_for_jerk` ⇒ 静态初始化,用**急动前**那一半的数据。
  /// 🔴 这是 14 份配置里 **12 份**的默认走向:**必须先动一下**。
  staticAfterJerk,

  /// `is_still && !wait_for_jerk` ⇒ 静止直接初始化。
  /// **只有 `try_zupt: true` 时才可能走到**(kaist / rpng_ironsides)。
  staticWhileStationary,

  /// `init_dyn_use && !is_still` ⇒ 动态初始化。
  dynamicInit,

  /// 以上都不成立,或前置守卫(窗/样本/特征)没过 ⇒ 不初始化。
  refuse,
}

/// 一份**已发布**的 OpenVINS 配置。
///
/// 🔴 抄就整份抄,**不要跨配置拼参数** —— 上游的取值是按场景一起调的
/// (例如 tum_vi 同时把窗调短到 1.5、imu 阈值压到 0.45、视差放宽到 15.0)。
class OpenVinsInitConfig {
  const OpenVinsInitConfig({
    required this.name,
    required this.windowSeconds,
    required this.imuExcitationThreshold,
    required this.maxDisparityPixels,
    required this.tryZupt,
    required this.zuptMaxDisparityPixels,
    required this.note,
  });

  final String name;
  final double windowSeconds;
  final double imuExcitationThreshold;
  final double maxDisparityPixels;
  final bool tryZupt;
  final double zuptMaxDisparityPixels;
  final String note;
}

/// 🔴 **我们该抄的那一份**:14 份里唯一的**手持**场景。
///
/// 注意它和常被引用的 euroc_mav 差得很远:窗 1.5 不是 2.0、imu 阈值 0.45
/// 不是 1.5、视差 15.0 不是 10.0。原文 `init_imu_thresh: 0.45` 后面还跟着
/// 注释 `# room1-5:0.45, room6:0.25` —— 同一个数据集内部不同场次都要改。
///
/// ⚠️ 它的 `try_zupt` 也是 **false** ⇒ 连手持这份参考配置都**不做静止初始化**。
const OpenVinsInitConfig kTumViHandheld = OpenVinsInitConfig(
  name: 'tum_vi',
  windowSeconds: 1.5,
  imuExcitationThreshold: 0.45,
  maxDisparityPixels: 15.0,
  tryZupt: false,
  zuptMaxDisparityPixels: 2.0,
  note: '手持;512×512;room1-5 用 0.45,room6 用 0.25',
);

/// 最常被引用的一份(无人机)。放在这里是为了对照,**不是**我们的默认。
const OpenVinsInitConfig kEurocMav = OpenVinsInitConfig(
  name: 'euroc_mav',
  windowSeconds: 2.0,
  imuExcitationThreshold: 1.5,
  maxDisparityPixels: 10.0,
  tryZupt: false,
  zuptMaxDisparityPixels: 0.5,
  note: '无人机;752×480',
);

/// 14 份里**仅有的两份** `try_zupt: true` 之一 —— 也就是仅有的两份真能
/// "静止直接初始化"的配置。注意它把 `zupt_max_disparity` 压到 0.4。
const OpenVinsInitConfig kKaist = OpenVinsInitConfig(
  name: 'kaist',
  windowSeconds: 2.0,
  imuExcitationThreshold: 0.5,
  maxDisparityPixels: 1.5,
  tryZupt: true,
  zuptMaxDisparityPixels: 0.4,
  note: '车载;try_zupt=true',
);

/// 半个窗的 IMU 统计量。对应 OpenVINS 的 `window_1to0` / `window_2to1`。
class HalfWindowImuStats {
  const HalfWindowImuStats({
    required this.accelStdDev,
    required this.gyroStdDev,
    required this.sampleCount,
  });

  /// `sqrt( Σ‖aᵢ − ā‖² / (N−1) )`,单位 **m/s²**。
  /// 这就是 OpenVINS 拿去和 `init_imu_thresh` 比的那个量
  /// (它变量名叫 `a_var_*`,但值是标准差 —— 见文件头 ①)。
  /// 样本 < 2 时为 `null`。
  final double? accelStdDev;

  /// 角速度的同一个量,单位 **rad/s**。OpenVINS 不拿它做判定(见文件头)。
  final double? gyroStdDev;

  final int sampleCount;

  bool get usable => accelStdDev != null;

  @override
  String toString() => 'a=${accelStdDev?.toStringAsExponential(3)}m/s² '
      'g=${gyroStdDev?.toStringAsExponential(3)}rad/s n=$sampleCount';
}

/// 一次判定的全部中间量。失败时要能看出**是哪一个量把它否掉的**。
class StationarityVerdict {
  const StationarityVerdict({
    required this.state,
    required this.olderHalf,
    required this.newerHalf,
    required this.disparityOlderPixels,
    required this.disparityNewerPixels,
    required this.featureCountOlder,
    required this.featureCountNewer,
    required this.windowSeconds,
    required this.rejectedBy,
    required this.decision,
  });

  /// 这一刻 OpenVINS 的流程会走哪条路。🔴 `stationary` 不等于"能初始化":
  /// `try_zupt=false`(14 份里 12 份)时,静止只会得到 [InitDecision.refuse]。
  final InitDecision decision;

  /// `window_2to1`:(newest − T, newest − 0.5·T]。
  /// 🔴 OpenVINS 的重力方向与初始零偏取自**这一半**(StaticInitializer.cpp:87-96)。
  final HalfWindowImuStats olderHalf;

  /// `window_1to0`:(newest − 0.5·T, newest]。
  final HalfWindowImuStats newerHalf;

  final Stationarity state;

  /// `avg_disp0` —— 老的那半跨度上的平均特征位移,像素。
  final double? disparityOlderPixels;

  /// `avg_disp1` —— 新的那半跨度上的平均特征位移,像素。
  final double? disparityNewerPixels;

  /// 两半各自参与计算的特征数。OpenVINS 要求**各自 ≥ 15**
  /// (InertialInitializer.cpp:121-126,`feat_thresh = 15`)。
  final int featureCountOlder;
  final int featureCountNewer;

  final double windowSeconds;

  /// 人读的否决原因;[Stationarity.stationary] 时为 `null`。
  final String? rejectedBy;

  @override
  String toString() => 'Stationarity(${state.name}→${decision.name} '
      'older[$olderHalf] newer[$newerHalf] '
      'disp=${disparityOlderPixels?.toStringAsFixed(2)},'
      '${disparityNewerPixels?.toStringAsFixed(2)}px '
      'feats=$featureCountOlder,$featureCountNewer'
      '${rejectedBy == null ? '' : ' ✗$rejectedBy'})';
}

/// 两量静止门。窗劈两半,**两半 × 两量,四个数全过才算静止**。
class StationarityGate {
  StationarityGate({
    required this.imuExcitationThreshold,
    required this.disparityThresholdPixels,
    required this.zeroVelocityUpdateEnabled,
    this.dynamicInitEnabled = false,
    this.gyroStdDevThreshold,
    this.windowSeconds = kOpenVinsWindowSeconds,
  })  : assert(imuExcitationThreshold > 0),
        assert(disparityThresholdPixels > 0),
        assert(windowSeconds > 0);

  /// 🔴 **整份抄**一个已发布配置。优先用这个,不要自己拼参数。
  /// 我们的场景抄 [kTumViHandheld](14 份里唯一的手持)。
  factory StationarityGate.fromConfig(
    OpenVinsInitConfig c, {
    bool dynamicInitEnabled = false,
    double? gyroStdDevThreshold,
  }) =>
      StationarityGate(
        imuExcitationThreshold: c.imuExcitationThreshold,
        disparityThresholdPixels: c.maxDisparityPixels,
        zeroVelocityUpdateEnabled: c.tryZupt,
        windowSeconds: c.windowSeconds,
        dynamicInitEnabled: dynamicInitEnabled,
        gyroStdDevThreshold: gyroStdDevThreshold,
      );

  /// `try_zupt`。🔴 **必填,故意不给默认值。**
  /// 上游默认 `false`,而 `false` 的后果是**静止时永远不初始化**
  /// (`wait_for_jerk = (updaterZUPT == nullptr)`)。这是整套判据里最容易
  /// 被忽略、后果又最大的一个开关,所以逼调用方明确写出来。
  final bool zeroVelocityUpdateEnabled;

  /// `init_dyn_use`。不开则"在动"时只能 [InitDecision.refuse]。
  final bool dynamicInitEnabled;

  /// `wait_for_jerk = (updaterZUPT == nullptr)`(VioManagerHelper.cpp:106)。
  bool get waitForJerk => !zeroVelocityUpdateEnabled;

  /// `init_window_time: 2.0`。**三份 OpenVINS 配置完全一致**,是设计值不是
  /// 场景参数,所以这一个可以直接抄,并作为默认值。
  static const double kOpenVinsWindowSeconds = 2.0;

  /// 每半窗最少样本数。OpenVINS:`window_1to0.size() < 2 || window_2to1.size() < 2`
  /// ⇒ 不足则 `return false`(StaticInitializer.cpp:67)。
  static const int kMinSamplesPerHalfWindow = 2;

  /// 每半跨度最少特征数。OpenVINS:`int feat_thresh = 15;`
  /// (InertialInitializer.cpp:121)。
  static const int kMinFeaturesPerHalfSpan = 15;

  /// 🔴 缓冲区要比窗**多留**这么多秒。抄自 InertialInitializer.cpp:91:
  ///     oldest_time = newest_cam_time - params.init_window_time - 0.10;
  ///
  /// 这个 `0.10` 看着像随手加的余量,其实是**必需**的:窗的两半是左开右闭
  /// `(newest − T, newest]`,若缓冲区恰好只留 T 秒,最老的一条严格晚于
  /// `newest − T`,跨度就**永远严格小于 T**,「窗满」这个条件**永远为假**。
  /// (我第一版就是这样,14 项测试全灭才看出来。)多留一截,窗才满得了。
  static const double kBufferMarginSeconds = 0.10;

  /// 🔴 必填,无默认值。对应 `init_imu_thresh`,单位 **m/s²**(标准差,不是
  /// 方差 —— 见文件头 ①)。量级参考(OpenVINS 三份配置):0.5 / 1.2 / 1.5。
  final double imuExcitationThreshold;

  /// 🔴 必填,无默认值。对应 `init_max_disparity`,单位**像素**。
  /// 量级参考:2.0 / 4.0 / 10.0,且注释自己写着 "dependent on resolution"。
  /// 🔴 它量的是**半个窗(≈1 秒)跨度上的位移**,不是相邻帧之间的 ——
  ///    30 fps 下这两者差约 30 倍,照搬到帧间会把阈值放松 30 倍。
  final double disparityThresholdPixels;

  /// 可选。OpenVINS 源码里**没有**这一项(见文件头);XR-VIO 文字里提到了
  /// 角速度。不填 ⇒ 不参与判定(与 OpenVINS 一致),单位 rad/s。
  final double? gyroStdDevThreshold;

  final double windowSeconds;

  final List<double> _t = <double>[];
  final List<ImuSample> _s = <ImuSample>[];

  /// 喂一条 IMU 样本。用 `sample.timestampSeconds` 维持 [windowSeconds] 的时间窗
  /// ——**按时间而不是按样本数**,因为采样率会变(生产 100 Hz、台架可能不同,
  /// 三端也不同),按样本数会让窗的**时长**随平台漂。
  void add(ImuSample sample) {
    final double timestampSeconds = sample.timestampSeconds;
    _t.add(timestampSeconds);
    _s.add(sample);
    // 🔴 多留 [kBufferMarginSeconds],否则窗永远满不了 —— 见该常量的注释。
    final double cutoff =
        timestampSeconds - windowSeconds - kBufferMarginSeconds;
    int drop = 0;
    while (drop < _t.length && _t[drop] < cutoff) {
      drop++;
    }
    if (drop > 0) {
      _t.removeRange(0, drop);
      _s.removeRange(0, drop);
    }
  }

  void reset() {
    _t.clear();
    _s.clear();
  }

  /// 窗内样本数。
  int get count => _s.length;

  /// 窗是否已经覆盖满 [windowSeconds]。
  /// OpenVINS:`if (newesttime - oldesttime < init_window_time) return false;`
  /// (StaticInitializer.cpp:50)。
  bool get windowFull =>
      _t.length >= 2 && (_t.last - _t.first) >= windowSeconds;

  /// 判定。
  ///
  /// [disparityOlderPixels] / [disparityNewerPixels] 是**两半跨度**各自的平均
  /// 特征位移,[featureCountOlder] / [featureCountNewer] 是各自参与平均的特征
  /// 数。任一为 `null` 或特征数不足 ⇒ [Stationarity.unknown],**不是** moving。
  ///
  /// 用 [DisparitySpan.fromMatchedPairs] 从跟踪结果算这两个数。
  StationarityVerdict evaluate({
    required double? disparityOlderPixels,
    required double? disparityNewerPixels,
    int featureCountOlder = 0,
    int featureCountNewer = 0,
  }) {
    final HalfWindowImuStats older = _statsBetween(
      lowExclusive: _t.isEmpty ? 0 : _t.last - windowSeconds,
      highInclusive: _t.isEmpty ? 0 : _t.last - 0.5 * windowSeconds,
    );
    final HalfWindowImuStats newer = _statsBetween(
      lowExclusive: _t.isEmpty ? 0 : _t.last - 0.5 * windowSeconds,
      highInclusive: _t.isEmpty ? 0 : _t.last,
    );

    StationarityVerdict verdict(Stationarity s, InitDecision d, String? why) =>
        StationarityVerdict(
          state: s,
          decision: d,
          olderHalf: older,
          newerHalf: newer,
          disparityOlderPixels: disparityOlderPixels,
          disparityNewerPixels: disparityNewerPixels,
          featureCountOlder: featureCountOlder,
          featureCountNewer: featureCountNewer,
          windowSeconds: windowSeconds,
          rejectedBy: why,
        );

    if (!windowFull) {
      return verdict(Stationarity.unknown, InitDecision.refuse,
          '窗未满 ${windowSeconds}s');
    }
    if (!older.usable || !newer.usable) {
      return verdict(Stationarity.unknown, InitDecision.refuse,
          '半窗样本不足(<$kMinSamplesPerHalfWindow):老${older.sampleCount} 新${newer.sampleCount}');
    }
    if (disparityOlderPixels == null || disparityNewerPixels == null) {
      return verdict(Stationarity.unknown, InitDecision.refuse, '无视差输入');
    }
    if (featureCountOlder < kMinFeaturesPerHalfSpan ||
        featureCountNewer < kMinFeaturesPerHalfSpan) {
      return verdict(Stationarity.unknown, InitDecision.refuse,
          '特征不足(<$kMinFeaturesPerHalfSpan):老$featureCountOlder 新$featureCountNewer');
    }

    // ═══ 两半 × 两量,先算出四个布尔 ═══════════════════════════════════════
    final bool movingOlder = disparityOlderPixels > disparityThresholdPixels;
    final bool movingNewer = disparityNewerPixels > disparityThresholdPixels;
    // InertialInitializer.cpp:135-136
    final bool hasJerk = !movingOlder && movingNewer;
    final bool isStill = !movingOlder && !movingNewer;

    final bool imuOlderQuiet = older.accelStdDev! <= imuExcitationThreshold;
    final bool imuNewerQuiet = newer.accelStdDev! <= imuExcitationThreshold;

    final double? gt = gyroStdDevThreshold;
    final bool gyroQuiet = gt == null ||
        (older.gyroStdDev! <= gt && newer.gyroStdDev! <= gt);

    // ═══ 逐量归因:失败时必须看得出**是哪一个量**把它否掉的 ═══════════════
    final List<String> over = <String>[];
    if (movingOlder) {
      over.add(
          '视差(老) ${disparityOlderPixels.toStringAsFixed(2)} > $disparityThresholdPixels px');
    }
    if (movingNewer) {
      over.add(
          '视差(新) ${disparityNewerPixels.toStringAsFixed(2)} > $disparityThresholdPixels px');
    }
    if (!imuOlderQuiet) {
      over.add(
          '加速度σ(老) ${older.accelStdDev!.toStringAsExponential(3)} > $imuExcitationThreshold m/s²');
    }
    if (!imuNewerQuiet) {
      over.add(
          '加速度σ(新) ${newer.accelStdDev!.toStringAsExponential(3)} > $imuExcitationThreshold m/s²');
    }
    if (gt != null && older.gyroStdDev! > gt) {
      over.add(
          '角速度σ(老) ${older.gyroStdDev!.toStringAsExponential(3)} > $gt rad/s');
    }
    if (gt != null && newer.gyroStdDev! > gt) {
      over.add(
          '角速度σ(新) ${newer.gyroStdDev!.toStringAsExponential(3)} > $gt rad/s');
    }
    final String? attribution = over.isEmpty ? null : over.join('; ');
    String? msg(String? decisionWhy) => attribution == null
        ? decisionWhy
        : (decisionWhy == null ? attribution : '$decisionWhy | $attribution');

    // ═══ 「现在静不静」——XR-VIO 正文问的那个问题 ═════════════════════════
    final Stationarity state =
        (isStill && imuOlderQuiet && imuNewerQuiet && gyroQuiet)
            ? Stationarity.stationary
            : Stationarity.moving;

    // ═══ 「会不会初始化」——照 InertialInitializer.cpp:133-147 + ═══════════
    //     StaticInitializer.cpp:101-117。🔴 这两件事**不是同一件**。
    if (hasJerk && waitForJerk) {
      if (imuNewerQuiet) {
        return verdict(state, InitDecision.refuse,
            msg('no IMU excitation:新半窗 ${newer.accelStdDev!.toStringAsExponential(3)} < $imuExcitationThreshold'));
      }
      if (!imuOlderQuiet) {
        return verdict(state, InitDecision.refuse,
            msg('too much IMU excitation(老半窗)'));
      }
      return verdict(state, InitDecision.staticAfterJerk, msg(null));
    }

    if (isStill && !waitForJerk) {
      if (!imuOlderQuiet || !imuNewerQuiet) {
        return verdict(
            state, InitDecision.refuse, msg('too much IMU excitation'));
      }
      return verdict(state, InitDecision.staticWhileStationary, msg(null));
    }

    if (dynamicInitEnabled && !isStill) {
      return verdict(state, InitDecision.dynamicInit, msg(null));
    }

    // 🔴 最常见的一支:**静止、但 try_zupt 关着** ⇒ 它在等你动一下。
    return verdict(
        state,
        InitDecision.refuse,
        msg(isStill && waitForJerk
            ? '静止,但 try_zupt=false ⇒ wait_for_jerk,要等一次急动才初始化'
            : '不满足任何一支(dynamicInit=$dynamicInitEnabled)'));
  }

  /// **老半窗**的原始样本 `(newest − T, newest − 0.5·T]`。
  ///
  /// 🔴 给 `GravityAttitude.solve` 用的就是这一半,不是整窗、不是新半窗 ——
  /// OpenVINS `StaticInitializer.cpp:87-96` 的重力方向与初始零偏取自
  /// `window_2to1`,:134 还把状态时间戳定在 `window_2to1` 的最后一条上。
  /// 理由在 wait_for_jerk 那条路上最清楚:急动发生在**新**半窗,拿它算重力
  /// 就把急动的加速度当成重力了。非 jerk 路上两半都静,取老的一半与上游一致。
  List<ImuSample> olderHalfSamples() => _pickBetween(
        lowExclusive: _t.isEmpty ? 0 : _t.last - windowSeconds,
        highInclusive: _t.isEmpty ? 0 : _t.last - 0.5 * windowSeconds,
      );

  List<ImuSample> _pickBetween({
    required double lowExclusive,
    required double highInclusive,
  }) {
    final List<ImuSample> picked = <ImuSample>[];
    for (int i = 0; i < _t.length; i++) {
      if (_t[i] > lowExclusive && _t[i] <= highInclusive) picked.add(_s[i]);
    }
    return picked;
  }

  /// 取 `(lowExclusive, highInclusive]` 内的样本算统计量。
  /// 左开右闭是照 OpenVINS 的窗口条件(`> low && <= high`)。
  HalfWindowImuStats _statsBetween({
    required double lowExclusive,
    required double highInclusive,
  }) {
    final List<ImuSample> picked =
        _pickBetween(lowExclusive: lowExclusive, highInclusive: highInclusive);
    if (picked.length < kMinSamplesPerHalfWindow) {
      return HalfWindowImuStats(
        accelStdDev: null,
        gyroStdDev: null,
        sampleCount: picked.length,
      );
    }
    return HalfWindowImuStats(
      accelStdDev: sampleStdDev(
          picked.map((ImuSample s) => <double>[s.ax, s.ay, s.az]).toList()),
      gyroStdDev: sampleStdDev(
          picked.map((ImuSample s) => <double>[s.gx, s.gy, s.gz]).toList()),
      sampleCount: picked.length,
    );
  }

  /// `sqrt( Σ‖vᵢ − v̄‖² / (N−1) )` —— 三轴向量对**窗均值向量**的样本标准差。
  ///
  /// 🔴 这三处口径都是读 OpenVINS 源码定的,不是我挑的:
  ///   * 偏差是对**均值向量**取的,三轴点积求和(不是逐轴分别算、也不是
  ///     先取模长再算方差 —— 这三者数值不同);
  ///   * 除以 **N−1**(Bessel);
  ///   * **开方**。
  ///
  /// 数值上:加速度带着 ~9.81 的直流,减均值是灾难性抵消,相对误差上界
  /// ≈ eps·(‖均值‖/σ)²。手机静止时 ‖均值‖/σ ≈ 1.4e3 ⇒ 相对误差可到 ~4e-10。
  /// 这对 1.5 m/s² 的阈值毫无影响,但写测试时容差得按这个量级给。
  static double? sampleStdDev(List<List<double>> v) {
    if (v.length < 2) return null;
    final int n = v.length;
    double mx = 0, my = 0, mz = 0;
    for (final List<double> x in v) {
      mx += x[0];
      my += x[1];
      mz += x[2];
    }
    mx /= n;
    my /= n;
    mz /= n;
    double s = 0;
    for (final List<double> x in v) {
      final double dx = x[0] - mx, dy = x[1] - my, dz = x[2] - mz;
      s += dx * dx + dy * dy + dz * dz;
    }
    return math.sqrt(s / (n - 1));
  }
}

/// 一段跨度上的平均特征位移 —— 对应 OpenVINS 的
/// `FeatureHelper::compute_disparity`,文档原文:
///   "The average raw disparity" … "NOTE: this is on the RAW coordinates of
///    the feature not the normalized ones."
/// ⇒ **原始像素坐标**,不做归一化、不除焦距、不去畸变。
///
/// 输入是**同一批特征在跨度两端的像素坐标对**。XRSLAM 自己的跟踪器
/// (`xrslam-extra/src/xrslam/extra/opencv_image.cpp:75` `track_keypoints`,
/// Apache-2.0)正好给这个:LK 光流 + 反向检查,输出 `next_keypoints` 与
/// `result_status`,取 `result_status[i] != 0` 的配对即可。
class DisparitySpan {
  const DisparitySpan({required this.meanPixels, required this.featureCount});

  /// 参与平均的特征数不足 [StationarityGate.kMinFeaturesPerHalfSpan] 时,
  /// [meanPixels] 仍会给出,但门会判 [Stationarity.unknown]。
  final double? meanPixels;
  final int featureCount;

  /// 从匹配好的像素坐标对算平均位移。[pairs] 每项是 `[x0, y0, x1, y1]`。
  static DisparitySpan fromMatchedPairs(List<List<double>> pairs) {
    if (pairs.isEmpty) {
      return const DisparitySpan(meanPixels: null, featureCount: 0);
    }
    double sum = 0;
    for (final List<double> p in pairs) {
      final double dx = p[2] - p[0], dy = p[3] - p[1];
      sum += math.sqrt(dx * dx + dy * dy);
    }
    return DisparitySpan(
      meanPixels: sum / pairs.length,
      featureCount: pairs.length,
    );
  }
}
