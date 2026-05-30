import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/signed_upload_broker.dart';

class CloudCaptureUploadException implements Exception {
  final String message;
  const CloudCaptureUploadException(this.message);

  @override
  String toString() => 'CloudCaptureUploadException: $message';
}

class CloudCaptureUploadProgress {
  final int uploadedFiles;
  final int totalFiles;
  final String currentObjectPath;

  const CloudCaptureUploadProgress({
    required this.uploadedFiles,
    required this.totalFiles,
    required this.currentObjectPath,
  });
}

class CloudCaptureUploadResult {
  final String scanId;
  final String cloudManifestPath;
  final String? coverThumbnailPath;
  final int uploadedFrameCount;
  final int uploadedFileCount;
  final int totalBytes;
  final DateTime uploadedAt;
  final bool serverAcked;
  final bool checksumConfirmed;
  final bool localRawDeleted;
  final DateTime? localRawDeletedAt;

  const CloudCaptureUploadResult({
    required this.scanId,
    required this.cloudManifestPath,
    required this.coverThumbnailPath,
    required this.uploadedFrameCount,
    required this.uploadedFileCount,
    required this.totalBytes,
    required this.uploadedAt,
    required this.serverAcked,
    required this.checksumConfirmed,
    required this.localRawDeleted,
    required this.localRawDeletedAt,
  });
}

class CloudCaptureFrameSource {
  final int index;
  final File imageFile;
  final File metadataFile;
  final String imageName;
  final String metadataName;
  final int imageBytes;
  final int metadataBytes;
  final String imageSha256;
  final String metadataSha256;

  const CloudCaptureFrameSource({
    required this.index,
    required this.imageFile,
    required this.metadataFile,
    required this.imageName,
    required this.metadataName,
    required this.imageBytes,
    required this.metadataBytes,
    required this.imageSha256,
    required this.metadataSha256,
  });

  int get totalBytes => imageBytes + metadataBytes;

  Map<String, Object?> toCloudJson({
    required String imageStoragePath,
    required String metadataStoragePath,
  }) {
    return <String, Object?>{
      'index': index,
      'image': <String, Object?>{
        'file': imageName,
        'storage_path': imageStoragePath,
        'bytes': imageBytes,
        'sha256': imageSha256,
        'upload_ack': true,
      },
      'metadata': <String, Object?>{
        'file': metadataName,
        'storage_path': metadataStoragePath,
        'bytes': metadataBytes,
        'sha256': metadataSha256,
        'upload_ack': true,
      },
    };
  }
}

class PreparedCloudCaptureManifest {
  final String clientCaptureId;
  final DateTime clientCreatedAt;
  final File localManifestFile;
  final String localManifestSha256;
  final List<CloudCaptureFrameSource> frames;

  const PreparedCloudCaptureManifest({
    required this.clientCaptureId,
    required this.clientCreatedAt,
    required this.localManifestFile,
    required this.localManifestSha256,
    required this.frames,
  });

  int get frameCount => frames.length;
  int get totalBytes => frames.fold<int>(0, (sum, f) => sum + f.totalBytes);

  Map<String, Object?> toCloudJson({
    required String userId,
    required String scanId,
    required String cloudManifestPath,
    required DateTime uploadedAt,
    required List<Map<String, Object?>> cloudFrames,
    String? coverThumbnailPath,
  }) {
    final json = <String, Object?>{
      'schema': 'pocketworld.cloud_capture_manifest.v1',
      'user_id': userId,
      'scan_id': scanId,
      'client_capture_id': clientCaptureId,
      'client_created_at': clientCreatedAt.toIso8601String(),
      'uploaded_at': uploadedAt.toIso8601String(),
      'frame_count': frameCount,
      'total_bytes': totalBytes,
      'cloud_manifest_storage_path': cloudManifestPath,
      'client_manifest': <String, Object?>{
        'file': localManifestFile.uri.pathSegments.last,
        'sha256': localManifestSha256,
      },
      'frames': cloudFrames,
    };
    if (coverThumbnailPath != null) {
      json['cover_thumbnail_path'] = coverThumbnailPath;
    }
    return json;
  }
}

class CloudCaptureManifestPreparer {
  const CloudCaptureManifestPreparer();

