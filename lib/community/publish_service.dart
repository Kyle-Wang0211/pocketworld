// PublishService — publish a finished local scan to the public community
// feed.
//
// Re-introduces the "发布到社区" flow deleted in Plan G W2 (2026-05-16),
// ported from the Aether3D-cross `claude/publish-to-community` branch and
// re-targeted from GLB to the sparse point cloud the official capture
// route actually produces.
//
// ── What changed vs the GLB-era original ─────────────────────────────
//
// (1) SOURCE. The original read `record.artifactPath` (a file:// GLB).
//     The official capture route never writes artifactPath — it leaves
//     `$captureDir/official_sfm_sparse.ply`. We locate the payload from
//     `record.captureDir` instead.
//
// (2) NO NORMALIZE. The original ran the model through GlbNormalizer with
//     a decimating community preset (150K faces / 2K atlas). That step is
//     dropped: decimating a point cloud is exactly the downsampling the
//     delivery rule forbids, and the whole cloud is ~1.4 MB for 100K
//     points — small enough to ship whole. The PLY goes up byte-for-byte.
//
// (3) THUMBNAIL. The original relied on a first-viewer JPEG bake. We
//     already render `official_sparse_thumb.png` beside the PLY
//     (lib/ui/sparse_thumbnail.dart, 斜上 45°, 真彩, 黑底), so we upload
//     that instead — same image the drafts grid shows, so a work looks
//     identical before and after publishing.
//
// ── Invariant carried over unchanged ─────────────────────────────────
// The `works` row is inserted ONLY after the storage upload succeeds, so
// the feed can never hold a row pointing at a missing file. A failed
// thumbnail is non-fatal — the row stands, the card falls back to its
// gradient backdrop.
//
// Cross-platform: pure Dart on supabase_flutter + dart:io. No Flutter
// widgets, no FFI — every external effect is an injected seam, so the
// orchestration is host-testable with no network and no device.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ui/scan_record.dart';
import '../util/file_signature.dart';
import '../config/endpoint_config.dart';
import '../ui/sparse_thumbnail.dart' show kSparseThumbFileName;
import 'community_service.dart';

/// File the official capture route leaves in `captureDir`.
const String kOfficialSparsePlyName = 'official_sfm_sparse.ply';

/// Storage upload seam. Real impl calls
/// `client.storage.from('works').uploadBinary(...)`. Injectable so the
/// orchestration test never touches a live Supabase.
typedef UploadModelFn =
    Future<String> Function({required String path, required Uint8List bytes});

/// `works` row insert seam. Real impl calls
/// `client.from('works').insert(row).select('id').single()` and returns
/// the read-back id.
typedef InsertWorkFn = Future<String> Function({
  required Map<String, dynamic> row,
});

/// Narrow view of [CommunityService] — just the thumbnail broker. Lets
/// the unit test fake it without a live Supabase.
abstract class CommunityServiceLike {
  Future<String?> uploadAndSetThumbnail({
    required String workId,
    required Uint8List bytes,
    String contentType,
    String extension,
  });
}

class _CommunityAdapter implements CommunityServiceLike {
  final CommunityService _inner;
  _CommunityAdapter(this._inner);

  @override
  Future<String?> uploadAndSetThumbnail({
    required String workId,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
    String extension = 'jpg',
  }) => _inner.uploadAndSetThumbnail(
    workId: workId,
    bytes: bytes,
    contentType: contentType,
    extension: extension,
  );
}

/// One progress event from an in-flight publish.
@immutable
class PublishProgress {
  /// 'reading' | 'uploading' | 'inserting' | 'thumbnail' | 'done'
  final String phase;

  /// Monotonic 0..1.
  final double fraction;

  const PublishProgress({required this.phase, required this.fraction});

  @override
  String toString() =>
      'PublishProgress($phase, ${(fraction * 100).toStringAsFixed(1)}%)';
}

/// Terminal result of a successful publish.
@immutable
class PublishResult {
  /// works.id (uuid), read back from the insert.
  final String workId;

  /// '{uid}/{sha1}.ply'.
  final String modelStoragePath;

  /// Uploaded PLY byte length.
  final int fileSizeBytes;

  /// null when no local thumbnail existed or the upload failed.
  final String? thumbnailStoragePath;

  const PublishResult({
    required this.workId,
    required this.modelStoragePath,
    required this.fileSizeBytes,
    this.thumbnailStoragePath,
  });
}

