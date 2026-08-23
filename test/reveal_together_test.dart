// 「置顶栏和任务卡片一起加载成功」的契约测试。
//
// [2026-08-24 用户签决] 原话:「而且置顶栏需要变宽 / 需要置顶栏和任务卡片
// 一起加载成功」。
//
// 之前每一层各揭各的:主题卡硬编码、瞬时完成,作品卡要等 glb viewer 第一帧。
// 真机日志(pw_device_log.txt)把这段时间量出来了:
//   23:51:20 挂载 live viewer ×2 (format=glb)
//   23:51:29 内存告警
// 中间是好几秒,页面上就一直是"一张已完成的卡压着两张加载中的卡"。
//
// 现在卡片只上报就绪,揭幕权归页面。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:pocketworld_flutter/community/community_service.dart';
import 'package:pocketworld_flutter/community/feed_models.dart';
import 'package:pocketworld_flutter/ui/community/skeleton_shimmer.dart';
import 'package:pocketworld_flutter/ui/community/work_card.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/design_system.dart';
import 'package:pocketworld_flutter/ui/vault_page.dart';

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  final service = CommunityService(
    client: SupabaseClient('https://offline.invalid', 'test-anon-key'),
  );

  FeedWork work(String id) => FeedWork(
        id: id,
        userId: 'u1',
        title: '未命名($id)',
        description: null,
        format: 'glb',
        modelStoragePath: null,
        fileSizeBytes: null,
        thumbnailStoragePath: null, // 无图 ⇒ contentReady 立刻为真
        likesCount: 0,
        viewsCount: 0,
        publishedAt: DateTime.utc(2026, 8, 21),
        authorDisplayName: 'kyle',
        authorHandle: 'kyle',
        authorAvatarUrl: null,
        likedByMe: false,
      );

  group('揭幕权归页面', () {
    testWidgets('内容早就好了,但 revealed=false ⇒ 幕布仍然盖着', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkCard(
            work: work('a'),
            service: service,
            onTap: () {},
            revealed: false,
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 32));

      expect(
        curtainOpacity(t),
        1.0,
        reason: '自己好了也要等同批的其他卡 —— 否则又变成各揭各的',
      );
    });

    testWidgets('revealed=true ⇒ 揭幕', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkCard(work: work('a'), service: service, onTap: () {}),
        ),
      ));
      await t.pump(const Duration(milliseconds: 32));
      expect(curtainOpacity(t), 0.0);
    });

    testWidgets('内容就绪要上报给页面,且只报一次', (t) async {
      var n = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkCard(
            work: work('a'),
            service: service,
            onTap: () {},
            revealed: false,
            onContentReady: () => n++,
          ),
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 32));
      }
      expect(n, 1, reason: '每帧都报会把页面拖进重建风暴');
    });
  });

  group('置顶栏与作品卡同宽 —— 量出来,不靠看截图', () {
    testWidgets('两者在同一 ListView 同一 padding 下宽度逐像素相同', (t) async {
      await t.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        // 生成物自带的这一份**含 Cupertino delegate** —— 手写三件套会漏它。
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: AetherSpacing.lg,
            ),
            children: [
              const TopicCard(),
              WorkCard(work: work('a'), service: service, onTap: () {}),
            ],
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 32));

      final topic = t.getSize(find.byType(TopicCard)).width;
      final card = t.getSize(find.byType(WorkCard)).width;
      // ignore: avoid_print
      print('  ▶ 实测宽度 TopicCard=$topic  WorkCard=$card');
      expect(
        topic,
        card,
        reason: 'D5 签决就是"与作品卡同宽同层"。两者拿的是同一份约束,'
            '看起来窄是别的原因(圆角/描边/填充对比度),不是宽度',
      );
    });
  });

  group('页面级揭幕闸的实现约束', () {
    final code = File('lib/ui/vault_page.dart').readAsStringSync();

    test('主题卡跟着 _revealed 走,不再无条件画真卡', () {
      expect(
        code,
        contains('? TopicCard(autoPlay: _governor.liveAllowed)'),
        reason: '自动翻页是叠在 live viewer 之上的第二个常驻 ticker,必须接热闸',
      );
      expect(code, contains('_SkeletonTopicCard(animate: _governor.liveAllowed)'));
    });

    test('作品卡接上 revealed / onContentReady', () {
      expect(code, contains('revealed: _revealed,'));
      expect(code, contains('onContentReady: () => _revealGate.markReady(w.id),'));
    });

    // [2026-08-24] 超时兜底与"同一组不重定"两条**不在这里测**。
    //
    // 它们原本是源码文本断言(expect(code, contains('Timer('))),而变异测试
    // 当场证明那种断言挡不住东西 —— 我删掉两处 cancel() 它照样全绿。逻辑已抽进
    // RevealGate,改由 test/reveal_gate_test.dart 用假时钟做**行为**验证。
    // 这里只守住"页面确实把判决交出去了、并且接住了通知"。
    test('揭幕判决交给 RevealGate,页面不自己算', () {
      expect(code, contains('final RevealGate _revealGate = RevealGate();'));
      expect(code, contains('bool get _revealed => _revealGate.revealed;'));
      expect(
        code,
        contains('_revealGate.addListener(_onRevealChanged);'),
        reason: '超时放行是异步的,页面不监听就不会重建',
      );
      expect(
        code,
        contains('_revealGate.dispose();'),
        reason: '不 dispose 就是每次进出社区页漏一个 Timer',
      );
    });
  });
}

/// 幕布(骨架)的当前不透明度。
double curtainOpacity(WidgetTester t) {
  final f = find.ancestor(
    of: find.byType(SkeletonWorkCard),
    matching: find.byType(AnimatedOpacity),
  );
  expect(f, findsOneWidget, reason: '幕布应当是 AnimatedOpacity 包着的骨架');
  return t.widget<AnimatedOpacity>(f).opacity;
}
