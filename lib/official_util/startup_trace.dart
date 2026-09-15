// startup_trace.dart — 冷启动的**逐帧账**。
//
// 🔴 诊断脚手架,不是功能。立项理由:启动卡顿我已经改过一刀(154 合并浮层),
// 用户回来说"还是卡顿,而且形变动画都没了"。第二刀不许再靠推理 —— 先把
// 「哪一帧、贵在 build 还是 raster、发生在启动的第几毫秒」测出来。
//
// 口径:
//   • mark(label) 记的是**距本类 start() 的毫秒数**,不是距进程启动 ——
//     Dart 侧拿不到进程启动时刻,写成"距进程启动"就是编数。
//   • 帧账用 SchedulerBinding 的 FrameTiming(Flutter 自己的量,不是我估的):
//     buildDuration = UI 线程,rasterDuration = GPU 线程。
//   • 只收前 [_windowMs] 毫秒,到点打一份汇总就摘钩子;逐帧写文件会自己
//     制造卡顿,那是拿尺子去改被测物。
library;

import 'dart:async';

import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';

import '../ui/frame_quiet_detector.dart';
import 'device_log.dart';

class StartupTrace {
  StartupTrace._();

  static const int _windowMs = 9000;
  static const int _maxFrames = 1200;

  static final Stopwatch _since = Stopwatch();
  static final List<FrameTiming> _frames = <FrameTiming>[];
  static bool _started = false;
  static int? _firstFrameEpochUs;

  static bool get started => _started;

  /// 在 runApp 之前调一次。
  static void start() {
    if (_started) return;
    _started = true;
    _since.start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    Timer(const Duration(milliseconds: _windowMs), _report);
  }

  static void mark(String label) {
    if (!_started) return;
    DeviceLog.log('Startup', '+${_since.elapsedMilliseconds}ms $label');
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (_frames.length >= _maxFrames) return;
    _frames.addAll(timings);
  }

  static int _ms(int us) => (us / 1000).round();

  static void _report() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    if (_frames.isEmpty) {
      DeviceLog.log('Startup', '帧账:一帧都没收到(钩子没生效?)');
      return;
    }
    _firstFrameEpochUs ??= _frames.first.timestampInMicroseconds(
      FramePhase.vsyncStart,
    );
    final base = _firstFrameEpochUs!;

    int total(FrameTiming f) =>
        f.buildDuration.inMicroseconds + f.rasterDuration.inMicroseconds;
    final sorted = <int>[for (final f in _frames) total(f)]..sort();
    int pct(double p) => sorted[((sorted.length - 1) * p).round()];
    // 🔴 预算必须按**实际刷新率**算。第一版写死 16667(60Hz),而 iPhone 14 Pro
    // 是 120Hz ⇒ 8333 —— 于是 14.1ms 和 11.1ms 两帧都被报成"没超预算",
    // 正好把用户看得见的那两下顿挫藏了起来。
    final budgetUs = frameBudgetFor(
      SchedulerBinding.instance.platformDispatcher.displays.isEmpty
          ? 60
          : SchedulerBinding.instance.platformDispatcher.displays.first.refreshRate,
    ).inMicroseconds;
    final over = sorted.where((v) => v > budgetUs).length;

    DeviceLog.log(
      'Startup',
      '帧账 ${_windowMs}ms 窗口:帧数=${_frames.length} '
          '超预算(>${(budgetUs / 1000).toStringAsFixed(1)}ms)=$over '
          'p50=${(pct(0.5) / 1000).toStringAsFixed(1)}ms '
          'p95=${(pct(0.95) / 1000).toStringAsFixed(1)}ms '
          'max=${(sorted.last / 1000).toStringAsFixed(1)}ms',
    );

    // 🔴 空洞账:**最严重的卡顿根本不产生帧计时**(线程被堵住时一帧都没有),
    // 只排"最贵的帧"会把它整个漏掉 —— 155 那次 +2293→+2944ms 的 651ms 空洞
    // 就没出现在最贵帧榜里。而且空洞还有第二重伤害:
    // AnimationController 按真实时间推进,空洞过后它会**一步跳过去**,
    // 500ms 的球→线形变会在一帧里走完 = 看上去"动画没了"。
    final gaps = <({int atMs, int gapMs})>[];
    for (var i = 1; i < _frames.length; i++) {
      final prev = _frames[i - 1].timestampInMicroseconds(FramePhase.vsyncStart);
      final cur = _frames[i].timestampInMicroseconds(FramePhase.vsyncStart);
      final gap = cur - prev;
      if (gap > budgetUs * 3) {
        gaps.add((atMs: _ms(prev - base), gapMs: _ms(gap)));
      }
    }
    gaps.sort((a, b) => b.gapMs.compareTo(a.gapMs));
    DeviceLog.log('Startup', '空洞(>3 帧预算没有画面)共 ${gaps.length} 处');
    for (final g in gaps.take(8)) {
      DeviceLog.log('Startup', '  空洞 @+${g.atMs}ms  持续 ${g.gapMs}ms');
    }

    final worst = <FrameTiming>[..._frames]
      ..sort((a, b) => total(b).compareTo(total(a)));
    for (final f in worst.take(12)) {
      final at = _ms(f.timestampInMicroseconds(FramePhase.vsyncStart) - base);
      DeviceLog.log(
        'Startup',
        '  最贵帧 @+${at}ms  build=${(f.buildDuration.inMicroseconds / 1000).toStringAsFixed(1)}ms '
            'raster=${(f.rasterDuration.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }
  }
}