/// Thrown on any non-recoverable publish failure. [phase] says where it
/// died so the UI can be specific.
/// 服务端是否因体积超限而拒绝。
///
/// Supabase Storage 的口径:错误码 `EntityTooLarge`,HTTP **413**。
/// 三种形态都匹配,因为这个错误会经过 SDK 包装,不同路径下暴露出来的
/// 字段不一样 —— 只认其中一种就会在另一条路径上漏判。
bool _isTooLargeError(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('entitytoolarge') ||
      s.contains('payload too large') ||
      s.contains('413');
}

class PublishException implements Exception {
  /// 'reading' | 'validating' | 'too_large' | 'uploading' | 'inserting'
  final String phase;
  final String message;
  const PublishException(this.phase, this.message);

  @override
  String toString() => 'PublishException($phase): $message';
}

class PublishService {
  final String? Function() _uid;
  final CommunityServiceLike _community;
  final UploadModelFn _uploadModel;
  final InsertWorkFn _insertWork;

  PublishService._({
    required String? Function() uid,
    required CommunityServiceLike community,
    required UploadModelFn uploadModel,
    required InsertWorkFn insertWork,
  }) : _uid = uid,
       _community = community,
       _uploadModel = uploadModel,
       _insertWork = insertWork;

  /// Production constructor.
  factory PublishService({SupabaseClient? client, CommunityService? community}) {
    final c = client ?? Supabase.instance.client;
    final comm = community ?? CommunityService(client: c);
    return PublishService._(
      uid: () => c.auth.currentUser?.id,
      community: _CommunityAdapter(comm),
      uploadModel: ({required path, required bytes}) async {
        // Direct owner-write to the `works` bucket (works_insert_self /
        // works_update_self survived the 2026-05-22 broker hardening).
        // upsert dedups a content-addressed re-publish.
        return c.storage
            .from('works')
            .uploadBinary(
              path,
              bytes,
              fileOptions: const FileOptions(
                contentType: 'application/octet-stream',
                upsert: true,
                cacheControl: '604800', // 7 days — content-addressed.
              ),
            );
      },
      insertWork: ({required row}) async {
        final inserted = await c
            .from('works')
            .insert(row)
            .select('id')
            .single();
        return inserted['id'] as String;
      },
    );
  }

  /// Test-only constructor — injects every external seam.
  @visibleForTesting
  factory PublishService.forTest({
    required String? Function() uid,
    required CommunityServiceLike community,
    required UploadModelFn uploadModel,
    required InsertWorkFn insertWork,
  }) => PublishService._(
    uid: uid,
    community: community,
    uploadModel: uploadModel,
    insertWork: insertWork,
  );

  /// Resolve the PLY a record would publish, or null when the record has
  /// no capture directory / the reconstruction has not landed yet.
  /// Exposed so the UI can gate the "发布" button without duplicating the
  /// layout convention.
  static File? sparsePlyFor(ScanRecord record) {
    final dir = record.captureDir;
    if (dir == null || dir.isEmpty) return null;
    final f = File('$dir/$kOfficialSparsePlyName');
    return f.existsSync() ? f : null;
  }

  /// Publish a finished local scan to the public community feed.
  ///
  /// Preconditions (the caller gates these too; re-checked as defence in
  /// depth): signed in, the record has a readable sparse PLY, and it is
  /// not already published. This service never touches ScanRecordStore —
  /// the CALLER marks `cloudWorkId` after a successful result.
  Future<PublishResult> publish({
    required ScanRecord record,
    required String title,
    String? description,
    void Function(PublishProgress)? onProgress,
  }) async {
    void emit(String phase, double fraction) {
      onProgress?.call(PublishProgress(phase: phase, fraction: fraction));
    }

    // 1) Preconditions.
    final uid = _uid();
    if (uid == null) {
      throw const PublishException('reading', 'signed out');
    }
    if (record.cloudWorkId != null) {
      throw const PublishException('reading', 'already published');
    }
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty || trimmedTitle.length > 100) {
      // Mirrors the DB CHECK so a bad payload never burns an upload.
      throw const PublishException('reading', 'title must be 1..100 chars');
    }
    final trimmedDesc = description?.trim();
    if (trimmedDesc != null && trimmedDesc.length > 5000) {
      throw const PublishException('reading', 'description exceeds 5000 chars');
    }

    // 2) Read the sparse PLY off disk.
    emit('reading', 0.02);
    final Uint8List bytes;
    try {
      final ply = sparsePlyFor(record);
      if (ply == null) {
        throw const PublishException(
          'reading',
          'no $kOfficialSparsePlyName under the record captureDir',
        );
      }
      bytes = await ply.readAsBytes();
      if (bytes.isEmpty) {
        throw const PublishException('reading', 'sparse PLY is empty');
      }
    } on PublishException {
      rethrow;
    } catch (e) {
      throw PublishException('reading', e.toString());
    }

