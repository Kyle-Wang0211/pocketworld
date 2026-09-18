// zero_velocity_detector.dart —— 零速(静止)检测。纯 Dart,零平台调用,三端同一份。
//
// ══ 这是复刻,逐行出处在下面 ═══════════════════════════════════════════════
//
// 主源:**`prateekgv/openshoe-sphere_limit`**,MIT License,
//       Copyright (c) 2018 Prateek Gundannavar(已核到 LICENSE 正文,
//       不是看徽章),文件
//       `sphere_limit_method/matlab_implementation/zero_velocity_detector.m`
//       里的 `function T=GLRT(u)`。原文 20 行,逐行照抄:
//
//         ya_m = mean(u(1:3, k:k+W-1), 2);
//         for l = k:k+W-1
//             tmp  = u(1:3,l) - g*ya_m/norm(ya_m);
//             T(k) = T(k) + u(4:6,l)'*u(4:6,l)/sigma2_g + tmp'*tmp/sigma2_a;
//         end
//         T = T./W;
//
// 这个检测器的学名是 **SHOE**(Stance Hypothesis Optimal dEtector),是把
// 零速检测写成广义似然比检验(GLRT)的结果:
//   **Skog, Händel, Nilsson, Rantakokko, "Zero-Velocity Detection—An
//    Algorithm Evaluation", IEEE Trans. Biomedical Engineering, 2010,
//    DOI 10.1109/tbme.2010.2060723**(Crossref 核实)。
//   该文横向评测四个检测器(GLRT/MV/MAG/ARE),SHOE 表现最好。
//
// ══ 为什么是这一份,而不是别的 ═════════════════════════════════════════════
//
// 🔑 **它就是我们这条血统自己指向的那个算法。**
// XRSLAM 作者后续的工作 **XR-VIO**(arXiv:2502.01297, 2025-02,
// Zhai/Wang/Wang/Chen/Xie)原文:
//   "We employ two initialization methods depending on the motion states,
//    namely **static** and **motion**. To determine the current state, we
//    consider the **average displacement of sparse features** and the
//    **standard deviation of acceleration and angular velocity**. If both ...
//    are below specific thresholds, we perform **static initialization
//    similar to OpenVINS**; otherwise, we proceed with motion initialization."
// 而 OpenVINS 的静止检测器正是这个 GLRT —— 但 OpenVINS 是 **GPL-3**
// (`ov_init/src/static/StaticInitializer.h` 文件头自证),我们不能抄。
// ⇒ **同一个算法,换一个许可干净的实现。** 上面那份是 MIT。
//
// 🔴 上游 XRSLAM 本身**没有**任何设备静止判定(`TT_STATIC` 是**静态特征
// 轨迹**的标签,给 IMU-PARSAC 剔动态物体用的,与设备是否静止无关)。
// 我们钉的 `4beb1a9` 就是 openxrlab/xrslam 的 HEAD,没有可追的新提交。
//
// ══ 本文件只做 XR-VIO 那两个量里的**第二个** ═══════════════════════════════
// XR-VIO 的门是**两个量同时**低于阈值:
//   ① 稀疏特征的平均位移  ② 加速度与角速度的标准差
// 本文件是 ②,而且是它**按传感器噪声归一化后的严格形式**。① 要用光流跟踪
// 的结果算,不在这里。**只用 ② 判静止是不完整的** —— 相机对着一面白墙、
// 手却在平移时,② 会说"在动"(对),但反过来设备架在三脚架上而场景在动时,
// ② 说"静止"(也对,设备确实静止)。两个量各自防的是不同的假阳性。

import 'dart:math' as math;

// 🔴 ImuSample 统一到 gravity_attitude.dart。
// 原先这里另有一个同名类(**不带时间戳**),与那边那个(**带时间戳**)同名不同形:
// 两边都 import 就必须起别名,接线时极易悄悄传错一个。仓里已经因为这类
// 静默不一致栽过好几次,所以合并成一个,并 export 出去保持既有 import 可用。
import 'gravity_attitude.dart' show ImuSample;

