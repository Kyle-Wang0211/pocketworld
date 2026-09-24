// xrslam_tracking_state.dart —— XRSLAM 引擎状态 → 既有 ARKit 状态词表。
//
// ══ 映射的两端各是什么 ═════════════════════════════════════════════════════
// **左边**:`XRSLAMState`(`vendor/xrslam/include/XRSLAM.h:101-105`),**只有
// 三个取值**:`INITIALIZING(0)` / `TRACKING_SUCCESS(1)` / `TRACKING_FAIL(2)`。
// **右边**:`ARPose.trackingStateName` 的七个字符串(`ar_pose.dart:76-88`),
// 逐字复刻 `ARCamera.TrackingState` 的分类:
//     normal / not_available /
//     limited_initializing / limited_relocalizing /
//     limited_excessive_motion / limited_insufficient_features /
//     limited_unknown
//
// 🔴 **词表不能加词。** `PoseDriftTracker` 按字符串聚合(`pose_drift_tracker
// .dart:204`),多一个词它就归不了类;`capture_session.dart:1584/1708` 还有两处
// 按字面量比较的闸。所以右边只能从那七个里选。
//
// ══ 🔴 三对多 ⇒ 必须显式承认「不知道」════════════════════════════════════
// ARKit 那七个里有四个是**诊断原因**(excessive_motion / insufficient_features
// / relocalizing / unknown),XRSLAM **一个都不报** —— 它的 `TRACKING_FAIL`
// 只说「失败了」,不说为什么。
//
// 所以本表里:
//   · `TRACKING_FAIL` → **`limited_unknown`**,不是 `limited_excessive_motion`
//     也不是 `limited_insufficient_features`。把「引擎没说」写成一个具体原因
//     就是编数据 —— 而且这两个词正好是 `capture_session.dart:1584` 的
//     `_isExcessiveMotion` 闸在读的,编错方向会直接改采集行为。
//   · 没有任何取值映射到 `limited_relocalizing`:XRSLAM 出货构建里
//     **没有重定位**(loop closure 的结果通道 09-19 实测是空实现),
//     报这个词等于宣称一个不存在的能力。
//   · `not_available` 留给「会话根本没建起来」,那不是引擎状态,是**会话状态**
//     —— 所以它由 [xrslamTrackingStateName] 的 `sessionAlive` 参数决定,
//     不在三值表里。
//
// ⚠️ `TRACKING_SUCCESS` → `normal` 是本表里**唯一**一条语义完全对齐的:两边
//    都表示「6DOF 位姿可用」。其余两条是**降级**映射,精度上不等价,
//    [kXrslamTrackingStateMappingConfidence] 逐条标了。

import '../ffi/xrslam_bindings.dart' show XRSLAMState;

/// 一条映射的把握程度。落进遥测/报告,让读的人知道哪几条是猜的。
enum XrslamStateMappingConfidence {
  /// 两边语义相同。
  exact,

  /// 右边比左边更粗或更细,但方向没错(不会把坏当好)。
  degraded,

  /// 引擎没提供对应信息 ⇒ 右边取最保守的那个词。**不猜具体原因。**
  unknown,
}

/// 一条映射。
class XrslamStateMapping {
  const XrslamStateMapping({
    required this.engineState,
    required this.trackingStateName,
    required this.isTracking,
    required this.confidence,
    required this.why,
  });

  /// `XRSLAMState` 的原值(0/1/2)。
  final int engineState;

  /// `ARPose.trackingStateName` 的取值。**必须在七词表里。**
  final String trackingStateName;

  /// `ARPose.isTracking` —— 只有 6DOF 可用才是 true。
  final bool isTracking;

  final XrslamStateMappingConfidence confidence;

  /// 为什么是这个词。报告与遥测直接引用。
  final String why;
}

/// `ARPose.trackingStateName` 的**封闭**词表。逐字取自 `ar_pose.dart:76-88`。
/// 映射表的每一条都要落在这里面 —— 有单测逐条查。
const Set<String> kArTrackingStateVocabulary = <String>{
  'normal',
  'not_available',
  'limited_initializing',
  'limited_relocalizing',
  'limited_excessive_motion',
  'limited_insufficient_features',
  'limited_unknown',
};

/// 会话没建起来时的取值。**不是**引擎状态,见文件头。
const String kXrslamSessionNotAvailable = 'not_available';

