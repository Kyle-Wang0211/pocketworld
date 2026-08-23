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

  /// works.file_size_bytes. Surfaced to the feed so a card can show the
  /// scan's point count — the domain-meaningful number for a 3D-capture
  /// community, and the one Polycam exposes as `vertexCount` alongside
  /// `downloadSize` on its own assets. See [approxPointCount].
  final int? fileSizeBytes;
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

  /// profiles.handle —— 全局唯一的 ID(小写 ASCII,迁移 20260823010000)。
  ///
  /// 与 [authorDisplayName] 是**两轨**,别混:昵称可重复、可中文可 emoji;
  /// handle 唯一、纯 ASCII。抖音号/小红书号/微信号都是这个结构。
  ///
  /// null = 该用户还没设置过 handle(建表时允许 NULL 且不自动生成 ——
  /// GitHub 的教训是自动分配 + 旧名释放会被抢注冒充)。
  /// ⚠️ UI 里的 `@` 只能跟 handle。跟在昵称后面等于告诉用户"这是唯一标识",
  ///    而昵称可以有无数个同名 —— 那是在说假话。
  final String? authorHandle;

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
    this.fileSizeBytes,
    this.authorHandle,
  });

  /// Point count implied by [fileSizeBytes], or null when it cannot be
  /// derived.
  ///
  /// Our sparse PLY is fixed-width: a ~150-byte ASCII header followed by
  /// 15 bytes per vertex (xyz float32 ×3 + rgb uchar ×3), written by the
  /// official capture route and parsed on exactly that assumption in
  /// `loadSparsePly`. So the count falls straight out of the file size —
  /// no schema column and no extra round trip. Only valid for 'ply';
  /// other formats have no fixed stride, so they get null rather than a
  /// number that would silently be wrong.
  int? get approxPointCount {
    if (format.toLowerCase() != 'ply') return null;
    final size = fileSizeBytes;
    if (size == null || size <= 0) return null;
    const headerBytes = 150; // ~exact for our writer; noise at 100K points
    const bytesPerVertex = 15;
    final n = (size - headerBytes) ~/ bytesPerVertex;
    return n > 0 ? n : null;
  }

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
      fileSizeBytes: fileSizeBytes,
      authorHandle: authorHandle,
    );
  }
}
