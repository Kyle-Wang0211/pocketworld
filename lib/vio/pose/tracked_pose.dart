// tracked_pose.dart — 位姿的**可用性契约**。纯 Dart,零 Flutter 依赖。
//
// ── 为什么需要这个类型 ────────────────────────────────────────────────────
// 我们现有的位姿出口是**二值**的:`XRSLAMTryGetLatestPose` 要么
// `XRSLAM_OK`(拿到 6DOF),要么 `XRSLAM_NO_NEW_DATA`(什么都没有)。
// 这表达不了中间那个状态 —— **朝向有效、位置无效** —— 而那恰好是:
//   * 静止起步(有重力对齐的姿态,但单目无平移 ⇒ 米制位置不可观);
//   * 跟丢之后(上一个已知位置还有意义,但已经不是"正在跟踪"了)。
// 二值出口把这些全压成"没有位姿",于是上层只能猜,或者干脆不接 ——
// 这正是消费层一直接不上的原因之一。
//
// ── 契约不是我们设计的,是抄 OpenXR 的 ───────────────────────────────────
// `XrSpaceLocationFlagBits`,四位正交(规范原文,已核到 Khronos 源:
// specification/sources/chapters/spaces.adoc):
//   * `..._ORIENTATION_VALID_BIT` —— "indicates that the pose field's
//     orientation field contains valid data."
//   * `..._POSITION_VALID_BIT`    —— 同上,position。
//   * `..._ORIENTATION_TRACKED_BIT` —— "represents an **actively tracked**
//     orientation."
//   * `..._POSITION_TRACKED_BIT`    —— 同上,position。
//
// 三条规范语义,本文件逐条做成机械强制:
//
// (1) 🔴 **"Applications must: not read the pose field's orientation if this
//     flag is unset"** —— 这是 `must`,不是"读到的可能不准"。所以本类型
//     **不提供**无条件读取 [orientation] / [position] 的入口:未置位时
//     getter 返回 `null`,而不是返回一个"看起来像数"的零值。
//     我们已经被零四元数咬过一次(`latest_pose_degenerate`:引擎在跟踪器
//     初始化前 `setZero()`,却照样配一个合法时间戳存下来,Dart 侧
//     normalize 会得到 NaN)。那次的教训就是"看起来像数"最危险。
//
// (2) **VALID 置位但 TRACKED 未置位 = 推断值或最后已知值**。规范原文:
//     runtimes "should: continue to provide valid but untracked position
//     values that are inferred or last-known, so long as it's still
//     meaningful for the application to use that position."
//     ⇒ 这不是错误状态,是**一等状态**。UI 该降级,不该报错。
//
// (3) **TRACKED 蕴含 VALID,反之不然**。规范对带自身惯性跟踪的设备说
//     orientation 的 TRACKED 位 "should: remain set when
//     ORIENTATION_VALID_BIT is set" —— 我们正是这种设备(有 IMU),
//     这也是"静止时仍可交出朝向"的规范依据。
//     构造器用 assert 把"TRACKED 而不 VALID"这种不可能态挡掉。
//
// ── 与 3DOF 的关系 ────────────────────────────────────────────────────────
// 规范明确 contemplate 了 "the location is 3dof tracked"。苹果自己也出
// `AROrientationTrackingConfiguration` 作为显式回退。所以
// [TrackedPose.orientationOnly] 不是我们发明的降级档,是三方都承认的一档。
//
// 🔴 本文件**不**决定"什么时候该降级" —— 那是 `capability_decision.dart`
// 的事。本文件只保证:一旦降级,类型系统不允许任何人误读不该读的字段。

import 'dart:math' as math;

/// 一个四元数,分量顺序与 `XRSLAMTryGetLatestPose` 的 `out_pose7` 前四位
/// 一致:**[x, y, z, w]**,实部 w 在第 4 位。
///
/// 顺序在这里写死并加断言,是因为这一层最容易出静默错误:w 放错位置不会
/// 崩,只会让所有旋转都错一点点,而且错得很像"精度不够"。
class PoseQuaternion {
  const PoseQuaternion(this.x, this.y, this.z, this.w);

  final double x;
  final double y;
  final double z;
  final double w;

  static const PoseQuaternion identity = PoseQuaternion(0, 0, 0, 1);

  double get normSquared => x * x + y * y + z * z + w * w;

  /// 几何上能不能当旋转用。零四元数与非有限值都不行。
  ///
  /// 阈值不是拍的:`XRSLAM.h` 把 `latest_pose_degenerate` 的成因写成
  /// `q.coeffs().setZero()`,即**精确零**;这里留 1e-12 的余量只为吸收
  /// 浮点往返,不是为了容忍"接近零"的四元数。
  bool get isUsableRotation =>
      x.isFinite &&
      y.isFinite &&
      z.isFinite &&
      w.isFinite &&
      normSquared > 1e-12;

  PoseQuaternion normalized() {
    final double n = math.sqrt(normSquared);
    if (!n.isFinite || n <= 0) {
      throw StateError(
        'PoseQuaternion.normalized() 调用在不可用的四元数上;'
        '请先查 isUsableRotation。这正是零四元数变 NaN 的那条路径。',
      );
    }
    return PoseQuaternion(x / n, y / n, z / n, w / n);
  }

  @override
  String toString() => 'q(x:$x, y:$y, z:$z, w:$w)';
}

