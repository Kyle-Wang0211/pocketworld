// vio_pose_source.dart — 把引擎的**二值**出口翻译成 OpenXR 的**四位**状态。
//
// ── 这一层补的是哪个缺口 ─────────────────────────────────────────────────
// `XRSLAMTryGetLatestPose` 只有两种回答:`XRSLAM_OK`(6DOF 到手)或
// `XRSLAM_NO_NEW_DATA`(没有)。而"没有"底下其实压着三种完全不同的情况:
//
//   (a) 引擎还在初始化,连姿态都没有         ⇒ 真的什么都没有
//   (b) 引擎还在初始化,但设备静止且有重力    ⇒ **只有朝向**(3DOF)
//   (c) 曾经跟上过,现在跟丢了                ⇒ **最后已知位置仍有意义**
//
// 三种被压成一种,上层就只能猜 —— 这正是消费层一直没人敢接的原因之一。
// 本文件把它们拆开,拆的依据是 OpenXR 的 `XrSpaceLocationFlagBits`(见
// `tracked_pose.dart` 的规范引文),不是我们自己编的档位。
//
// ── 状态迁移就是规范语义,没有别的规则 ───────────────────────────────────
//   OK                      → [TrackedPose.tracked]          四位全置
//   NO_NEW_DATA + 未初始化 + 有静止姿态 → [TrackedPose.orientationOnly]
//                                          oV/oT 置,pV/pT 不置
//   NO_NEW_DATA + 曾经 6DOF → [TrackedPose.lastKnown]        pV 置、pT 不置
//   其余                     → [TrackedPose.none]             四位全不置
//
// (c) 那一档直接对应规范原文:runtimes "should: continue to provide valid
// but untracked position values that are inferred or last-known, so long as
// it's still meaningful for the application to use that position."
//
// ── 🔴 本文件**不**做的三件事 ────────────────────────────────────────────
// 1. 不判断"该不该用自研核" —— 那是 `capability_decision.dart`,它已经有
//    `PoseSource{selfVio, platformVio, none}` 和 13 个 blocker。本文件只在
//    被告知用 selfVio 时工作。
// 2. 不做预测到显示时刻。引擎的 `predict_pose` 只补到**图像时刻**
//    (`XRSLAMManager.cpp` 传的是 `image->t`),补显示延迟要 Monado 的
//    `m_predict_relation`(BSL-1.0,115 行整文件)+ `CADisplayLink
//    .targetTimestamp`。那是下一刀,不在这一刀里。
// 3. 不换轴。世界系约定我们有**两个互相矛盾**的记录(实测 SE(3) 拟合
//    `x_A=−y_X, y_A=+z_X, z_A=−x_X` vs 上游 SceneKit 硬编码
//    `(x,y,z)→(−y,−x,−z)`),必须先从我们自己的 build 打一个真实位姿判死,
//    才能接渲染器。在那之前本文件交出的是**引擎原始系**的位姿,并且不假装
//    自己知道它是哪个系。

import 'gravity_attitude.dart';
import 'tracked_pose.dart';

/// 引擎一次轮询的原始结果。由 FFI 层填,本文件不碰指针。
class EnginePoseSample {
  const EnginePoseSample({
    required this.ok,
    required this.quaternionXyzw,
    required this.translationXyz,
    required this.timestampSeconds,
  });

  /// `XRSLAMTryGetLatestPose` 是否返回了 `XRSLAM_OK`。
  ///
  /// 🔴 唯一判据。`XRSLAMHealth.overall == HEALTHY` **不是** —— 头文件自己
  /// 写着初始化期间按定义就是 HEALTHY,但 `predict_pose` 交出的还是零四元数。
  final bool ok;

  /// `out_pose7` 的前四位,顺序 **[x, y, z, w]**。
  final List<double> quaternionXyzw;

  /// `out_pose7` 的后三位。
  final List<double> translationXyz;

  final double timestampSeconds;

  static const EnginePoseSample empty = EnginePoseSample(
    ok: false,
    quaternionXyzw: <double>[0, 0, 0, 0],
    translationXyz: <double>[0, 0, 0],
    timestampSeconds: 0,
  );
}

/// 位姿源当前处在哪一档。给 UI 和回执用,不参与几何。
enum VioPoseStage {
  /// 什么都没有。
  none,

