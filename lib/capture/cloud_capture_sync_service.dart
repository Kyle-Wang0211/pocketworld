import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../me/scan_record_store.dart';
import '../ui/scan_record.dart';
import 'cloud_capture_uploader.dart';

/// Keeps the phone/tablet/laptop view of captures in sync with the
/// cloud-first product loop:
///
/// 1. retry local captures that still have staging files;
/// 2. pull cloud scans/works created by any device on the same account;
/// 3. download finished GLB artifacts into this device's local cache.
class CloudCaptureSyncService {
  static const bool keepLocalRawForDebug = bool.fromEnvironment(
    'POCKETWORLD_KEEP_LOCAL_RAW',
  );

  final SupabaseClient _client;
  final ScanRecordStore _store;
  final CloudCaptureUploader _uploader;

  CloudCaptureSyncService({
    SupabaseClient? client,
    ScanRecordStore? store,
    CloudCaptureUploader? uploader,
  }) : _client = client ?? Supabase.instance.client,
       _store = store ?? ScanRecordStore.instance,
       _uploader = uploader ?? CloudCaptureUploader(client: client);

  Future<void> resume() async {
    await retryPendingLocalUploads();
    await syncFromCloud();
  }

  Future<void> retryPendingLocalUploads() async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    await _store.ensureLoaded();
    final candidates = _store.records.where(_shouldRetryUpload).toList();
    for (final record in candidates) {
      await _retryOne(record);
    }
  }

  Future<void> syncFromCloud({bool downloadArtifacts = true}) async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    await _store.ensureLoaded();

    final scansRaw = await _client
        .from('scans')
        .select(
          'id,user_id,status,frames_count,raw_storage_path,'
          'cover_thumbnail_path,metadata,error_message,created_at,'
          'updated_at,upload_acknowledged_at,local_raw_deleted_at,'
          'cloud_raw_deleted_at,work_id',
        )
        .eq('user_id', user.id)
        .order('created_at', ascending: false)
        .limit(200);
    final scans = (scansRaw as List).cast<Map<String, dynamic>>();

    final worksRaw = await _client
        .from('works')
        .select(
          'id,scan_id,title,format,model_storage_path,'
          'thumbnail_storage_path,created_at,updated_at',
        )
        .eq('user_id', user.id)
        .order('created_at', ascending: false)
        .limit(200);
    final works = (worksRaw as List).cast<Map<String, dynamic>>();
    final worksByScanId = <String, Map<String, dynamic>>{};
    for (final work in works) {
      final scanId = work['scan_id'] as String?;
      if (scanId != null && scanId.isNotEmpty) {
        worksByScanId.putIfAbsent(scanId, () => work);
      }
    }
    final consumedWorkIds = <String>{};

    for (final scan in scans) {
      final scanId = scan['id'] as String;
      final metadata = _asStringKeyMap(scan['metadata']);
      final recordId =
          (metadata['client_capture_id'] as String?)?.trim().isNotEmpty == true
          ? metadata['client_capture_id'] as String
          : scanId;
      final old = _store.byId(recordId);
      final work = worksByScanId[scanId];
      final workId = work?['id'] as String?;
      if (workId != null) consumedWorkIds.add(workId);
      final cloudArtifactPath = work?['model_storage_path'] as String?;
      final artifactPath = downloadArtifacts && cloudArtifactPath != null
          ? await _downloadWorkGlb(
              recordId: recordId,
              storagePath: cloudArtifactPath,
              existingArtifactPath: old?.artifactPath,
            )
          : old?.artifactPath;
      final cloudThumbnailPath =
          (work?['thumbnail_storage_path'] as String?) ??
          (scan['cover_thumbnail_path'] as String?);
      final thumbnailBucket = work?['thumbnail_storage_path'] != null
          ? 'works'
          : 'scans';
      final thumbnailPath = downloadArtifacts && cloudThumbnailPath != null
          ? await _downloadThumbnail(
              bucket: thumbnailBucket,
              recordId: recordId,
              storagePath: cloudThumbnailPath,
              existingThumbnailPath: old?.thumbnailPath,
            )
          : old?.thumbnailPath;
      final status = _statusFor(scan['status'] as String?, work);
      await _store.addOrUpdate(
        (old ??
                ScanRecord(
                  id: recordId,
                  name: (work?['title'] as String?) ?? 'Cloud capture',
                  createdAt: _parseDate(scan['created_at']) ?? DateTime.now(),
                  preferredCaptureMode: CaptureMode.newRemote,
                ))
            .copyWith(
              thumbnailPath: thumbnailPath,
              cloudUploadStatus: status,
              cloudScanId: scanId,
              cloudManifestPath: scan['raw_storage_path'] as String?,
              cloudWorkId: work?['id'] as String? ?? scan['work_id'] as String?,
              cloudArtifactPath: cloudArtifactPath,
              artifactPath: artifactPath,
              uploadedFrameCount: (scan['frames_count'] as num?)?.toInt(),
              uploadedAt: _parseDate(metadata['uploaded_at']),
              localRawDeletedAt: _parseDate(scan['local_raw_deleted_at']),
              cloudRawDeletedAt: _parseDate(scan['cloud_raw_deleted_at']),
              cloudUploadFailureMessage: scan['error_message'] as String?,
              localRawRetainedForDebug:
                  old?.localRawRetainedForDebug ?? keepLocalRawForDebug,
            ),
      );
    }

    // Legacy/manual works can exist without a scan_id. The old sync path
    // ignored them entirely, so reinstall/re-login could miss already-finished
    // GLB projects even though they were safely in the cloud.
    for (final work in works) {
      final workId = work['id'] as String;
      if (consumedWorkIds.contains(workId)) continue;
      final cloudArtifactPath = work['model_storage_path'] as String?;
      if (cloudArtifactPath == null || cloudArtifactPath.isEmpty) continue;
      final old = _store.byId(workId);
      final artifactPath = downloadArtifacts
          ? await _downloadWorkGlb(
              recordId: workId,
              storagePath: cloudArtifactPath,
              existingArtifactPath: old?.artifactPath,
            )
          : old?.artifactPath;
      if (old == null && artifactPath == null) {
        continue;
      }
      final cloudThumbnailPath = work['thumbnail_storage_path'] as String?;
      final thumbnailPath = downloadArtifacts && cloudThumbnailPath != null
          ? await _downloadThumbnail(
              bucket: 'works',
              recordId: workId,
              storagePath: cloudThumbnailPath,
              existingThumbnailPath: old?.thumbnailPath,
            )
          : old?.thumbnailPath;
      await _store.addOrUpdate(
        (old ??
                ScanRecord(
                  id: workId,
                  name: (work['title'] as String?) ?? 'Cloud work',
                  createdAt: _parseDate(work['created_at']) ?? DateTime.now(),
                  preferredCaptureMode: CaptureMode.newRemote,
                ))
            .copyWith(
              thumbnailPath: thumbnailPath,
              artifactPath: artifactPath,
              cloudUploadStatus: ScanCloudUploadStatus.completed,
              cloudWorkId: workId,
              cloudArtifactPath: cloudArtifactPath,
            ),
      );
    }
  }

  bool _shouldRetryUpload(ScanRecord record) {
    if (record.captureDir == null ||
        record.photosDir == null ||
        record.captureManifestPath == null) {
      return false;
    }
    if (!Directory(record.captureDir!).existsSync()) return false;
    switch (record.cloudUploadStatus) {
      case ScanCloudUploadStatus.localPending:
      case ScanCloudUploadStatus.failed:
      case ScanCloudUploadStatus.uploading:
        return true;
      case ScanCloudUploadStatus.none:
      case ScanCloudUploadStatus.uploaded:
      case ScanCloudUploadStatus.acknowledged:
      case ScanCloudUploadStatus.queued:
      case ScanCloudUploadStatus.processing:
      case ScanCloudUploadStatus.completed:
        return false;
    }
  }

  Future<void> _retryOne(ScanRecord record) async {
    await _store.addOrUpdate(
      record.copyWith(
        cloudUploadStatus: ScanCloudUploadStatus.uploading,
        clearCloudUploadFailureMessage: true,
      ),
    );
    try {
      final result = await _uploader.uploadDraft(
        clientCaptureId: record.id,
        captureDir: Directory(record.captureDir!),
        photosDir: Directory(record.photosDir!),
        captureManifestFile: File(record.captureManifestPath!),
        thumbnailFile: record.thumbnailPath == null
            ? null
            : File(record.thumbnailPath!),
        deleteLocalOnSuccess: true,
        debugKeepLocalRaw: keepLocalRawForDebug,
      );
      await _store.addOrUpdate(
        (_store.byId(record.id) ?? record).copyWith(
          cloudUploadStatus: ScanCloudUploadStatus.acknowledged,
          cloudScanId: result.scanId,
          cloudManifestPath: result.cloudManifestPath,
          uploadedFrameCount: result.uploadedFrameCount,
          uploadedAt: result.uploadedAt,
          localRawDeletedAt: result.localRawDeletedAt,
          clearCloudUploadFailureMessage: true,
          localRawRetainedForDebug: !result.localRawDeleted,
        ),
      );
    } catch (e, st) {
      debugPrint(
        '[CloudCaptureSyncService] retry failed for ${record.id}: $e\n$st',
      );
      await _store.addOrUpdate(
        (_store.byId(record.id) ?? record).copyWith(
          cloudUploadStatus: ScanCloudUploadStatus.failed,
          cloudUploadFailureMessage: _shortError(e),
          localRawRetainedForDebug: true,
        ),
      );
    }
  }

  Future<String?> _downloadWorkGlb({
    required String recordId,
    required String storagePath,
    required String? existingArtifactPath,
  }) async {
    final existingPath = existingArtifactPath?.startsWith('file://') == true
        ? existingArtifactPath!.substring(7)
        : existingArtifactPath;
    if (existingPath != null &&
        existingPath.isNotEmpty &&
        File(existingPath).existsSync()) {
      return existingArtifactPath;
    }
    final out = await _store.glbFileFor(recordId);
    if (await out.exists() && await out.length() > 0) {
      return 'file://${out.path}';
    }
    final normalizedPath = _normalizeStoragePath(
      bucket: 'works',
      storagePath: storagePath,
    );
    if (normalizedPath == null) return existingArtifactPath;
    try {
      final bytes = await _client.storage
          .from('works')
          .download(normalizedPath);
      await out.writeAsBytes(bytes, flush: true);
      return 'file://${out.path}';
    } catch (e) {
      debugPrint(
        '[CloudCaptureSyncService] GLB download skipped for $recordId '
        'path=$storagePath normalized=$normalizedPath: $e',
      );
      return existingArtifactPath;
    }
  }

  Future<String?> _downloadThumbnail({
    required String bucket,
    required String recordId,
    required String storagePath,
    required String? existingThumbnailPath,
  }) async {
    if (existingThumbnailPath != null &&
        existingThumbnailPath.isNotEmpty &&
        File(existingThumbnailPath).existsSync()) {
      return existingThumbnailPath;
    }
    final out = await _store.thumbnailFileFor(recordId);
    if (await out.exists() && await out.length() > 0) {
      return out.path;
    }
    final normalizedPath = _normalizeStoragePath(
      bucket: bucket,
      storagePath: storagePath,
    );
    if (normalizedPath == null) return existingThumbnailPath;
    try {
      final bytes = await _client.storage.from(bucket).download(normalizedPath);
      await out.writeAsBytes(bytes, flush: true);
      return out.path;
    } catch (e) {
      debugPrint(
        '[CloudCaptureSyncService] thumbnail download skipped for $recordId '
        'bucket=$bucket path=$storagePath normalized=$normalizedPath: $e',
      );
      return existingThumbnailPath;
    }
  }

  String? _normalizeStoragePath({
    required String bucket,
    required String storagePath,
  }) {
    var path = storagePath.trim();
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        debugPrint(
          '[CloudCaptureSyncService] unsupported storage URI skipped: $path',
        );
        return null;
      }
      final segments = uri.pathSegments;
      final bucketIndex = segments.indexOf(bucket);
      if (bucketIndex >= 0 && bucketIndex < segments.length - 1) {
        return segments.skip(bucketIndex + 1).join('/');
      }
    }
    path = path.replaceFirst(RegExp(r'^/+'), '');
    for (final prefix in <String>[
      '$bucket/',
      'object/public/$bucket/',
      'object/sign/$bucket/',
      'storage/v1/object/public/$bucket/',
      'storage/v1/object/sign/$bucket/',
    ]) {
      if (path.startsWith(prefix)) {
        return path.substring(prefix.length);
      }
    }
    return path;
  }

  ScanCloudUploadStatus _statusFor(
    String? scanStatus,
    Map<String, dynamic>? work,
  ) {
    if (work != null) return ScanCloudUploadStatus.completed;
    return ScanCloudUploadStatusWire.fromWireName(scanStatus);
  }

  static Map<String, dynamic> _asStringKeyMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return const <String, dynamic>{};
  }

  static DateTime? _parseDate(Object? value) {
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  static String _shortError(Object e) {
    final s = e.toString();
    return s.length <= 300 ? s : s.substring(0, 300);
  }
}