  Future<PreparedCloudCaptureManifest> prepare({
    required File captureManifestFile,
    required Directory photosDir,
  }) async {
    if (!await captureManifestFile.exists()) {
      throw CloudCaptureUploadException(
        'capture manifest missing: ${captureManifestFile.path}',
      );
    }
    if (!await photosDir.exists()) {
      throw CloudCaptureUploadException(
        'photos dir missing: ${photosDir.path}',
      );
    }

    final raw = await captureManifestFile.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const CloudCaptureUploadException(
        'capture manifest is not a JSON object',
      );
    }
    final framesRaw = decoded['frames'];
    if (framesRaw is! List) {
      throw const CloudCaptureUploadException(
        'capture manifest has no frames array',
      );
    }

    final clientCaptureId =
        decoded['capture_id'] as String? ??
        _lastNonEmptySegment(captureManifestFile.parent.uri.pathSegments) ??
        'unknown_capture';
    final clientCreatedAt =
        DateTime.tryParse(decoded['created_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    final frames = <CloudCaptureFrameSource>[];
    for (var i = 0; i < framesRaw.length; i++) {
      final item = framesRaw[i];
      if (item is! Map<String, dynamic>) {
        throw CloudCaptureUploadException('frame[$i] is not a JSON object');
      }
      final imageFile = _resolveCaptureFile(
        photosDir: photosDir,
        absolutePath: item['image_path'] as String?,
        fileName: item['image_file'] as String?,
        fallbackExtension: '.jpg',
      );
      final metadataFile = _resolveCaptureFile(
        photosDir: photosDir,
        absolutePath: item['metadata_path'] as String?,
        fileName: item['metadata_file'] as String?,
        fallbackPath: _replaceExtension(imageFile.path, '.json'),
        fallbackExtension: '.json',
      );
      if (!await imageFile.exists()) {
        throw CloudCaptureUploadException(
          'frame[$i] image missing: ${imageFile.path}',
        );
      }
      if (!await metadataFile.exists()) {
        throw CloudCaptureUploadException(
          'frame[$i] metadata missing: ${metadataFile.path}',
        );
      }
      frames.add(
        CloudCaptureFrameSource(
          index: i,
          imageFile: imageFile,
          metadataFile: metadataFile,
          imageName: imageFile.uri.pathSegments.last,
          metadataName: metadataFile.uri.pathSegments.last,
          imageBytes: await imageFile.length(),
          metadataBytes: await metadataFile.length(),
          imageSha256: await sha256ForFile(imageFile),
          metadataSha256: await sha256ForFile(metadataFile),
        ),
      );
    }
    if (frames.isEmpty) {
      throw const CloudCaptureUploadException(
        'capture manifest contains zero frames',
      );
    }

    return PreparedCloudCaptureManifest(
      clientCaptureId: clientCaptureId,
      clientCreatedAt: clientCreatedAt,
      localManifestFile: captureManifestFile,
      localManifestSha256: await sha256ForFile(captureManifestFile),
      frames: frames,
    );
  }

  static File _resolveCaptureFile({
    required Directory photosDir,
    required String? absolutePath,
    required String? fileName,
    required String fallbackExtension,
    String? fallbackPath,
  }) {
    final path = absolutePath?.trim();
    if (path != null && path.isNotEmpty) {
      return File(path);
    }
    final name = fileName?.trim();
    if (name != null && name.isNotEmpty) {
      return File('${photosDir.path}/$name');
    }
    if (fallbackPath != null && fallbackPath.endsWith(fallbackExtension)) {
      return File(fallbackPath);
    }
    throw CloudCaptureUploadException(
      'capture frame missing $fallbackExtension path',
    );
  }
}

class CloudCaptureUploader {
  final SupabaseClient _client;
  final SignedUploadBroker _uploadBroker;
  final CloudCaptureManifestPreparer _preparer;
  final String bucket;

  CloudCaptureUploader({
    SupabaseClient? client,
    SignedUploadBroker? uploadBroker,
    CloudCaptureManifestPreparer preparer =
        const CloudCaptureManifestPreparer(),
    this.bucket = 'scans',
  }) : _client = client ?? Supabase.instance.client,
       _uploadBroker =
           uploadBroker ??
           SignedUploadBroker(client: client ?? Supabase.instance.client),
       _preparer = preparer;

