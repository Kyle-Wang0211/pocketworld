// Supabase queries that power the community feed.
//
// Three responsibilities:
//   • fetchPublicFeed — a paginated read of public works joined with
//     authoring profiles, plus a bulk work_likes lookup so each card
//     knows whether the current user has liked it.
//   • toggleLike       — flips the current user's like on a work.
//                        Schema-side trigger maintains works.likes_count.
//   • thumbnailUrlFor / modelUrlFor — turn storage paths into
//     publicly-resolvable URLs (or signed URLs for private buckets).
//
// Cross-platform: pure Dart on top of supabase_flutter, runs identically
// on iOS / Android / HarmonyOS / Web.

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/endpoint_config.dart';
import '../storage/signed_upload_broker.dart';
import 'feed_models.dart';

/// How the community feed is ordered.
///   • recent  → published_at desc (the "发现 / Discover" tab).
///   • hot     → likes_count desc, then published_at desc as tiebreaker
///               (the "热门 / Hot" tab).
enum FeedSort { recent, hot }

/// [KEYSET-PAGINATION 2026-08-23] 构造 keyset 游标的 PostgREST 过滤串。
///
/// PostgreSQL 的元组比较 `(published_at, id) < (T, I)` 等价于
///   `published_at < T  OR  (published_at = T AND id < I)`
/// PostgREST **没有**原生元组比较,所以只能发上面这条展开式。
///
/// 抽成纯函数是为了能脱离数据库测 —— 展开式写错(比如漏掉 `AND id < I`
/// 那一半)在真机上表现为"边界处漏一条",极难察觉。
///
/// ⚠️ 值不做转义:ISO8601 时间戳与 uuid 都不含 `,` 与括号,
/// 不会破坏 `or=(...)` 的语法。换成别的列类型前先确认这一点仍成立。
String buildFeedKeysetFilter({
  required DateTime afterPublishedAt,
  required String afterId,
}) {
  final t = afterPublishedAt.toUtc().toIso8601String();
  return 'published_at.lt.$t,and(published_at.eq.$t,id.lt.$afterId)';
}

class CommunityService {
  final SupabaseClient _client;
  final SignedUploadBroker _uploadBroker;

  /// Test seam only. Production leaves this null and reads the live
  /// config, so a background refresh is picked up without rebuilding
  /// the service.
  final EndpointConfig? _endpointOverride;

  CommunityService({
    SupabaseClient? client,
    SignedUploadBroker? uploadBroker,
    @visibleForTesting EndpointConfig? endpointOverride,
  }) : _client = client ?? Supabase.instance.client,
       _endpointOverride = endpointOverride,
       _uploadBroker =
           uploadBroker ??
           SignedUploadBroker(client: client ?? Supabase.instance.client);

