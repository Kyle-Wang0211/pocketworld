// zupt_probe_page.dart —— 静止判定门的真机取数。**不开摄像头,纯 IMU。**
//
// ══ 量的是 OpenVINS / XR-VIO 的那个判据量,不是 GLRT ═══════════════════════
// 判据形式见 `lib/vio/pose/stationarity_gate.dart` 的文件头:
//   * 窗长 **2.0 秒**(OpenVINS `init_window_time`,三份配置一致,已抄)
//   * IMU 量 = 窗内加速度相对窗均值的**均方偏差**(OpenVINS `init_imu_thresh`)
//   * 视觉量 = 稀疏特征平均视差(OpenVINS `init_max_disparity`)
//
// 🔴 **本页只能标定 IMU 那一半。** 视差那一半要相机 + 特征跟踪,不在这里;
// 而且按 OpenVINS 自己的注释,视差阈值 "dependent on resolution",必须在
// 目标分辨率下单独取数。别把本页的结果当成整个门标定完了。
//
// ══ 🔴 一次只采一种状态,分两次跑 ═══════════════════════════════════════════
//   flutter run --dart-define=PW_ZUPT=still    ← 第一次:全程静止
//   flutter run --dart-define=PW_ZUPT=moving   ← 第二次:全程手持运动
//
// 一次跑完两段要靠人盯倒计时切换动作,切换那几秒既不属于静止也不代表运动;
// 更要紧的是标签的可信度 —— 一次跑里"哪一段是什么"要靠时间轴推断,推断就会
// 错(第一版我就把人根本没动过的几个窗标成了"手持轻动",据此下了错判词)。
// 分两次跑,**每一场整场只有一个标签**,无从推断也就无从推错。
//
// ══ 阈值不在这里定 ═════════════════════════════════════════════════════════
// 本页只出**分布**。OpenVINS 自己三份配置三个阈值(1.5 / 1.2 / 0.5),
// 注释里还写着依赖分辨率 ⇒ **按场景给,不假装有普适常数**。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../pose/stationarity_gate.dart';
import '../pose/zero_velocity_detector.dart' show ImuSample;

/// 本次采集的标签。由 `--dart-define=PW_ZUPT=still|moving` 给定。
const String kZuptLabel = String.fromEnvironment('PW_ZUPT', defaultValue: 'still');

class ZuptProbePage extends StatefulWidget {
  const ZuptProbePage({super.key});

  @override
  State<ZuptProbePage> createState() => _ZuptProbePageState();
}

class _ZuptProbePageState extends State<ZuptProbePage> {
  static const Duration _kPeriod = Duration(milliseconds: 10); // 100 Hz
  /// 采集时长。真机单场硬性上限 300 s 的规矩摆着,这里取 30 s 足够:
  /// 100 Hz × 30 s = 3000 个样本,分位数已经很稳。
  static const int _kSeconds = 30;
  /// 前 3 秒丢弃:给人把手放好/开始动的余量。
  static const int _kWarmupSeconds = 3;

  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyrSub;
  Timer? _tick;

  /// 🔴 改成**两遍**:先把原始样本收下来,量出 g,再用那个 g 算 T。
  ///
  /// 为什么不能边收边算:g 是**这一段数据自己**的统计量(静止段比力模长的
  /// 均值),收之前不知道。一边收一边用一个猜的 g 算,就是我们刚踩过的那个
  /// 跨管线错配。
  final List<ImuSample> _raw = <ImuSample>[];


  double _gx = 0, _gy = 0, _gz = 0;
  bool _gotGyro = false;
  int _elapsed = 0;
  bool _done = false;
  final List<String> _report = <String>[];

  bool get _collecting => !_done && _elapsed >= _kWarmupSeconds;

