// imu_calib_capture_page.dart —— 多姿态静止法 IMU 内参标定采集。**不开摄像头,纯 IMU。**
//
// ══ 这一页存在的理由 ═══════════════════════════════════════════════════════
// XRSLAM 的尺度是在**约 1.2 秒的初始化窗口里一次性定死**的
// (`initializer.cpp:426` 线性解出重力+尺度+速度 → `:467` 重力钉在 9.80665 再解
//  → `:543` `p = scale * (q * p)` 只乘一次;之后滑窗里**没有 scale 参数**)。
// 决定它准不准的输入里,加速度计内参我们从未标定 —— 本页采标定所需的数据。
//
// ══ 🔴 协议已更正一次(第一版是错的)═══════════════════════════════════════
// 第一版照 iKalibr 配置里那六个 bag 名做成**六个固定方位、每段 60 秒**。两处都错:
//
// Tedaldi/Pretto/Menegatti ICRA 2014 §IV 原文:
//   "To avoid unobservability in the calibration parameters estimation, **a minimum
//    of nine different attitudes** has to be collected. In our experience, **a higher
//    number N of distinct attitudes are required to get better calibration results**,
//    while **keeping reduced the duration of each static interval** in order to
//    preserve the assumption of temporal [stability]"
//
//   ⇒ 姿态数 **≥9,越多越好**(不是 6);每段**要短**(不是 60 秒)。
//      6 个姿态对 9 个未知量(3 标度 + 3 非正交 + 3 零偏)**欠定**,
//      除非六个姿态是**精确的** ±x/±y/±z 对称组 —— 手持做不到,也不该被要求做到。
//
// 🔑 **姿态不需要准,只需要彼此不同。** 代价函数(论文 Eq.10)
//    `L(θ) = Σ_k (‖g‖² − ‖h(a_k, θ)‖²)²` **只用 ‖g‖ 的模长,朝向从不进入方程**。
//    ⇒ 垫书、靠墙角、斜搭着都算数;不用把手机立起来,不用卡准 90°。
//    要的是"**放着不动**",不是"**立着不动**"。
//
// ══ 🔴 两条继承自 `zupt_probe_page.dart` 的教训(不是我重新想的)═════════════
// 1. **不在 initState 里自动开始。** 装机实测「Installing and launching」单次 136 秒,
//    自动开始等于让人蒙着眼睛猜什么时候摆好。⇒ 人点了才开始。
// 2. **参数在页面上选,不用编译期常量。** 否则换一次要重编重装。
//
// ══ 采集走原生,不走 sensors_plus ═══════════════════════════════════════════
// 走 `ios/Runner/PwImuCalibCapture.swift`(CoreMotion 回调里直接 append)。
// 标定**一条样本都不能漏**,而轮询会漏(见 `native_imu_ffi.dart` 文件头)。
//
// ══ 怎么跑 ═════════════════════════════════════════════════════════════════
//   flutter run --release --dart-define=PW_IMU_CALIB=true
// 落盘 `Documents/imu_calib/POSE_NN/{gyro.csv,accel.csv,capture_meta.json}`。
// 🔴 主机侧转换脚本**遍历所有子目录、不认名字**,所以早先那六个
//    `X_DOWN_STATIC` 等目录会被一并计入,不用删也不用重采。

import 'dart:async';

import 'package:flutter/material.dart';

import 'imu_calib_ffi.dart';

class ImuCalibCapturePage extends StatefulWidget {
  const ImuCalibCapturePage({super.key});

  @override
  State<ImuCalibCapturePage> createState() => _ImuCalibCapturePageState();
}

class _ImuCalibCapturePageState extends State<ImuCalibCapturePage> {
  /// 每段时长。论文只说"要短",没给具体秒数;2026 年那篇扩展
  /// (arXiv 2607.25784,明说沿用 Tedaldi 的采集方式)写的是
  /// "36 to 50 different attitudes for **at least 5 s** are sufficient"。
  /// ⇒ 默认 10 s,页面可选 —— **不写死成常数**。
  static const List<int> _kDurationChoices = <int>[5, 10, 20];
  int _seconds = 10;

  /// 论文的下限。到 9 之前 UI 一直提示还差几个。
  static const int _kMinAttitudes = 9;

  Timer? _tick;
  int _elapsed = 0;
  String? _active;
  int _next = 1;

  final List<String> _done = <String>[];
  final List<String> _log = <String>[];

  @override
  void dispose() {
    _tick?.cancel();
    if (_active != null) ImuCalibCapture.stopAndWrite();
    super.dispose();
  }

  void _begin() {
    final String label = imuCalibPoseLabel(_next);
    final int rc = ImuCalibCapture.start(label);
    if (rc != 0) {
      setState(() => _log.insert(
          0,
          '🔴 $label 启动失败 rc=$rc'
          '${rc == -1 ? ' (陀螺不可用)' : rc == -2 ? ' (加速度计不可用)' : rc == -3 ? ' (host 时钟异常)' : rc == -4 ? ' (已在录)' : ''}'));
      return;
    }
    setState(() {
      _active = label;
      _elapsed = 0;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      setState(() => _elapsed++);
      if (_elapsed >= _seconds) _finish();
    });
  }

  void _finish() {
    _tick?.cancel();
    _tick = null;
    final String? label = _active;
    if (label == null) return;
    final ImuCalibCaptureStats s = ImuCalibCapture.stats();
    final int n = ImuCalibCapture.stopAndWrite();
    setState(() {
      _active = null;
      if (n < 0) {
        _log.insert(
            0,
            '🔴 $label 落盘失败 rc=$n'
            '${n == -5 ? ' (建目录失败)' : n == -6 ? ' (写文件失败)' : ''}');
      } else {
        _done.add(label);
        _next++;
        _log.insert(0, '✅ $label  $n 样本  ${s.toDiagnosticString()}');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool busy = _active != null;
    final int n = _done.length;
    final bool enough = n >= _kMinAttitudes;
    return Scaffold(
      appBar: AppBar(title: const Text('IMU 内参标定采集(多姿态静止)')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '把手机放成一个姿态、放着别动,点「采下一个姿态」。\n'
                '姿态不用准 —— 垫书、靠墙角、斜搭着都算,只要每次跟上一次不一样。\n'
                '不用把手机立起来平衡。要的是「放着不动」,不是「立着不动」。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(children: <Widget>[
                const Text('每段 '),
                for (final int d in _kDurationChoices)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('$d s'),
                      selected: _seconds == d,
                      onSelected:
                          busy ? null : (_) => setState(() => _seconds = d),
                    ),
                  ),
              ]),
              const SizedBox(height: 10),
              if (busy)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  color: Colors.red.shade900,
                  child: Text(
                    '正在采 $_active   $_elapsed / $_seconds s\n别碰手机',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _begin,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text('采下一个姿态  ${imuCalibPoseLabel(_next)}',
                          style: const TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                color: enough ? Colors.green.shade900 : Colors.orange.shade900,
                child: Text(
                  enough
                      ? '本次已采 $n 个姿态 —— 已过论文下限 9。再多采几个只会更好。'
                      : '本次已采 $n 个姿态 —— 论文下限是 9,还差 ${_kMinAttitudes - n} 个。',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    for (final String line in _log)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(line,
                            style: const TextStyle(
                                fontFamily: 'Menlo', fontSize: 11)),
                      ),
                  ],
                ),
              ),
              const Text(
                '落盘:Documents/imu_calib/<姿态>/ —— 之前采的六个方位目录会被一并计入,不用删。',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
