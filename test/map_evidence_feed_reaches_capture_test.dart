// 地图口径的数据源必须喂在**拍摄期真的会执行到**的那个分支上。
//
// 🔴 事故(build 150,未命名(11) 实测 `evidence.ticks_map = 0`):
// 我把 `_mapEvidenceSource.updateFromSnapshot` 加在了 colorize switch 那一支,
// 而页面里早就写着一行注释:
//   「拍摄期的流式快照**只走这条早退分支**,下方 colorize switch 里的同款
//     钩子在拍摄期根本执行不到 —— 未命名(7) 整场 fire_live_depth_m 为空
//     就是这么来的」
// 同一个坑,两次(未命名(7) 的 live_depth、未命名(11) 的 map evidence)。
//
// 判据不是"存在一处调用",而是**与 `_liveCloudXyz` 一一配对**:那一行是这条
// 分支上已经被验证过、拍摄期确实会执行到的赋值。只要两者成对出现,就不会
// 再有"加在够不到的分支里"这种事。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> lines;

  setUpAll(() {
    final f = File('lib/ui/official_capture/ar_capture_page.dart');
    expect(f.existsSync(), isTrue);
    lines = f
        .readAsStringSync()
        .split('\n')
        .where(
          (l) =>
              !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
        )
        .toList();
  });

  test('锚点自身可读(阳性对照)', () {
    expect(
      lines.where((l) => l.contains('_liveCloudXyz = snapshot.xyz;')).length,
      greaterThanOrEqualTo(1),
      reason: '锚点改名了 —— 先修锚,别把它读成回归',
    );
  });

  test('🔴 每一处 _liveCloudXyz 赋值旁边都必须喂 map evidence', () {
    final anchors = <int>[
      for (var i = 0; i < lines.length; i++)
        if (lines[i].contains('_liveCloudXyz = snapshot.xyz;')) i,
    ];
    expect(anchors.length, 2, reason: '早退分支 + colorize 分支,共两处');
    for (final i in anchors) {
      final window = lines.sublist(i, (i + 8).clamp(0, lines.length));
      expect(
        window.any((l) => l.contains('_mapEvidenceSource.updateFromSnapshot(')),
        isTrue,
        reason:
            '第 ${i + 1} 行的 _liveCloudXyz 旁边没有喂 map evidence —— '
            '拍摄期只走其中一条分支,漏了哪条都会让 ticks_map 恒为 0',
      );
    }
  });

  test('两处都在同一道守卫之下(未做重力旋转的流式快照)', () {
    final src = lines.join('\n');
    final guarded = 'gravityAlignQuatWxyz == null && snapshot.xyz.isNotEmpty';
    expect(
      guarded.allMatches(src).length,
      2,
      reason: '守卫条件必须两处同款 —— 重力旋转过的快照与 ARKit 不同系,不许喂',
    );
  });
}
