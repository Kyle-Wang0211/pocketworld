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
  const PhotoArchiveManifest({required this.entries});

  static const fileName = 'official_photo_archive.json';
  static const schemaV1 = 'pw_photo_archive_manifest_v1';

  final Map<String, PhotoArchiveEntry> entries;

  PhotoArchiveManifest withEntry(String name, PhotoArchiveEntry entry) {
    return PhotoArchiveManifest(
      entries: <String, PhotoArchiveEntry>{...entries, name: entry},
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schemaV1,
    'codec': PhotoArchivePolicy.jpegXlCodec,
    'mode': PhotoArchivePolicy.jpegReconstructionMode,
    'libjxl_revision': PhotoArchivePolicy.pinnedLibjxlRevision,
    'entries': entries.map((name, entry) => MapEntry(name, entry.toJson())),
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

  static Future<PhotoArchiveManifest?> read(Directory captureDirectory) async {
    final manifest = File('${captureDirectory.path}/$fileName');
    try {
      if (!await manifest.exists()) return null;
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != schemaV1 ||
          decoded['codec'] != PhotoArchivePolicy.jpegXlCodec ||
          decoded['mode'] != PhotoArchivePolicy.jpegReconstructionMode ||
          decoded['libjxl_revision'] !=
              PhotoArchivePolicy.pinnedLibjxlRevision) {
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
      return PhotoArchiveManifest(entries: Map.unmodifiable(entries));
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