export 'gravity_attitude.dart' show ImuSample;

/// 一条 IMU 样本。加速度是**比力**(含重力),单位 m/s²;角速度 rad/s。
///
/// 🔴 必须含重力。GLRT 的第一步就是拿窗内均值定重力方向再减掉它;
/// 喂"去重力加速度"(iOS 的 `userAcceleration` / 安卓的
/// `TYPE_LINEAR_ACCELERATION`)进来,`norm(ya_m)` 会趋近 0,整个式子发散。

/// 参考实现的参数取值,原样带过来。
///
/// 🔴 它们是**足部 MEMS IMU** 的取值(`settings.m:92-104`),
/// **不是**我们手机的。照搬当默认只是为了"复刻时不改数",
/// 真正该用的阈值必须在我们自己的设备上**测出来**,见 [kReferenceThreshold]。
abstract final class ZuptReference {
  /// `simdata.sigma_a = 0.01` —— 加速度计每样本标准差,m/s²。
  ///
  /// ⚠️ 与 XRSLAM 标定 yaml 里的 `accelerometer_noise_density`(4e-6,
  /// 单位 m/s²/√Hz)**不是同一个量**:后者是噪声密度,要乘 √fs 才是每样本
  /// 标准差。两者不可直接互换。
  static const double sigmaA = 0.01;

  /// `simdata.sigma_g = 0.1*pi/180` —— 陀螺每样本标准差,rad/s。
  static const double sigmaG = 0.1 * math.pi / 180.0;

  /// `simdata.Window_size = 3`。
  static const int windowSize = 3;

  /// `simdata.gamma = 0.3e5`,原注释:
  /// "Threshold used in the zero-velocity detector. If the test statistics
  ///  are below this value the zero-velocity hypothesis is chosen."
  ///
  /// 🔴 **这个数与上面两个 σ 和窗长绑死**(T 是按 σ² 归一化的),换了
  /// 传感器就不成立。我们自己的阈值要在真机上量:静止时 T 的分布是什么,
  /// 拿起来时是什么,两个分布之间取。**不许拍脑袋。**
  static const double gamma = 0.3e5;
}

/// 重力大小。
///
/// 🔴 **必须与喂进来的 IMU 走同一条管线测出来,不能跨管线借。**
///
/// 参考实现按部署算:`simdata.g = gravity(simdata.latitude, simdata.altitude)`
/// (`settings.m:50`,WGS-84 公式在 `:190-194`)。纬度 58° / 海拔 100 m
/// (斯德哥尔摩,KTH)给出 **9.81727**。也就是说**参考实现本身就把 g 当成
/// "按你的部署填"的参数**,不是写死的常数。
///
/// 我们这边曾经踩过的坑:一度填 **9.7442**,那是 `run-eb74a545` 录制经
/// **XRSLAM 的 IMU 管线**算出来的世界系平均比力模长;而检测器实际吃的是
/// **sensors_plus** 的数据,后者在 iOS 侧把 CoreMotion 的 g 单位乘
/// `let GRAVITY = 9.81`(`FPPStreamHandlerPlus.swift:10`)。**两条管线、
/// 两个数**,混用就是纯粹的参数错配。
///
/// ⇒ 正解:**在静止段就地量**(见 [measureGravity])。这既符合参考实现
/// "按部署填"的精神,又保证与数据源同管线。
///
/// 这个值只是**没量到时的兜底**,取 CODATA 标准重力,并明确标注它是兜底。
const double kStandardGravity = 9.80665;

