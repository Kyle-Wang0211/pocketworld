// 卡片只有**两种**可见状态的契约测试。
//
// [2026-08-23 用户签决]「我就要两个状态:基础架构,灰色闪烁的加载状态和最终的
// 完成状态。」
//
// 修之前真机上至少漏出三种(用户截图为证):
//   ① feed 级加载 —— 2 张骨架卡,**连主题卡都还没有**(feed 到达时整列跳一格)
//   ② 黑底 + **无条件画出来的玻璃板** —— 文字浮在纯黑上几乎看不见
//   ③ 完成态
// ② 最难看:它既不是"在加载"也不是"好了",是个幽灵。根因是玻璃板那一层
// 不等缩略图、也不等 viewer 出第一帧。
//
// 现在收成一个闸 `ready`:
//   · 焦点卡要挂 viewer  → 等 viewer 第一帧
//   · 只有缩略图         → 等图第一帧(图挂了也放行,否则骨架永远盖着)
//   · 两者都没有         → 立刻 ready
// 在 ready 之前,骨架**盖住整张卡**(黑底 / 缩略图 / 玻璃板全在它下面)。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:pocketworld_flutter/community/community_service.dart';
import 'package:pocketworld_flutter/community/feed_models.dart';
import 'package:pocketworld_flutter/ui/community/skeleton_shimmer.dart';
import 'package:pocketworld_flutter/ui/community/work_card.dart';

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  final service = CommunityService(
    client: SupabaseClient('https://offline.invalid', 'test-anon-key'),
  );

  FeedWork work({String? thumb, String? model}) => FeedWork(
    id: 'w1',
    userId: 'u1',
    title: '未命名(1)',
    description: null,
    format: 'glb',
    modelStoragePath: model,
    fileSizeBytes: null,
    thumbnailStoragePath: thumb,
    likesCount: 3,
    viewsCount: 9,
    publishedAt: DateTime.utc(2026, 8, 21),
    authorDisplayName: 'kyle',
    authorHandle: 'kyle',
    authorAvatarUrl: null,
    likedByMe: false,
  );

  Future<void> pump(WidgetTester t, FeedWork w) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkCard(work: w, service: service, onTap: () {}),
        ),
      ),
    );
    await t.pump();
  }

  /// 骨架幕布当前的不透明度。1 = 加载态,0 = 完成态。
  double curtainOpacity(WidgetTester t) {
    final f = find.ancestor(
      of: find.byType(SkeletonWorkCard),
      matching: find.byType(AnimatedOpacity),
    );
    return t.widget<AnimatedOpacity>(f.first).opacity;
  }

  group('两种状态,不多不少', () {
    testWidgets('有缩略图但还没加载出来 → 骨架盖着,玻璃板不画', (t) async {
      // 测试环境没有网络,Image.network 永远出不来第一帧 ⇒ 停在加载态。
      await pump(t, work(thumb: 'thumbs/a.png'));
      expect(curtainOpacity(t), 1.0, reason: '加载态:幕布全不透明');
      // 玻璃板上的文字一个都不该在
      expect(
        find.text('未命名(1)'),
        findsNothing,
        reason: '玻璃板必须等 ready —— 否则就是那个"黑底 + 幽灵文字"的中间态',
      );
      expect(find.text('3'), findsNothing);
    });

    testWidgets('既无缩略图也无模型 → 立刻完成态,不能永远盖着', (t) async {
      await pump(t, work());
      expect(curtainOpacity(t), 0.0, reason: '没东西可等,就该直接是完成态');
      expect(find.text('未命名(1)'), findsOneWidget);
    });

    testWidgets('加载态下点击仍能穿透(幕布不吞手势)', (t) async {
      var tapped = false;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkCard(
              work: work(thumb: 'thumbs/a.png'),
              service: service,
              onTap: () => tapped = true,
            ),
          ),
        ),
      );
      await t.pump();
      await t.tap(find.byType(WorkCard));
      expect(tapped, isTrue, reason: '加载中点一下也该能进详情页');
    });
  });

  group('源码契约', () {
    final src = File('lib/ui/community/work_card.dart').readAsStringSync();
    final code = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('只有一个就绪闸,三种情形都覆盖', () {
      // [2026-08-24 更名] ready → contentReady:卡片自己算的那个现在只是
      // "内容能看了",揭不揭幕布由页面统一决定(见 reveal_together_test)。
      expect(code, contains('final contentReady = canMountLiveViewer'));
      expect(code, contains('? _viewerFirstFrameReady'));
      expect(code, contains(': (thumbUrl == null ? true : _thumbReady)'));
    });

    test('自己好了也要等页面统一揭幕', () {
      expect(code, contains('final ready = contentReady && widget.revealed;'));
    });

    test('玻璃板被 ready 挡住', () {
      expect(
        code,
        contains('if (ready)\n                Positioned('),
        reason: '此前它是无条件的 —— 那正是幽灵态的根因',
      );
    });

    test('不再有"某一层各画各的占位"', () {
      expect(
        code,
        isNot(contains('_CardPlaceholder')),
        reason: '逐层占位就是中间态的来源;现在统一用一块幕布',
      );
    });

    // ⚠️ 这条原本写成"源码里含 errorBuilder 和 setState 就算过" —— 变异测试
    // 当场证明它是摆设:把那段包进 `if (false)`,两个字符串都还在,断言照样过。
    // 改成**行为**测试,见下面 group('图加载失败')。
  });

  group('feed 层也只有两态', () {
    final vault = File('lib/ui/vault_page.dart').readAsStringSync();

    test('加载态也画主题卡 —— 否则 feed 到达时整列跳一格', () {
      expect(vault, contains('showTopicCard: _showTopicCard'));
      expect(vault, contains('if (showTopicCard) ...['));
    });
  });

  group('图加载失败 —— 必须放行,不能永远盖着', () {
    testWidgets('缩略图 404 → 幕布退场,进入完成态', (t) async {
      // Flutter 测试环境的默认 HttpClient 对所有请求返回 400,
      // 于是 Image.network 走 errorBuilder —— 正是要测的那条路。
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkCard(
              work: work(thumb: 'thumbs/does-not-exist.png'),
              service: service,
              onTap: () {},
            ),
          ),
        ),
      );
      // 给 image resolve + errorBuilder + addPostFrameCallback 各一拍
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(curtainOpacity(t), 0.0, reason: '图挂了也必须放行 —— 否则骨架永远盖着,那是第三种状态');
      expect(find.text('未命名(1)'), findsOneWidget);
    });
  });
}
