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
  }, skip:
      '[2026-08-22 用户签决:挂起] 133 不是 bug,是当前锚色下的数学下界。'
      '着色是红→黄→绿分段插值,t>0.5 段要在 span/2 个整数步里扫完红分量 199 阶,'
      '故最大单步 ≈ 398/span。出货配置 satAt=5 ⇒ span=3 ⇒ 下界 133。'
      '而 133 > 旧实现的 128 —— 该模块在出货配置下已无法兑现它自己的立项目的'
      '(它就是为打败那个 128 阶跳变而做的)。'
      '⇒ satAt=5 与"整数粒度无硬台阶"数学上互斥,这是产品缺陷不是测试挂错旋钮。'
      'satAt 调回 8~10 的路被 capture_quality_ramp.dart:66-85 的三方证据判死。'
      '出路只有两条:重调锚色/插值路径,或整体删除该模块(自 08-09 全白签决后'
      '它在 lib/ 已零调用)。在做出选择前不假装修好,也不让红灯淹掉其它测试。');

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

    // [2026-08-22] 上面那条只盯单文件的精确子串,`final r = kCaptureQualityRamp;
    // r.colorFor(t)` 或在别的文件接入都绕得过去。升级为全 lib/ 树扫描:
    // 任何地方调 .colorFor( 都算 ramp 被接回。(实测当前 lib/ 零命中。)
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('official_capture/capture_quality_ramp.dart')) {
        continue; // 定义处本身不算消费者
      }
      if (f.readAsStringSync().contains('.colorFor(')) offenders.add(f.path);
    }
    expect(
      offenders,
      isEmpty,
      reason: 'ramp 着色被重新接入了这些文件 —— 用户签决 live 云全白:$offenders',
    );
    expect(src, contains('rgb.fillRange(0, rgb.length, 255)'));
    // 旧的三段硬阈值也必须不在。
    expect(src, isNot(contains('if (trackLength >= 5) {')));
    expect(src, isNot(contains('} else if (trackLength >= 3) {')));
  });
}
