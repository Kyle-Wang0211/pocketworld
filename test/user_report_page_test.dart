import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/community/social_profile_models.dart';
import 'package:pocketworld_flutter/community/social_profile_repository.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/community/user_report_page.dart';

void main() {
  testWidgets('shows all nine approved reasons', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: UserReportPage(
          targetUserId: 'target',
          repository: _FakeRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in const [
      '冒充他人或账号资料虚假',
      '骚扰、网络暴力或人身威胁',
      '诈骗、广告骚扰或异常账号行为',
      '涉及未成年人安全',
      '色情低俗',
      '暴力、自伤、仇恨、极端或其他违法有害信息',
      '虚假不实或误导性信息',
      '隐私、人肉搜索、肖像或知识产权',
      '其他 / 不确定',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('normal reason allows detail, source work, and three images', (
    tester,
  ) async {
    final evidence = ReportEvidenceUpload(
      bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
      contentType: 'image/jpeg',
      extension: 'jpg',
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: UserReportPage(
          targetUserId: 'target',
          sourceWorkId: 'work-1',
          repository: _FakeRepository(),
          evidencePicker: (remaining) async => [evidence],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('骚扰、网络暴力或人身威胁'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('关联作品：work-1'), findsOneWidget);
    expect(find.text('添加截图或照片（最多 3 张）'), findsOneWidget);
    await tester.tap(find.text('添加截图或照片（最多 3 张）'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('report-evidence-0')), findsOneWidget);
  });

  testWidgets('sensitive reasons never expose an upload control', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: UserReportPage(
          targetUserId: 'target',
          repository: _FakeRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('涉及未成年人安全'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不要重新上传或传播'), findsOneWidget);
    expect(find.textContaining('添加截图'), findsNothing);
  });

  testWidgets('submits stable reason, trimmed detail, and source context', (
    tester,
  ) async {
    final repository = _FakeRepository();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: UserReportPage(
          targetUserId: 'target',
          sourceWorkId: 'work-1',
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('其他 / 不确定'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -100));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '其他 / 不确定'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  补充说明  ');
    await tester.tap(find.text('提交举报'));
    await tester.pumpAndSettle();

    final draft = repository.drafts.single;
    expect(draft.targetUserId, 'target');
    expect(draft.reason, UserReportReason.other);
    expect(draft.detail, '补充说明');
    expect(draft.sourceWorkId, 'work-1');
  });
}

class _FakeRepository implements SocialProfileRepository {
  final List<UserReportDraft> drafts = [];

  @override
  String? get currentUserId => 'viewer';

  @override
  Future<UserReportResult> reportUser(UserReportDraft draft) async {
    drafts.add(draft);
    return UserReportResult(
      reportId: '42',
      uploadedEvidenceCount: draft.evidence.length,
      failedEvidenceCount: 0,
    );
  }

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
  Future<void> block(String userId) async {}
  @override
  Future<void> unblock(String userId) async {}
  @override
  Future<List<SocialProfile>> fetchBlockedUsers() async => const [];
}