  /// Public works joined with profile (display_name + avatar_url) and the
  /// current user's like state.
  ///
  /// Empty database returns []. Network / auth errors throw.
  Future<List<FeedWork>> fetchPublicFeed({
    int limit = 20,
    int offset = 0,
    FeedSort sortBy = FeedSort.recent,
    String? query,

    /// [D7 2026-08-23 用户签决] 只看某个作者的作品 —— 流内过滤,**不是**
    /// 个人主页。后端本就 100% 就绪:profiles 六字段齐、FeedWork 已带 userId,
    /// 过滤就是下面这一句 .eq('user_id', ...)。
    String? authorUserId,

    /// [KEYSET-PAGINATION 2026-08-23] 上一页最后一条的 (published_at, id)。
    ///
    /// 传了就走 keyset(seek),`offset` 被忽略;不传就是首页。
    ///
    /// 为什么必须改掉 offset:offset 分页在"边翻页边有新内容插到顶部"时
    /// **静默漏项** —— 整列下移一位,原本在 offset 处的那条挪到 offset+1,
    /// 第二页从下一条开始,中间那条对该用户永远不出现。
    /// 客户端按 id 去重只挡得住**重复**,挡不住**漏**。
    ///
    /// ⚠️ 两个参数必须**成对**传 —— 只传时间戳会退化成不唯一的排序键,
    /// 边界上同一时刻发布的行会被跳过或重复。
    DateTime? afterPublishedAt,
    String? afterId,
  }) async {
    // 1) Public works. Visibility filter belongs in code even though RLS
    // would already enforce it — public clients should never get a row
    // they shouldn't, but explicit is clearer.
    var filter = _client
        .from('works')
        .select(
          'id, user_id, title, description, format, '
          'model_storage_path, thumbnail_storage_path, '
          'file_size_bytes, likes_count, views_count, published_at, '
          'publish_region',
        )
        .eq('visibility', 'public')
        .not('published_at', 'is', null);
    if (authorUserId != null && authorUserId.isNotEmpty) {
      filter = filter.eq('user_id', authorUserId);
    }
    final trimmedQuery = query?.trim();
    if (trimmedQuery != null && trimmedQuery.isNotEmpty) {
      // ilike is parameterized — pattern is sent as-is and matches as a
      // case-insensitive substring. Wildcards in the user's input
      // collapse to literals on the wire (PostgREST escapes them).
      filter = filter.ilike('title', '%$trimmedQuery%');
    }
    // [KEYSET-PAGINATION 2026-08-23] 游标 —— 等价于 PostgreSQL 的元组比较
    //   (published_at, id) < (T, I)
    // ≡ published_at < T  OR  (published_at = T AND id < I)
    // PostgREST 没有原生元组比较,用上面这条展开式。
    // ISO8601 时间戳与 uuid 都不含 `,` 与括号,不会破坏 or=(...) 的语法。
    final useKeyset = afterPublishedAt != null && afterId != null;
    if (useKeyset) {
      filter = filter.or(
        buildFeedKeysetFilter(
          afterPublishedAt: afterPublishedAt,
          afterId: afterId,
        ),
      );
    }

    final transformed = switch (sortBy) {
      // 次级键 id 是 keyset 的硬性前提:排序键必须唯一确定一个位置,
      // 否则边界上 published_at 相同的行会被跳过或重复。
      FeedSort.recent =>
        filter
            .order('published_at', ascending: false)
            .order('id', ascending: false),
      // ⚠️ hot 仍走 offset。它自 2026-08-23 砍掉标签后已无生产调用点
      // (vault_page 定死 FeedSort.recent),不值得为它再补一套三键游标
      // (likes_count, published_at, id)。若哪天复活,照 recent 的样子加。
      FeedSort.hot =>
        filter
            .order('likes_count', ascending: false)
            .order('published_at', ascending: false)
            .order('id', ascending: false),
    };
    final worksRes = useKeyset
        ? await transformed.limit(limit)
        : await transformed.range(offset, offset + limit - 1);
    var works = (worksRes as List).cast<Map<String, dynamic>>();
    if (works.isEmpty) return const [];

    // Guideline 1.2 "ability to block abusive users": the blocks table has
    // existed since 20260429020002 but the feed never consulted it, so
    // blocking had no visible effect. Filtered here rather than in RLS
    // because works_select_visible has no notion of the *viewer*, and
    // OR-ing a per-viewer subquery into it would run for every row.
    //
    // Trade-off accepted: filtering after .range() means a page can come
    // back short when a blocked author is on it. That is better than
    // showing content the user explicitly blocked, and the pager keeps
    // advancing by `works.length` so nothing is skipped or repeated.
    final blocked = await fetchBlockedUserIds();
    if (blocked.isNotEmpty) {
      works = works
          .where((w) => !blocked.contains(w['user_id'] as String))
          .toList();
      if (works.isEmpty) return const [];
    }

    // 2) Profiles for the unique authors.
    final userIds = works.map((w) => w['user_id'] as String).toSet().toList();
    final profilesRes = await _client
        .from('profiles')
        .select('id, display_name, avatar_url, handle')
        .inFilter('id', userIds);
    final profilesById = {
      for (final p in (profilesRes as List).cast<Map<String, dynamic>>())
        p['id'] as String: p,
    };

    // 3) Current user's likes for these works (one round trip, not N).
    final myId = _client.auth.currentUser?.id;
    final myLikes = <String>{};
    if (myId != null) {
      final workIds = works.map((w) => w['id'] as String).toList();
      final likesRes = await _client
          .from('work_likes')
          .select('work_id')
          .eq('user_id', myId)
          .inFilter('work_id', workIds);
      for (final r in (likesRes as List).cast<Map<String, dynamic>>()) {
        myLikes.add(r['work_id'] as String);
      }
    }

    return works.map((w) {
      final profile = profilesById[w['user_id'] as String] ?? const {};
      final publishedAtStr = w['published_at'] as String?;
      return FeedWork(
        id: w['id'] as String,
        userId: w['user_id'] as String,
        title: (w['title'] as String?) ?? '',
        description: w['description'] as String?,
        format: (w['format'] as String?) ?? 'glb',
        modelStoragePath: w['model_storage_path'] as String?,
        thumbnailStoragePath: w['thumbnail_storage_path'] as String?,
        fileSizeBytes: (w['file_size_bytes'] as num?)?.toInt(),
        likesCount: (w['likes_count'] as int?) ?? 0,
        viewsCount: (w['views_count'] as int?) ?? 0,
        publishedAt: publishedAtStr == null
            ? null
            : DateTime.parse(publishedAtStr),
        authorDisplayName: (profile['display_name'] as String?) ?? 'unknown',
        // 唯一 ID。null = 用户还没设 —— 卡片据此决定要不要显示 `@`。
        authorHandle: profile['handle'] as String?,
        authorAvatarUrl: profile['avatar_url'] as String?,
        likedByMe: myLikes.contains(w['id'] as String),
        // [IP-REGION 2026-08-24] 第十二条。服务端判定,客户端只读。
        publishRegion: (w['publish_region'] as String?)?.trim().isEmpty ?? true
            ? null
            : w['publish_region'] as String?,
      );
    }).toList();
  }

