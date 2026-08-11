// [UNTITLED-NAME 2026-07-29] 自动命名不得重名,且空号要补回来。
//
// 旧写法是 `未命名(${store.records.length + 1})` —— 用**数量**当序号。它在两个
// 方向上都是错的,而且都不是边角情况:
//   • 重名:{1,2,3} 删掉 2 之后数量变 2,下一次就叫"未命名(3)",而 3 已经存在,
//     两条记录从此终身同名;
//   • 空号:数量不区分改过名的记录,{玩具, 未命名(2)} 会得到"未命名(3)",
//     1 号永远空着。
// 计数法修不了任何一种,必须读"已占用的名字集合"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';

void main() {
  test('empty store starts at 1', () {
    expect(nextUntitledScanName(const <String>[]), '未命名(1)');
  });

  test('fills the lowest gap — 1 and 3 present yields 2', () {
    expect(nextUntitledScanName(const <String>['未命名(1)', '未命名(3)']), '未命名(2)');
  });

  test('never reuses a live name after a middle delete (the old bug)', () {
    // {1,2,3} minus 2 → old code produced 未命名(3), colliding with the survivor.
    const afterDelete = <String>['未命名(1)', '未命名(3)'];
    final minted = nextUntitledScanName(afterDelete);
    expect(afterDelete.contains(minted), isFalse);
    expect(minted, '未命名(2)');
  });

  test('renamed records do not consume a number', () {
    // Old code counted them, so 1 was leaked forever.
    expect(nextUntitledScanName(const <String>['玩具', '未命名(2)']), '未命名(1)');
  });

  test('English-form defaults occupy the same number space', () {
    // The store writes Chinese, but older builds and hand edits leave the
    // English spelling around; ignoring it mints a cross-locale duplicate.
    expect(
      nextUntitledScanName(const <String>['Untitled(1)', '未命名(2)']),
      '未命名(3)',
    );
  });

  test('contiguous run appends at the end', () {
    expect(
      nextUntitledScanName(const <String>['未命名(1)', '未命名(2)', '未命名(3)']),
      '未命名(4)',
    );
  });

  test('junk, zero and negative-looking names are ignored', () {
    expect(
      nextUntitledScanName(const <String>[
        '未命名(0)', // 0 is not a valid slot
        '未命名()', // no digits
        '未命名(1) ', // trailing space => not the default shape
        'Untitled(abc)',
      ]),
      '未命名(1)',
    );
  });

  test('the three capture entry points all use the shared helper', () {
    // A regression here silently reintroduces duplicate names on one route
    // only, which is exactly how the bug survived this long.
    for (final path in const <String>[
      'lib/ui/capture/capture_page.dart',
      'lib/ui/official_capture/capture_page.dart',
      'lib/ui/official_capture/ar_capture_page.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(
        src.contains('nextUntitledScanName('),
        isTrue,
        reason: '$path must mint names through the shared helper',
      );
      expect(
        src.contains(r"未命名(${store.records.length + 1})"),
        isFalse,
        reason: '$path still uses count-based naming',
      );
    }
  });
}
