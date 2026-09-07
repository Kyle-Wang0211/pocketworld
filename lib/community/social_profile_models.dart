import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';

/// Read-only account data plus relationship state for the current viewer.
class SocialProfile {
  final String id;
  final String displayName;
  final String? handle;
  final String? avatarUrl;
  final String? bio;
  final String? lastRegion;
  final int followersCount;
  final int followingCount;
  final int publicWorksCount;
  final bool isFollowing;
  final bool isBlockedByViewer;

  const SocialProfile({
    required this.id,
    required this.displayName,
    required this.handle,
    required this.avatarUrl,
    required this.bio,
    required this.lastRegion,
    required this.followersCount,
    required this.followingCount,
    required this.publicWorksCount,
    required this.isFollowing,
    required this.isBlockedByViewer,
  });

  factory SocialProfile.fromMap(Map<String, dynamic> map) {
    final id = _requiredString(map['id'], 'id');
    final displayName = _optionalString(map['display_name']) ?? 'unknown';
    return SocialProfile(
      id: id,
      displayName: displayName,
      handle: _optionalString(map['handle']),
      avatarUrl: _optionalString(map['avatar_url']),
      bio: _optionalString(map['bio']),
      lastRegion: _optionalString(map['last_region']),
      followersCount: _nonNegativeInt(map['followers_count']),
      followingCount: _nonNegativeInt(map['following_count']),
      publicWorksCount: _nonNegativeInt(
        map['public_works_count'] ?? map['works_count'],
      ),
      isFollowing: _boolValue(map['is_following']),
      isBlockedByViewer: _boolValue(map['is_blocked_by_viewer']),
    );
  }

  SocialProfile copyWith({
    int? followersCount,
    int? followingCount,
    int? publicWorksCount,
    bool? isFollowing,
    bool? isBlockedByViewer,
  }) {
    return SocialProfile(
      id: id,
      displayName: displayName,
      handle: handle,
      avatarUrl: avatarUrl,
      bio: bio,
      lastRegion: lastRegion,
      followersCount: followersCount ?? this.followersCount,
      followingCount: followingCount ?? this.followingCount,
      publicWorksCount: publicWorksCount ?? this.publicWorksCount,
      isFollowing: isFollowing ?? this.isFollowing,
      isBlockedByViewer: isBlockedByViewer ?? this.isBlockedByViewer,
    );
  }
}

enum ReportKind {
  standard('standard', 50),
  rights('rights', 500);

  final String code;
  final int maxDetailGraphemes;

  const ReportKind(this.code, this.maxDetailGraphemes);

  static ReportKind? fromCode(String? code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// Stable moderation codes. Enum names are UI-facing Dart identifiers; [code]
/// is the only value persisted or sent to the server.
enum UserReportReason {
  impersonation('impersonation', kind: ReportKind.rights),
  harassmentThreat('harassment_threat'),
  spamFraud('spam_fraud'),
  minorSafety('minor_safety', allowsEvidenceUpload: false),
  sexualContent('sexual_content', allowsEvidenceUpload: false),
  violenceIllegal('violence_illegal'),
  misinformation('misinformation'),
  privacyIp('privacy_ip', kind: ReportKind.rights),
  other('other');

  final String code;
  final ReportKind kind;
  final bool allowsEvidenceUpload;

  const UserReportReason(
    this.code, {
    this.kind = ReportKind.standard,
    this.allowsEvidenceUpload = true,
  });

  /// Returns null for an unknown value so callers never silently downgrade a
  /// new or malformed server code to a different report reason.
  static UserReportReason? fromCode(String? code) {
    if (code == null) return null;
    for (final reason in values) {
      if (reason.code == code) return reason;
    }
    return null;
  }
}

enum ReportEvidenceKind {
  context('context'),
  identity('identity'),
  ownership('ownership'),
  authorization('authorization'),
  other('other');

  final String code;
  const ReportEvidenceKind(this.code);
}

/// Sanitized, re-encoded bytes prepared for private report evidence upload.
///
/// Deliberately has no original-filename field. The server owns storage paths,
/// and the byte list is copied into an unmodifiable view at construction.
class ReportEvidenceUpload {
  static const int maxBytes = 5 * 1024 * 1024;

  final Uint8List _bytes;
  final String contentType;
  final String extension;
  final ReportEvidenceKind kind;

  /// Returns a defensive copy so callers can pass a [Uint8List] to image and
  /// upload APIs without gaining mutation access to this value object.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  ReportEvidenceUpload({
    required Uint8List bytes,
    required String contentType,
    required String extension,
    this.kind = ReportEvidenceKind.context,
  }) : _bytes = Uint8List.fromList(bytes),
       contentType = _normalizeContentType(contentType),
       extension = _normalizeExtension(extension) {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'must not be empty');
    }
    if (bytes.lengthInBytes > maxBytes) {
      throw ArgumentError.value(
        bytes.lengthInBytes,
        'bytes',
        'must not exceed $maxBytes bytes',
      );
    }
    final expectedExtension = this.contentType == 'image/png' ? 'png' : 'jpg';
    if (this.extension != expectedExtension) {
      throw ArgumentError.value(
        extension,
        'extension',
        'does not match $contentType',
      );
    }
  }

  Map<String, String> toFunctionBody() => {
    'bytes': base64Encode(_bytes),
    'content_type': contentType,
    'extension': extension,
    'evidence_kind': kind.code,
  };
}

/// Validated input for one account report.
class UserReportDraft {
  final String targetUserId;
  final UserReportReason reason;
  ReportKind get kind => reason.kind;
  final String? detail;
  final String? sourceWorkId;
  final List<ReportEvidenceUpload> evidence;

