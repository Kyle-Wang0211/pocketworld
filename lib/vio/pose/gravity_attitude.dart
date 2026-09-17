// gravity_attitude.dart — 静止时从 IMU 解重力对齐姿态。纯 Dart,零依赖。
//
// ── 这是复刻,不是自研。逐行出处在下面 ─────────────────────────────────
// 主源:**Kimera-VIO**,`src/initial/InitializationFromImu.cpp`,BSD-2
//       (LICENSE.BSD:1,MIT 2019,两条件、无背书条款)。
//       选它而不是更短的 Basalt(BSD-3,~10 行)或 OKVIS(BSD-3,~25 行),
//       是因为**它在代码里自报前提**,而我们这个代码库反复栽在静默降级上:
//         `LOG(WARNING) << "InitializationFromImu: assumes that the vehicle
//          is stationary and upright along some axis, and gravity vector is
//          along a single axis!"`
//       以及最要紧的那句注释:
//         *"Absolute translation is unobservable, so return [0, 0, 0]"*
//       —— 这句话是本文件存在的全部理由,也是 [TrackedPose.orientationOnly]
//       的语义来源:那个零**不是**"位置是原点",是"位置不可观"。
//
// 次源:`src/utils/UtilsOpenCV.cpp` 的 `AlignGravityVectors` 与 `RoundUnit3`,
//       同一许可。下面的三分支与 1e-3 / 1e-4 阈值逐个照抄,包括它那个
//       "反平行时用 (1,2,3) 扰动,若仍平行再用 (3,2,1)" 的兜底。
//
// 旁证(不抄代码,只作口径佐证):
//   * Basalt `sqrt_keypoint_vio.cpp:194-219`(BSD-3):
//     `FromTwoVectors(accel, UnitZ())`,v=0,直接开跑,**无激励门**。
//   * OKVIS `Estimator.cpp:811-840` / OKVIS2 `ImuError.cpp:781-807`(BSD-3):
//     取 IMU 队列**均值**而非单样本,更抗单次噪声 —— 本文件取均值,同 Kimera。
//   * OpenVINS `InertialInitializerOptions.h:76` `init_dyn_use = false`:
//     **静态初始化是它的默认路径**,不是例外。
//   ⚰️ msckf_vio 一行都不能碰:`LICENSE.txt:6` 只给 non-profit research,
//     第 4 条禁止未经宾大书面许可分发。与 ADVIO/Hypersim 同一死刑档。
//
// ── 这一层**不**做什么 ───────────────────────────────────────────────────
// 不判断"现在静不静止"。Kimera 自己也不判断 —— 它把前提写进日志然后信调用方。
// 判断静止是 `capability_decision.dart` 的事(它已经有 13 个 blocker 的位置)。
// 本文件只回答:**给我一段 IMU,姿态是多少。**
//
// 🔴 也不给尺度。VINS 作者 Tong Qin 原话(VINS-Mobile #11,MEMBER):
//    *"Without enough translation, the monocular visual-inertial system
//    cannot optimize scale."* 静止起步给的是**姿态,不是位姿**。

import 'dart:math' as math;

import 'tracked_pose.dart';

/// 一条 IMU 样本。加速度单位 m/s²,角速度 rad/s。
class ImuSample {
  const ImuSample({
    required this.timestampSeconds,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });

  final double timestampSeconds;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;

  bool get isFinite =>
      ax.isFinite &&
      ay.isFinite &&
      az.isFinite &&
      gx.isFinite &&
      gy.isFinite &&
      gz.isFinite;
}

/// 静止起步的解:姿态 + 两个偏置。**没有位置,也没有速度以外的任何米制量。**
class StationaryAttitude {
  const StationaryAttitude({
    required this.attitude,
    required this.accelerometerBias,
    required this.gyroscopeBias,
    required this.sampleCount,
    required this.timestampSeconds,
  });

  /// 重力对齐的姿态。偏航(yaw)**不可观** —— 重力只约束两个自由度。
  final PoseQuaternion attitude;

  /// `ImuBias(mean_acc + local_gravity, mean_gyro)`,Kimera `guessImuBias`。
  final List<double> accelerometerBias;
  final List<double> gyroscopeBias;

  final int sampleCount;
  final double timestampSeconds;

