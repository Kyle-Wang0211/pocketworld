// 任务完成那一瞬间的强震动(用户 2026-09-10 令)。
//
// 判据钉两件事:
//   ① **边沿触发** —— 只在「生成中 → 不再生成中」那一次响。轮询是每 2 秒一跳、
//      build 更频繁,写成"看到完成态就响"会变成连续震动。
//   ② 用 `heavyImpact`,与快门那一次同一种强度(ar_capture_page 的
//      `_triggerShutterHaptic`),全仓不引入第二种口径。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final page = File('lib/ui/me_page.dart');

  late String code;

  setUpAll(() {
    expect(page.existsSync(), isTrue);
    code = page
        .readAsStringSync()
        .split('\n')
        .where(
          (l) =>
              !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
        )
        .join('\n');
  });

  test('① 边沿触发:比的是上一帧的生成中集合', () {
    expect(
      code.contains('Set<String> _generatingIds'),
      isTrue,
      reason: '没有上一帧的集合就没法判边沿',
    );
    expect(
      code.contains('_generatingIds.difference(nowGenerating)') ||
          code.contains('_generatingIds\n        .difference(nowGenerating)'),
      isTrue,
      reason: '完成 = 上一帧在生成中、这一帧不在了',
    );
    expect(
      code.contains('_generatingIds = nowGenerating;'),
      isTrue,
      reason: '每帧要把集合推进,否则第二帧还会再响一次',
    );
  });

  test('② 删掉的卡片不算完成(阳性对照:别把删除震成完成)', () {
    expect(
      code.contains('.where((id) => badges.containsKey(id))'),
      isTrue,
      reason: '卡片被删也会离开生成中集合 —— 必须要求它此刻仍在列表里',
    );
  });

  test('③ 用 heavyImpact,与快门同一种强度', () {
    expect(code.contains('HapticFeedback.heavyImpact()'), isTrue);
    final shutter = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    expect(
      shutter.contains('HapticFeedback.heavyImpact()'),
      isTrue,
      reason: '阳性对照:快门那一次就是 heavyImpact,两处必须同口径',
    );
  });

  test('④ 震动失败不许穿出去打断作品页', () {
    expect(
      code.contains("DeviceLog.log('MePage', 'completion haptic failed"),
      isTrue,
      reason: '失败要留痕(静默出口是头号复发缺陷),但不能抛',
    );
    expect(code.contains('.catchError('), isTrue);
  });
}