  /// 只有朝向。静止起步落在这里。
  orientationOnly,

  /// 六自由度,正在跟踪。
  tracking,

  /// 跟丢,交出最后已知位置(VALID 但不 TRACKED)。
  lastKnown,
}

/// 把引擎轮询 + 静止姿态合成一条 [TrackedPose] 流。
///
/// 无状态方法拿不到 (c) 那一档 —— "曾经跟上过"本身就是状态。所以这是个
/// 有状态对象,而它持有的状态**只有两样**:最后一个 6DOF 位姿,和它的时刻。
class VioPoseSource {
  VioPoseSource({this.lastKnownHoldSeconds = 5.0});

  /// 跟丢后还交出最后已知位置多久。
  ///
  /// 规范的措辞是 "so long as it's still meaningful for the application to
  /// use that position" —— 把"多久算 meaningful"留给了实现。这里取一个
  /// 保守的 5 秒并**做成参数**,因为它没有可复刻的出处:我查到的实现里
  /// 没有一个公开这个常数。不要把它当有依据的阈值。
  final double lastKnownHoldSeconds;

  TrackedPose? _lastSixDof;

  /// 最近一次交出的档位。
  VioPoseStage get stage => _stage;
  VioPoseStage _stage = VioPoseStage.none;

  /// 到目前为止有没有拿到过 6DOF。决定 (b) 与 (c) 走哪一支。
  bool get hasEverTracked => _lastSixDof != null;

  /// 合成一次。
  ///
  /// [stationaryAttitude] 由调用方在判定设备静止时给出(判定不在本层)。
  /// 给 `null` 表示"现在没有可用的静止姿态"。
  TrackedPose update({
    required EnginePoseSample sample,
    StationaryAttitude? stationaryAttitude,
    required double nowSeconds,
  }) {
    if (sample.ok) {
      final PoseQuaternion q = PoseQuaternion(
        sample.quaternionXyzw[0],
        sample.quaternionXyzw[1],
        sample.quaternionXyzw[2],
        sample.quaternionXyzw[3],
      );
      final PosePosition p = PosePosition(
        sample.translationXyz[0],
        sample.translationXyz[1],
        sample.translationXyz[2],
      );
      // 引擎承诺 OK 时位姿几何合法,但我们**再查一次**:这条链上一次
      // 出事就是"时间戳在前进"被当成了"位姿可用"。防御的成本是两次乘法。
      if (q.isUsableRotation && p.isFinite) {
        final TrackedPose pose = TrackedPose.tracked(
          orientation: q,
          position: p,
          timestampSeconds: sample.timestampSeconds,
        );
        _lastSixDof = pose;
        _stage = VioPoseStage.tracking;
        return pose;
      }
      // OK 却拿到不可用的位姿 —— 契约被破坏了。按"没有"处理,绝不
      // 把它当成一个位姿往上送。
    }

    // (c) 曾经跟上过 ⇒ 最后已知位置在保持窗口内仍然交出,但不宣称在跟踪。
    final TrackedPose? last = _lastSixDof;
    if (last != null &&
        nowSeconds - last.timestampSeconds <= lastKnownHoldSeconds) {
      _stage = VioPoseStage.lastKnown;
      return TrackedPose.lastKnown(
        orientation: last.orientation!,
        position: last.position!,
        timestampSeconds: last.timestampSeconds,
        // 有 IMU 的设备,朝向仍在跟踪 —— 规范对这类设备说 orientation 的
        // TRACKED 位 "should: remain set when ORIENTATION_VALID_BIT is set"。
        orientationStillTracked: true,
      );
    }

    // (b) 还没跟上过,但静止姿态解得出来 ⇒ 3DOF。
    if (last == null && stationaryAttitude != null) {
      _stage = VioPoseStage.orientationOnly;
      return stationaryAttitude.toTrackedPose();
    }

    // (a) 真的什么都没有。
    _stage = VioPoseStage.none;
    return TrackedPose.none(timestampSeconds: nowSeconds);
  }

  /// 会话重启时调用。**必须**调 —— 不调的话上一场的最后已知位姿会漏进
  /// 新一场,而新一场的世界系和它没有任何关系。
  void reset() {
    _lastSixDof = null;
    _stage = VioPoseStage.none;
  }
}