  /// 交成一个只有朝向的定位结果。位置那一位**故意不给** —— 见
  /// [TrackedPose.orientationOnly] 的文档与 Kimera 的 unobservable 注释。
  TrackedPose toTrackedPose() => TrackedPose.orientationOnly(
        orientation: attitude,
        timestampSeconds: timestampSeconds,
      );
}

/// 重力对齐的姿态求解器。
abstract final class GravityAttitude {
  /// 世界系重力方向。z 向上,所以重力指向 −z。
  ///
  /// 🔴 这个常量决定了输出姿态所在的世界系约定,**必须**与消费端一致。
  /// 我们记录在案的两个轴映射互相矛盾(实测拟合 vs 上游 SceneKit 硬编码),
  /// 所以接线前要从我们自己的 build 打一个真实位姿出来判,不要信任何一边。
  static const List<double> globalGravityZUp = <double>[0, 0, -1];

  /// 标称重力大小。上游 demo `Motion.swift` 用的是同一个数
  /// (`GRAVITY_NOMINAL = -9.80665`,它把 CoreMotion 的 g 乘上去)。
  static const double nominalGravity = 9.80665;

  /// 从一段 IMU 求姿态。
  ///
  /// 逐行对应 Kimera `InitializationFromImu::getInitialStateEstimate`:
  ///   1. `computeAverageImuMeasurements(imu_accgyr)`
  ///   2. `measured_gravity = -1.0 * mean_acc`
  ///   3. `attitude = AlignGravityVectors(measured_gravity, global_gravity)`
  ///   4. 位置 = Zero(不可观),速度 = Zero(静止假设)
  ///   5. `ImuBias(mean_acc + local_gravity, mean_gyro)`
  ///
  /// [round] 对应 Kimera 的同名参数:把重力方向吸附到最强轴。默认 `false` ——
  /// 手机很少恰好正对某个轴,吸附会引入一个它自己造出来的误差。Kimera 把它
  /// 做成参数而不是默认行为,我们保持同样的默认。
  ///
  /// 返回 `null` 的唯一情况:样本不足或全非有限。**不静默返回单位姿态** ——
  /// 单位姿态看起来像个答案,而这正是我们反复栽的那种坑。
  static StationaryAttitude? solve(
    List<ImuSample> window, {
    bool round = false,
    int minimumSamples = 10,
  }) {
    if (window.length < minimumSamples) return null;
    final List<ImuSample> usable =
        window.where((ImuSample s) => s.isFinite).toList(growable: false);
    if (usable.length < minimumSamples) return null;

    // (1) 均值。取均值而非单样本:OKVIS/OKVIS2 的做法,对单次噪声更稳。
    double ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
    for (final ImuSample s in usable) {
      ax += s.ax;
      ay += s.ay;
      az += s.az;
      gx += s.gx;
      gy += s.gy;
      gz += s.gz;
    }
    final double n = usable.length.toDouble();
    final List<double> meanAcc = <double>[ax / n, ay / n, az / n];
    final List<double> meanGyro = <double>[gx / n, gy / n, gz / n];

    // 加速度计在静止时读到的是**比力**,模长应当接近 g。差太远说明这段
    // 根本不静止,或者单位错了(g vs m/s² 是我们踩过的坑)。
    final double accNorm = _norm(meanAcc);
    if (!accNorm.isFinite || accNorm <= 1e-6) return null;

    // (2) `measured_gravity = -1.0 * mean_acc` —— Kimera
    //     `guessPoseFromImuMeasurements` 第一行。
    final List<double> measuredGravity = <double>[
      -meanAcc[0],
      -meanAcc[1],
      -meanAcc[2],
    ];

    // (3) 对齐。
    final PoseQuaternion? attitude = alignVectors(
      measuredGravity,
      globalGravityZUp,
      round: round,
    );
    if (attitude == null) return null;

    // (5) 偏置。`local_gravity = R^{-1} * global_gravity`,然后
    //     `ba = mean_acc + local_gravity`、`bg = mean_gyro`。
    final List<double> localGravity = _rotateByInverse(
      attitude,
      <double>[
        globalGravityZUp[0] * nominalGravity,
        globalGravityZUp[1] * nominalGravity,
        globalGravityZUp[2] * nominalGravity,
      ],
    );

    return StationaryAttitude(
      attitude: attitude,
      accelerometerBias: <double>[
        meanAcc[0] + localGravity[0],
        meanAcc[1] + localGravity[1],
        meanAcc[2] + localGravity[2],
      ],
      gyroscopeBias: meanGyro,
      sampleCount: usable.length,
      timestampSeconds: usable.last.timestampSeconds,
    );
  }