  Future<CloudCaptureUploadResult> uploadDraft({
    required String clientCaptureId,
    required Directory captureDir,
    required Directory photosDir,
    required File captureManifestFile,
    File? thumbnailFile,
    bool deleteLocalOnSuccess = false,
    bool debugKeepLocalRaw = true,
    void Function(CloudCaptureUploadProgress progress)? onProgress,
  }) async {
    final user = _client.auth.currentUser;
    final userId = user?.id;
    if (userId == null || userId.isEmpty) {
      throw const CloudCaptureUploadException(
        'not signed in; keeping capture in local staging',
      );
    }

    String? scanId;
    try {
      final prepared = await _preparer.prepare(
        captureManifestFile: captureManifestFile,
        photosDir: photosDir,
      );

      final inserted = await _client
          .from('scans')
          .insert(<String, Object?>{
            'user_id': userId,
            'status': 'uploading',
            'frames_count': prepared.frameCount,
            'metadata': <String, Object?>{
              'schema': 'pocketworld.cloud_upload.v1',
              'client_capture_id': clientCaptureId,
              'client_frame_count': prepared.frameCount,
              'client_total_bytes': prepared.totalBytes,
              'upload_credential_strategy': 'edge_broker_signed_upload_url_v1',
              'delete_local_after_ack_requested':
                  deleteLocalOnSuccess && !debugKeepLocalRaw,
            },
          })
          .select('id')
          .single();
      scanId = inserted['id'] as String;
      final prefix = '$userId/$scanId';
      final cloudFrames = <Map<String, Object?>>[];
      final uploadedObjects = <Map<String, Object?>>[];
      final totalFiles =
          prepared.frameCount * 2 + 1 + (thumbnailFile == null ? 0 : 1);
      var uploadedFiles = 0;

      void report(String path) {
        uploadedFiles++;
        onProgress?.call(
          CloudCaptureUploadProgress(
            uploadedFiles: uploadedFiles,
            totalFiles: totalFiles,
            currentObjectPath: path,
          ),
        );
      }

      for (final frame in prepared.frames) {
        final imagePath = '$prefix/frames/${frame.imageName}';
        final metadataPath = '$prefix/frames/${frame.metadataName}';
        await _uploadFile(
          storagePath: imagePath,
          file: frame.imageFile,
          contentType: 'image/jpeg',
          sha256: frame.imageSha256,
          bytes: frame.imageBytes,
          role: 'frame_image',
          scanId: scanId,
          clientCaptureId: clientCaptureId,
        );
        uploadedObjects.add(
          _uploadedObject(
            storagePath: imagePath,
            sha256: frame.imageSha256,
            bytes: frame.imageBytes,
            role: 'frame_image',
          ),
        );
        report(imagePath);
        await _uploadFile(
          storagePath: metadataPath,
          file: frame.metadataFile,
          contentType: 'application/json',
          sha256: frame.metadataSha256,
          bytes: frame.metadataBytes,
          role: 'frame_metadata',
          scanId: scanId,
          clientCaptureId: clientCaptureId,
        );
        uploadedObjects.add(
          _uploadedObject(
            storagePath: metadataPath,
            sha256: frame.metadataSha256,
            bytes: frame.metadataBytes,
            role: 'frame_metadata',
          ),
        );
        report(metadataPath);
        cloudFrames.add(
          frame.toCloudJson(
            imageStoragePath: imagePath,
            metadataStoragePath: metadataPath,
          ),
        );
      }

      String? coverThumbnailPath;
      final coverSource = thumbnailFile != null && await thumbnailFile.exists()
          ? thumbnailFile
          : prepared.frames.first.imageFile;
      if (coverSource.existsSync()) {
        final coverBytes = await coverSource.length();
        final coverSha256 = await sha256ForFile(coverSource);
        coverThumbnailPath = '$prefix/preview/cover.jpg';
        await _uploadFile(
          storagePath: coverThumbnailPath,
          file: coverSource,
          contentType: 'image/jpeg',
          sha256: coverSha256,
          bytes: coverBytes,
          role: 'cover_thumbnail',
          scanId: scanId,
          clientCaptureId: clientCaptureId,
        );
        uploadedObjects.add(
          _uploadedObject(
            storagePath: coverThumbnailPath,
            sha256: coverSha256,
            bytes: coverBytes,
            role: 'cover_thumbnail',
          ),
        );
        report(coverThumbnailPath);
      }

      final cloudManifestPath = '$prefix/manifest/capture_manifest.json';
      final uploadedAt = DateTime.now().toUtc();
      final cloudManifest = prepared.toCloudJson(
        userId: userId,
        scanId: scanId,
        cloudManifestPath: cloudManifestPath,
        uploadedAt: uploadedAt,
        cloudFrames: cloudFrames,
        coverThumbnailPath: coverThumbnailPath,
      );
      final manifestBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(cloudManifest)),
      );
      final cloudManifestSha256 = crypto.sha256
          .convert(manifestBytes)
          .toString();
      await _uploadBytes(
        storagePath: cloudManifestPath,
        bytesData: manifestBytes,
        contentType: 'application/json',
        sha256: cloudManifestSha256,
        bytes: manifestBytes.length,
        role: 'cloud_manifest',
        scanId: scanId,
        clientCaptureId: clientCaptureId,
      );
      uploadedObjects.add(
        _uploadedObject(
          storagePath: cloudManifestPath,
          sha256: cloudManifestSha256,
          bytes: manifestBytes.length,
          role: 'cloud_manifest',
        ),
      );
      report(cloudManifestPath);

