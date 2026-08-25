// world_frame_accel.dart — 把机体系线加速度转到世界系。纯 Dart,零 Flutter。
//
// ── 为什么单独成文件 ────────────────────────────────────────────────────
// scale_observability.dart 的判据二**要求**喂入世界系、已去重力的线加速度
// (见那个文件头的第 2 条),但仓里没有任何一处在产出这种量:
//   • sensors_plus 的 `userAccelerometerEventStream()` 已去重力,但是**机体系**;
//   • lib/capture/fusion_ahrs.dart 有姿态四元数,但字段是私有的。
// 把这段旋转留在注释里等调用方自己写,等于把判据的正确性外包出去。所以它在
// 这里,并且有单测。
//
// ── 🔴 为什么必须用 userAcceleration 而不是「原始比力转世界系再减 g」──────
// 两条路看起来等价,实际差一个数量级,这是本文件最值钱的一条:
//
//   路线 A(原始比力 → 世界系 → 减去 (0,0,−g)):世界系里重力是常数,而常数会
//     被 (★) 里的加速度计零偏 b 整个吃掉 —— 数学上确实不影响尺度信息。**但**
//     姿态估计有误差 δθ 时,重力会漏进水平轴,幅度 g·sin(δθ)。δθ = 0.5° ⇒
//     0.086 m/s²。而 σ_a=0.02、2 s@300 Hz 的达标门槛是 acRms ≥ 0.082 m/s²
//     ([requiredAcRmsMps2])—— **同一个量级**。姿态一抖,判据就会把重力泄漏
//     当成平移激励,把「站着原地转」误判成 sufficient。这正是判据二最怕的
//     假阳性。
//   路线 B(userAcceleration → 世界系):iOS 用自己的 Kalman 姿态先把重力
//     去掉,剩下的残差本身就很小(手持典型 < 1 m/s²),我们的 δθ 只按比例
//     缩放这个小量,不会把 9.81 引进来。
//
// ⇒ **只走路线 B**。[rotateDeviceToWorld] 因此只接受已去重力的输入,并在
//   文档里写死这条契约。单测 `重力泄漏:路线 A 会把原地转判成有激励` 把两条
//   路线的差距量出来,钉住这个选择。
//
// ── 旋转约定 ────────────────────────────────────────────────────────────
// 四元数 q = (w, x, y, z) 表示 **device→world**,与 FusionAhrs 内部 _qw.._qz
// 同一约定。用 Rodrigues 形式,不建矩阵:
//     t = 2 · (q_vec × v)
//     v_world = v + w·t + q_vec × t

import 'dart:math' as math;

/// 把**已去重力**的机体系线加速度 [v]=(x,y,z) 按 device→world 四元数
/// [qw],[qx],[qy],[qz] 旋到世界系。返回长度 3 的新列表。
///
/// ⚠️ 契约:[v] 必须已经去过重力(iOS: CMDeviceMotion.userAcceleration;
/// sensors_plus: userAccelerometerEventStream)。**不要**传原始 accelerometer
/// 读数 —— 见文件头「为什么必须用 userAcceleration」。
List<double> rotateDeviceToWorld(
  double vx,
  double vy,
  double vz, {
  required double qw,
  required double qx,
  required double qy,
  required double qz,
}) {
  // 归一化,防止 AHRS 漂出单位模长时缩放加速度幅值(那会直接毒化 acRms)。
  final n = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz);
  if (n == 0 || !n.isFinite) return <double>[vx, vy, vz];
  final w = qw / n, x = qx / n, y = qy / n, z = qz / n;

  // t = 2 (q_vec × v)
  final tx = 2.0 * (y * vz - z * vy);
  final ty = 2.0 * (z * vx - x * vz);
  final tz = 2.0 * (x * vy - y * vx);

  // v' = v + w t + q_vec × t
  return <double>[
    vx + w * tx + (y * tz - z * ty),
    vy + w * ty + (z * tx - x * tz),
    vz + w * tz + (x * ty - y * tx),
  ];
}

/// sensors_plus 给的是 m/s²,与本模块口径一致;这里只做一次单位自证,
/// 免得有人误传 g 为单位的读数(那会让 acRms 差 9.81 倍)。
/// 静止时 |userAcceleration| 应当远小于 1 m/s²;若长期接近 9.8,多半是把
/// 原始比力当成了 userAcceleration。
bool looksLikeGravityRemoved(double magnitudeMps2) => magnitudeMps2 < 5.0;
