import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/community/social_profile_models.dart';
import 'package:pocketworld_flutter/community/social_profile_repository.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/community/report_history_page.dart';

void main() {
  testWidgets('shows reporter-safe statuses and public feedback', (
    tester,
  ) async {
    final repository = _HistoryRepository([
      ReportHistoryItem(
        id: '42',
        kind: ReportKind.rights,
        reason: UserReportReason.privacyIp,
        status: ReportStatus.needsInfo,
        reporterFeedback: '请补充权属证明',
        sourceWorkTitle: '雕塑扫描',
        createdAt: DateTime.utc(2026, 9, 6),
        dueAt: DateTime.utc(2026, 9, 9),
        resolvedAt: null,
        isOverdue: false,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: ReportHistoryPage(repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的举报'), findsOneWidget);
    expect(find.text('需要补充材料'), findsOneWidget);
    expect(find.text('请补充权属证明'), findsOneWidget);
    expect(find.textContaining('雕塑扫描'), findsOneWidget);
    expect(find.textContaining('#42'), findsOneWidget);
  });
}

class _HistoryRepository implements SocialProfileRepository {
  _HistoryRepository(this.reports);
  final List<ReportHistoryItem> reports;

  @override
  String? get currentUserId => 'viewer';
  @override
  Future<List<ReportHistoryItem>> fetchMyReports() async => reports;
  @override
  Future<List<SocialProfile>> fetchBlockedUsers() async => const [];
  @override
  Future<List<SocialProfile>> fetchFollowing(String userId) async => const [];
  @override
  Future<SocialProfile> fetchProfile(String userId) =>
      throw UnimplementedError();
  @override
  Future<UserReportResult> reportUser(UserReportDraft draft) =>
      throw UnimplementedError();
  @override
  Future<void> block(String userId) async {}
  @override
  Future<void> follow(String userId) async {}
  @override
  Future<void> unblock(String userId) async {}
  @override
  Future<void> unfollow(String userId) async {}
}
