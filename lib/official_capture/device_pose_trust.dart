// device_pose_trust.dart — [DEVICE-POSE-TRUST 2026-09-24] 每张喂给 SfM 的照片
// 带一个布尔 `devicePoseTrusted`:这张照片自己那一帧的设备位姿,追踪器本身
// 是否承认它可用。纯 Dart,零 Flutter/平台依赖;四端同一份判据。
//
// ── 为什么要有它(cap_1787733401226757,08-26 真机)──────────────────────
// ARKit 对第 1–3 张照片自己那一帧报 `limited_initializing`(photo bundle 与
// 原生 sidecar 都记着),我们照样把那三帧的 ARKit 位姿当可信位姿喂进了 SfM
// 核;核把帧直接摆在设备位姿上,交付后这三帧离像 78–382 mm,尺度偏 −3.2%。
// 链路上有三处把"追踪器说没准备好"丢掉了:
//   1. 原生高清帧回传了 trackingStateName,但
//      `OfficialHighResReconstructionInput.validate` 没有这个字段,
//      `SfmLiveRecon.offerFrame` 无条件把 cameraTransform 当位姿喂核;
//   2. 自动快门的 tracking 硬闸 `AutoCaptureController._trackingNormal`
//      读 `ARPose.isTracking`,而 `CaptureSession._resolveHybridPose` 在
//      ARKit limited 时用 IMU 航位推算替换 az/el 并**强行置 isTracking=true**
//      (为穹顶 UI),于是闸永远不响:那一场 924 次判定 `skipTracking=0`,
//      却有 3 张在 limited_initializing 窗口里拍下;
//   3. 手动快门路径注释写着 "Downstream filters on pose quality later",
//      但下游从来没有这个过滤。
//
// ── 判据(照官方,不自研)──────────────────────────────────────────────
// 可信 ⇔ 追踪器对**这张照片自己那一帧**报告的状态是它的"正常/完全追踪"。
// 其余一律不可信,包括状态缺失(fail-closed:不知道追踪器状态就不能宣称
// 位姿可信 —— 用户铁律「必须准」)。
//   • Apple ARKit(developer.apple.com/documentation/arkit/
//     managing-session-life-cycle-and-tracking-quality):`.limited(.initializing)`
//     时 "a device pose is available but its accuracy is uncertain";只有
//     `.normal` 表示位姿准确。Apple 自己的 Object Capture 取景样例
//     (Scanning objects using Object Capture,CapturePrimaryView.swift:65-66)
//     只在 `session.cameraTracking == .normal` 时才显示快门。
//   • Google ARCore(developers.google.com/ar/reference/java/com/google/ar/core/
//     Camera,getPose / getTrackingState):位姿只在 `TRACKING` 时有用,否则不应
//     使用;`PAUSED` + `TrackingFailureReason.NONE` 就是正常初始化中。官方
//     hello_ar_java(HelloArActivity.java:553-556)`PAUSED` 时直接 return。
//     映射:TRACKING→"normal";PAUSED→"limited_*";STOPPED→"not_available"。
//   • Huawei HarmonyOS AR Engine(HMS_AREngine_ARCamera_GetPose /
//     GetTrackingState):同 ARCore,只在 TRACKING 时使用位姿。
//   • OpenXR `XR_SPACE_LOCATION_POSITION_TRACKED_BIT`(VALID 但未 TRACKED =
//     推算/最后已知位置)与 WebXR `XRPose.emulatedPosition`:标准里就有"位姿在、
//     但不是真追踪"的逐位姿标志 —— 本文件的 devicePoseTrusted 就是它的对等物。
//   • XRSLAM:官方 `XRSLAM_RESULT_STATE == TRACKING_SUCCESS`,见本文件底部
//     [XRSLAM] 段(映射 [xrslamTrackerStateName])。
// 引文与 URL 见交付报告;这里不复制长段原文。
//
// ── 契约(与 agent B / C 共用)───────────────────────────────────────────
// devicePoseTrusted=false ⇒ 核**不得**把该帧摆在设备位姿上、不得拿它做
// Sim3 对齐对、不得拿它做位姿先验;像上游没有先验的图像一样从图像证据注册,
// 证据不够就不注册。照片本身**照常入库、照常喂**(用户按下的快门不丢)。
//
// 状态字符串词表 = `ARPose.trackingStateName` 已有的跨端词表
// ("normal" / "not_available" / "limited_*"),由各端原生层映射。

import '../vio/diagnostics/vio_shadow_se3_comparison.dart'
    show RawXrslamPoseClassification;

/// 追踪器的"正常/完全追踪"状态在跨端词表里的唯一取值。
const String kTrackerStateNormal = 'normal';

/// 一张照片的设备位姿可信判决 + 原因(原因只做审计,判决只看 [trusted])。
class DevicePoseTrust {
  const DevicePoseTrust._(this.trusted, this.trackerState, this.reason);

