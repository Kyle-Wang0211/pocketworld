// stationarity_gate.dart —— 「设备是否静止」的判定门。纯 Dart,三端同一份。
//
// ══ 出处:判据形式来自 XR-VIO 的正文,参数口径来自 OpenVINS 的配置 ═══════
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
// 它说的是**两个量**,而且都是**原始统计量**:特征位移 + IMU 标准差。
// 它把静止初始化指向 OpenVINS,而 OpenVINS 的配置文件把这两个量的窗长与
// 阈值都写出来了(`config/*/estimator_config.yaml`):
//
//   init_window_time:   2.0    # how many seconds to collect initialization information
//   init_imu_thresh:    1.5    # threshold for variance of the accelerometer to detect a "jerk" in motion
//   init_max_disparity: 10.0   # max disparity to consider the platform stationary (dependent on resolution)
//
// 🔴 **OpenVINS 是 GPL-3,本文件不含它的任何代码。** 判据形式取自 XR-VIO 的
// **文字描述**(那篇不是 GPL),参数取自其配置文件里的**数值与注释**。
//
// ══ 🔴 阈值不是普适常数,OpenVINS 自己就不当它是 ═══════════════════════════
// 逐份配置核过,**窗长恒为 2.0 秒**(设计值,可直接抄),两个阈值**三份三样**:
//
//   配置            window   imu_thresh   max_disparity
//   euroc_mav        2.0        1.5           10.0
//   rpng_aruco       2.0        1.2            2.0
//   rpng_plane       2.0        0.5            4.0
//
// 而且视差那条的注释自己写着 "dependent on resolution"。
// ⇒ **阈值必须按场景给**,本文件做成必填参数,不设默认值 —— 设了默认值就是
//   假装有普适常数,那正是这个代码库反复栽过的静默降级。
//
// ══ 🔴 两个量各防一件事,缺一不可 ═══════════════════════════════════════════
//   * **视差**防的是"有没有视差可用来做 SfM" —— 这才是静止初始化的**主因**;
//   * **IMU 方差**防的是"有没有急动"(OpenVINS 注释原文 "to detect a jerk")。
// 量级可以佐证这一点:OpenVINS 的 imu_thresh 在 0.5–1.5 这个量级,而手机
// 平放桌上的加速度标准差实测只有 **7e-3 m/s²**,低两个数量级 —— 也就是说
// IMU 那一半**极其宽松**,它不是用来要求"纹丝不动"的。
//
// ⚠️ 本文件**不含**先前那个 GLRT/SHOE 检测器(`zero_velocity_detector.dart`)。
// 那一条是把 IMU 判据按噪声 σ 归一化的严格形式,出处是 Skog 一脉;但**我们
// 这条血统用的不是它**,XR-VIO 与 OpenVINS 用的都是原始统计量。那个文件保留
// 为备选,不接进这个门。

import 'dart:math' as math;

import 'zero_velocity_detector.dart' show ImuSample;

/// 判定结果。**三态**,不是布尔 —— "还不知道"和"在动"是两件事。
enum Stationarity {
  /// 两个量都低于阈值。
  stationary,

  /// 至少一个量超阈值。
  moving,

  /// 数据不足以判断(窗没满 / 没有视差输入)。**不要当成 moving。**
  unknown,
}

/// 一次判定的全部中间量。失败时要能看出**是哪一个量把它否掉的**。
class StationarityVerdict {
  const StationarityVerdict({
    required this.state,
    required this.accelVariance,
    required this.gyroVariance,
    required this.averageDisparityPixels,
    required this.sampleCount,
    required this.windowSeconds,
  });

  final Stationarity state;

  /// 窗内加速度相对**窗均值**的均方偏差,单位 (m/s²)²。
  /// 对应 OpenVINS 的 `init_imu_thresh`。窗不足时为 `null`。
  final double? accelVariance;

  /// 角速度的同一个量,单位 (rad/s)²。
  ///
  /// XR-VIO 原文说的是 "standard deviation of acceleration **and angular
  /// velocity**",两个都提了;而 OpenVINS 的配置里**只有加速度那一个阈值**。
  /// 这里两个都算出来、都报出去,但**默认只有加速度参与判定**(与 OpenVINS
  /// 一致),角速度阈值可选。两边不一致的地方要摆出来,不能替它们选一个。
  final double? gyroVariance;

  /// 稀疏特征的平均位移,像素。由调用方从光流/跟踪结果算好传进来。
  final double? averageDisparityPixels;

  final int sampleCount;
  final double windowSeconds;

  @override
  String toString() => 'Stationarity(${state.name} '
      'accelVar=${accelVariance?.toStringAsExponential(3)} '
      'gyroVar=${gyroVariance?.toStringAsExponential(3)} '
      'disparity=${averageDisparityPixels?.toStringAsFixed(2)}px '
      'n=$sampleCount/${windowSeconds}s)';
}

