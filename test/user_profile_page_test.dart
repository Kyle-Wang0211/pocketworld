import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/community/feed_models.dart';
import 'package:pocketworld_flutter/community/social_profile_models.dart';
import 'package:pocketworld_flutter/community/social_profile_repository.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/community/user_profile_page.dart';

void main() {
  Widget app(UserProfilePage page) => MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: page,
  );

  testWidgets('approved profile chrome has back-only title and small menu', (
    tester,
  ) async {
    final repository = _FakeRepository(profile: _linProfile());
    await tester.pumpWidget(
      app(
        UserProfilePage(
          userId: 'lin-id',
          repository: repository,
          worksLoader: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('林墨'), findsOneWidget);
    expect(find.text('@lin.mo · 上海'), findsOneWidget);
    expect(find.text('把日常物件做成可触摸的空间记忆。'), findsOneWidget);
    expect(find.text('公开作品'), findsNothing);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('286'), findsOneWidget);
    expect(find.text('48'), findsOneWidget);
    expect(find.text('作品'), findsOneWidget);
    expect(find.text('粉丝'), findsOneWidget);
    expect(find.text('关注'), findsWidgets);

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.title, isNull);
    expect(find.byKey(const Key('profile-overflow')), findsOneWidget);
    final more = tester.widget<Icon>(find.byIcon(Icons.more_horiz));
    expect(more.size, lessThanOrEqualTo(20));
  });

  testWidgets('follow waits for success then updates relation and count', (
    tester,
  ) async {
    final completer = Completer<void>();
    final repository = _FakeRepository(
      profile: _linProfile(),
      followCompleter: completer,
    );
    await tester.pumpWidget(
      app(
        UserProfilePage(
          userId: 'lin-id',
          repository: repository,
          worksLoader: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '关注'));
    await tester.pump();
    expect(repository.followedIds, ['lin-id']);
    expect(find.text('已关注'), findsNothing);

    completer.complete();
    await tester.pumpAndSettle();
    expect(find.text('已关注'), findsOneWidget);
    expect(find.text('287'), findsOneWidget);
  });

  testWidgets('overflow opens an anchored top-right safety menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(
        UserProfilePage(
          userId: 'lin-id',
          repository: _FakeRepository(profile: _linProfile()),
          worksLoader: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-overflow')));
    await tester.pumpAndSettle();

    expect(find.text('举报该用户'), findsOneWidget);
    expect(find.text('拉黑该用户'), findsOneWidget);
    final menuTop = tester.getTopLeft(find.text('举报该用户')).dy;
    final menuLeft = tester.getTopLeft(find.text('举报该用户')).dx;
    expect(menuTop, lessThan(300));
    expect(menuLeft, greaterThan(150));
  });

  testWidgets('own profile has no follow or safety menu', (tester) async {
    final profile = _linProfile();
    final repository = _FakeRepository(
      profile: profile,
      currentUserId: profile.id,
    );
    await tester.pumpWidget(
      app(
        UserProfilePage(
          userId: profile.id,
          repository: repository,
          worksLoader: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-follow-button')), findsNothing);
    expect(find.byKey(const Key('profile-overflow')), findsNothing);
  });

  testWidgets(
    'report menu opens the real flow and submits through repository',
    (tester) async {
      final repository = _FakeRepository(profile: _linProfile());
      await tester.pumpWidget(
        app(
          UserProfilePage(
            userId: 'lin-id',
            seedWork: _work('lin-id'),
            repository: repository,
            worksLoader: (_) async => const [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('举报该用户'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('冒充他人或账号资料虚假'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交举报'));
      await tester.pumpAndSettle();

      expect(repository.reportDrafts, hasLength(1));
      expect(repository.reportDrafts.single.targetUserId, 'lin-id');
      expect(repository.reportDrafts.single.sourceWorkId, 'work-1');
      expect(find.text('举报已提交'), findsOneWidget);
    },
  );

  testWidgets('loads only selected author works and renders direct grid', (
    tester,
  ) async {
    String? requestedUserId;
    await tester.pumpWidget(
      app(
        UserProfilePage(
          userId: 'lin-id',
          repository: _FakeRepository(profile: _linProfile()),
          worksLoader: (userId) async {
            requestedUserId = userId;
            return [_work(userId)];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(requestedUserId, 'lin-id');
    expect(find.byKey(const Key('profile-work-work-1')), findsOneWidget);
    expect(find.text('公开作品'), findsNothing);
  });
}

SocialProfile _linProfile() => const SocialProfile(
  id: 'lin-id',
  displayName: '林墨',
  handle: 'lin.mo',
  avatarUrl: null,
  bio: '把日常物件做成可触摸的空间记忆。',
  lastRegion: '上海',
  followersCount: 286,
  followingCount: 48,
  publicWorksCount: 12,
  isFollowing: false,
  isBlockedByViewer: false,
);

FeedWork _work(String userId) => FeedWork(
  id: 'work-1',
  userId: userId,
  title: '杯子',
  description: null,
  format: 'ply',
  modelStoragePath: null,
  thumbnailStoragePath: null,
  likesCount: 0,
  viewsCount: 0,
  publishedAt: DateTime.utc(2026, 8, 29),
  authorDisplayName: '林墨',
  authorAvatarUrl: null,
  likedByMe: false,
);

class _FakeRepository implements SocialProfileRepository {
  _FakeRepository({
    required this.profile,
    this.currentUserId = 'viewer-id',
    this.followCompleter,
  });

  final SocialProfile profile;
  @override
  final String? currentUserId;
  final Completer<void>? followCompleter;
  final List<String> followedIds = [];
  final List<UserReportDraft> reportDrafts = [];

  @override
  Future<SocialProfile> fetchProfile(String userId) async => profile;

  @override
  Future<void> follow(String userId) async {
    followedIds.add(userId);
    await followCompleter?.future;
  }

  @override
  Future<void> unfollow(String userId) async {}

  @override
  Future<void> block(String userId) async {}

  @override
  Future<void> unblock(String userId) async {}

  @override
  Future<List<SocialProfile>> fetchFollowing(String userId) async => const [];

  @override
  Future<List<SocialProfile>> fetchBlockedUsers() async => const [];

  @override
  Future<UserReportResult> reportUser(UserReportDraft draft) async {
    reportDrafts.add(draft);
    return UserReportResult(
      reportId: '42',
      uploadedEvidenceCount: draft.evidence.length,
      failedEvidenceCount: 0,
    );
  }
}
