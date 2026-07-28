import 'dart:io';

import 'package:crypto/crypto.dart';

import 'photo_archive_codec.dart';
import 'photo_archive_manifest.dart';

/// Resolves an authoritative high-resolution JPEG without weakening integrity.
class PhotoArchiveResolver {
  const PhotoArchiveResolver({required this.codec});

  final PhotoArchiveCodec codec;

  Future<File?> resolveJpeg({
    required Directory captureDirectory,
    required String highresFilename,
    required Directory cacheDirectory,
  }) async {
    final candidates = await PhotoArchiveManifest.loadCandidateNames(
      captureDirectory,
    );
    if (!candidates.contains(highresFilename)) return null;

    final source = File(
      '${captureDirectory.path}/photos_highres/$highresFilename',
    );
    if (await source.exists()) return source;
    if (!codec.isSupported) return null;

    final manifest = await PhotoArchiveManifest.read(captureDirectory);
    final entry = manifest?.entries[highresFilename];
    if (entry == null ||
        entry.sourceRelativePath != 'photos_highres/$highresFilename' ||
        entry.archiveRelativePath != 'photos_highres/$highresFilename.jxl') {
      return null;
    }
    final archive = File(
      '${captureDirectory.path}/${entry.archiveRelativePath}',
    );
    if (!await _matches(
      archive,
      length: entry.archiveBytes,
      sha256Hex: entry.archiveSha256,
    )) {
      return null;
    }

    await cacheDirectory.create(recursive: true);
    final cached = File(
      '${cacheDirectory.path}/${entry.sourceSha256}_$highresFilename',
    );
    if (await _matches(
      cached,
      length: entry.sourceBytes,
      sha256Hex: entry.sourceSha256,
    )) {
      return cached;
    }
    final temporary = File('${cached.path}.tmp');
    try {
      await _deleteIfPresent(cached);
      await _deleteIfPresent(temporary);
      await codec.reconstructJpeg(
        sourceJxl: archive,
        destinationJpeg: temporary,
      );
      if (!await _matches(
        temporary,
        length: entry.sourceBytes,
        sha256Hex: entry.sourceSha256,
      )) {
        await _deleteIfPresent(temporary);
        return null;
      }
      await temporary.rename(cached.path);
      return cached;
    } catch (_) {
      await _deleteIfPresent(temporary);
      return null;
    }
  }
}

Future<bool> _matches(
  File file, {
  required int length,
  required String sha256Hex,
}) async {
  try {
    if (!await file.exists() || await file.length() != length) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == sha256Hex;
  } on FileSystemException {
    return false;
  }
}

Future<void> _deleteIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // The caller fails closed if a stale file cannot be replaced.
  }
}
