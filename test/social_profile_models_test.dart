import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/community/social_profile_models.dart';

void main() {
  group('SocialProfile.fromMap', () {
    test(
      'normalizes nullable and blank strings and coerces numeric counts',
      () {
        final profile = SocialProfile.fromMap({
          'id': 'user-1',
          'display_name': '  Kai  ',
          'handle': null,
          'avatar_url': '   ',
          'bio': '\n Builder \t',
          'last_region': '',
          'followers_count': 12.9,
          'following_count': 4,
          'works_count': 3.0,
          'is_following': 1,
          'is_blocked_by_viewer': false,
        });

        expect(profile.id, 'user-1');
        expect(profile.displayName, 'Kai');
        expect(profile.handle, isNull);
        expect(profile.avatarUrl, isNull);
        expect(profile.bio, 'Builder');
        expect(profile.lastRegion, isNull);
        expect(profile.followersCount, 12);
        expect(profile.followingCount, 4);
        expect(profile.publicWorksCount, 3);
        expect(profile.isFollowing, isTrue);
        expect(profile.isBlockedByViewer, isFalse);
      },
    );

    test(
      'blank handles normalize to null and missing counts default to zero',
      () {
        final profile = SocialProfile.fromMap({
          'id': 'user-2',
          'display_name': 'User',
          'handle': ' \t ',
        });

        expect(profile.handle, isNull);
        expect(profile.followersCount, 0);
        expect(profile.followingCount, 0);
        expect(profile.publicWorksCount, 0);
        expect(profile.isFollowing, isFalse);
        expect(profile.isBlockedByViewer, isFalse);
      },
    );
  });

  test(
    'report reasons expose stable codes and fail closed for unknown codes',
    () {
      const expected = <UserReportReason, String>{
        UserReportReason.impersonation: 'impersonation',
        UserReportReason.harassmentThreat: 'harassment_threat',
        UserReportReason.spamFraud: 'spam_fraud',
        UserReportReason.minorSafety: 'minor_safety',
        UserReportReason.sexualContent: 'sexual_content',
        UserReportReason.violenceIllegal: 'violence_illegal',
        UserReportReason.misinformation: 'misinformation',
        UserReportReason.privacyIp: 'privacy_ip',
        UserReportReason.other: 'other',
      };

      expect(UserReportReason.values, hasLength(9));
      for (final entry in expected.entries) {
        expect(entry.key.code, entry.value);
        expect(UserReportReason.fromCode(entry.value), entry.key);
      }
      expect(UserReportReason.fromCode('spam'), isNull);
      expect(UserReportReason.fromCode(''), isNull);
    },
  );

  test('report reasons are partitioned into standard and rights tiers', () {
    expect(ReportKind.standard.code, 'standard');
    expect(ReportKind.standard.maxDetailGraphemes, 50);
    expect(ReportKind.rights.code, 'rights');
    expect(ReportKind.rights.maxDetailGraphemes, 500);
    expect(UserReportReason.impersonation.kind, ReportKind.rights);
    expect(UserReportReason.privacyIp.kind, ReportKind.rights);
    expect(
      UserReportReason.values
          .where(
            (reason) =>
                reason != UserReportReason.impersonation &&
                reason != UserReportReason.privacyIp,
          )
          .every((reason) => reason.kind == ReportKind.standard),
      isTrue,
    );
  });

  test('minor and sexual reports disable user-supplied evidence', () {
    expect(UserReportReason.minorSafety.allowsEvidenceUpload, isFalse);
    expect(UserReportReason.sexualContent.allowsEvidenceUpload, isFalse);
    expect(
      UserReportReason.values
          .where(
            (reason) =>
                reason != UserReportReason.minorSafety &&
                reason != UserReportReason.sexualContent,
          )
          .every((reason) => reason.allowsEvidenceUpload),
      isTrue,
    );
  });

  test('evidence retains only sanitized transport metadata', () {
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final evidence = ReportEvidenceUpload(
      bytes: bytes,
      contentType: ' image/jpeg ',
      extension: ' .JPG ',
      kind: ReportEvidenceKind.ownership,
    );

    expect(evidence.bytes, bytes);
    expect(evidence.contentType, 'image/jpeg');
    expect(evidence.extension, 'jpg');
    expect(evidence.toFunctionBody(), {
      'bytes': 'AQID',
      'content_type': 'image/jpeg',
      'extension': 'jpg',
      'evidence_kind': 'ownership',
    });
    bytes[0] = 9;
    expect(evidence.bytes, <int>[1, 2, 3]);
    evidence.bytes[0] = 9;
    expect(evidence.bytes, <int>[1, 2, 3]);
  });

  group('UserReportDraft validation', () {
    test('trims detail and optional source work id', () {
      final draft = UserReportDraft(
        targetUserId: ' target-user ',
        reason: UserReportReason.harassmentThreat,
        detail: '  context  ',
        sourceWorkId: ' work-1 ',
      );

      expect(draft.targetUserId, 'target-user');
      expect(draft.detail, 'context');
      expect(draft.sourceWorkId, 'work-1');
      expect(draft.evidence, isEmpty);
    });

    test('standard reports accept exactly 50 trimmed graphemes', () {
      final draft = UserReportDraft(
        targetUserId: 'target-user',
        reason: UserReportReason.other,
        detail: ' ${'x' * 50} ',
      );
      expect(draft.kind, ReportKind.standard);
      expect(draft.detail, hasLength(50));
    });

    test('standard reports reject detail longer than 50 graphemes', () {
      expect(
        () => UserReportDraft(
          targetUserId: 'target-user',
          reason: UserReportReason.other,
          detail: ' ${'x' * 51} ',
        ),
        throwsArgumentError,
      );
    });

    test('rights complaints accept 500 and reject 501 graphemes', () {
      final draft = UserReportDraft(
        targetUserId: 'target-user',
        reason: UserReportReason.privacyIp,
        detail: ' ${'x' * 500} ',
      );
      expect(draft.kind, ReportKind.rights);
      expect(draft.detail, hasLength(500));
      expect(
        () => UserReportDraft(
          targetUserId: 'target-user',
          reason: UserReportReason.impersonation,
          detail: '👨‍👩‍👧‍👦' * 501,
        ),
        throwsArgumentError,
      );
    });

    test('keeps detail optional for other', () {
      final draft = UserReportDraft(
        targetUserId: 'target-user',
        reason: UserReportReason.other,
        detail: '   ',
      );
      expect(draft.detail, isNull);
    });

    test('counts emoji grapheme clusters as one character', () {
      final draft = UserReportDraft(
        targetUserId: 'target-user',
        reason: UserReportReason.spamFraud,
        detail: '👨‍👩‍👧‍👦' * 50,
      );
      expect(draft.detail, isNotNull);
      expect(
        () => UserReportDraft(
          targetUserId: 'target-user',
          reason: UserReportReason.spamFraud,
          detail: '👨‍👩‍👧‍👦' * 51,
        ),
        throwsArgumentError,
      );
    });

    test('rejects more than three evidence uploads', () {
      final evidence = List<ReportEvidenceUpload>.generate(
        4,
        (_) => ReportEvidenceUpload(
          bytes: Uint8List.fromList(<int>[1]),
          contentType: 'image/png',
          extension: 'png',
        ),
      );
      expect(
        () => UserReportDraft(
          targetUserId: 'target-user',
          reason: UserReportReason.spamFraud,
          evidence: evidence,
        ),
        throwsArgumentError,
      );
    });

    test('accepts exactly three uploads and freezes the list', () {
      final mutableEvidence = List<ReportEvidenceUpload>.generate(
        3,
        (_) => ReportEvidenceUpload(
          bytes: Uint8List.fromList(<int>[1]),
          contentType: 'image/png',
          extension: 'png',
        ),
      );
      final draft = UserReportDraft(
        targetUserId: 'target-user',
        reason: UserReportReason.privacyIp,
        evidence: mutableEvidence,
      );

      mutableEvidence.clear();
      expect(draft.evidence, hasLength(3));
      expect(
        () => draft.evidence.add(
          ReportEvidenceUpload(
            bytes: Uint8List.fromList(<int>[1]),
            contentType: 'image/png',
            extension: 'png',
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('rejects evidence for sensitive reasons', () {
      final evidence = ReportEvidenceUpload(
        bytes: Uint8List.fromList(<int>[1]),
        contentType: 'image/png',
        extension: 'png',
      );
      expect(
        () => UserReportDraft(
          targetUserId: 'target-user',
          reason: UserReportReason.minorSafety,
          detail: 'linked content',
          evidence: [evidence],
        ),
        throwsArgumentError,
      );
    });
  });

  group('ReportEvidenceUpload byte boundary', () {
    test('accepts exactly five MiB and keeps compact defensive bytes', () {
      final source = Uint8List(ReportEvidenceUpload.maxBytes);
      final evidence = ReportEvidenceUpload(
        bytes: source,
        contentType: 'image/png',
        extension: 'png',
      );
      source[0] = 9;
      expect(evidence.bytes.lengthInBytes, ReportEvidenceUpload.maxBytes);
      expect(evidence.bytes.first, 0);
    });

    test('rejects evidence over five MiB', () {
      expect(
        () => ReportEvidenceUpload(
          bytes: Uint8List(ReportEvidenceUpload.maxBytes + 1),
          contentType: 'image/jpeg',
          extension: 'jpg',
        ),
        throwsArgumentError,
      );
    });
  });

  test('UserReportResult validates evidence accounting', () {
    final result = UserReportResult(
      reportId: '42',
      uploadedEvidenceCount: 2,
      failedEvidenceCount: 1,
    );
    expect(result.reportId, '42');
    expect(result.uploadedEvidenceCount, 2);
    expect(result.failedEvidenceCount, 1);
    expect(
      () => UserReportResult(
        reportId: '42',
        uploadedEvidenceCount: -1,
        failedEvidenceCount: 0,
      ),
      throwsArgumentError,
    );
  });

  test('ReportHistoryItem parses only reporter-safe result fields', () {
    final item = ReportHistoryItem.fromMap({
      'id': 42,
      'kind': 'rights',
      'reason': 'privacy_ip',
      'status': 'needs_info',
      'reporter_feedback': '请补充权属证明',
      'source_work_title': '雕塑扫描',
      'created_at': '2026-09-06T08:00:00Z',
      'due_at': '2026-09-09T08:00:00Z',
      'is_overdue': false,
    });

    expect(item.id, '42');
    expect(item.kind, ReportKind.rights);
    expect(item.reason, UserReportReason.privacyIp);
    expect(item.status, ReportStatus.needsInfo);
    expect(item.reporterFeedback, '请补充权属证明');
    expect(item.sourceWorkTitle, '雕塑扫描');
    expect(item.isOverdue, isFalse);
  });
}
