import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/community/social_profile_models.dart';
import 'package:pocketworld_flutter/community/social_profile_repository.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/community/blocked_users_page.dart';

void main() {
  testWidgets('shows caller-owned blocks and removes a row after unblock', (
    tester,
  ) async {
    final repository = _FakeRepository([
      _profile('blocked-1', '被拉黑的人', 'blocked'),
      _profile('blocked-2', '另一个人', null),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: BlockedUsersPage(repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已拉黑用户'), findsOneWidget);
    expect(find.text('被拉黑的人'), findsOneWidget);
    expect(find.text('@blocked'), findsOneWidget);

    await tester.tap(find.byKey(const Key('unblock-blocked-1')));
    await tester.pumpAndSettle();
    expect(find.text('解除拉黑？'), findsOneWidget);
    expect(find.textContaining('不会自动恢复'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '解除拉黑'));
    await tester.pumpAndSettle();

    expect(repository.unblocked, ['blocked-1']);
    expect(find.text('被拉黑的人'), findsNothing);
    expect(find.text('另一个人'), findsOneWidget);
  });

  testWidgets('shows empty and retry states', (tester) async {
    final empty = _FakeRepository(const []);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: BlockedUsersPage(key: const Key('empty'), repository: empty),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有已拉黑的用户'), findsOneWidget);

    final failing = _FakeRepository(const [])..failLoad = true;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: BlockedUsersPage(key: const Key('failing'), repository: failing),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载拉黑名单'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}

SocialProfile _profile(String id, String name, String? handle) => SocialProfile(
  id: id,
  displayName: name,
  handle: handle,
  avatarUrl: null,
  bio: null,
  lastRegion: null,
  followersCount: 0,
  followingCount: 0,
  publicWorksCount: 0,
  isFollowing: false,
  isBlockedByViewer: true,
);

class _FakeRepository implements SocialProfileRepository {
  _FakeRepository(this.blocked);

  final List<SocialProfile> blocked;
  final List<String> unblocked = [];
  bool failLoad = false;

  @override
  String? get currentUserId => 'viewer';

  @override
  Future<List<SocialProfile>> fetchBlockedUsers() async {
    if (failLoad) throw StateError('offline');
    return blocked;
  }

  @override
  Future<void> unblock(String userId) async => unblocked.add(userId);

  @override
  Future<void> block(String userId) async {}
  @override
  Future<SocialProfile> fetchProfile(String userId) =>
      throw UnimplementedError();
  @override
  Future<List<SocialProfile>> fetchFollowing(String userId) async => const [];
  @override
  Future<void> follow(String userId) async {}
  @override
  Future<void> unfollow(String userId) async {}
  @override
  Future<UserReportResult> reportUser(UserReportDraft draft) =>
      throw UnimplementedError();
}