/// 三维位置,米制。
class PosePosition {
  const PosePosition(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  static const PosePosition origin = PosePosition(0, 0, 0);

  bool get isFinite => x.isFinite && y.isFinite && z.isFinite;

  @override
  String toString() => 'p(x:$x, y:$y, z:$z)';
}

/// 一次定位的结果,携带 OpenXR 的四个正交标志位。
///
/// 读字段的唯一合法入口是 [orientation] / [position],它们在对应 VALID 位
/// 未置位时返回 `null`。**没有**返回原始字段的后门 —— 规范说的是 `must
/// not read`,能读到就迟早有人读。
class TrackedPose {
  TrackedPose._({
    required PoseQuaternion? orientation,
    required PosePosition? position,
    required this.orientationTracked,
    required this.positionTracked,
    required this.timestampSeconds,
  })  : _orientation = orientation,
        _position = position {
    // 规范语义 (3):TRACKED 蕴含 VALID。反过来不成立。
    assert(
      !orientationTracked || _orientation != null,
      'orientationTracked 为真但 orientation 无效 —— '
      'OpenXR 的 TRACKED 位蕴含 VALID 位,这是不可能态。',
    );
    assert(
      !positionTracked || _position != null,
      'positionTracked 为真但 position 无效 —— 同上。',
    );
  }

  /// 6DOF,正在跟踪。引擎 `XRSLAMTryGetLatestPose` 返回 `XRSLAM_OK` 时的状态。
  factory TrackedPose.tracked({
    required PoseQuaternion orientation,
    required PosePosition position,
    required double timestampSeconds,
  }) {
    if (!orientation.isUsableRotation) {
      throw ArgumentError(
        'TrackedPose.tracked 收到不可用的四元数 $orientation。'
        '零四元数必须在这一层之前就被挡掉,不能带着 VALID 位往上走。',
      );
    }
    if (!position.isFinite) {
      throw ArgumentError('TrackedPose.tracked 收到非有限位置 $position。');
    }
    return TrackedPose._(
      orientation: orientation,
      position: position,
      orientationTracked: true,
      positionTracked: true,
      timestampSeconds: timestampSeconds,
    );
  }

  /// 3DOF:**朝向有效且正在跟踪,位置无效**。
  ///
  /// 静止起步落在这一档 —— 重力对齐给得出姿态,而单目没有平移就没有米制
  /// 位置。Kimera 的静态初始化在代码里把这句写得最直白:
  /// *"Absolute translation is unobservable, so return [0, 0, 0]"*。
  /// 🔴 注意它返回的零**不是**"位置是原点",是"位置不可观"。本类型用
  /// `positionValid == false` 表达这一点,而不是交出一个零向量让上层去猜。
  factory TrackedPose.orientationOnly({
    required PoseQuaternion orientation,
    required double timestampSeconds,
  }) {
    if (!orientation.isUsableRotation) {
      throw ArgumentError('TrackedPose.orientationOnly 收到不可用的四元数。');
    }
    return TrackedPose._(
      orientation: orientation,
      position: null,
      orientationTracked: true,
      positionTracked: false,
      timestampSeconds: timestampSeconds,
    );
  }

  /// VALID 但不 TRACKED:推断值或最后已知值。规范语义 (2)。
  ///
  /// 跟丢之后该走这一档:位置还有意义(上一个已知位置),但不能再宣称
  /// "正在跟踪"。UI 据此降级,而不是把内容整个撤掉。
  factory TrackedPose.lastKnown({
    required PoseQuaternion orientation,
    required PosePosition position,
    required double timestampSeconds,
    bool orientationStillTracked = true,
  }) {
    if (!orientation.isUsableRotation) {
      throw ArgumentError('TrackedPose.lastKnown 收到不可用的四元数。');
    }
    if (!position.isFinite) {
      throw ArgumentError('TrackedPose.lastKnown 收到非有限位置。');
    }
    return TrackedPose._(
      orientation: orientation,
      position: position,
      orientationTracked: orientationStillTracked,
      positionTracked: false,
      timestampSeconds: timestampSeconds,
    );
  }

  /// 什么都没有。初始化尚未完成、且连姿态都还没有的时候。
  factory TrackedPose.none({required double timestampSeconds}) {
    return TrackedPose._(
      orientation: null,
      position: null,
      orientationTracked: false,
      positionTracked: false,
      timestampSeconds: timestampSeconds,
    );
  }

  final PoseQuaternion? _orientation;
  final PosePosition? _position;

  /// `XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT`
  final bool orientationTracked;

  /// `XR_SPACE_LOCATION_POSITION_TRACKED_BIT`
  final bool positionTracked;

  final double timestampSeconds;

  /// `XR_SPACE_LOCATION_ORIENTATION_VALID_BIT`
  bool get orientationValid => _orientation != null;

  /// `XR_SPACE_LOCATION_POSITION_VALID_BIT`
  bool get positionValid => _position != null;

  /// 朝向;VALID 位未置位时为 `null`。规范语义 (1)。
  PoseQuaternion? get orientation => _orientation;

  /// 位置;VALID 位未置位时为 `null`。规范语义 (1)。
  PosePosition? get position => _position;

  /// 位置与朝向都在跟踪 —— 唯一可以拿来做米制锚定的一档。
  bool get isSixDegreeOfFreedom => orientationTracked && positionTracked;

  /// 只有朝向可用。3DOF 一档,苹果的
  /// `AROrientationTrackingConfiguration` 是同一个东西。
  bool get isOrientationOnly => orientationValid && !positionValid;

  /// 一行摘要,给回执和日志。故意包含四个位,便于事后判读。
  String get flagSummary => 'oV:${orientationValid ? 1 : 0} '
      'pV:${positionValid ? 1 : 0} '
      'oT:${orientationTracked ? 1 : 0} '
      'pT:${positionTracked ? 1 : 0}';

  @override
  String toString() => 'TrackedPose($flagSummary t:$timestampSeconds)';
}
