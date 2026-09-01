// 卡片作者行的命名契约:`@` 只跟唯一 ID,不跟昵称。
//
// 为什么需要这一条:2026-08-23 之前卡片渲染的是 '@${authorDisplayName}',
// 而 display_name 是**可重复**的(迁移 20260823010000 把命名做成双轨:
// 昵称可重复 + handle 唯一,与抖音号/小红书号/微信号同构)。
// `@` 在 Twitter / Instagram / GitHub / Discord 里都专指唯一标识,跟在一个
// 可以有无数同名的昵称后面,等于告诉用户"这是唯一的" —— 那是在说假话。
//
// ⚠️ 这个渲染此前**没有任何测试覆盖**:改动前后全量 1162 个用例都是绿的,
//    因为没有一条断言过 '@'。全绿在这里不代表被验证过,只代表没人在看。
//    补上这一条,是为了让下一个改这行的人立刻知道自己动了什么。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:pocketworld_flutter/community/community_service.dart';
import 'package:pocketworld_flutter/community/feed_models.dart';
import 'package:pocketworld_flutter/ui/community/work_card.dart';

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  final service = CommunityService(
    client: SupabaseClient('https://offline.invalid', 'test-anon-key'),
  );

  FeedWork work({String? handle}) => FeedWork(
    id: 'w1',
    userId: 'u1',
    title: '未命名(1)',
    description: null,
    format: 'ply',
    modelStoragePath: null,
    fileSizeBytes: null,
    thumbnailStoragePath: null,
    likesCount: 0,
    viewsCount: 0,
    publishedAt: DateTime.utc(2026, 8, 21),
    authorDisplayName: '张三',
    authorAvatarUrl: null,
    likedByMe: false,
    authorHandle: handle,
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

  /// 把渲染出来的作者行文本取出来(Text.rich ⇒ 要读 TextSpan 的完整拼接)。
  String authorLine(WidgetTester t) {
    final texts = t.widgetList<Text>(find.byType(Text));
    for (final w in texts) {
      final s = w.textSpan?.toPlainText() ?? w.data ?? '';
      if (s.contains('张三') || s.contains('@')) return s;
    }
    return '';
  }

  testWidgets('设了 handle ⇒ 显示 @handle,不显示昵称', (t) async {
    await pump(t, work(handle: 'kyle_w'));
    final line = authorLine(t);
    expect(line, contains('@kyle_w'));
    expect(
      line.contains('张三'),
      isFalse,
      reason:
          '同时显示昵称与 ID 会让用户不知道哪个是唯一的;'
          '有 ID 时以 ID 为准',
    );
  });

  testWidgets('🔑 没设 handle ⇒ 显示昵称且**不带 @**', (t) async {
    await pump(t, work(handle: null));
    final line = authorLine(t);
    expect(line, contains('张三'));
    expect(
      line.contains('@'),
      isFalse,
      reason:
          '@ 跟着可重复的昵称,是在宣称一个不存在的唯一性。'
          '没有 ID 就诚实地不显示 @',
    );
  });

  testWidgets('handle 是空串也按"没设"处理,不能渲染出一个孤零零的 @', (t) async {
    await pump(t, work(handle: ''));
    expect(authorLine(t).contains('@'), isFalse);
  });
}
