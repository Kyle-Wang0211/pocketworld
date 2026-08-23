// 社区首页改造(§3 砍标签与搜索 / §5 主题卡)的契约测试。
// 方案:docs/superpowers/specs/2026-08-22-community-home-restructure.md
//
// 用两种尺子,因为它们测的是两类不同的东西:
//   · 源码契约 —— "标签代码被删了 / 搜索代码被保留了"是**结构事实**,
//     渲染测试测不出"某段代码还在不在"
//   · widget 测试 —— 主题卡是纯 StatelessWidget,直接 pump 最实在

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/vault_page.dart';
import 'package:pocketworld_flutter/ui/community/skeleton_shimmer.dart';

void main() {
  final src = File('lib/ui/vault_page.dart').readAsStringSync();

  /// ⚠️ 剥掉注释行之后再做"不该出现"类断言。
  ///
  /// 本仓踩过不止一次:源码里**故意留着**注释掉的恢复代码
  /// (`//   child: _SearchBar(`),纯 contains 会命中它 ⇒ 判据自证失败。
  /// 见 memory/feedback_verification_predicate_must_not_match_own_comment。
  final code = src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  group('§3 砍掉标签与搜索', () {
    test('D1:三个标签的代码整体删除', () {
      // 热门/附近/发现。实测「热门」与「发现」是同一个流的两个排序键,
      // 合并零信息损失;「附近」的文案是"敬请期待"——没兑现的承诺。
      expect(code, isNot(contains('_CommunityTab')));
      expect(code, isNot(contains('_CommunityTabBar')));
      expect(code, isNot(contains('_CommunityTabPill')));
      expect(code, isNot(contains('_NearbyComingSoonState')));
    });

    test('排序定死 recent —— 不留 hot 分支', () {
      // 原默认 tab 是 discover,本就映射 recent ⇒ 这是行为不变的改法。
      expect(src, contains('sortBy: FeedSort.recent'));
      expect(
        code,
        isNot(contains('FeedSort.hot')),
        reason: '砍掉标签后不该还有走 hot 的路径',
      );
    });

    test('D2:搜索代码**保留**,只是不渲染', () {
      // 用户明确要求"先留着别删"。这条是**反向**断言:
      // 别哪天有人"顺手清理未使用代码"把它删了。
      for (final kept in [
        'class _SearchBar',
        '_searchController',
        '_onQuerySubmitted',
        '_onClearQuery',
        'communitySearchHint',
      ]) {
        expect(src, contains(kept), reason: 'D2 要求保留:$kept');
      }
      // 但不能在 build 里被真的挂上去
      expect(
        code,
        isNot(contains('child: _SearchBar(')),
        reason: '保留 ≠ 渲染。这一行一旦从注释里复活,搜索框就回到页面上了',
      );
    });
  });

  group('§5 主题卡', () {
    test('D5:做成流内第一张卡,靠下标偏移,不换 CustomScrollView', () {
      // 注:偏移条件后来从 kShowCommunityTopicCard 换成 _showTopicCard ——
      // 因为主题卡还要与 D7 的作者过滤联动(过滤时隐藏)。
      expect(code, contains('itemCount: works.length + (_showTopicCard ? 1 : 0)'));
      expect(code, contains('if (_showTopicCard && rawIndex == 0)'));
      expect(code, contains('final i = rawIndex - (_showTopicCard ? 1 : 0);'));
      expect(
        src,
        contains('ListView.separated'),
        reason: 'D5 要求同宽同层可滑走 —— 留在同一个 ListView 里,别升级成 Sliver',
      );
    });

    test('D9(a):硬编码,不发请求 ⇒ D10 的时机问题自动消失', () {
      expect(src, contains('const bool kShowCommunityTopicCard'));
      // 主题卡本体不该碰 service / Future / 网络
      final topicCard = src.substring(src.indexOf('class TopicCard'));
      expect(topicCard, isNot(contains('_service')));
      expect(topicCard, isNot(contains('Future')));
      expect(topicCard, isNot(contains('FutureBuilder')));
    });
  });

  group('§5 主题卡渲染', () {
    Future<void> pump(WidgetTester t, Locale locale) async {
      await t.pumpWidget(MaterialApp(
        locale: locale,
        // 生成物自带的这一份**含 Cupertino delegate**;手写三件套会漏它,
        // zh 下报 "A CupertinoLocalizations delegate ... was not found"。
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const Scaffold(body: TopicCard()),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('中文下渲染标题与正文', (t) async {
      await pump(t, const Locale('zh'));
      expect(find.text('本周精选'), findsOneWidget);
      expect(find.textContaining('编辑挑出的空间'), findsOneWidget);
    });

    testWidgets('英文下走 en 文案,不漏中文', (t) async {
      await pump(t, const Locale('en'));
      expect(find.textContaining("Editors"), findsOneWidget);
      expect(find.text('本周精选'), findsNothing);
    });
  });

  group('§4 骨架屏', () {
    final card = File('lib/ui/community/work_card.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    test('D4:不引入任何骨架屏包', () {
      // shimmer 判死的理由与 Flutter 版本无关:issue #64「40-60% CPU /
      // iOS 过热」开了三年未关,正对本项目的热软肋。
      for (final pkg in ['shimmer', 'skeletonizer', 'skeleton_loader', 'skeletons']) {
        expect(pubspec, isNot(contains('\n  $pkg:')), reason: '不该引入 $pkg');
      }
    });

    test('抄了 splash_overlay 的坑:不可见时必须 stop,不是转着看不见', () {
      final sk = File('lib/ui/community/skeleton_shimmer.dart').readAsStringSync();
      expect(sk, contains('_c.stop()'));
      // animate=false 时不能还挂着 AnimatedBuilder —— 那就是持续重绘。
      expect(sk, contains('if (!widget.animate)'));
      expect(sk, contains('didUpdateWidget'), reason: '热闸翻转要立刻生效');
    });

    test('热闸接到 CardLiveGovernor —— 一屏多个骨架卡是真实发热面', () {
      expect(code, contains('_LoadingState(animate: _governor.liveAllowed)'));
      expect(card, contains('_CardPlaceholder(animate: widget.rotationAllowed)'));
    });

    testWidgets('animate=false → 静态,不挂 AnimatedBuilder', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: SkeletonBox(animate: false, width: 40, height: 8)),
      ));
      // ⚠️ 不能用裸的 find.byType(AnimatedBuilder) —— MaterialApp 自己内部就有
      // 一个(listenable: ValueNotifier<String?>),会误报。只在 SkeletonBox
      // 的子树里找。
      expect(
        find.descendant(
          of: find.byType(SkeletonBox),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
      );
    });

    testWidgets('animate=true → 挂 AnimatedBuilder', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: SkeletonBox(width: 40, height: 8)),
      ));
      expect(
        find.descendant(
          of: find.byType(SkeletonBox),
          matching: find.byType(AnimatedBuilder),
        ),
        findsOneWidget,
      );
    });
  });

  group('§6 @handle 流内过滤', () {
    final card = File('lib/ui/community/work_card.dart').readAsStringSync();
    final svc = File('lib/community/community_service.dart').readAsStringSync();

    test('后端:fetchPublicFeed 支持按作者过滤', () {
      expect(svc, contains('String? authorUserId'));
      expect(svc, contains(".eq('user_id', authorUserId)"));
    });

    test('D7:点 @handle 走过滤,**不做个人主页**', () {
      expect(card, contains('onAuthorTap'));
      expect(code, contains('void _onAuthorTap(FeedWork work)'));
      expect(code, contains('_authorFilterId = work.userId'));
      // 明确不做的东西,一样都不许冒出来
      for (final forbidden in ['ProfilePage', 'FollowButton', 'followersCount',
                               'followingCount', 'avatarUrl:', 'bio']) {
        expect(code, isNot(contains(forbidden)), reason: 'D7 明确不做:$forbidden');
      }
    });

    test('TapGestureRecognizer 必须 dispose(每张卡漏一个就是持续泄漏)', () {
      expect(card, contains('_authorTapRecognizer.dispose()'));
    });

    test('过滤生效时主题卡隐藏 —— 策展卡在"只看某人"里没有意义', () {
      expect(code, contains('kShowCommunityTopicCard && _authorFilterId == null'));
    });
  });
}