/// 两量静止门。
class StationarityGate {
  StationarityGate({
    required this.accelVarianceThreshold,
    required this.disparityThresholdPixels,
    this.gyroVarianceThreshold,
    this.windowSeconds = kOpenVinsWindowSeconds,
  })  : assert(accelVarianceThreshold > 0),
        assert(disparityThresholdPixels > 0),
        assert(windowSeconds > 0);

  /// `init_window_time: 2.0`。**三份 OpenVINS 配置完全一致**,是设计值不是
  /// 场景参数,所以这一个可以直接抄,并作为默认值。
  static const double kOpenVinsWindowSeconds = 2.0;

  /// 🔴 必填,无默认值。见文件头:阈值按场景给,OpenVINS 自己三份三样。
  /// 量级参考(OpenVINS 配置):0.5 / 1.2 / 1.5。
  final double accelVarianceThreshold;

  /// 🔴 必填,无默认值。量级参考:2.0 / 4.0 / 10.0 像素,
  /// 且 OpenVINS 注释自己写着 "dependent on resolution"。
  final double disparityThresholdPixels;

  /// 可选。OpenVINS 的配置里**没有**这一项;XR-VIO 的文字里提到了角速度。
  /// 不填 ⇒ 不参与判定(与 OpenVINS 一致)。
  final double? gyroVarianceThreshold;

  final double windowSeconds;

  final List<double> _t = <double>[];
  final List<ImuSample> _s = <ImuSample>[];

  /// 喂一条 IMU 样本。[timestampSeconds] 用来维持 [windowSeconds] 的时间窗
  /// ——**按时间而不是按样本数**,因为采样率会变(生产 100 Hz、台架可能不同,
  /// 三端也不同),按样本数会让窗的**时长**随平台漂。
  void add(double timestampSeconds, ImuSample sample) {
    _t.add(timestampSeconds);
    _s.add(sample);
    final double cutoff = timestampSeconds - windowSeconds;
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
  bool get windowFull =>
      _t.length >= 2 && (_t.last - _t.first) >= windowSeconds * 0.95;

  /// 判定。[averageDisparityPixels] 为 `null` 表示暂无视觉输入 ⇒ 结果是
  /// [Stationarity.unknown],**不是** moving。
  StationarityVerdict evaluate({required double? averageDisparityPixels}) {
    final double? av = _varianceOfAccel();
    final double? gv = _varianceOfGyro();
    if (!windowFull || av == null || gv == null) {
      return StationarityVerdict(
        state: Stationarity.unknown,
        accelVariance: av,
        gyroVariance: gv,
        averageDisparityPixels: averageDisparityPixels,
        sampleCount: _s.length,
        windowSeconds: windowSeconds,
      );
    }
    if (averageDisparityPixels == null) {
      return StationarityVerdict(
        state: Stationarity.unknown,
        accelVariance: av,
        gyroVariance: gv,
        averageDisparityPixels: null,
        sampleCount: _s.length,
        windowSeconds: windowSeconds,
      );
    }
    final bool ok = av < accelVarianceThreshold &&
        averageDisparityPixels < disparityThresholdPixels &&
        (gyroVarianceThreshold == null || gv < gyroVarianceThreshold!);
    return StationarityVerdict(
      state: ok ? Stationarity.stationary : Stationarity.moving,
      accelVariance: av,
      gyroVariance: gv,
      averageDisparityPixels: averageDisparityPixels,
      sampleCount: _s.length,
      windowSeconds: windowSeconds,
    );
  }

  /// 窗内加速度相对窗均值的**均方偏差**:`(1/N)·Σ‖aᵢ − ā‖²`。
  ///
  /// 🔴 口径声明:OpenVINS 的注释只说 "variance of the accelerometer",
  /// **没说是逐轴方差之和、模长的方差、还是向量对均值的均方偏差**。这三者
  /// 数值不同。这里取**向量对均值的均方偏差** —— 它是"方差"在向量情形最直接
  /// 的推广,且等于逐轴方差之和。若日后发现 OpenVINS 用的是别的口径,
  /// 阈值量级要跟着重定;为此 [StationarityVerdict] 把原始量都报出去。
  double? _varianceOfAccel() => _meanSquaredDeviation(
      _s.map((ImuSample s) => <double>[s.ax, s.ay, s.az]).toList());

  double? _varianceOfGyro() => _meanSquaredDeviation(
      _s.map((ImuSample s) => <double>[s.gx, s.gy, s.gz]).toList());

  static double? _meanSquaredDeviation(List<List<double>> v) {
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
    return s / n;
  }

  /// 便利:把均方偏差换成标准差(XR-VIO 的文字说的是 "standard deviation",
  /// OpenVINS 的字段名说的是 "variance" —— 两边口径不同,换算摆在这里,
  /// 别让调用方自己猜)。
  static double toStdDev(double meanSquaredDeviation) =>
      math.sqrt(meanSquaredDeviation);
}
