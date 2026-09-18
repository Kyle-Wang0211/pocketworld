// static_initializer.dart —— 把判定门接到静止初始化数学上的那根线。
//
// ══ 它补的是哪个缺口 ═══════════════════════════════════════════════════════
// 两头本来就都建好了,中间没人接:
//   * [StationarityGate]        —— 判"现在静不静 / 会不会初始化"(XR-VIO 正文
//                                  的判据 + OpenVINS 已发布配置的常数)
//   * [GravityAttitude.solve]   —— 静止时从 IMU 解重力对齐姿态与零偏
//                                  (Kimera-VIO `InitializationFromImu`,BSD-2)
//   * [VioPoseSource.update]    —— 收 `StationaryAttitude?`,注释明写
//                                  "判定不在本层"
// 本文件就是那个"本层"。**它不新增任何判据**,只做编排。
//
// ══ 🔴 编排里有三处是有出处的决定,不是随手接 ═══════════════════════════════
//
// ① **姿态取自老半窗,不是整窗、不是新半窗。**
//    OpenVINS `StaticInitializer.cpp:87-96` 的重力方向与初始零偏取自
//    `window_2to1`(老的一半),:134 把状态时间戳定在它的最后一条上。
//    理由在 wait_for_jerk 那条路上最清楚:急动发生在**新**半窗,拿新半窗算
//    重力就等于把急动的加速度当成了重力。
//
// ② **只在 [InitDecision] 允许静态初始化时才交出姿态。**
//    `staticWhileStationary`(try_zupt 开着)与 `staticAfterJerk`(默认路径,
//    等到一次急动之后)两支才给;`refuse` / `dynamicInit` 一律交 `null`。
//    🔴 这是本文件存在的第二个理由:**「设备静止」不等于「可以初始化」**。
//    上游 14 份配置里 12 份 `try_zupt: false`,静止时走的是 refuse。
//    把两者混为一谈,就会出现"门说静止、姿态却永远不来"的静默悬挂。
//
// ③ **解不出来就交 `null`,不退化成单位姿态。**
//    [GravityAttitude.solve] 自己也是这个约定(样本不足或非有限 ⇒ null)。
//    单位姿态看起来像个答案,这个代码库在这种静默降级上栽过太多次。
//
// ══ 本文件**不**做什么 ═════════════════════════════════════════════════════
// * 不判断该不该用自研核 —— `capability_decision.dart` 的事。
// * 不换世界系。`gravity_attitude.dart` 的 [GravityAttitude.globalGravityZUp]
//   定的是 z 向上;我们记录在案的两个轴映射互相矛盾,必须先从真机打一个位姿
//   判死才能接渲染器。本文件原样透传,不假装知道它是哪个系。
// * 不给尺度、不给位置。静止起步交的是**姿态**,位置不可观
//   (Kimera 原注释:"Absolute translation is unobservable, so return [0,0,0]")。
//
// ══ 🔴 `zeroVelocityUpdateEnabled` 该设什么:取决于**这个姿态交给谁** ══════
//
// 上游把它写成 `wait_for_jerk = (updaterZUPT == nullptr)`,是因为 OpenVINS 的
// 静止初始化会**写进 EKF 状态**:静止段没有运动约束,没有 ZUPT 更新器扛着,
// 滤波器会飘,所以宁可等一次急动。
//
// 我们有两种用途,答案相反:
//
//   ① 把姿态**喂回 XRSLAM 的滤波器** ⇒ 必须 `false`(等急动)
//      实证:XRSLAM 里 `zupt` / `zero_velocity` / `stationary` / `standstill`
//      四个关键词命中数**全是 0** —— 它一点静止段保护都没有,
//      比 OpenVINS 默认关掉 try_zupt 的处境还差。
//
//   ② 把姿态**交给渲染器当 3DOF 兜底** ⇒ `true` 才对
//      这个输出走的是 [VioPoseSource] 的 `orientationOnly` 档,**不回灌任何
//      滤波器**,不存在发散风险;而且这正是 ARKit 的行为(它静止时也跟踪不了,
//      但自带 3DOF fallback)。
//
// [StaticInitPoseChain] 走的是**②**。字段名沿用上游是为了可追溯,但它在我们
// 这里的语义是「**愿不愿意在静止时就交出姿态**」,不是「有没有 ZUPT 更新器」。
// 🔴 日后若真要把它接回 XRSLAM 的状态初始化,**必须改回 `false`**,
//    否则就是在一个毫无静止段保护的滤波器上做静止初始化。

import 'gravity_attitude.dart';
import 'stationarity_gate.dart';
import 'tracked_pose.dart';
import 'vio_pose_source.dart';

/// 一次编排的结果。中间量全部报出 —— 失败时要看得出卡在哪一环。
class StaticInitAttempt {
  const StaticInitAttempt({
    required this.verdict,
    required this.attitude,
    required this.olderHalfSampleCount,
    required this.blockedBy,
  });

  /// 门这一刻的完整判定(含逐量归因)。
  final StationarityVerdict verdict;

  /// 解出来的静止姿态;没解出来就是 `null`。
  final StationaryAttitude? attitude;

  /// 实际喂给 [GravityAttitude.solve] 的样本数(老半窗)。
  final int olderHalfSampleCount;

  /// 人读的"为什么没有姿态"。有姿态时为 `null`。
  final String? blockedBy;

  bool get hasAttitude => attitude != null;

  @override
  String toString() => 'StaticInitAttempt(${verdict.state.name}'
      '→${verdict.decision.name} '
      'attitude=${attitude == null ? "无" : "有"} '
      'n(老半窗)=$olderHalfSampleCount'
      '${blockedBy == null ? '' : ' ✗$blockedBy'})';
}

