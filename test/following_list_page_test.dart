import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/community/social_profile_models.dart';
import 'package:pocketworld_flutter/community/social_profile_repository.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/community/following_list_page.dart';

void main() {
  testWidgets('shows following rows and unfollows only the selected account', (
    tester,
  ) async {
    final repository = _FakeRepository([
      _profile('a', '阿青', 'aqing'),
      _profile('b', '白昼', 'daylight'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: FollowingListPage(
          userId: 'viewer',
          repository: repository,
          profileBuilder: (profile) =>
              Scaffold(key: Key('opened-${profile.id}')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的关注'), findsOneWidget);
    expect(find.text('阿青'), findsOneWidget);
    expect(find.text('@aqing'), findsOneWidget);
    expect(find.text('白昼'), findsOneWidget);
    expect(find.text('已关注'), findsNWidgets(2));

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('following-row-a')),
        matching: find.text('已关注'),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.unfollowedIds, ['a']);
    expect(
      find.descendant(
        of: find.byKey(const Key('following-row-a')),
        matching: find.text('关注'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('following-row-b')),
        matching: find.text('已关注'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('白昼'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('opened-b')), findsOneWidget);
  });

  testWidgets('shows the approved empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: FollowingListPage(
          userId: 'viewer',
          repository: _FakeRepository(const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有关注任何人'), findsOneWidget);
  });

  testWidgets('failed load uses stable copy and retry', (tester) async {
    final repository = _FakeRepository(
      const [],
      fetchError: StateError('PostgREST JWT leaked detail'),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: FollowingListPage(userId: 'viewer', repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载关注列表'), findsOneWidget);
    expect(find.textContaining('PostgREST'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });
}

SocialProfile _profile(String id, String name, String handle) => SocialProfile(
  id: id,
  displayName: name,
  handle: handle,
  avatarUrl: null,
  bio: null,
  lastRegion: null,
  followersCount: 0,
  followingCount: 0,
  publicWorksCount: 0,
  isFollowing: true,
  isBlockedByViewer: false,
);

class _FakeRepository implements SocialProfileRepository {
  _FakeRepository(this.profiles, {this.fetchError});

  final List<SocialProfile> profiles;
  final Object? fetchError;
  final List<String> unfollowedIds = [];

  @override
  String? get currentUserId => 'viewer';

  @override
  Future<List<SocialProfile>> fetchFollowing(String userId) async {
    if (fetchError != null) throw fetchError!;
    return profiles;
  }

  @override
  Future<void> unfollow(String userId) async => unfollowedIds.add(userId);

  @override
  Future<void> follow(String userId) async {}

  @override
  Future<SocialProfile> fetchProfile(String userId) async =>
      profiles.firstWhere((profile) => profile.id == userId);

  @override
  Future<void> block(String userId) async {}

  @override
  Future<void> unblock(String userId) async {}

  @override
  Future<List<SocialProfile>> fetchBlockedUsers() async => const [];

  @override
  Future<UserReportResult> reportUser(UserReportDraft draft) =>
      throw UnimplementedError();
}
