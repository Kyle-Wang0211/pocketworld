// Models for the community feed.
//
// FeedWork is a denormalized "card-ready" row: works fields plus the
// author's display_name / avatar (joined from profiles in
// CommunityService.fetchPublicFeed). Kept deliberately narrow — the
// detail page can fetch the rest of works.* on demand.

class FeedWork {
  final String id;
  final String userId;
  final String title;
  final String? description;
  final String format; // 'glb' | 'spz' | 'gsplat' | 'ply'
  final String? modelStoragePath;
  final String? thumbnailStoragePath;
  final int likesCount;
  /// Server-maintained view counter (works.views_count). Bumped by the
  /// `bump_work_views_count` trigger on every new public.work_views row;
  /// the dedup key is (work_id, viewer_id, hour-bucket) so the same
  /// viewer reopening a card 10 times in a minute counts once.
  final int viewsCount;
  final DateTime? publishedAt;

  // Joined from profiles.
  final String authorDisplayName;
  final String? authorAvatarUrl;

  // Mutable per-user state — whether the *current* user has liked this
  // work. Filled in by CommunityService.fetchPublicFeed via a bulk
  // work_likes lookup so the heart icon can render without a per-card
  // network roundtrip. Defaults to false when the user is signed out.
  final bool likedByMe;

  const FeedWork({
    required this.id,
    required this.userId,
    required this.title,
    required this.description,
    required this.format,
    required this.modelStoragePath,
    required this.thumbnailStoragePath,
    required this.likesCount,
    required this.viewsCount,
    required this.publishedAt,
    required this.authorDisplayName,
    required this.authorAvatarUrl,
    required this.likedByMe,
  });

  /// Returns a copy with optional field overrides. Used by the
  /// optimistic like-toggle path in PostCard so the parent feed can
  /// swap a stale FeedWork for a fresh one without rebuilding the list.
  FeedWork copyWith({
    int? likesCount,
    int? viewsCount,
    bool? likedByMe,
  }) {
    return FeedWork(
      id: id,
      userId: userId,
      title: title,
      description: description,
      format: format,
      modelStoragePath: modelStoragePath,
      thumbnailStoragePath: thumbnailStoragePath,
      likesCount: likesCount ?? this.likesCount,
      viewsCount: viewsCount ?? this.viewsCount,
      publishedAt: publishedAt,
      authorDisplayName: authorDisplayName,
      authorAvatarUrl: authorAvatarUrl,
      likedByMe: likedByMe ?? this.likedByMe,
    );
  }
}
