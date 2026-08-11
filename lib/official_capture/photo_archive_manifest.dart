import 'dart:convert';
import 'dart:io';

import 'photo_archive_policy.dart';

enum PhotoArchiveEntryStatus { verified }

class PhotoArchiveEntry {
  const PhotoArchiveEntry({
    required this.sourceRelativePath,
    required this.sourceBytes,
    required this.sourceSha256,
    required this.archiveRelativePath,
    required this.archiveBytes,
    required this.archiveSha256,
    required this.status,
    required this.verifiedAt,
  });

  final String sourceRelativePath;
  final int sourceBytes;
  final String sourceSha256;
  final String archiveRelativePath;
  final int archiveBytes;
  final String archiveSha256;
  final PhotoArchiveEntryStatus status;
  final String verifiedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'source_relative_path': sourceRelativePath,
    'source_bytes': sourceBytes,
    'source_sha256': sourceSha256,
    'archive_relative_path': archiveRelativePath,
    'archive_bytes': archiveBytes,
    'archive_sha256': archiveSha256,
    'status': status.name,
    'verified_at': verifiedAt,
  };

  static PhotoArchiveEntry? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    try {
      final statusName = value['status'] as String? ?? '';
      if (statusName != PhotoArchiveEntryStatus.verified.name) return null;
      final entry = PhotoArchiveEntry(
        sourceRelativePath: value['source_relative_path'] as String,
        sourceBytes: value['source_bytes'] as int,
        sourceSha256: value['source_sha256'] as String,
        archiveRelativePath: value['archive_relative_path'] as String,
        archiveBytes: value['archive_bytes'] as int,
        archiveSha256: value['archive_sha256'] as String,
        status: PhotoArchiveEntryStatus.verified,
        verifiedAt: value['verified_at'] as String,
      );
      if (entry.sourceBytes < 0 ||
          entry.archiveBytes < 0 ||
          entry.sourceSha256.isEmpty ||
          entry.archiveSha256.isEmpty ||
          entry.verifiedAt.isEmpty) {
        return null;
      }
      return entry;
    } on TypeError {
      return null;
    }
  }
}

class PhotoArchiveManifest {
  const PhotoArchiveManifest({
    required this.entries,
    this.schema = schemaV1,
    this.codec = PhotoArchivePolicy.jpegXlCodec,
    this.codecVersion = PhotoArchivePolicy.pinnedLibjxlVersion,
    this.codecRevision = PhotoArchivePolicy.pinnedLibjxlRevision,
  });

  static const fileName = 'official_photo_archive.json';
  static const schemaV1 = 'pw_photo_archive_manifest_v1';
  static const schemaV2 = 'pw_photo_archive_manifest_v2';

  final Map<String, PhotoArchiveEntry> entries;
  final String schema;
  final String codec;
  final String codecVersion;
  final String codecRevision;

  factory PhotoArchiveManifest.forPolicy(
    PhotoArchivePolicy policy, {
    required Map<String, PhotoArchiveEntry> entries,
  }) => PhotoArchiveManifest(
    entries: entries,
    schema: policy.schema == PhotoArchivePolicy.schemaV2 ? schemaV2 : schemaV1,
    codec: policy.codec,
    codecVersion: policy.codecVersion,
    codecRevision: policy.codecRevision,
  );

  bool matchesPolicy(PhotoArchivePolicy policy) =>
      codec == policy.codec &&
      codecVersion == policy.codecVersion &&
      codecRevision == policy.codecRevision &&
      ((schema == schemaV1 && policy.schema == PhotoArchivePolicy.schemaV1) ||
          (schema == schemaV2 && policy.schema == PhotoArchivePolicy.schemaV2));

  PhotoArchiveManifest withEntry(String name, PhotoArchiveEntry entry) {
    return PhotoArchiveManifest(
      entries: <String, PhotoArchiveEntry>{...entries, name: entry},
      schema: schema,
      codec: codec,
      codecVersion: codecVersion,
      codecRevision: codecRevision,
    );
  }

  Map<String, Object?> toJson() {
    final result = <String, Object?>{
      'schema': schema,
      'codec': codec,
      'mode': PhotoArchivePolicy.jpegReconstructionMode,
      'entries': entries.map((name, entry) => MapEntry(name, entry.toJson())),
    };
    if (schema == schemaV1) {
      result['libjxl_revision'] = codecRevision;
    } else {
      result['codec_version'] = codecVersion;
      result['codec_revision'] = codecRevision;
    }
    return result;
  }

  Future<void> writeAtomic(Directory captureDirectory) async {
    final manifest = File('${captureDirectory.path}/$fileName');
    final temporary = File('${manifest.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
    await temporary.rename(manifest.path);
  }

  static Future<PhotoArchiveManifest?> read(Directory captureDirectory) async {
    final manifest = File('${captureDirectory.path}/$fileName');
    try {
      if (!await manifest.exists()) return null;
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['mode'] != PhotoArchivePolicy.jpegReconstructionMode) {
        return null;
      }
      final schema = decoded['schema'] as String? ?? '';
      final codec = decoded['codec'] as String? ?? '';
      late final String codecVersion;
      late final String codecRevision;
      if (schema == schemaV1) {
        codecVersion = PhotoArchivePolicy.pinnedLibjxlVersion;
        codecRevision = decoded['libjxl_revision'] as String? ?? '';
        if (codec != PhotoArchivePolicy.jpegXlCodec ||
            codecRevision != PhotoArchivePolicy.pinnedLibjxlRevision) {
          return null;
        }
      } else if (schema == schemaV2) {
        codecVersion = decoded['codec_version'] as String? ?? '';
        codecRevision = decoded['codec_revision'] as String? ?? '';
        if (codec != PhotoArchivePolicy.leptonCodec ||
            codecVersion != PhotoArchivePolicy.pinnedLeptonVersion ||
            codecRevision != PhotoArchivePolicy.pinnedLeptonRevision) {
          return null;
        }
      } else {
        return null;
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is! Map<String, dynamic>) return null;
      final entries = <String, PhotoArchiveEntry>{};
      for (final item in rawEntries.entries) {
        if (!_isSafeJpegBasename(item.key)) return null;
        final entry = PhotoArchiveEntry.fromJson(item.value);
        if (entry == null) return null;
        entries[item.key] = entry;
      }
      return PhotoArchiveManifest(
        entries: Map.unmodifiable(entries),
        schema: schema,
        codec: codec,
        codecVersion: codecVersion,
        codecRevision: codecRevision,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static Future<List<String>> loadCandidateNames(
    Directory captureDirectory,
  ) async {
    final bundle = File('${captureDirectory.path}/official_photo_bundle.json');
    try {
      if (!await bundle.exists()) return const <String>[];
      final decoded = jsonDecode(await bundle.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != 'aether_photo_bundle_v1' ||
          decoded['photosHighresDir'] != 'photos_highres') {
        return const <String>[];
      }
      final rawFrames = decoded['frames'];
      if (rawFrames is! List) return const <String>[];
      final names = <String>{};
      for (final rawFrame in rawFrames) {
        if (rawFrame is! Map) continue;
        final rawName = rawFrame['highresFilename'];
        if (rawName is String && _isSafeJpegBasename(rawName)) {
          names.add(rawName);
        }
      }
      return List<String>.unmodifiable(names);
    } on FileSystemException {
      return const <String>[];
    } on FormatException {
      return const <String>[];
    }
  }
}

bool _isSafeJpegBasename(String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains(r'\') ||
      name.contains('\u0000')) {
    return false;
  }
  final lower = name.toLowerCase();
  return lower.endsWith('.jpg') || lower.endsWith('.jpeg');
}