    // 3) Content-address. Same bytes → same path → upsert dedups.
    final hash = sha1.convert(bytes).toString();
    final storagePath = '$uid/$hash.ply';

    // 3b) 内容必须与声明的扩展名相符。
    //
    // ⚠️ 这**不是**安全边界 —— 攻击者会直接改客户端。它挡的是误操作
    // (选错文件、上游生成器写坏),以及为服务端强制校验预备同一套规则
    // (util/file_signature.dart 是纯函数,两端共用,不会出现标准不一致)。
    // 真正的强制必须在服务端;直传架构下服务端拿不到内容,需要上传后用
    // Range 请求读文件头 —— 那一步会改变发布流程,待定。
    if (!matchesDeclaredExtension(bytes, storagePath)) {
      throw PublishException(
        'validating',
        '文件内容不是有效的 PLY 点云。请确认选择的是扫描产物文件。',
      );
    }

    // 3c) 体积预检 —— 只为快速失败,不是安全控制。
    //
    // 服务端的 Global file size limit 是 dashboard 配置(Free 封顶 50MB,
    // 付费可调高),不是代码常量。所以这里读的是运行时下发的值,而不是
    // 硬编码 —— 硬编码必然在改计划/改设置的那天悄悄漂移,且漂移方向危险:
    // 客户端以为没问题,服务端在传完几十 MB 之后才拒。
    //
    // 值缺失时不预检,直接依赖服务端的 413(见下)。宁可多传一次,
    // 也不要因为配置没下发就把用户挡在门外。
    final maxBytes = EndpointConfigResolver.current?.maxUploadBytes;
    if (maxBytes != null && bytes.length > maxBytes) {
      throw PublishException(
        'too_large',
        '${(bytes.length / 1048576).toStringAsFixed(1)}MB / '
        '${(maxBytes / 1048576).toStringAsFixed(0)}MB',
      );
    }

    // 4) Upload. NO works row exists yet → nothing can be orphaned.
    emit('uploading', 0.10);
    try {
      await _uploadModel(path: storagePath, bytes: bytes);
    } catch (e) {
      // 服务端超限返回 EntityTooLarge / HTTP 413。必须与网络故障区分开:
      // 网络故障重试会成功,超限重试**永远**不会成功 —— 而原来两者共用
      // 同一句"请检查网络后重试",会让用户一直重试到放弃。
      //
      // 这一道是兜底,不是替代预检:预检用的配置值可能滞后于服务端实际
      // 设置,只有服务端自己的拒绝是当下为真的。
      if (_isTooLargeError(e)) {
        throw PublishException(
          'too_large',
          '${(bytes.length / 1048576).toStringAsFixed(1)}MB',
        );
      }
      throw PublishException('uploading', e.toString());
    }

    // 5) Insert the public works row, read back the id.
    emit('inserting', 0.80);
    final row = <String, dynamic>{
      'user_id': uid,
      'title': trimmedTitle,
      'description': (trimmedDesc == null || trimmedDesc.isEmpty)
          ? null
          : trimmedDesc,
      'format': 'ply',
      'model_storage_path': storagePath,
      'file_size_bytes': bytes.length,
      'visibility': 'public',
      'published_at': DateTime.now().toUtc().toIso8601String(),
    };
    final String workId;
    try {
      workId = await _insertWork(row: row);
    } catch (e) {
      throw PublishException('inserting', e.toString());
    }

    // 6) Thumbnail — best effort, NEVER throws. We reuse the PNG the
    // drafts grid already rendered, so a published card looks identical
    // to the local one. A miss just leaves thumbnail_storage_path null.
    emit('thumbnail', 0.90);
    String? thumbPath;
    final dir = record.captureDir;
    if (dir != null && dir.isNotEmpty) {
      try {
        final thumb = File('$dir/$kSparseThumbFileName');
        if (await thumb.exists()) {
          final png = await thumb.readAsBytes();
          if (png.isNotEmpty) {
            thumbPath = await _community.uploadAndSetThumbnail(
              workId: workId,
              bytes: png,
              contentType: 'image/png',
              extension: 'png',
            );
          }
        }
      } catch (e) {
        debugPrint('[PublishService] thumbnail best-effort failed: $e');
        thumbPath = null;
      }
    }

    emit('done', 1.0);
    return PublishResult(
      workId: workId,
      modelStoragePath: storagePath,
      fileSizeBytes: bytes.length,
      thumbnailStoragePath: thumbPath,
    );
  }
}
