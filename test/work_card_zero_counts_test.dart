// D8「卡片上不展示为 0 的计数」的契约测试。
//
// [2026-08-23 用户签决] 依据:低数字本身就是负向信号。冷启动期公开作品
// 个位数,一张写着"0 个赞 / 1 次浏览"的卡片比不写更伤 —— 而那 1 次浏览
// 几乎必然是创作者自己点进去的。
//
// 两者落法**故意不同**,这正是本测试要钉住的:
//   赞    只藏数字,心形图标**必须留** —— 它是点赞的可供性,藏了等于藏功能
//   浏览  整块藏(图标一并),因为它不可点,藏掉不损失任何功能

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:pocketworld_flutter/community/community_service.dart';
import 'package:pocketworld_flutter/community/feed_models.dart';
import 'package:pocketworld_flutter/ui/community/work_card.dart';

void main() {
  // WorkCard 用 VisibilityDetector 上报可见度(闸 1/5/6 靠它算焦点)。
  // 它默认 500ms 批处理一次,widget 树销毁后那个 Timer 还在跑 ⇒
  // "A Timer is still pending even after the widget tree was disposed"。
  // 本测试只关心渲染结果,不关心可见度节流,置 0 让回调同步发生。
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  // 缩略图/模型路径都为 null ⇒ build 全程不碰 service ⇒ 无需联网。
  final service = CommunityService(
    client: SupabaseClient('https://offline.invalid', 'test-anon-key'),
  );

  FeedWork work({required int likes, required int views}) => FeedWork(
    id: 'w1',
    userId: 'u1',
    title: '未命名(1)',
    description: null,
    format: 'ply',
    modelStoragePath: null,
    fileSizeBytes: null,
    thumbnailStoragePath: null,
    likesCount: likes,
    viewsCount: views,
    publishedAt: DateTime.utc(2026, 8, 21),
    authorDisplayName: 'kyle',
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

  testWidgets('0 个赞 → 不渲染数字,但心形图标必须还在', (t) async {
    await pump(t, work(likes: 0, views: 99));
    expect(find.text('0'), findsNothing, reason: 'D8:0 不该被印出来');
    expect(
      find.byIcon(Icons.favorite_outline_rounded),
      findsOneWidget,
      reason: '心是点赞的可供性,藏掉等于把功能藏了 —— 只该藏数字',
    );
  });

  testWidgets('赞 > 0 → 数字照常渲染', (t) async {
    await pump(t, work(likes: 7, views: 99));
    expect(find.text('7'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_outline_rounded), findsOneWidget);
  });

  testWidgets('浏览数低于下限 → 整块藏掉,眼睛图标也不在', (t) async {
    for (final v in [0, kWorkCardMinViewsToShow - 1]) {
      await pump(t, work(likes: 5, views: v));
      expect(
        find.byIcon(Icons.remove_red_eye_outlined),
        findsNothing,
        reason: '浏览块不可点 ⇒ 无可供性 ⇒ 连图标一起藏(views=$v)',
      );
    }
  });

  testWidgets('浏览数达到下限 → 整块渲染', (t) async {
    await pump(t, work(likes: 5, views: kWorkCardMinViewsToShow));
    expect(find.byIcon(Icons.remove_red_eye_outlined), findsOneWidget);
    expect(find.text('$kWorkCardMinViewsToShow'), findsOneWidget);
  });

  testWidgets('赞与浏览同时为 0 → 两个数字都不在,心还在', (t) async {
    await pump(t, work(likes: 0, views: 0));
    expect(find.text('0'), findsNothing);
    expect(find.byIcon(Icons.remove_red_eye_outlined), findsNothing);
    expect(find.byIcon(Icons.favorite_outline_rounded), findsOneWidget);
  });

  test('下限是具名常量,可一行调整', () {
    // 这条钉的是"它是个可调旋钮"这件事本身 —— 别哪天被硬编码回去。
    expect(kWorkCardMinViewsToShow, greaterThanOrEqualTo(1));
  });
}
