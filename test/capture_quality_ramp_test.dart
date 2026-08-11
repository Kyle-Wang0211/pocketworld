// [P1 SATURATING-RAMP 2026-07-28] 拍摄期质量色标的契约。
//
// 守两件事:①**饱和**(达标后颜色不再变)——这是复刻 RS 读感的核心机制,
// RS 主体 67% 的点撞顶端才不显雪花;②**连续**(相邻 track 只差一点色),
// 旧的三段硬阈值把噪声 1:1 翻成颜色,正是"看不清分区"的病因。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/capture_quality_ramp.dart';

void main() {
  const ramp = kCaptureQualityRamp;

  test('saturates: at/above satAt the colour stops changing', () {
    final atSat = ramp.colorFor(ramp.satAt);
    for (final t in [ramp.satAt, ramp.satAt + 1, 12, 33, 500]) {
      expect(ramp.colorFor(t), atSat, reason: 'track=$t must stay saturated');
    }
    // 顶端是纯绿(与旧实现同一锚色)。
    expect(atSat, (56, 220, 110));
  });

  test('floor and below is pure red (old anchor colour kept)', () {
    for (final t in [ramp.floor, 1, 0, -3]) {
      expect(ramp.colorFor(t), (255, 82, 47), reason: 'track=$t');
    }
  });

  test('monotone and continuous: no hard steps between floor and satAt', () {
    // 绿分量单调不降,且相邻 track 的色差远小于旧的三段跳变(旧实现从红到
    // 黄一步跳 128 个绿阶)。
    var prevG = -1;
    var maxStep = 0;
    (int, int, int)? prev;
    for (var t = ramp.floor; t <= ramp.satAt; t++) {
      final c = ramp.colorFor(t);
      expect(c.$2, greaterThanOrEqualTo(prevG), reason: 'green must not drop');
      prevG = c.$2;
      if (prev != null) {
        final step = [
          (c.$1 - prev.$1).abs(),
          (c.$2 - prev.$2).abs(),
          (c.$3 - prev.$3).abs(),
        ].reduce((a, b) => a > b ? a : b);
        if (step > maxStep) maxStep = step;
      }
      prev = c;
    }
    expect(maxStep, lessThan(80), reason: '单步色差应远小于旧的 128 阶跳变');
  });

  test('degenerate ramp config cannot divide by zero', () {
    const bad = CaptureQualityRamp(floor: 5, satAt: 5);
    expect(bad.colorFor(5), (56, 220, 110));
    expect(bad.colorFor(1), (255, 82, 47));
  });

  test('拍摄页 live 云全白 —— 不再按 track 长度上三色', () {
    // [2026-08-09 用户签决] "现在改为全部都是白色,不用根据颜色区分状态。"
    // 本测试原先钉的是"消费 ramp 而非三段硬阈值";ramp 着色随该签决整体退出
    // 拍摄页(ramp 类本体保留,他处工具仍引用)。
    final src = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    expect(
      src,
      isNot(contains('kCaptureQualityRamp.colorFor')),
      reason: '三色 ramp 又被接回拍摄页了 —— 用户签决 live 云全白',
    );
    expect(src, contains('rgb.fillRange(0, rgb.length, 255)'));
    // 旧的三段硬阈值也必须不在。
    expect(src, isNot(contains('if (trackLength >= 5) {')));
    expect(src, isNot(contains('} else if (trackLength >= 3) {')));
  });
}