  /// Toggle the current user's like on a work. Returns the new
  /// like state (true = now liked, false = now unliked). Throws if the
  /// user is signed out — call sites should already gate on that.
  Future<bool> toggleLike({
    required String workId,
    required bool currentlyLiked,
  }) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) {
      throw StateError('Cannot toggle like — no signed-in user.');
    }
    if (currentlyLiked) {
      await _client
          .from('work_likes')
          .delete()
          .eq('user_id', myId)
          .eq('work_id', workId);
      return false;
    } else {
      // Upsert tolerates a race where two taps fire concurrently — the
      // (user_id, work_id) PK keeps the row unique either way.
      await _client
          .from('work_likes')
          .upsert(
            {'user_id': myId, 'work_id': workId},
            onConflict: 'user_id,work_id',
            ignoreDuplicates: true,
          );
      return true;
    }
  }

  /// Record a view on the given work. The schema's unique index dedups
  /// (work_id, viewer_id, hour-bucket), so calling this on every detail-
  /// page open is safe — the same viewer reopening within the hour is
  /// silently ignored and the counter is not double-incremented.
  ///
  /// Goes through the record_work_view RPC, not a client-side upsert:
  /// the dedup target uq_work_views_dedup is an *expression* index and
  /// PostgREST's on_conflict only accepts plain column lists, so the
  /// old direct upsert was rejected with 400 on every call (and the
  /// catch below ate it — views_count sat at 0 forever). Server-side
  /// ON CONFLICT DO NOTHING matches expression indexes fine.
  ///
  /// Returns the new total views_count if the bump was effective, or
  /// the prior value if this hour already counted, or null when the
  /// work isn't visible to the caller. Errors (network, auth) are
  /// swallowed so the viewer never breaks; views are a nice-to-have,
  /// not load-bearing.
  Future<int?> recordView(String workId) async {
    try {
      final result = await _client.rpc(
        'record_work_view',
        params: {'p_work_id': workId},
      );
      return result as int?;
    } catch (_) {
      return null;
    }
  }

  /// Id of the signed-in user, or null when signed out. Exposed so UI can
  /// tell "my own work" from someone else's without reaching for the
  /// Supabase client itself (the feed UI otherwise never touches it).
  String? get currentUserId => _client.auth.currentUser?.id;

  /// Remove one of the caller's own published works from the community,
  /// including its storage objects.
  ///
  /// Apple's UGC rejections ask for "a mechanism for users to immediately
  /// remove posts from the feed". `works_delete_own` would let us delete
  /// the row straight from here, but that is not actually a removal: the
  /// `works` bucket is public and a public bucket bypasses RLS on
  /// /object/public/ reads, so the file would stay downloadable — and
  /// storage objects can't be deleted from SQL at all. Hence the
  /// server-side delete-work function, which removes the files first and
  /// re-checks ownership against the row.
  ///
  /// Throws on failure so the UI can say so instead of pretending the
  /// work is gone while it is still in everyone's feed.
  Future<void> deleteMyWork(String workId) async {
    if (_client.auth.currentUser == null) {
      throw StateError('Cannot delete — no signed-in user.');
    }
    final res = await _client.functions.invoke(
      'delete-work',
      body: {'work_id': workId},
    );
    if (res.status != 200) {
      final data = res.data;
      final code = data is Map ? data['error']?.toString() : null;
      throw StateError(
        'delete-work failed (${res.status}${code == null ? '' : ': $code'})',
      );
    }
  }

  /// Report a work. App Store Guideline 1.2 requires "a mechanism to
  /// report offensive content and timely responses to concerns" — the
  /// `reports` table has existed since 20260429020005 but had no client
  /// entry point at all, which is the gap this closes.
  ///
  /// `reason` must be one of the schema's CHECK values:
  /// spam | harassment | hate_speech | sexual_content | violence |
  /// copyright | misinformation | other.
  ///
  /// RLS (`reports_insert_self`) pins reporter_id to auth.uid() and
  /// requires status='pending' with the admin fields blank, so a client
  /// cannot forge a report from someone else or pre-resolve one.
  /// Throws on failure so the UI can tell the user it didn't go through —
  /// a silently dropped report would be worse than no report button.
  Future<void> reportWork({
    required String workId,
    required String reason,
    String? detail,
  }) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) {
      throw StateError('Cannot report — no signed-in user.');
    }
    await _client.from('reports').insert({
      'reporter_id': myId,
      'target_type': 'work',
      'target_id': workId,
      'reason': reason,
      if (detail != null && detail.trim().isNotEmpty) 'detail': detail.trim(),
    });
  }

  /// Block a user. Guideline 1.2 requires "the ability to block abusive
  /// users from the service".
  ///
  /// The schema does the heavy lifting: `blocks` has a
  /// `blocker_id <> blocked_id` CHECK, and a trigger
  /// (`cascade_block_unfollow`) tears down any follow relationship in
  /// both directions. Blocking is idempotent via the composite PK.
  Future<void> blockUser(String blockedUserId) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) {
      throw StateError('Cannot block — no signed-in user.');
    }
    if (myId == blockedUserId) {
      throw ArgumentError('Cannot block yourself.');
    }
    await _client
        .from('blocks')
        .upsert(
          {'blocker_id': myId, 'blocked_id': blockedUserId},
          onConflict: 'blocker_id,blocked_id',
          ignoreDuplicates: true,
        );
  }

  /// Undo [blockUser].
  Future<void> unblockUser(String blockedUserId) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) return;
    await _client
        .from('blocks')
        .delete()
        .eq('blocker_id', myId)
        .eq('blocked_id', blockedUserId);
  }

  /// User ids the current user has blocked. Empty when signed out.
  ///
  /// Used to filter the feed client-side: RLS cannot do it for us because
  /// `works_select_visible` has no notion of the *viewer's* block list,
  /// and adding one would make every feed row run a correlated subquery.
  Future<Set<String>> fetchBlockedUserIds() async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) return const <String>{};
    try {
      final rows = await _client
          .from('blocks')
          .select('blocked_id')
          .eq('blocker_id', myId);
      return {
        for (final r in (rows as List).cast<Map<String, dynamic>>())
          r['blocked_id'] as String,
      };
    } catch (_) {
      // Fail open: a blocks lookup failure must not blank the feed.
      return const <String>{};
    }
  }

  /// Server-side moderation state of one of the caller's own works, or
  /// null if it can't be determined (signed out, network error, or the
  /// row is gone).
  ///
  /// Why this exists: a published work is stamped locally with
  /// `cloudWorkId` and from then on the drafts UI calls it "已发布"
  /// forever — it has no idea the server may since have taken it down.
  /// An author would see their work vanish from the feed with no
  /// explanation. `works_select_visible` lets an owner read their own row
  /// in ANY moderation state (that is deliberate), so the owner can
  /// always learn the truth even when the public can't see the row.
  ///
  /// Returns one of 'ok' | 'under_review' | 'removed'.
  Future<String?> fetchMyWorkModerationStatus(String workId) async {
    try {
      if (_client.auth.currentUser == null) return null;
      final row = await _client
          .from('works')
          .select('moderation_status')
          .eq('id', workId)
          .maybeSingle();
      return row?['moderation_status'] as String?;
    } catch (_) {
      // Non-load-bearing: on failure the UI keeps showing the plain
      // "published" state rather than blocking the page.
      return null;
    }
  }

  /// Public URL for a thumbnails/-bucket asset path. Thumbnails are a
  /// public bucket (RLS allows anon SELECT), so getPublicUrl returns a
  /// stable URL with no token.
  ///
  /// Routed through [_cdn] so the bytes can be served from an edge cache
  /// instead of hitting Supabase egress on every feed scroll.
  String thumbnailUrlFor(String path) {
    return _cdn(_client.storage.from('thumbnails').getPublicUrl(path));
  }

  /// Swap the asset origin for the configured CDN, when one is configured.
  ///
  /// Resolved per call rather than captured at construction: a background
  /// config refresh can change the origin mid-session, and a service built
  /// at launch would otherwise pin the old one for the whole process.
  /// Falls back to the untouched URL whenever no CDN is set, so the
  /// default path is byte-for-byte what it was before.
  String _cdn(String url) =>
      (_endpointOverride ?? EndpointConfigResolver.current)?.cdnRewrite(url) ??
      url;

  /// Returns a URL the client can use to fetch the model file.
  ///
  /// works/ is conditionally readable (public when works.visibility='public',
  /// else owner-only). For public works getPublicUrl is enough; for
  /// private works we'd need createSignedUrl. Feed only shows public
  /// works so the public path is correct here.
  String modelUrlFor(String path) {
    return _cdn(_client.storage.from('works').getPublicUrl(path));
  }

  /// Phase 6.4f.10 — bake-and-publish a thumbnail JPG for a work that
  /// doesn't have one yet. Returns the storage path written on success,
  /// or null if anything failed (RLS rejection, network error, etc.).
  ///
  /// This is the "first viewer wins" mechanic: when the work owner (or
  /// a future authorized RPC) opens a work detail page that has no
  /// thumbnail yet, the viewer captures the rendered IOSurface and
  /// uploads it here. RLS on `works` only allows the owner to UPDATE,
  /// so today this only succeeds when the user is the work owner —
  /// good enough to fix our own SPZ test sample without a server-side
  /// migration. Later we can add an RPC that lets any authenticated
  /// user one-shot bake a missing thumb.
  ///
  /// Phase 6.4f.10.2 — path layout fix. The supabase `thumbnails`
  /// bucket's storage RLS policy is the conventional
  ///   (storage.foldername(name))[1] = auth.uid()::text
  /// — i.e. the first path segment must be the caller's auth.uid.
  /// The original 6.4f.10 layout `<work_id>/auto.jpg` violated this
  /// (work_id ≠ user_id in our schema) and the upload returned 403
  /// "new row violates row-level security policy" on real-device
  /// testing 2026-05-04. The new layout `<uid>/<work_id>.jpg` mirrors
  /// the [PublishService] convention `<uid>/<record_id>.jpg` and
  /// satisfies the standard storage RLS policy. Bucket is public so
  /// feed readers (any auth state, including anon) still get the JPG.
  ///
  /// Phase B (2026-08-16) — generalised beyond JPEG, and the "first
  /// qualified viewer bakes it" mechanic described above is retired. The
  /// official capture route already renders `official_sparse_thumb.png`
  /// beside each PLY (lib/ui/sparse_thumbnail.dart), so [PublishService]
  /// uploads that file at publish time rather than re-encoding it: a work
  /// carries its thumbnail from the moment it enters the feed, and it is
  /// the same image the drafts grid shows. The old ThumbBaker lost its
  /// last caller and was deleted; [contentType]/[extension] still default
  /// to JPEG so this stays a drop-in for any future bake-style caller.
  Future<String?> uploadAndSetThumbnail({
    required String workId,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
    String extension = 'jpg',
  }) async {
    try {
      final uid = _client.auth.currentUser?.id;
      if (uid == null) {
        debugPrint(
          '[CommunityService] uploadAndSetThumbnail($workId) skipped — '
          'no signed-in user (anon RLS will reject upload anyway)',
        );
        return null;
      }
      // Phase 6.4f.10.2: path = <uid>/<work_id>.<ext>, NOT <work_id>/auto.*.
      // Required by the standard supabase storage RLS policy that pins
      // the first folder segment to auth.uid().
      final storagePath = '$uid/$workId.$extension';
      final storage = _client.storage.from('thumbnails');
      final credential = await _uploadBroker.createCredential(
        bucket: 'thumbnails',
        path: storagePath,
        contentType: contentType,
        bytes: bytes.lengthInBytes,
        role: 'auto_thumbnail',
        workId: workId,
      );
      await storage.uploadBinaryToSignedUrl(
        storagePath,
        credential.token,
        bytes,
        FileOptions(
          contentType: contentType,
          upsert: true,
          cacheControl: '604800', // 7 days — content-addressed by work id;
          // if a re-bake replaces it, supabase + CDN rev the URL via
          // the upsert.
          metadata: const <String, String>{
            'role': 'auto_thumbnail',
            'upload_credential_strategy': 'edge_broker_signed_upload_url_v1',
          },
        ),
      );
      // Update the work row. RLS on the `works` table allows the owner
      // to UPDATE; since the upload above just succeeded under the same
      // auth, this should also succeed if owner==caller. Soft-fail
      // (debugPrint + return null) preserves the bucket file for the
      // next bake retry to discover.
      await _client
          .from('works')
          .update({'thumbnail_storage_path': storagePath})
          .eq('id', workId);
      debugPrint(
        '[CommunityService] thumbnail baked for $workId → $storagePath '
        '(${(bytes.lengthInBytes / 1024).toStringAsFixed(1)} KB, $contentType)',
      );
      return storagePath;
    } catch (e, s) {
      debugPrint(
        '[CommunityService] uploadAndSetThumbnail($workId) failed: $e\n$s',
      );
      return null;
    }
  }
}
