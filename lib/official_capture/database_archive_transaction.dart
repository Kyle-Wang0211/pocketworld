import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'database_archive_codec.dart';
import 'database_archive_manifest.dart';
import 'database_archive_policy.dart';

typedef DatabaseArchiveCommitHook = Future<void> Function(File sourceDatabase);
typedef DatabaseArchiveContinueCheck = FutureOr<bool> Function();

class DatabaseArchiveRunResult {
  const DatabaseArchiveRunResult({
    this.eligible = true,
    this.archived = false,
    this.skipped = false,
    this.failed = false,
    this.interrupted = false,
  });

  final bool eligible;
  final bool archived;
  final bool skipped;
  final bool failed;
  final bool interrupted;
}

/// Executes the source-last archive transaction for one official database.
class DatabaseArchiveTransaction {
  const DatabaseArchiveTransaction({
    required this.codec,
    this.afterManifestCommitted,
    this.canContinue,
  });

  final DatabaseArchiveCodec codec;
  final DatabaseArchiveCommitHook? afterManifestCommitted;
  final DatabaseArchiveContinueCheck? canContinue;

  Future<DatabaseArchiveRunResult> archiveCapture(
    Directory captureDirectory,
  ) async {
    final policy = await DatabaseArchivePolicy.readCompatible(captureDirectory);
    if (policy == null || !codec.isSupported) {
      return const DatabaseArchiveRunResult(eligible: false);
    }
    if (!await _hasDurableFinalArtifacts(captureDirectory)) {
      return const DatabaseArchiveRunResult(skipped: true);
    }

    final source = File(
      '${captureDirectory.path}/${DatabaseArchivePolicy.sourceFileName}',
    );
    final archive = File(
      '${captureDirectory.path}/${DatabaseArchiveManifest.archiveFileName}',
    );
    final archiveTemporary = File('${archive.path}.tmp');
    final verificationTemporary = File('${source.path}.verify.tmp');

    await _deleteIfPresent(archiveTemporary);
    await _deleteIfPresent(verificationTemporary);

    for (final suffix in const <String>['-wal', '-shm', '-journal']) {
      if (await File('${source.path}$suffix').exists()) {
        return const DatabaseArchiveRunResult(skipped: true);
      }
    }

    try {
      final manifest = await DatabaseArchiveManifest.read(captureDirectory);
      if (manifest != null) {
        final archiveMatches = await databaseArchiveFileMatches(
          archive,
          length: manifest.archiveBytes,
          sha256Hex: manifest.archiveSha256,
        );
        if (!await source.exists()) {
          return DatabaseArchiveRunResult(
            archived: archiveMatches,
            failed: !archiveMatches,
          );
        }
        final sourceMatches = await databaseArchiveFileMatches(
          source,
          length: manifest.sourceBytes,
          sha256Hex: manifest.sourceSha256,
        );
        if (archiveMatches && sourceMatches) {
          final reconciled = await _reconcileCommitted(
            source: source,
            archive: archive,
            verificationTemporary: verificationTemporary,
            manifest: manifest,
          );
          if (reconciled) {
            return const DatabaseArchiveRunResult(archived: true);
          }
        }
      }

      if (!await source.exists()) {
        return const DatabaseArchiveRunResult(failed: true);
      }
      if (!await _mayContinue()) {
        return const DatabaseArchiveRunResult(interrupted: true);
      }

      final sourceBytes = await source.length();
      if (sourceBytes <= 0) {
        return const DatabaseArchiveRunResult(skipped: true);
      }
      final sourceSha256 = await databaseArchiveSha256(source);

      await codec.compress(
        sourceDatabase: source,
        destinationArchive: archiveTemporary,
      );
      if (!await archiveTemporary.exists()) {
        throw const FileSystemException('ZPAQ encoder produced no output');
      }
      if (!await _mayContinue()) {
        await _deleteIfPresent(archiveTemporary);
        return const DatabaseArchiveRunResult(interrupted: true);
      }

      await codec.decompress(
        sourceArchive: archiveTemporary,
        destinationDatabase: verificationTemporary,
      );
      if (!await databaseArchiveFilesEqual(source, verificationTemporary) ||
          !await databaseArchiveFileMatches(
            verificationTemporary,
            length: sourceBytes,
            sha256Hex: sourceSha256,
          )) {
        throw const FileSystemException(
          'ZPAQ reconstruction differs from source bytes',
        );
      }

      final archiveBytes = await archiveTemporary.length();
      if (archiveBytes >= sourceBytes) {
        await _deleteIfPresent(archiveTemporary);
        await _deleteIfPresent(verificationTemporary);
        return const DatabaseArchiveRunResult(skipped: true);
      }
      if (!await _mayContinue()) {
        await _deleteIfPresent(archiveTemporary);
        await _deleteIfPresent(verificationTemporary);
        return const DatabaseArchiveRunResult(interrupted: true);
      }

      final archiveSha256 = await databaseArchiveSha256(archiveTemporary);
      await _deleteIfPresent(archive);
      await archiveTemporary.rename(archive.path);
      final nextManifest = DatabaseArchiveManifest(
        sourceBytes: sourceBytes,
        sourceSha256: sourceSha256,
        archiveBytes: archiveBytes,
        archiveSha256: archiveSha256,
        verifiedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await nextManifest.writeAtomic(captureDirectory);
      await afterManifestCommitted?.call(source);
      await source.delete();
      await _deleteIfPresent(verificationTemporary);
      return const DatabaseArchiveRunResult(archived: true);
    } on DatabaseArchiveCancelled {
      await _deleteIfPresent(archiveTemporary);
      await _deleteIfPresent(verificationTemporary);
      return const DatabaseArchiveRunResult(interrupted: true);
    } catch (_) {
      await _deleteIfPresent(archiveTemporary);
      await _deleteIfPresent(verificationTemporary);
      return const DatabaseArchiveRunResult(failed: true);
    }
  }

  Future<bool> _reconcileCommitted({
    required File source,
    required File archive,
    required File verificationTemporary,
    required DatabaseArchiveManifest manifest,
  }) async {
    if (!await _mayContinue()) return false;
    await codec.decompress(
      sourceArchive: archive,
      destinationDatabase: verificationTemporary,
    );
    final verified =
        await databaseArchiveFilesEqual(source, verificationTemporary) &&
        await databaseArchiveFileMatches(
          verificationTemporary,
          length: manifest.sourceBytes,
          sha256Hex: manifest.sourceSha256,
        );
    if (!verified || !await _mayContinue()) {
      await _deleteIfPresent(verificationTemporary);
      return false;
    }
    await source.delete();
    await _deleteIfPresent(verificationTemporary);
    return true;
  }

  Future<bool> _mayContinue() async {
    final check = canContinue;
    return check == null || await check();
  }
}

Future<bool> _hasDurableFinalArtifacts(Directory captureDirectory) async {
  for (final name in const <String>[
    'official_sfm_sparse.ply',
    'official_sfm_sparse_meta.json',
  ]) {
    final file = File('${captureDirectory.path}/$name');
    try {
      if (!await file.exists() || await file.length() == 0) return false;
    } on FileSystemException {
      return false;
    }
  }
  return true;
}

Future<String> databaseArchiveSha256(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<bool> databaseArchiveFileMatches(
  File file, {
  required int length,
  required String sha256Hex,
}) async {
  try {
    if (!await file.exists() || await file.length() != length) return false;
    return await databaseArchiveSha256(file) == sha256Hex;
  } on FileSystemException {
    return false;
  }
}

Future<bool> databaseArchiveFilesEqual(File left, File right) async {
  if (!await left.exists() || !await right.exists()) return false;
  if (await left.length() != await right.length()) return false;
  final leftHandle = await left.open();
  final rightHandle = await right.open();
  try {
    const chunkSize = 256 * 1024;
    while (true) {
      final leftBytes = await leftHandle.read(chunkSize);
      final rightBytes = await rightHandle.read(chunkSize);
      if (leftBytes.length != rightBytes.length) return false;
      if (leftBytes.isEmpty) return true;
      for (var index = 0; index < leftBytes.length; index++) {
        if (leftBytes[index] != rightBytes[index]) return false;
      }
    }
  } finally {
    await leftHandle.close();
    await rightHandle.close();
  }
}

Future<void> _deleteIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // The caller fails closed while the raw source remains authoritative.
  }
}
