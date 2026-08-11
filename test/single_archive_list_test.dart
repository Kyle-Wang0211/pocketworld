// 存档单列表(源码钉子):删除"项目/草稿"分页。
//
// [2026-08-10 用户签决] "删除项目和草稿的分页,以后不管什么阶段的存档,都用
// 卡片的形式放在一起,继续以现在的时间顺序排序。把上面的分类 ui 和功能都删掉。"
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/ui/me_page.dart').readAsStringSync();

  test('分类 UI 与状态已删干净', () {
    for (final token in [
      '_ProjectsDraftsTab',
      '_TabPill',
      '_showProjects',
      'initialShowDrafts',
    ]) {
      expect(
        src.contains(token),
        isFalse,
        reason: '$token 又回来了 ⇒ 分页 UI/状态被复活(用户签决删除)',
      );
    }
  });

  test('列表是全量单列表,不再按 hasCompletedArtifact 二分', () {
    expect(
      src.contains('final mine = ScanRecordStore.instance.records;'),
      isTrue,
      reason: '存档列表不再是全量 ⇒ 又开始过滤了',
    );
    expect(
      RegExp(r'where\(\(r\) => !?r\.hasCompletedArtifact\)').hasMatch(src),
      isFalse,
      reason: '按完成态过滤的旧写法回来了',
    );
  });
}
