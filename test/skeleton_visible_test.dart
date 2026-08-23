// 骨架屏**看得见**吗?
//
// [2026-08-23] 这个文件是被真机截图逼出来的。之前 community_home_restructure_test
// 里关于骨架的 6 条断言**全过**,而真机上骨架是两块纯黑板 —— 因为那 6 条钉的全是
// 结构(挂没挂 AnimatedBuilder、热闸接没接对、有几个 SkeletonBox),
// **对颜色结构性失明**。
//
// 病根:kSkeletonBase/Highlight 是从 lib/ui/splash_overlay.dart 抄范式时连
// **深色启动页的底色语境**一起抄来的,而社区页用的 AetherColors 是浅色系。
// 于是骨架比页面底色暗 200 多阶,两端还只差 4%。
//
// 所以这里只测一件事:骨架在**它真正被放置的那个底色上**是不是看得见、动得起来。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/community/skeleton_shimmer.dart';
import 'package:pocketworld_flutter/ui/design_system.dart';

/// 相对亮度差 —— WCAG 的对比度公式,(L1+0.05)/(L2+0.05)。
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('骨架的灰阶属于**浅色**语境', () {
    test('两端都比页面底色暗,但不能暗成黑板', () {
      final bg = AetherColors.bg;
      for (final (name, c) in [
        ('base', kSkeletonBase),
        ('highlight', kSkeletonHighlight),
      ]) {
        expect(
          c.computeLuminance(),
          greaterThan(0.5),
          reason: '$name 必须是浅灰 —— 深色值是从深色启动页误抄过来的,'
              '在 ${bg.toARGB32().toRadixString(16)} 的页面上会变成黑板',
        );
      }
    });

    test('骨架与页面底色可分辨 —— 否则它就"消失"在页面里', () {
      final c = contrast(kSkeletonBase, AetherColors.bg);
      expect(
        c,
        greaterThan(1.05),
        reason: '基色与页面底色至少要有一点对比,不然看不出这里有块占位',
      );
      expect(
        c,
        lessThan(3.0),
        reason: '骨架不是内容,对比度过高会喧宾夺主',
      );
    });

    test('呼吸的幅度要看得出来 —— 阈值由两次真机判决钉死', () {
      final d = (kSkeletonHighlight.computeLuminance() -
              kSkeletonBase.computeLuminance())
          .abs();
      // 这个 0.20 不是我拍的,是两次真机判决夹出来的:
      //   · #1B1B1F → #26262B   Δ≈0.004  用户:「完全黑屏」
      //   · #E4E4E4 → #FAFAFA   Δ≈0.165  用户:「灰色,没有任何呼吸闪烁」
      //     ↑ 而设备日志同时证明 live_allowed=true,动画**确实在跑**,
      //       所以 0.165 是"在动但看不出来"的实测上界。
      //   · #CCCCCC → #F3F3F2   Δ≈0.30   当前值
      // 门槛必须落在 0.165 与 0.30 之间,否则第二次那版会重新溜过去 ——
      // 我第一版写的 0.03 就正是这么漏的。
      expect(
        d,
        greaterThan(0.20),
        reason: '真机实测:Δ=0.165 时用户报「没有任何呼吸闪烁」',
      );
    });
  });

  group('渲染出来的确实是浅灰', () {
    testWidgets('SkeletonWorkCard 画出的底色是浅色', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            backgroundColor: AetherColors.bg,
            body: SkeletonWorkCard(),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 16));

      final boxes = t
          .widgetList<Container>(
            find.descendant(
              of: find.byType(SkeletonBox),
              matching: find.byType(Container),
            ),
          )
          .toList();
      expect(boxes, isNotEmpty, reason: '骨架应当由 Container 画出来');

      for (final b in boxes) {
        final color = (b.decoration as BoxDecoration).color!;
        expect(
          color.computeLuminance(),
          greaterThan(0.5),
          reason: '真机上看到的就是这个颜色 —— 它必须是浅灰,不是黑',
        );
      }
    });
  });

  group('加载态的主题卡也是骨架', () {
    final code = _read('lib/ui/vault_page.dart');

    test('_LoadingState 画骨架版而不是真 TopicCard', () {
      final loading = _slice(code, 'class _LoadingState');
      expect(
        loading,
        contains('_SkeletonTopicCard('),
        reason: '真卡压在两块加载中的卡上面,本身就是第三种状态',
      );
      expect(
        loading,
        isNot(contains('const TopicCard()')),
        reason: '加载态不该出现已完成的主题卡',
      );
    });

    test('骨架与真卡共用同一个比例常量,不是各写各的高度', () {
      // [2026-08-24 更新] 原来的做法是拿一张不可见的真 TopicCard 当尺寸模板
      // (Visibility(maintainSize: true))。TopicCard 变成有状态的轮播之后这招
      // 不能用了 —— 那个隐形实例会真的建 PageController、真的跑自动翻页 Timer。
      // 现在两边都读 kTopicCardAspect,这就是"不会走散"的新保证。
      final sk = _slice(code, 'class _SkeletonTopicCard');
      expect(
        sk,
        contains('aspectRatio: kTopicCardAspect'),
        reason: '手算高度迟早跟真卡走散,走散就会在真卡到位那一刻跳格',
      );
      expect(
        sk,
        isNot(contains('child: TopicCard()')),
        reason: '隐形的真卡会跑一个看不见的自动翻页 Timer',
      );
      // 真卡那一侧读的必须是同一个常量。
      final card = _slice(code, 'class _TopicCardState');
      expect(card, contains('aspectRatio: kTopicCardAspect'));
    });
  });
}

String _read(String p) => File(p).readAsStringSync();

/// 取出某个 class 的源码片段(到下一个顶层 `class ` 为止)。
String _slice(String code, String header) {
  final i = code.indexOf(header);
  if (i < 0) return '';
  final j = code.indexOf('\nclass ', i + header.length);
  return j < 0 ? code.substring(i) : code.substring(i, j);
}
