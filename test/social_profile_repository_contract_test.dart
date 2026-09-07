import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/community/social_profile_repository.dart',
    ).readAsStringSync();
  });

  test('keeps the repository interface stable and testable', () {
    expect(
      source,
      contains('abstract interface class SocialProfileRepository'),
    );
    for (final member in <String>[
      'String? get currentUserId;',
      'Future<SocialProfile> fetchProfile(String userId);',
      'Future<List<SocialProfile>> fetchFollowing(String userId);',
      'Future<void> follow(String userId);',
      'Future<void> unfollow(String userId);',
      'Future<void> block(String userId);',
      'Future<void> unblock(String userId);',
      'Future<List<SocialProfile>> fetchBlockedUsers();',
      'Future<UserReportResult> reportUser(UserReportDraft draft);',
      'Future<List<ReportHistoryItem>> fetchMyReports();',
    ]) {
      expect(source, contains(member));
    }
  });

  test('profile reads use a caller-bound projection RPC', () {
    expect(source, contains(RegExp(r"\.rpc\(\s*'get_social_profile'")));
    expect(source, contains("params: {'p_user_id': userId}"));
    expect(source, isNot(contains(".select('*')")));
  });

  test('following is one narrow RPC rather than N plus one profile reads', () {
    expect(source, contains(RegExp(r"\.rpc\(\s*'get_my_following'")));
    expect(source, contains("params: const {'p_limit': 1000}"));
    expect(
      source,
      contains("final viewerId = _requireViewer('fetch following')"),
    );
  });

  test('follow and block writes use their composite keys', () {
    expect(source, contains("onConflict: 'follower_id,followee_id'"));
    expect(source, contains("onConflict: 'blocker_id,blocked_id'"));
    expect(source, contains(".eq('follower_id', viewerId)"));
    expect(source, contains(".eq('followee_id', userId)"));
    expect(source, contains(".eq('blocker_id', viewerId)"));
    expect(source, contains(".eq('blocked_id', userId)"));
  });

  test('user report insert preserves stable structured context', () {
    expect(source, contains("'submit-report'"));
    expect(source, contains("'target_user_id': draft.targetUserId"));
    expect(source, contains("'kind': draft.kind.code"));
    expect(source, contains("'reason': draft.reason.code"));
    expect(source, contains("'detail': draft.detail"));
    expect(source, contains("'source_work_id': draft.sourceWorkId"));
    expect(source, contains("reportData['report_id']"));
  });

  test('evidence invokes sequentially after the durable report insert', () {
    expect(source, contains("'report-evidence-upload'"));
    expect(source, contains("for (final evidence in draft.evidence)"));
    expect(source, contains("'report_id': reportId"));
    expect(source, contains('uploadedEvidenceCount'));
    expect(source, contains('failedEvidenceCount'));
    expect(
      source.indexOf("'submit-report'"),
      lessThan(source.indexOf("'report-evidence-upload'")),
    );
    expect(
      source.indexOf("'submit-report'"),
      lessThan(source.indexOf('try {')),
      reason: 'the durable report insert must not be swallowed as evidence',
    );
  });

  test('report history uses a server-owned safe projection', () {
    expect(source, contains("'my-reports'"));
    expect(source, contains('ReportHistoryItem.fromMap'));
    expect(source, isNot(contains("_client.from('reports').select")));
  });
}