/// 从一段**静止**的 IMU 采样里就地量出重力大小 = 比力模长的均值。
///
/// 🔴 只能用**静止**段。运动时比力 = 重力 + 线加速度,量出来的不是 g。
/// 运动段要用的 g,必须由同一台设备、同一条管线的**静止段**提供。
double measureGravity(List<ImuSample> staticSamples) {
  if (staticSamples.isEmpty) return double.nan;
  double sum = 0;
  for (final ImuSample s in staticSamples) {
    sum += math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az);
  }
  return sum / staticSamples.length;
}

/// 零速检测器(GLRT / SHOE)。
///
/// 用法:每来一条 IMU 样本调 [add],然后读 [statistic] / [isStationary]。
/// 窗未满时两者都是 `null` —— **不是** false。"还不知道"和"在动"是两件事,
/// 这个代码库在静默降级上栽过太多次了。
class ZeroVelocityDetector {
  ZeroVelocityDetector({
    this.windowSize = ZuptReference.windowSize,
    this.sigmaA = ZuptReference.sigmaA,
    this.sigmaG = ZuptReference.sigmaG,
    this.gravity = kStandardGravity,
    this.threshold = ZuptReference.gamma,
  })  : assert(windowSize > 0),
        assert(sigmaA > 0 && sigmaG > 0),
        assert(gravity > 0);

  final int windowSize;
  final double sigmaA;
  final double sigmaG;
  final double gravity;
  final double threshold;

  final List<ImuSample> _window = <ImuSample>[];

  void add(ImuSample s) {
    _window.add(s);
    if (_window.length > windowSize) _window.removeAt(0);
  }

  void reset() => _window.clear();

  /// 窗内样本数。
  int get count => _window.length;

  /// 最新一个满窗的检验统计量 T;窗未满返回 `null`。
  double? get statistic => _window.length < windowSize
      ? null
      : computeStatistic(_window,
          sigmaA: sigmaA, sigmaG: sigmaG, gravity: gravity);

  /// `T < threshold` ⇒ 判静止。窗未满返回 `null`(= 还不知道)。
  bool? get isStationary {
    final double? t = statistic;
    return t == null ? null : t < threshold;
  }

  /// 逐行复刻 `zero_velocity_detector.m` 的 `function T=GLRT(u)`。
  ///
  /// 对应关系:MATLAB 的 `u(1:3,·)` = 加速度,`u(4:6,·)` = 角速度。
  /// 那份是批处理(对整段数据滑窗),这里是单窗;滑窗由 [add] 负责。
  static double computeStatistic(
    List<ImuSample> window, {
    required double sigmaA,
    required double sigmaG,
    required double gravity,
  }) {
    final int w = window.length;
    if (w == 0) return double.nan;
    final double s2a = sigmaA * sigmaA;
    final double s2g = sigmaG * sigmaG;

    // ya_m = mean(u(1:3, k:k+W-1), 2)
    double mx = 0, my = 0, mz = 0;
    for (final ImuSample s in window) {
      mx += s.ax;
      my += s.ay;
      mz += s.az;
    }
    mx /= w;
    my /= w;
    mz /= w;

    // norm(ya_m)
    final double n = math.sqrt(mx * mx + my * my + mz * mz);
    if (!(n > 0) || !n.isFinite) return double.nan; // 见 ImuSample 的说明

    // g*ya_m/norm(ya_m) —— 按窗内均值定出的重力向量
    final double gxv = gravity * mx / n;
    final double gyv = gravity * my / n;
    final double gzv = gravity * mz / n;

    double t = 0;
    for (final ImuSample s in window) {
      // tmp = u(1:3,l) - g*ya_m/norm(ya_m)
      final double tx = s.ax - gxv;
      final double ty = s.ay - gyv;
      final double tz = s.az - gzv;
      // T = T + u(4:6,l)'*u(4:6,l)/sigma2_g + tmp'*tmp/sigma2_a
      t += (s.gx * s.gx + s.gy * s.gy + s.gz * s.gz) / s2g +
          (tx * tx + ty * ty + tz * tz) / s2a;
    }
    return t / w; // T = T./W
  }
}