/// IMU 流 → 判定门 → 静止姿态。
///
/// 用法就三步,和上游的调用顺序一致:
/// ```dart
/// final init = StaticInitializer(
///   gate: StationarityGate.fromConfig(kTumViHandheld),
/// );
/// init.addImu(sample);                       // 每来一条 IMU
/// init.setDisparity(older: .., newer: ..);   // 每来一对跟踪结果
/// final attempt = init.attempt();            // 想初始化时问一次
/// ```
class StaticInitializer {
  StaticInitializer({
    required this.gate,
    this.minimumSamplesForAttitude = 10,
    this.roundGravityToAxis = false,
  });

  final StationarityGate gate;

  /// 转给 [GravityAttitude.solve] 的 `minimumSamples`。默认 10,与那边一致。
  final int minimumSamplesForAttitude;

  /// 转给 [GravityAttitude.solve] 的 `round`。默认 `false` —— 手机很少恰好
  /// 正对某个轴,吸附会引入它自己造出来的误差(Kimera 也把它做成参数)。
  final bool roundGravityToAxis;

  double? _dispOlder;
  double? _dispNewer;
  int _featOlder = 0;
  int _featNewer = 0;

  /// 每来一条 IMU 就喂。时间戳取自 `sample.timestampSeconds`。
  void addImu(ImuSample sample) => gate.add(sample);

  /// 每算出一对视差就喂。
  ///
  /// [older] / [newer] 是**两个半跨度**各自的平均特征位移(原始像素),
  /// [featureCountOlder] / [featureCountNewer] 是各自参与平均的特征数。
  /// 用 [DisparitySpan.fromMatchedPairs] 从跟踪结果算 —— 我们这条血统的
  /// 跟踪器是 XRSLAM 自己的 `track_keypoints`(Apache-2.0)。
  void setDisparity({
    required double? older,
    required double? newer,
    int featureCountOlder = 0,
    int featureCountNewer = 0,
  }) {
    _dispOlder = older;
    _dispNewer = newer;
    _featOlder = featureCountOlder;
    _featNewer = featureCountNewer;
  }

  /// 问一次:现在能不能拿到静止姿态。
  StaticInitAttempt attempt() {
    final StationarityVerdict v = gate.evaluate(
      disparityOlderPixels: _dispOlder,
      disparityNewerPixels: _dispNewer,
      featureCountOlder: _featOlder,
      featureCountNewer: _featNewer,
    );

    // ② 只有两支静态初始化路径才继续。
    final bool allowed = v.decision == InitDecision.staticWhileStationary ||
        v.decision == InitDecision.staticAfterJerk;
    final List<ImuSample> older = gate.olderHalfSamples();

    if (!allowed) {
      return StaticInitAttempt(
        verdict: v,
        attitude: null,
        olderHalfSampleCount: older.length,
        // 门自己的归因已经很具体,直接透传;没有就说明是决策分支挡的。
        blockedBy: v.rejectedBy ?? '决策为 ${v.decision.name},不走静态初始化',
      );
    }

    // ① 老半窗。
    final StationaryAttitude? a = GravityAttitude.solve(
      older,
      round: roundGravityToAxis,
      minimumSamples: minimumSamplesForAttitude,
    );

    // ③ 解不出来就是解不出来。
    return StaticInitAttempt(
      verdict: v,
      attitude: a,
      olderHalfSampleCount: older.length,
      blockedBy: a == null
          ? '老半窗解不出姿态(样本 ${older.length} < $minimumSamplesForAttitude,或全非有限)'
          : null,
    );
  }

  void reset() {
    gate.reset();
    _dispOlder = null;
    _dispNewer = null;
    _featOlder = 0;
    _featNewer = 0;
  }
}

/// 把整条链接到 [VioPoseSource] 上:引擎出口 + 静止初始化 → [TrackedPose]。
///
/// 这是**生产消费者要调的那一个函数**。在它出现之前,
/// `GravityAttitude.solve` 在生产侧的调用者数是 **0**。
class StaticInitPoseChain {
  StaticInitPoseChain({
    required this.initializer,
    VioPoseSource? source,
  }) : source = source ?? VioPoseSource();

  final StaticInitializer initializer;
  final VioPoseSource source;

  /// 最近一次的编排细节,给探针/日志看。
  StaticInitAttempt? get lastAttempt => _last;
  StaticInitAttempt? _last;

  void addImu(ImuSample sample) => initializer.addImu(sample);

  void setDisparity({
    required double? older,
    required double? newer,
    int featureCountOlder = 0,
    int featureCountNewer = 0,
  }) =>
      initializer.setDisparity(
        older: older,
        newer: newer,
        featureCountOlder: featureCountOlder,
        featureCountNewer: featureCountNewer,
      );

  /// 每帧调一次。[sample] 是引擎那一轮的原始结果。
  ///
  /// 🔴 **只在引擎没给出 6DOF 时才去算静止姿态。** 引擎给了就用引擎的 ——
  /// 静止姿态是初始化期的兜底,不是与 6DOF 并列的另一个来源。
  /// 这也省掉了跟踪期每帧一次的姿态求解。
  TrackedPose update({
    required EnginePoseSample sample,
    required double nowSeconds,
  }) {
    StationaryAttitude? attitude;
    if (!sample.ok && !source.hasEverTracked) {
      final StaticInitAttempt a = initializer.attempt();
      _last = a;
      attitude = a.attitude;
    } else {
      _last = null;
    }
    return source.update(
      sample: sample,
      stationaryAttitude: attitude,
      nowSeconds: nowSeconds,
    );
  }

  void reset() {
    initializer.reset();
    source.reset();
    _last = null;
  }
}