/// 三值表本体。`XRSLAMState` 只有这三个取值,没有第四个。
const Map<int, XrslamStateMapping> kXrslamTrackingStateMap =
    <int, XrslamStateMapping>{
  0: XrslamStateMapping(
    engineState: 0, // XRSLAM_STATE_INITIALIZING
    trackingStateName: 'limited_initializing',
    isTracking: false,
    confidence: XrslamStateMappingConfidence.exact,
    why: 'XRSLAM_STATE_INITIALIZING 与 ARKit 的 .limited(.initializing) '
        '语义相同:视觉惯性初始化还没收敛,没有 6DOF。',
  ),
  1: XrslamStateMapping(
    engineState: 1, // XRSLAM_STATE_TRACKING_SUCCESS
    trackingStateName: 'normal',
    isTracking: true,
    confidence: XrslamStateMappingConfidence.exact,
    why: '两边都表示 6DOF 位姿可用。本表里唯一语义完全对齐的一条。',
  ),
  2: XrslamStateMapping(
    engineState: 2, // XRSLAM_STATE_TRACKING_FAIL
    trackingStateName: 'limited_unknown',
    isTracking: false,
    confidence: XrslamStateMappingConfidence.unknown,
    why: '🔴 XRSLAM 只说「失败」不说原因。ARKit 的四个诊断原因 '
        '(excessive_motion / insufficient_features / relocalizing / unknown)'
        '引擎一个都不报 ⇒ 取 limited_unknown。写成 excessive_motion 会直接 '
        '触发 capture_session.dart:1584 的既有闸,那是编数据改行为。',
  ),
};

/// 逐条的把握程度,给报告/遥测读。
const Map<int, XrslamStateMappingConfidence>
    kXrslamTrackingStateMappingConfidence = <int, XrslamStateMappingConfidence>{
  0: XrslamStateMappingConfidence.exact,
  1: XrslamStateMappingConfidence.exact,
  2: XrslamStateMappingConfidence.unknown,
};

/// ARKit 那七个词里**本表永远不会产出**的三个,以及为什么。
/// 写成常量而不是注释,是为了让「我们宣称不了这三种状态」这件事可被测试查。
const Map<String, String> kXrslamUnreachableTrackingStates = <String, String>{
  'limited_relocalizing': '出货 XRSLAM 构建没有重定位(loop closure 结果通道'
      '09-19 实证是空实现)⇒ 报这个词等于宣称一个不存在的能力。',
  'limited_excessive_motion': '引擎不报原因(见 TRACKING_FAIL 那条)。'
      '而且这个词是 capture_session 既有闸的触发条件,编不得。',
  'limited_insufficient_features': '同上;另外 XRSLAMGetResult(RESULT_FEATURES) '
      '在出货引擎里是空实现(09-19 实证),连判据都拿不到。',
};

/// 引擎状态 → 词表取值。
///
/// [engineState] 传 `null` 表示**还没读到过引擎状态**。
/// [sessionAlive] = `XrslamSession.current != null`。会话没建起来时一律
/// `not_available` —— 那是会话状态不是引擎状态,优先级最高。
///
/// 🔴 未知的 [engineState](不是 0/1/2)**不静默回落**:返回
/// `limited_unknown` 并在 [xrslamTrackingStateMappingOf] 里标成 unknown。
/// 引擎哪天加了第四个状态码,读遥测的人要能看见「我们不认识它」。
String xrslamTrackingStateName({
  required int? engineState,
  required bool sessionAlive,
}) {
  if (!sessionAlive) return kXrslamSessionNotAvailable;
  if (engineState == null) return 'limited_initializing';
  final XrslamStateMapping? m = kXrslamTrackingStateMap[engineState];
  return m?.trackingStateName ?? 'limited_unknown';
}

/// 同上,但把整条映射交出来(含 confidence 与 why),给遥测/诊断用。
/// 未知码返回一条 confidence=unknown 的合成映射,**不抛**。
XrslamStateMapping xrslamTrackingStateMappingOf(int engineState) {
  final XrslamStateMapping? m = kXrslamTrackingStateMap[engineState];
  if (m != null) return m;
  return XrslamStateMapping(
    engineState: engineState,
    trackingStateName: 'limited_unknown',
    isTracking: false,
    confidence: XrslamStateMappingConfidence.unknown,
    why: '🔴 未知的 XRSLAMState=$engineState —— 出货头里只有 0/1/2。'
        '按最保守的一档处理,并如实标成 unknown。',
  );
}

/// 引擎状态是否代表 6DOF 可用。
///
/// 🔴 这一条**不等于** `trackingStateName == 'normal'` 的反推 —— 它是独立判据:
/// `EnginePosePoller` 已经按上游的做法「状态不是 TRACKING_SUCCESS 就当没位姿」,
/// 本函数与那一处是同一个口径,写成两处是为了让映射表可以被单独测。
bool xrslamStateIsSixDof(int? engineState) =>
    engineState == XRSLAMState.XRSLAM_STATE_TRACKING_SUCCESS.value;