  /// 追踪器对该帧报告 "normal" ⇔ true。
  final bool trusted;

  /// 追踪器对该帧报告的原始状态(跨端词表);null = 未报告。
  final String? trackerState;

  /// `tracker_normal` / `tracker_state_missing` / `tracker_<state>`。
  final String reason;

  /// 由**产生该位姿的那一帧**的追踪状态判定。
  ///
  /// 注意:必须传位姿所属那一帧的状态(高清静照 = 原生回传的
  /// `HighResolutionStillCapture.trackingStateName`),不是按快门那一刻预览
  /// 帧的状态,也不是 `CaptureSession` 的 hybrid `isTracking`。
  factory DevicePoseTrust.fromTrackerState(String? trackerState) {
    if (trackerState == null || trackerState.isEmpty) {
      return const DevicePoseTrust._(false, null, 'tracker_state_missing');
    }
    if (trackerState == kTrackerStateNormal) {
      return const DevicePoseTrust._(
        true,
        kTrackerStateNormal,
        'tracker_normal',
      );
    }
    return DevicePoseTrust._(false, trackerState, 'tracker_$trackerState');
  }

  /// 预览位姿流用的"追踪器明确说了非正常"判断(自动快门硬闸)。
  ///
  /// 与 [DevicePoseTrust.fromTrackerState] 的区别只在 null:预览流上 null 表示
  /// provider 还没给值(`ARPose.trackingStateName` 文档:mock/Web/HarmonyOS
  /// 约定给 "normal",null 由 PoseDriftTracker 当 normal),此时退回既有的
  /// `isTracking` 布尔;真正决定位姿能不能进重建的是喂帧时的
  /// [DevicePoseTrust.fromTrackerState](那里 null 一律不可信)。
  static bool trackerReportsDegraded(String? trackerState) =>
      trackerState != null &&
      trackerState.isNotEmpty &&
      trackerState != kTrackerStateNormal;

  /// [DEVICE-SESSION 2026-09-24](B)位姿来自**非参考**设备跟踪会话 ⇒ 不可信
  /// (device_pose_session.dart)。只会收紧:追踪器已判不可信的保留原因。
  DevicePoseTrust notInReferenceSession() => trusted
      ? DevicePoseTrust._(false, trackerState, 'device_session_not_reference')
      : this;

  Map<String, Object?> toJson() => <String, Object?>{
    'devicePoseTrusted': trusted,
    'deviceTrackingState': trackerState,
    'devicePoseTrustReason': reason,
  };

  @override
  String toString() => 'DevicePoseTrust($trusted, $reason)';
}

// ── [XRSLAM] 发布版只有 XRSLAM ────────────────────────────────────────────
// XRSLAM 的 `track()` 恒 true,但它**有**官方就绪信号:
// `XRSLAMGetResult(XRSLAM_RESULT_STATE)` ∈ {INITIALIZING, TRACKING_SUCCESS,
// TRACKING_FAIL}(xrslam-interface/src/XRSLAMManager.cpp:191-202 @upstream
// 4beb1a9;INITIALIZING ⇔ initializer 仍非空,core/frontend_worker.cpp:120-127)。
// 上游自己的消费端只在 `state == TRACKING_SUCCESS && pose.timestamp > 0` 时用
// 位姿(xrslam-pc/player/src/main.cpp:150-158;ROS / iOS demo 同口径)。
// 上游在第一个 TRACKING_SUCCESS 帧会吐全零四元数(feature_tracker.cpp:43-46,
// 113-122),我们既有的 `classifyRawXrslamPose` 已把它判 degenerate。
// 生产传输层每帧都已读这两个量(vendor/xrslam/transport/
// PwXrslamTransportCore.cpp:223-231 → wire 'rawXrslamState')。
// 已知盲区(上游**没有**官方信号,要上台架量,见交付报告第 6 节):
//   • 初始化成功后尺度/重力/偏置是否已收敛;
//   • 视觉丢失 / 纯 IMU 外推段(上游从不宣告丢失,TRACKING_FAIL 实际不出现)。

/// XRSLAM 原始状态分类 → 跨端词表。只有 [RawXrslamPoseClassification.valid]
/// (= 上游用位姿的条件 + 非退化四元数)映射到 "normal"。
String xrslamTrackerStateName(RawXrslamPoseClassification c) => switch (c) {
  RawXrslamPoseClassification.valid => kTrackerStateNormal,
  RawXrslamPoseClassification.initializing => 'limited_initializing',
  RawXrslamPoseClassification.trackingFailed => 'not_available',
  RawXrslamPoseClassification.degenerate => 'limited_unknown',
  RawXrslamPoseClassification.malformed => 'limited_unknown',
};