      final scanUpdate = <String, Object?>{
        'status': 'pending',
        'frames_count': prepared.frameCount,
        'raw_storage_path': cloudManifestPath,
        'metadata': <String, Object?>{
          'schema': 'pocketworld.cloud_upload.v1',
          'client_capture_id': clientCaptureId,
          'cloud_manifest_storage_path': cloudManifestPath,
          'uploaded_at': uploadedAt.toIso8601String(),
          'frame_count': prepared.frameCount,
          'total_bytes': prepared.totalBytes,
          'upload_credential_strategy': 'edge_broker_signed_upload_url_v1',
          'upload_credential_expires_seconds': 60,
          'checksum_source': 'client_sha256_manifest',
          'uploaded_objects': uploadedObjects,
          'server_ack_required': true,
          'local_raw_retention': debugKeepLocalRaw
              ? 'retained_for_beta_debug'
              : (deleteLocalOnSuccess ? 'delete_after_ack' : 'retained'),
        },
      };
      if (coverThumbnailPath != null) {
        scanUpdate['cover_thumbnail_path'] = coverThumbnailPath;
      }
      await _client.from('scans').update(scanUpdate).eq('id', scanId);

      final ackRaw = await _client.rpc(
        'ack_scan_upload',
        params: <String, Object?>{'p_scan_id': scanId},
      );
      final ack = Map<String, dynamic>.from(ackRaw as Map);
      final serverAcked = ack['acknowledged'] == true;
      final checksumConfirmed = ack['checksum_confirmed'] == true;
      if (!serverAcked || !checksumConfirmed) {
        throw CloudCaptureUploadException(
          'cloud upload ack did not confirm checksums; keeping local staging',
        );
      }

      var localRawDeleted = false;
      DateTime? localRawDeletedAt;
      if (deleteLocalOnSuccess && !debugKeepLocalRaw) {
        try {
          await captureDir.delete(recursive: true);
          localRawDeleted = true;
          localRawDeletedAt = DateTime.now().toUtc();
          try {
            await _client.rpc(
              'mark_scan_local_raw_deleted',
              params: <String, Object?>{'p_scan_id': scanId},
            );
          } catch (e) {
            debugPrint(
              '[CloudCaptureUploader] mark local raw deleted skipped: $e',
            );
          }
        } catch (e) {
          debugPrint(
            '[CloudCaptureUploader] local raw delete failed; keeping staging: $e',
          );
        }
      }

