// 「安静判据」本身的守门。它决定启动动画什么时候开始播,判错的后果就是
// 用户看到的那下顿挫,所以每条都带阴性对照。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/frame_quiet_detector.dart';

void main() {
  const budget = Duration(microseconds: 8333); // 120Hz
  FrameQuietDetector d({Duration window = const Duration(milliseconds: 100)}) =>
      FrameQuietDetector(budget: budget, quietWindow: window);

  /// 按 [count] 帧、每帧间隔一个预算地喂,每帧耗时 [cost]。返回是否在中途达成安静。
  bool feed(
    FrameQuietDetector det,
    int count, {
    Duration cost = const Duration(microseconds: 500),
    int startUs = 0,
  }) {
    var hit = false;
    for (var i = 0; i < count; i++) {
      hit |= det.addFrame(
        vsyncUs: startUs + i * budget.inMicroseconds,
        build: cost,
        raster: Duration.zero,
      );
    }
    return hit;
  }

  test('刷新率 → 预算:120Hz 是 8.3ms,不是 16.7ms', () {
    expect(frameBudgetFor(120).inMicroseconds, 8333);
    expect(frameBudgetFor(60).inMicroseconds, 16667);
  });

  test('刷新率读数不可信时退回 60Hz(不许把 0 当预算)', () {
    expect(frameBudgetFor(0).inMicroseconds, 16667);
    expect(frameBudgetFor(double.nan).inMicroseconds, 16667);
  });

  test('连续便宜帧铺满窗口 ⇒ 安静', () {
    final det = d();
    expect(feed(det, 14), isTrue, reason: '第 14 帧时 13×8.333ms = 108ms ≥ 100ms 窗口');
    expect(det.isQuiet, isTrue);
  });

  test('阴性对照:还没铺满窗口不许算安静', () {
    final det = d();
    expect(feed(det, 6), isFalse);
    expect(det.isQuiet, isFalse);
  });

  test('🔴 中途来一帧超预算 ⇒ 计时清零,重来', () {
    final det = d();
    feed(det, 10);
    det.addFrame(
      vsyncUs: 10 * budget.inMicroseconds,
      build: const Duration(milliseconds: 14), // 实测那一帧
      raster: Duration.zero,
    );
    expect(det.isQuiet, isFalse);
    expect(
      feed(det, 6, startUs: 11 * budget.inMicroseconds),
      isFalse,
      reason: '被打断后必须重新攒满整个窗口,不能接着上次的数',
    );
  });

  test('🔴 整段没有帧(线程被堵)同样算打断 —— 只数超预算帧会漏掉最严重的那种', () {
    final det = d();
    feed(det, 10);
    // 实测:+2293→+2944ms 之间一帧都没有。这里模拟 651ms 的空洞。
    det.addFrame(
      vsyncUs: 10 * budget.inMicroseconds + 651000,
      build: const Duration(microseconds: 300),
      raster: Duration.zero,
    );
    expect(
      det.isQuiet,
      isFalse,
      reason: '空洞之后那一帧本身很便宜,但它前面是 651ms 没有画面 —— '
          '这正是球僵住的那一段,必须判成不安静',
    );
  });

  test('达成之后不再改口(一次性信号)', () {
    final det = d();
    feed(det, 14);
    expect(det.isQuiet, isTrue);
    final again = det.addFrame(
      vsyncUs: 99999999,
      build: const Duration(milliseconds: 40),
      raster: Duration.zero,
    );
    expect(again, isFalse);
    expect(det.isQuiet, isTrue, reason: '动画已经开播了,再撤回没有意义');
  });

  test('reset 之后回到零态', () {
    final det = d();
    feed(det, 14);
    det.reset();
    expect(det.isQuiet, isFalse);
  });
}