  factory UserReportDraft({
    required String targetUserId,
    required UserReportReason reason,
    String? detail,
    String? sourceWorkId,
    List<ReportEvidenceUpload> evidence = const [],
  }) {
    final normalizedTargetUserId = _requiredString(
      targetUserId,
      'targetUserId',
    );
    final normalizedDetail = _optionalString(detail);
    final normalizedSourceWorkId = _optionalString(sourceWorkId);

    if ((normalizedDetail?.characters.length ?? 0) >
        reason.kind.maxDetailGraphemes) {
      throw ArgumentError.value(
        detail,
        'detail',
        'must be at most ${reason.kind.maxDetailGraphemes} characters after trimming',
      );
    }
    if (evidence.length > 3) {
      throw ArgumentError.value(
        evidence.length,
        'evidence',
        'must contain at most three uploads',
      );
    }
    if (evidence.isNotEmpty && !reason.allowsEvidenceUpload) {
      throw ArgumentError.value(
        evidence,
        'evidence',
        'is not allowed for ${reason.code}',
      );
    }

    return UserReportDraft._(
      targetUserId: normalizedTargetUserId,
      reason: reason,
      detail: normalizedDetail,
      sourceWorkId: normalizedSourceWorkId,
      evidence: List<ReportEvidenceUpload>.unmodifiable(evidence),
    );
  }

  const UserReportDraft._({
    required this.targetUserId,
    required this.reason,
    required this.detail,
    required this.sourceWorkId,
    required this.evidence,
  });
}

enum ReportStatus {
  pending('pending'),
  inReview('in_review'),
  needsInfo('needs_info'),
  actioned('actioned'),
  dismissed('dismissed');

  final String code;
  const ReportStatus(this.code);

  static ReportStatus? fromCode(String? code) {
    for (final status in values) {
      if (status.code == code) return status;
    }
    return null;
  }
}

class ReportHistoryItem {
  final String id;
  final ReportKind kind;
  final UserReportReason reason;
  final ReportStatus status;
  final String? reporterFeedback;
  final String? sourceWorkTitle;
  final DateTime createdAt;
  final DateTime? dueAt;
  final DateTime? resolvedAt;
  final bool isOverdue;

  const ReportHistoryItem({
    required this.id,
    required this.kind,
    required this.reason,
    required this.status,
    required this.reporterFeedback,
    required this.sourceWorkTitle,
    required this.createdAt,
    required this.dueAt,
    required this.resolvedAt,
    required this.isOverdue,
  });

  factory ReportHistoryItem.fromMap(Map<String, dynamic> map) {
    final kind = ReportKind.fromCode(_optionalString(map['kind']));
    final reason = UserReportReason.fromCode(_optionalString(map['reason']));
    final status = ReportStatus.fromCode(_optionalString(map['status']));
    final createdAt = DateTime.tryParse('${map['created_at'] ?? ''}');
    if (kind == null || reason == null || status == null || createdAt == null) {
      throw const FormatException('Invalid report history row.');
    }
    return ReportHistoryItem(
      id: _requiredString(map['id'], 'id'),
      kind: kind,
      reason: reason,
      status: status,
      reporterFeedback: _optionalString(map['reporter_feedback']),
      sourceWorkTitle: _optionalString(map['source_work_title']),
      createdAt: createdAt,
      dueAt: DateTime.tryParse('${map['due_at'] ?? ''}'),
      resolvedAt: DateTime.tryParse('${map['resolved_at'] ?? ''}'),
      isOverdue: _boolValue(map['is_overdue']),
    );
  }
}

/// Durable report identity plus best-effort evidence upload accounting.
class UserReportResult {
  final String reportId;
  final int uploadedEvidenceCount;
  final int failedEvidenceCount;

  factory UserReportResult({
    required String reportId,
    required int uploadedEvidenceCount,
    required int failedEvidenceCount,
  }) {
    final normalizedReportId = _requiredString(reportId, 'reportId');
    if (uploadedEvidenceCount < 0) {
      throw ArgumentError.value(
        uploadedEvidenceCount,
        'uploadedEvidenceCount',
        'must not be negative',
      );
    }
    if (failedEvidenceCount < 0) {
      throw ArgumentError.value(
        failedEvidenceCount,
        'failedEvidenceCount',
        'must not be negative',
      );
    }
    return UserReportResult._(
      reportId: normalizedReportId,
      uploadedEvidenceCount: uploadedEvidenceCount,
      failedEvidenceCount: failedEvidenceCount,
    );
  }

  const UserReportResult._({
    required this.reportId,
    required this.uploadedEvidenceCount,
    required this.failedEvidenceCount,
  });
}

String _requiredString(Object? value, String name) {
  final normalized = _optionalString(value);
  if (normalized == null) {
    throw ArgumentError.value(value, name, 'must not be blank');
  }
  return normalized;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  final normalized = value.toString().trim();
  return normalized.isEmpty ? null : normalized;
}

int _nonNegativeInt(Object? value) {
  final number = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  return number < 0 ? 0 : number;
}

bool _boolValue(Object? value) =>
    value == true || value == 1 || value == '1' || value == 'true';

String _normalizeContentType(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized != 'image/jpeg' && normalized != 'image/png') {
    throw ArgumentError.value(
      value,
      'contentType',
      'must be image/jpeg or image/png',
    );
  }
  return normalized;
}

String _normalizeExtension(String value) {
  var normalized = value.trim().toLowerCase();
  if (normalized.startsWith('.')) normalized = normalized.substring(1);
  if (normalized == 'jpeg') normalized = 'jpg';
  if (normalized != 'jpg' && normalized != 'png') {
    throw ArgumentError.value(value, 'extension', 'must be jpg, jpeg, or png');
  }
  return normalized;
}
