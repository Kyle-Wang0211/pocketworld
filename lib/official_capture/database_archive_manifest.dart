import 'dart:convert';
import 'dart:io';

import 'database_archive_policy.dart';
import 'database_archive_preprocessor.dart';

/// Durable proof for the single official SQLite database archive.
class DatabaseArchiveManifest {
  const DatabaseArchiveManifest({
    required this.sourceBytes,
    required this.sourceSha256,
    required this.archiveBytes,
    required this.archiveSha256,
    required this.verifiedAt,
    this.preprocess = DatabaseArchivePreprocess.rawV1,
    this.rawArchiveBytes,
    this.trackArchiveBytes,
  });

  static const fileName = 'official_database_archive.json';
  static const schemaV1 = 'pw_official_database_archive_manifest_v1';
  static const schemaV2 = 'pw_official_database_archive_manifest_v2';
  static const archiveFileName = 'official_sfm_live.db.zpaq';

  final int sourceBytes;
  final String sourceSha256;
  final int archiveBytes;
  final String archiveSha256;
  final String verifiedAt;
  final String preprocess;
  final int? rawArchiveBytes;
  final int? trackArchiveBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schemaV2,
    'source_file': DatabaseArchivePolicy.sourceFileName,
    'archive_file': archiveFileName,
    'codec': DatabaseArchivePolicy.codecName,
    'version': DatabaseArchivePolicy.version715,
    'revision': DatabaseArchivePolicy.pinnedRevision,
    'method': DatabaseArchivePolicy.method5,
    'source_bytes': sourceBytes,
    'source_sha256': sourceSha256,
    'archive_bytes': archiveBytes,
    'archive_sha256': archiveSha256,
    'preprocess': preprocess,
    'candidate_bytes': <String, Object?>{
      if (rawArchiveBytes != null ||
          preprocess == DatabaseArchivePreprocess.rawV1)
        DatabaseArchivePreprocess.rawV1: rawArchiveBytes ?? archiveBytes,
      if (trackArchiveBytes != null)
        DatabaseArchivePreprocess.trackDeltaV1: trackArchiveBytes,
    },
    'verified_at': verifiedAt,
  };

  Future<void> writeAtomic(Directory captureDirectory) async {
    final manifest = File('${captureDirectory.path}/$fileName');
    final temporary = File('${manifest.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
    await temporary.rename(manifest.path);
  }

  static Future<DatabaseArchiveManifest?> read(
    Directory captureDirectory,
  ) async {
    final file = File('${captureDirectory.path}/$fileName');
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          (decoded['schema'] != schemaV1 && decoded['schema'] != schemaV2) ||
          decoded['source_file'] != DatabaseArchivePolicy.sourceFileName ||
          decoded['archive_file'] != archiveFileName ||
          decoded['codec'] != DatabaseArchivePolicy.codecName ||
          decoded['version'] != DatabaseArchivePolicy.version715 ||
          decoded['revision'] != DatabaseArchivePolicy.pinnedRevision ||
          decoded['method'] != DatabaseArchivePolicy.method5) {
        return null;
      }
      final isV1 = decoded['schema'] == schemaV1;
      final preprocess = isV1
          ? DatabaseArchivePreprocess.rawV1
          : decoded['preprocess'] as String;
      final candidateBytes = isV1
          ? null
          : decoded['candidate_bytes'] as Map<String, dynamic>;
      final manifest = DatabaseArchiveManifest(
        sourceBytes: decoded['source_bytes'] as int,
        sourceSha256: decoded['source_sha256'] as String,
        archiveBytes: decoded['archive_bytes'] as int,
        archiveSha256: decoded['archive_sha256'] as String,
        verifiedAt: decoded['verified_at'] as String,
        preprocess: preprocess,
        rawArchiveBytes: isV1
            ? decoded['archive_bytes'] as int
            : candidateBytes?[DatabaseArchivePreprocess.rawV1] as int?,
        trackArchiveBytes: isV1
            ? null
            : candidateBytes?[DatabaseArchivePreprocess.trackDeltaV1] as int?,
      );
      if (manifest.sourceBytes < 0 ||
          manifest.archiveBytes < 0 ||
          !_isSha256(manifest.sourceSha256) ||
          !_isSha256(manifest.archiveSha256) ||
          !DatabaseArchivePreprocess.isSupported(manifest.preprocess) ||
          (manifest.rawArchiveBytes != null && manifest.rawArchiveBytes! < 0) ||
          (manifest.trackArchiveBytes != null &&
              manifest.trackArchiveBytes! < 0) ||
          (manifest.preprocess == DatabaseArchivePreprocess.rawV1 &&
              manifest.rawArchiveBytes != manifest.archiveBytes) ||
          (manifest.preprocess == DatabaseArchivePreprocess.trackDeltaV1 &&
              manifest.trackArchiveBytes != manifest.archiveBytes) ||
          DateTime.tryParse(manifest.verifiedAt) == null) {
        return null;
      }
      return manifest;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
