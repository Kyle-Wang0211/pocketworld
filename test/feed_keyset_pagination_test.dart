// feed 分页从 offset 改 keyset(seek)的契约测试。
//
// [2026-08-23 用户签决:全部复刻,能抄就抄] 依据是 PostgreSQL/PostgREST 社区
// 对分页的一致判断:**offset 分页在数据插入时会重复或跳过**,实时 feed 必须用
// cursor/keyset;且**排序键若不唯一(如时间戳)必须补主键作次级键**,否则边界上
// 值相同的行会被跳过或重复。
//
// 我们踩的正是这两条:
//   ① offset —— 边翻页边有新作品插到顶部,整列下移一位,原本在 offset 处的
//      那条挪到 offset+1,第二页从下一条开始,**中间那条永远不出现**。
//      客户端按 id 去重只挡得住重复,挡不住漏。
//   ② published_at 没有 tiebreaker —— 同一时刻发布的两条,跨页时顺序不确定。
//
// 本仓修过一次同类(此前只拉一次 limit:20 且无加载更多,第 21 个作品对所有人
// 永久不可见)。这是它更隐蔽的变体。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/community/community_service.dart';

void main() {
  group('keyset 过滤串 —— PostgreSQL 元组比较的等价展开式', () {
    final t = DateTime.utc(2026, 8, 21, 11, 37, 0, 123, 456);
    const id = '1fba8bdf-560b-4107-a8a1-73d25266a1fb';

    test('两半都在:严格小于 + 同刻时按 id 破平', () {
      final f = buildFeedKeysetFilter(afterPublishedAt: t, afterId: id);
      // (published_at, id) < (T, I)
      //   ≡ published_at < T  OR  (published_at = T AND id < I)
      expect(f, contains('published_at.lt.'));
      expect(
        f,
        contains('and(published_at.eq.'),
        reason: '漏掉这一半 = 同一时刻发布的行在边界处被整批跳过',
      );
      expect(f, contains('id.lt.$id'));
    });

    test('时间戳统一转 UTC —— 本地时区不能泄漏进游标', () {
      final local = DateTime(2026, 8, 21, 11, 37).toLocal();
      final f = buildFeedKeysetFilter(afterPublishedAt: local, afterId: id);
      expect(f, contains('Z'), reason: '必须是 UTC ISO8601,否则跨时区游标错位');
    });

    test('微秒精度不丢 —— timestamptz 是微秒的', () {
      final f = buildFeedKeysetFilter(afterPublishedAt: t, afterId: id);
      expect(f, contains('.123456'));
    });

    test('不含会破坏 or=(...) 语法的字符', () {
      final f = buildFeedKeysetFilter(afterPublishedAt: t, afterId: id);
      // or 列表以 `,` 分隔、以 `()` 分组。值里出现这两者会把语法拆坏。
      // ISO8601 与 uuid 都不含 —— 这条断言钉住"换列类型前先想清楚"。
      final valuePart = f.split('published_at.lt.')[1].split(',')[0];
      expect(valuePart, isNot(contains('(')));
      expect(valuePart, isNot(contains(')')));
    });
  });

  group('查询构造的源码契约', () {
    final src = File('lib/community/community_service.dart').readAsStringSync();
    final code = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
        .join('\n');

    test('recent 排序必须带 id 次级键', () {
      expect(
        code,
        contains("FeedSort.recent => filter\n"
            "          .order('published_at', ascending: false)\n"
            "          .order('id', ascending: false)"),
        reason: 'keyset 的硬性前提:排序键必须唯一确定一个位置',
      );
    });

    test('有游标时走 limit,没游标才用 range(offset)', () {
      expect(code, contains('? await transformed.limit(limit)'));
      expect(code, contains(': await transformed.range(offset, offset + limit - 1)'));
    });

    test('游标两个参数必须成对判定', () {
      expect(
        code,
        contains('afterPublishedAt != null && afterId != null'),
        reason: '只传时间戳会退化成不唯一的排序键',
      );
    });
  });

  group('调用方契约', () {
    final vault = File('lib/ui/vault_page.dart').readAsStringSync();

    test('加载更多用上一页最后一条作游标,不再用 current.length 当 offset', () {
      expect(vault, contains('final last = current.isEmpty ? null : current.last;'));
      expect(vault, contains('afterPublishedAt: cursorAt'));
      expect(
        vault,
        isNot(contains('offset: current.length,')),
        reason: '这一行就是旧的 offset 分页 —— 它会静默漏项',
      );
    });
  });
}
