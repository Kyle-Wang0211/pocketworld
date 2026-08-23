// 拍摄期 live 点云**必须全白** —— 这是本仓关于采集期着色的唯一现存契约。
//
// [2026-08-09 用户签决] 原话:"现在改为全部都是白色,不用根据颜色区分状态。"
// [2026-08-23 用户复述] "对呀。live 云全白。"
//
// ## 为什么这个文件叫"全白"而不是叫 ramp
//
// 它的前身是 capture_quality_ramp_test.dart,守的是"拍摄页必须消费 ramp 而非
// 三段硬阈值"。ramp 模块(lib/official_capture/capture_quality_ramp.dart,86 行)
// 已于 2026-08-23 **整体删除**,原因有两条,缺一不可:
//
//   1. **它零调用点** —— 08-09 全白签决后就从拍摄页拔掉了,躺了两周
//   2. **它在出货配置下无法兑现自己的立项目的**:
//      着色是红→黄→绿分段插值,t>0.5 段要在 span/2 个整数步里扫完红分量 199 阶
//      ⇒ 最大单步 ≈ 398/span。出货配置 floor:2 / satAt:5 ⇒ span=3 ⇒ **下界 133**。
//      而它当初就是为了打败旧实现那个 **128 阶**跳变才做的 —— 133 > 128,更差。
//      satAt 调回 8~10 的路被该文件自己 66-85 行的三方证据判死过("10-12 比 8 更糟")。
//      即 **satAt=5 与"整数粒度无硬台阶"数学上互斥**,是产品缺陷不是参数没调好。
//
// 删掉它之后,唯一还需要守的就是这一条:**别把按 track 长度上色悄悄接回来**。
//
// ⚠️ 若哪天要回到"按质量上色",不是把这个文件删掉就行 —— 要重新调锚色,
// 让 satAt=5 下最大单步 < 128。那是需要肉眼参与的产品决策。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('拍摄页 live 云全白 —— 不再按 track 长度上三色', () {
    final src = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    expect(src, contains('rgb.fillRange(0, rgb.length, 255)'));
    // 旧的三段硬阈值必须不在。
    expect(src, isNot(contains('if (trackLength >= 5) {')));
    expect(src, isNot(contains('} else if (trackLength >= 3) {')));
  });

  test('ramp 模块已删除,且全 lib/ 树无人按质量上色', () {
    expect(
      File('lib/official_capture/capture_quality_ramp.dart').existsSync(),
      isFalse,
      reason: 'ramp 已于 2026-08-23 删除;要复活得先重调锚色(见文件头)',
    );

    // 只盯单文件的精确子串挡不住 `final r = kSomeRamp; r.colorFor(t)`
    // 或在别的文件接入。扫全树。
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final s = f.readAsStringSync();
      if (s.contains('.colorFor(') || s.contains('CaptureQualityRamp')) {
        offenders.add(f.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '按质量上色被接回来了 —— 用户签决 live 云全白:$offenders',
    );
  });
}
