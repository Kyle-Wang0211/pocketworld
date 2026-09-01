import 'package:supabase_flutter/supabase_flutter.dart';

import 'social_profile_models.dart';

abstract interface class SocialProfileRepository {
  String? get currentUserId;
  Future<SocialProfile> fetchProfile(String userId);
  Future<List<SocialProfile>> fetchFollowing(String userId);
  Future<void> follow(String userId);
  Future<void> unfollow(String userId);
  Future<void> block(String userId);
  Future<void> unblock(String userId);
  Future<List<SocialProfile>> fetchBlockedUsers();
  Future<UserReportResult> reportUser(UserReportDraft draft);
}

class SupabaseSocialProfileRepository implements SocialProfileRepository {
  final SupabaseClient _client;
  final String? Function() _viewerIdProvider;

  SupabaseSocialProfileRepository({
    required SupabaseClient client,
    String? Function()? viewerIdProvider,
  }) : _client = client,
       _viewerIdProvider =
           viewerIdProvider ?? (() => client.auth.currentUser?.id);

  @override
  String? get currentUserId => _viewerIdProvider();

  @override
  Future<SocialProfile> fetchProfile(String userId) async {
    final rows = await _client.rpc(
      'get_social_profile',
      params: {'p_user_id': userId},
    );
    if (rows is! List || rows.length != 1) {
      throw StateError('Profile is unavailable.');
    }
    return SocialProfile.fromMap(Map<String, dynamic>.from(rows.single as Map));
  }

  @override
  Future<List<SocialProfile>> fetchFollowing(String userId) async {
    final viewerId = _requireViewer('fetch following');
    if (viewerId != userId) {
      throw ArgumentError.value(
        userId,
        'userId',
        'get_my_following is restricted to the signed-in user',
      );
    }
    final rows = await _client.rpc(
      'get_my_following',
      params: const {'p_limit': 1000},
    );
    return _profilesFromRows(rows, isFollowing: true);
  }

  @override
  Future<void> follow(String userId) async {
    final viewerId = _requireViewer('follow');
    if (viewerId == userId) {
      throw ArgumentError.value(userId, 'userId', 'cannot follow yourself');
    }
    await _client
        .from('follows')
        .upsert(
          {'follower_id': viewerId, 'followee_id': userId},
          onConflict: 'follower_id,followee_id',
          ignoreDuplicates: true,
        );
  }

  @override
  Future<void> unfollow(String userId) async {
    final viewerId = _requireViewer('unfollow');
    await _client
        .from('follows')
        .delete()
        .eq('follower_id', viewerId)
        .eq('followee_id', userId);
  }

  @override
  Future<void> block(String userId) async {
    final viewerId = _requireViewer('block');
    if (viewerId == userId) {
      throw ArgumentError.value(userId, 'userId', 'cannot block yourself');
    }
    await _client
        .from('blocks')
        .upsert(
          {'blocker_id': viewerId, 'blocked_id': userId},
          onConflict: 'blocker_id,blocked_id',
          ignoreDuplicates: true,
        );
  }

  @override
  Future<void> unblock(String userId) async {
    final viewerId = _requireViewer('unblock');
    await _client
        .from('blocks')
        .delete()
        .eq('blocker_id', viewerId)
        .eq('blocked_id', userId);
  }

  @override
  Future<List<SocialProfile>> fetchBlockedUsers() async {
    _requireViewer('fetch blocked users');
    final rows = await _client.rpc(
      'get_my_blocked_users',
      params: const {'p_limit': 1000},
    );
    return _profilesFromRows(rows, isBlockedByViewer: true);
  }

  @override
  Future<UserReportResult> reportUser(UserReportDraft draft) async {
    final viewerId = _requireViewer('report');
    if (viewerId == draft.targetUserId) {
      throw ArgumentError.value(
        draft.targetUserId,
        'targetUserId',
        'cannot report yourself',
      );
    }
    final response = await _client.functions.invoke(
      'submit-user-report',
      body: {
        'target_user_id': draft.targetUserId,
        'reason': draft.reason.code,
        if (draft.detail != null) 'detail': draft.detail,
        if (draft.sourceWorkId != null) 'source_work_id': draft.sourceWorkId,
      },
    );
    if (response.status < 200 || response.status >= 300) {
      throw StateError('User report submission failed.');
    }
    final reportData = response.data;
    final reportId = _reportIdFrom(
      reportData is Map ? reportData['report_id'] : null,
    );

    var uploadedEvidenceCount = 0;
    var failedEvidenceCount = 0;
    for (final evidence in draft.evidence) {
      try {
        final response = await _client.functions.invoke(
          'report-evidence-upload',
          body: {'report_id': reportId, ...evidence.toFunctionBody()},
        );
        if (response.status >= 200 && response.status < 300) {
          uploadedEvidenceCount++;
        } else {
          failedEvidenceCount++;
        }
      } catch (_) {
        failedEvidenceCount++;
      }
    }

    return UserReportResult(
      reportId: reportId,
      uploadedEvidenceCount: uploadedEvidenceCount,
      failedEvidenceCount: failedEvidenceCount,
    );
  }

  String _requireViewer(String action) {
    final viewerId = currentUserId;
    if (viewerId == null) {
      throw StateError('Cannot $action without a signed-in user.');
    }
    return viewerId;
  }

  List<SocialProfile> _profilesFromRows(
    dynamic rows, {
    bool? isFollowing,
    bool? isBlockedByViewer,
  }) {
    if (rows is! List) {
      throw StateError('Expected a profile list from Supabase.');
    }
    return rows
        .map((row) {
          final profile = SocialProfile.fromMap(
            Map<String, dynamic>.from(row as Map),
          );
          return profile.copyWith(
            isFollowing: isFollowing,
            isBlockedByViewer: isBlockedByViewer,
          );
        })
        .toList(growable: false);
  }

  String _reportIdFrom(Object? value) {
    if (value is int && value > 0) return value.toString();
    if (value is num && value.isFinite && value > 0 && value == value.round()) {
      return value.toInt().toString();
    }
    if (value is String) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && normalized.toLowerCase() != 'null') {
        return normalized;
      }
    }
    throw StateError('Supabase report insert returned an invalid id.');
  }
}