  @override
  void initState() {
    super.initState();
    _startSensors();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_done) return;
      setState(() {
        _elapsed++;
        if (_elapsed >= _kWarmupSeconds + _kSeconds) {
          _done = true;
          _emit();
        }
      });
    });
  }

  @override
  void dispose() {
    _accSub?.cancel();
    _gyrSub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _startSensors() {
    _gyrSub = gyroscopeEventStream(samplingPeriod: _kPeriod).listen((e) {
      _gx = e.x;
      _gy = e.y;
      _gz = e.z;
      _gotGyro = true;
    });
    _accSub = accelerometerEventStream(samplingPeriod: _kPeriod).listen((e) {
      if (!_gotGyro || !_collecting) return;
      _raw.add(ImuSample(ax: e.x, ay: e.y, az: e.z, gx: _gx, gy: _gy, gz: _gz));
    });
  }

  static double _q(List<double> sorted, double p) =>
      sorted.isEmpty ? double.nan : sorted[((sorted.length - 1) * p).round()];

  void _emit() {
    void line(String x) {
      debugPrint('[zupt] $x');
      _report.add(x);
    }

    line('===== 标签 = $kZuptLabel   n=${_raw.length} 样本 =====');
    if (_raw.length < 200) {
      line('样本太少,作废');
      setState(() {});
      return;
    }

    // 逐样本喂进门,收集**每一次满窗**的两个方差。
    final StationarityGate gate = StationarityGate(
      // 阈值在这里无意义(只取数不判定),给 OpenVINS euroc 的量级占位。
      accelVarianceThreshold: 1.5,
      disparityThresholdPixels: 10.0,
    );
    final List<double> av = <double>[], gv = <double>[];
    final double hz = 1000.0 / _kPeriod.inMilliseconds;
    for (int i = 0; i < _raw.length; i++) {
      gate.add(i / hz, _raw[i]);
      if (!gate.windowFull) continue;
      final v = gate.evaluate(averageDisparityPixels: 0.0);
      if (v.accelVariance != null) av.add(v.accelVariance!);
      if (v.gyroVariance != null) gv.add(v.gyroVariance!);
    }
    if (av.isEmpty) {
      line('窗从未满 —— 采集时长不足 ${StationarityGate.kOpenVinsWindowSeconds}s?');
      setState(() {});
      return;
    }
    av.sort();
    gv.sort();

    line('窗长 ${StationarityGate.kOpenVinsWindowSeconds}s @ '
        '${hz.toStringAsFixed(0)}Hz  ⇒ 每窗 ${(hz * 2).round()} 样本,'
        '共 ${av.length} 个满窗');
    line('加速度方差 (m/s²)²  [= OpenVINS init_imu_thresh 的量]');
    line('  p01=${_q(av, .01).toStringAsExponential(3)}  '
        'p50=${_q(av, .50).toStringAsExponential(3)}  '
        'p99=${_q(av, .99).toStringAsExponential(3)}  '
        'max=${av.last.toStringAsExponential(3)}');
    line('  (换成标准差 p50=${StationarityGate.toStdDev(_q(av, .5)).toStringAsExponential(3)} m/s²'
        ' —— XR-VIO 文字说的是 std,OpenVINS 字段名说的是 variance)');
    line('角速度方差 (rad/s)²  [OpenVINS 配置里没有这一项,XR-VIO 文字提到了]');
    line('  p01=${_q(gv, .01).toStringAsExponential(3)}  '
        'p50=${_q(gv, .50).toStringAsExponential(3)}  '
        'p99=${_q(gv, .99).toStringAsExponential(3)}  '
        'max=${gv.last.toStringAsExponential(3)}');
    line('OpenVINS 的 init_imu_thresh 量级:euroc 1.5 / aruco 1.2 / plane 0.5');
    line('🔴 本场只出分布,不定阈值;且只标定了 IMU 那一半,'
        '视差那一半要相机+特征跟踪,另外取数。');
    line('🔴 两场都跑完后,看 still 的 p99 与 moving 的 p01 之间有没有空隙。');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bool still = kZuptLabel == 'still';
    final String what = still ? '放在桌上 别碰它' : '拿在手上 正常走动、转动';
    final Color c = still ? Colors.greenAccent : Colors.redAccent;
    final int left = math.max(0, _kWarmupSeconds + _kSeconds - _elapsed);
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('本场标签:$kZuptLabel',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.withValues(alpha: 0.7), fontSize: 14)),
              const SizedBox(height: 6),
              Text(_done ? '完成' : what,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: c,
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      height: 1.25)),
              const SizedBox(height: 8),
              if (!_done)
                Text('$left',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: _collecting ? c : Colors.white24,
                        fontSize: 96,
                        fontWeight: FontWeight.w300,
                        height: 1.0)),
              if (!_done)
                Text(_collecting ? '采集中' : '预热(不采)',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: _collecting ? c : Colors.white38, fontSize: 13)),
              const SizedBox(height: 14),
              Expanded(
                child: ListView(
                  children: _report
                      .map((String s) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(s,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    height: 1.4,
                                    fontFamily: 'Menlo')),
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
