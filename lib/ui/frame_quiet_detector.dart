// frame_quiet_detector.dart — 「UI 线程真的安静下来了吗」。
//
// 🔴 [2026-09-15 用户令]「我可以允许多等几秒,但是不能有卡顿」。
// 启动动画(球→线→开门)总长 1290ms,只要这 1290ms 里有任何一帧超预算,
// 用户就会看到一下顿挫。155 的实测账:
//   • 温启动:开门中途 @+1774ms 有一帧 build=14.1ms;
//   • 冷启动:门刚开完 @+4693ms 有一帧 build=11.1ms,而且 +2293→+2944ms
//     之间 **一帧都没有**(平台线程被整段堵住,球当场僵住)。
// ⇒ 判据不能只看"某一帧贵不贵",还必须看**有没有帧**:整段堵住时帧计时
//   根本不会产生,只数超预算帧会把最严重的那种卡顿判成"很安静"。
//
// 本类只做一件事:吃帧计时,回答"最近是否连续安静了足够久"。
// 不认识动画、不认识启动、不碰 Flutter binding —— 便于直接喂数据测。
library;

import 'dart:async';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';

/// 一帧的预算按**实际刷新率**算。iPhone 14 Pro 是 ProMotion 120Hz ⇒ 8.3ms,
/// 拿 60Hz 的 16.7ms 当预算会漏掉一半的掉帧(155 那份账就是这么漏的)。
Duration frameBudgetFor(double refreshRateHz) {
  final hz = (refreshRateHz.isFinite && refreshRateHz >= 20) ? refreshRateHz : 60.0;
  return Duration(microseconds: (1000000 / hz).round());
}

class FrameQuietDetector {
  FrameQuietDetector({
    required this.budget,
    required this.quietWindow,
    this.stallFactor = 3,
  }) : assert(stallFactor >= 2);

  /// 单帧 build+raster 的上限。超了就算一次打断。
  final Duration budget;

  /// 必须**连续**安静这么久才算数。
  final Duration quietWindow;

  /// 两帧间隔超过 [stallFactor] 倍预算 = 掉帧/线程被堵,同样算打断。
  final int stallFactor;

  int? _quietSinceUs;
  int? _lastVsyncUs;
  bool _quiet = false;

  bool get isQuiet => _quiet;

  /// 喂一帧;返回**这一帧是否刚刚达成安静**(只在跨过阈值那一次为 true)。
  bool addFrame({
    required int vsyncUs,
    required Duration build,
    required Duration raster,
  }) {
    if (_quiet) return false;
    final last = _lastVsyncUs;
    _lastVsyncUs = vsyncUs;

    final tooExpensive =
        build.inMicroseconds + raster.inMicroseconds > budget.inMicroseconds;
    final stalled =
        last != null && vsyncUs - last > budget.inMicroseconds * stallFactor;

    if (tooExpensive || stalled) {
      _quietSinceUs = null;
      return false;
    }
    _quietSinceUs ??= vsyncUs;
    if (vsyncUs - _quietSinceUs! >= quietWindow.inMicroseconds) {
      _quiet = true;
      return true;
    }
    return false;
  }

  void reset() {
    _quietSinceUs = null;
    _lastVsyncUs = null;
    _quiet = false;
  }
}

/// 把 [FrameQuietDetector] 接到 Flutter 的帧计时上,安静达成时回调一次。
///
/// 只负责"什么时候安静",不负责"安静了要干什么" —— 调用方自己决定。
class FrameQuietWatcher {
  FrameQuietWatcher({
    required Duration budget,
    required Duration quietWindow,
    required this.onQuiet,
    this.deadline,
  }) : _detector = FrameQuietDetector(budget: budget, quietWindow: quietWindow);

  final FrameQuietDetector _detector;
  final void Function({required bool byDeadline}) onQuiet;

  /// 等不到安静也必须放行的上限 —— 没有它就是又一个静默出口。
  final Duration? deadline;

  bool _fired = false;
  bool _attached = false;
  Timer? _deadlineTimer;

  bool get isQuiet => _detector.isQuiet;

  void start() {
    if (_attached) return;
    _attached = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    final d = deadline;
    if (d != null) {
      _deadlineTimer = Timer(d, () => _fire(byDeadline: true));
    }
  }

  void dispose() {
    _deadlineTimer?.cancel();
    if (_attached) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _attached = false;
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final hit = _detector.addFrame(
        vsyncUs: t.timestampInMicroseconds(FramePhase.vsyncStart),
        build: t.buildDuration,
        raster: t.rasterDuration,
      );
      if (hit) {
        _fire(byDeadline: false);
        return;
      }
    }
  }

  void _fire({required bool byDeadline}) {
    if (_fired) return;
    _fired = true;
    _deadlineTimer?.cancel();
    if (_attached) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _attached = false;
    }
    onQuiet(byDeadline: byDeadline);
  }
}