      debugPrint(
        '[CloudCaptureUploader] uploaded capture=$clientCaptureId '
        'scan=$scanId frames=${prepared.frameCount} bytes=${prepared.totalBytes}',
      );
      return CloudCaptureUploadResult(
        scanId: scanId,
        cloudManifestPath: cloudManifestPath,
        coverThumbnailPath: coverThumbnailPath,
        uploadedFrameCount: prepared.frameCount,
        uploadedFileCount: uploadedFiles,
        totalBytes: prepared.totalBytes,
        uploadedAt: uploadedAt,
        serverAcked: serverAcked,
        checksumConfirmed: checksumConfirmed,
        localRawDeleted: localRawDeleted,
        localRawDeletedAt: localRawDeletedAt,
      );
    } catch (e) {
      if (scanId != null) {
        await _markScanFailed(scanId, e);
      }
      rethrow;
    }
  }

  Future<void> _uploadFile({
    required String storagePath,
    required File file,
    required String contentType,
    required String sha256,
    required int bytes,
    required String role,
    required String scanId,
    required String clientCaptureId,
  }) async {
    final storage = _client.storage.from(bucket);
    final credential = await _uploadBroker.createCredential(
      bucket: bucket,
      path: storagePath,
      contentType: contentType,
      bytes: bytes,
      role: role,
      scanId: scanId,
      clientCaptureId: clientCaptureId,
      sha256: sha256,
    );
    await storage.uploadToSignedUrl(
      storagePath,
      credential.token,
      file,
      _fileOptions(
        contentType: contentType,
        sha256: sha256,
        bytes: bytes,
        role: role,
        scanId: scanId,
        clientCaptureId: clientCaptureId,
      ),
    );
  }

  Future<void> _uploadBytes({
    required String storagePath,
    required Uint8List bytesData,
    required String contentType,
    required String sha256,
    required int bytes,
    required String role,
    required String scanId,
    required String clientCaptureId,
  }) async {
    final storage = _client.storage.from(bucket);
    final credential = await _uploadBroker.createCredential(
      bucket: bucket,
      path: storagePath,
      contentType: contentType,
      bytes: bytes,
      role: role,
      scanId: scanId,
      clientCaptureId: clientCaptureId,
      sha256: sha256,
    );
    await storage.uploadBinaryToSignedUrl(
      storagePath,
      credential.token,
      bytesData,
      _fileOptions(
        contentType: contentType,
        sha256: sha256,
        bytes: bytes,
        role: role,
        scanId: scanId,
        clientCaptureId: clientCaptureId,
      ),
    );
  }

  Future<void> _markScanFailed(String scanId, Object error) async {
    try {
      await _client
          .from('scans')
          .update(<String, Object?>{
            'status': 'failed',
            'error_message': _compactError(error),
          })
          .eq('id', scanId);
    } catch (e) {
      debugPrint('[CloudCaptureUploader] mark failed skipped: $e');
    }
  }
}

FileOptions _fileOptions({
  required String contentType,
  required String sha256,
  required int bytes,
  required String role,
  required String scanId,
  required String clientCaptureId,
}) {
  return FileOptions(
    contentType: contentType,
    upsert: true,
    metadata: <String, Object?>{
      'sha256': sha256,
      'bytes': bytes,
      'role': role,
      'scan_id': scanId,
      'client_capture_id': clientCaptureId,
      'upload_credential_strategy': 'edge_broker_signed_upload_url_v1',
    },
  );
}

@visibleForTesting
Future<String> sha256ForFile(File file) async {
  final digest = crypto.sha256.convert(await file.readAsBytes());
  return digest.toString();
}

String _replaceExtension(String path, String extension) {
  final idx = path.lastIndexOf('.');
  if (idx <= path.lastIndexOf('/')) return '$path$extension';
  return '${path.substring(0, idx)}$extension';
}

String? _lastNonEmptySegment(List<String> segments) {
  for (var i = segments.length - 1; i >= 0; i--) {
    final segment = segments[i];
    if (segment.isNotEmpty) return segment;
  }
  return null;
}

String _compactError(Object error) {
  final text = error.toString();
  if (text.length <= 500) return text;
  return text.substring(0, 500);
}

Map<String, Object?> _uploadedObject({
  required String storagePath,
  required String sha256,
  required int bytes,
  required String role,
}) {
  return <String, Object?>{
    'storage_path': storagePath,
    'sha256': sha256,
    'bytes': bytes,
    'role': role,
    'upload_credential_strategy': 'edge_broker_signed_upload_url_v1',
  };
}
