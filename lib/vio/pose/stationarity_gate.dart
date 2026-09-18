// stationarity_gate.dart —— 「设备是否静止」的判定门。纯 Dart,三端同一份。
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
// 量级佐证:1.5 m/s² 的加速度标准差,对照手机平放桌上实测噪声地板
// **σ̂_a ≈ 7e-3 m/s²**,是它的 **~215 倍** —— IMU 那一半**极其宽松**,
// 它不是用来要求"纹丝不动"的,防的是急动(注释原文 "detect a jerk")。
// 真正卡住静止初始化的是**视差**那一半。
//
// ⚠️ 本文件**不含** GLRT/SHOE 检测器(`zero_velocity_detector.dart`)。
// 那一条是把 IMU 判据按噪声 σ 归一化的严格形式,出处是 Skog 一脉;但**我们
// 这条血统用的不是它**,XR-VIO 与 OpenVINS 用的都是原始统计量。保留为备选,
// 不接进这个门。

import 'dart:math' as math;

import 'zero_velocity_detector.dart' show ImuSample;

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
  });

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
  String toString() => 'Stationarity(${state.name} '
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
    this.gyroStdDevThreshold,
    this.windowSeconds = kOpenVinsWindowSeconds,
  })  : assert(imuExcitationThreshold > 0),
        assert(disparityThresholdPixels > 0),
        assert(windowSeconds > 0);

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

  /// 喂一条 IMU 样本。[timestampSeconds] 用来维持 [windowSeconds] 的时间窗
  /// ——**按时间而不是按样本数**,因为采样率会变(生产 100 Hz、台架可能不同,
  /// 三端也不同),按样本数会让窗的**时长**随平台漂。
  void add(double timestampSeconds, ImuSample sample) {
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

    StationarityVerdict verdict(Stationarity s, String? why) =>
        StationarityVerdict(
          state: s,
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
      return verdict(Stationarity.unknown, '窗未满 ${windowSeconds}s');
    }
    if (!older.usable || !newer.usable) {
      return verdict(Stationarity.unknown,
          '半窗样本不足(<$kMinSamplesPerHalfWindow):老${older.sampleCount} 新${newer.sampleCount}');
    }
    if (disparityOlderPixels == null || disparityNewerPixels == null) {
      return verdict(Stationarity.unknown, '无视差输入');
    }
    if (featureCountOlder < kMinFeaturesPerHalfSpan ||
        featureCountNewer < kMinFeaturesPerHalfSpan) {
      return verdict(Stationarity.unknown,
          '特征不足(<$kMinFeaturesPerHalfSpan):老$featureCountOlder 新$featureCountNewer');
    }

    // 🔴 四个数全过才算静止。顺序照 OpenVINS:先视差后 IMU。
    if (disparityOlderPixels > disparityThresholdPixels) {
      return verdict(Stationarity.moving,
          '视差(老) ${disparityOlderPixels.toStringAsFixed(2)} > $disparityThresholdPixels px');
    }
    if (disparityNewerPixels > disparityThresholdPixels) {
      return verdict(Stationarity.moving,
          '视差(新) ${disparityNewerPixels.toStringAsFixed(2)} > $disparityThresholdPixels px');
    }
    if (older.accelStdDev! > imuExcitationThreshold) {
      return verdict(Stationarity.moving,
          '加速度σ(老) ${older.accelStdDev!.toStringAsExponential(3)} > $imuExcitationThreshold m/s²');
    }
    if (newer.accelStdDev! > imuExcitationThreshold) {
      return verdict(Stationarity.moving,
          '加速度σ(新) ${newer.accelStdDev!.toStringAsExponential(3)} > $imuExcitationThreshold m/s²');
    }
    final double? gt = gyroStdDevThreshold;
    if (gt != null) {
      if (older.gyroStdDev! > gt) {
        return verdict(Stationarity.moving,
            '角速度σ(老) ${older.gyroStdDev!.toStringAsExponential(3)} > $gt rad/s');
      }
      if (newer.gyroStdDev! > gt) {
        return verdict(Stationarity.moving,
            '角速度σ(新) ${newer.gyroStdDev!.toStringAsExponential(3)} > $gt rad/s');
      }
    }
    return verdict(Stationarity.stationary, null);
  }

  /// 取 `(lowExclusive, highInclusive]` 内的样本算统计量。
  /// 左开右闭是照 OpenVINS 的窗口条件(`> low && <= high`)。
  HalfWindowImuStats _statsBetween({
    required double lowExclusive,
    required double highInclusive,
  }) {
    final List<ImuSample> picked = <ImuSample>[];
    for (int i = 0; i < _t.length; i++) {
      if (_t[i] > lowExclusive && _t[i] <= highInclusive) {
        picked.add(_s[i]);
      }
    }
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