  /// 求把 [from] 转到 [to] 的旋转 —— `R * from = to`。
  ///
  /// 逐行复刻 Kimera `UtilsOpenCV::AlignGravityVectors`,三个分支与阈值照抄:
  ///   * `|1 - c| < 1e-3` ⇒ 已对齐,返回单位旋转;
  ///   * `|1 + c| < 1e-3` ⇒ 反平行,绕任一垂直轴转 180°;它先用
  ///     `from + (1,2,3)` 构造扰动,若叉积仍非有限再用 `from + (3,2,1)`;
  ///   * 否则 ⇒ 最短弧旋转。
  ///
  /// 一般分支 Kimera 调的是 gtsam 的 `Rot3::AlignPair`;我们没有 gtsam,
  /// 用最短弧四元数,这与 Basalt 的 `Eigen::Quaternion::FromTwoVectors`
  /// 和 VINS-Fusion `Utility::g2R` 的第一步是同一个量。
  static PoseQuaternion? alignVectors(
    List<double> from,
    List<double> to, {
    bool round = false,
  }) {
    List<double>? a = _normalize(from);
    List<double>? b = _normalize(to);
    if (a == null || b == null) return null;
    if (round) {
      a = _roundUnit3(a);
      b = _roundUnit3(b);
    }

    final double c = _dot(a, b);
    if (!c.isFinite) return null;

    if ((1 - c).abs() < 1e-3) {
      return PoseQuaternion.identity;
    }

    if ((1 + c).abs() < 1e-3) {
      // 反平行。Kimera 的扰动兜底,两个魔数向量照抄。
      List<double>? axis = _normalize(
        _cross(a, <double>[a[0] + 1, a[1] + 2, a[2] + 3]),
      );
      axis ??= _normalize(_cross(a, <double>[a[0] + 3, a[1] + 2, a[2] + 1]));
      if (axis == null) return null;
      // 绕 axis 转 π:q = (axis * sin(π/2), cos(π/2)) = (axis, 0)。
      return PoseQuaternion(axis[0], axis[1], axis[2], 0);
    }

    // 最短弧。w = 1 + a·b,向量部 = a × b,然后归一化。
    final List<double> v = _cross(a, b);
    final PoseQuaternion q = PoseQuaternion(v[0], v[1], v[2], 1 + c);
    if (!q.isUsableRotation) return null;
    return q.normalized();
  }

  /// Kimera `RoundUnit3`:最大分量吸到 ±1,其余归零;`1e-4` 的并列判定与
  /// "取第一个最大值就 break"的 tie-breaker 照抄。
  static List<double> _roundUnit3(List<double> x) {
    final List<double> out = <double>[0, 0, 0];
    final double maxAbs =
        math.max(x[0].abs(), math.max(x[1].abs(), x[2].abs()));
    if (maxAbs <= 0) return out;
    for (int i = 0; i < 3; i++) {
      if ((x[i].abs() - maxAbs).abs() < 1e-4) {
        out[i] = x[i] / maxAbs;
        break;
      }
    }
    return out;
  }

  static double _norm(List<double> v) =>
      math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

  static List<double>? _normalize(List<double> v) {
    final double n = _norm(v);
    if (!n.isFinite || n <= 1e-12) return null;
    return <double>[v[0] / n, v[1] / n, v[2] / n];
  }

  static double _dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  static List<double> _cross(List<double> a, List<double> b) => <double>[
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
      ];

  /// v' = q⁻¹ · v · q。四元数分量顺序 [x,y,z,w]。
  static List<double> _rotateByInverse(PoseQuaternion q, List<double> v) {
    final PoseQuaternion u = q.normalized();
    // 共轭即逆(单位四元数)。
    final double x = -u.x, y = -u.y, z = -u.z, w = u.w;
    // Rodrigues 形式:v' = v + 2w(u×v) + 2(u×(u×v)),u 为向量部。
    final List<double> uv = _cross(<double>[x, y, z], v);
    final List<double> uuv = _cross(<double>[x, y, z], uv);
    return <double>[
      v[0] + 2 * (w * uv[0] + uuv[0]),
      v[1] + 2 * (w * uv[1] + uuv[1]),
      v[2] + 2 * (w * uv[2] + uuv[2]),
    ];
  }
}
