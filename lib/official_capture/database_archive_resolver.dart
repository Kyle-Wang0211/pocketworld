import 'dart:io';

import 'database_archive_codec.dart';
import 'database_archive_manifest.dart';
import 'database_archive_policy.dart';
import 'database_archive_transaction.dart';

/// Finds or materializes the exact SQLite database used by official recovery.
class DatabaseArchiveResolver {
  const DatabaseArchiveResolver({required this.codec});

  final DatabaseArchiveCodec codec;

  Future<bool> isRecoverable(Directory captureDirectory) async {
    final source = _sourceFor(captureDirectory);
    if (await source.exists()) return true;
    if (!codec.isSupported ||
        await DatabaseArchivePolicy.readCompatible(captureDirectory) == null) {
      return false;
    }
    final manifest = await DatabaseArchiveManifest.read(captureDirectory);
    if (manifest == null) return false;
    return databaseArchiveFileMatches(
      _archiveFor(captureDirectory),
      length: manifest.archiveBytes,
      sha256Hex: manifest.archiveSha256,
    );
  }

  Future<File?> resolveDatabase(Directory captureDirectory) async {
    final source = _sourceFor(captureDirectory);
    if (await source.exists()) return source;
    if (!codec.isSupported ||
        await DatabaseArchivePolicy.readCompatible(captureDirectory) == null) {
      return null;
    }

    final manifest = await DatabaseArchiveManifest.read(captureDirectory);
    if (manifest == null) return null;
    final archive = _archiveFor(captureDirectory);
    if (!await databaseArchiveFileMatches(
      archive,
      length: manifest.archiveBytes,
      sha256Hex: manifest.archiveSha256,
    )) {
      return null;
    }

    final temporary = File('${source.path}.verify.tmp');
    try {
      await _deleteIfPresent(temporary);
      await codec.decompress(
        sourceArchive: archive,
        destinationDatabase: temporary,
      );
      if (!await databaseArchiveFileMatches(
        temporary,
        length: manifest.sourceBytes,
        sha256Hex: manifest.sourceSha256,
      )) {
        await _deleteIfPresent(temporary);
        return null;
      }
      if (await source.exists()) {
        await _deleteIfPresent(temporary);
        return source;
      }
      await temporary.rename(source.path);
      return source;
    } catch (_) {
      await _deleteIfPresent(temporary);
      return null;
    }
  }

  File _sourceFor(Directory captureDirectory) =>
      File('${captureDirectory.path}/${DatabaseArchivePolicy.sourceFileName}');

  File _archiveFor(Directory captureDirectory) => File(
    '${captureDirectory.path}/${DatabaseArchiveManifest.archiveFileName}',
  );
}

Future<void> _deleteIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Restore fails closed if a stale temporary cannot be removed.
  }
}
