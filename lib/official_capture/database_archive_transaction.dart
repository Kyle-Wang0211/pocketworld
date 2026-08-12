import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'database_archive_codec.dart';
import 'database_archive_manifest.dart';
import 'database_archive_policy.dart';
import 'database_archive_preprocessor.dart';

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
    this.preprocessor,
    this.afterManifestCommitted,
    this.canContinue,
  });

  final DatabaseArchiveCodec codec;
  final DatabaseArchivePreprocessor? preprocessor;
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
    final rawArchiveTemporary = File(
      preprocessor == null
          ? '${archive.path}.tmp'
          : '${source.path}.raw.zpaq.tmp',
    );
    final trackDatabaseTemporary = File('${source.path}.track.db.tmp');
    final trackArchiveTemporary = File('${source.path}.track.zpaq.tmp');
    final decodedTemporary = File('${source.path}.preprocessed.tmp');
    final verificationTemporary = File('${source.path}.verify.tmp');
    final temporaryFiles = <File>[
      rawArchiveTemporary,
      trackDatabaseTemporary,
      trackArchiveTemporary,
      decodedTemporary,
      verificationTemporary,
    ];

    await _deleteAll(temporaryFiles);

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
          final restorable = _canRestore(manifest);
          return DatabaseArchiveRunResult(
            archived: archiveMatches && restorable,
            failed: !archiveMatches || !restorable,
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
            decodedTemporary: decodedTemporary,
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
      await _requireMayContinue();

      final sourceBytes = await source.length();
      if (sourceBytes <= 0) {
        return const DatabaseArchiveRunResult(skipped: true);
      }
      final sourceSha256 = await databaseArchiveSha256(source);

      final rawCandidate = await _buildRawCandidate(
        source: source,
        archiveTemporary: rawArchiveTemporary,
        verificationTemporary: verificationTemporary,
        sourceBytes: sourceBytes,
        sourceSha256: sourceSha256,
      );
      final trackCandidate = await _tryBuildTrackCandidate(
        source: source,
        transformedTemporary: trackDatabaseTemporary,
        archiveTemporary: trackArchiveTemporary,
        decodedTemporary: decodedTemporary,
        verificationTemporary: verificationTemporary,
        sourceBytes: sourceBytes,
        sourceSha256: sourceSha256,
      );
      if (!await databaseArchiveFileMatches(
        source,
        length: sourceBytes,
        sha256Hex: sourceSha256,
      )) {
        throw const FileSystemException(
          'SQLite preprocessing changed the source database',
        );
      }

      final candidates =
          <_DatabaseArchiveCandidate>[rawCandidate, ?trackCandidate]
              .where((candidate) => candidate.archiveBytes < sourceBytes)
              .toList()
            ..sort((left, right) {
              final size = left.archiveBytes.compareTo(right.archiveBytes);
              if (size != 0) return size;
              return left.preprocess == DatabaseArchivePreprocess.rawV1
                  ? -1
                  : 1;
            });
      if (candidates.isEmpty) {
        await _deleteAll(temporaryFiles);
        return const DatabaseArchiveRunResult(skipped: true);
      }
      await _requireMayContinue();

      final selected = candidates.first;
      final archiveSha256 = await databaseArchiveSha256(selected.file);
      await _deleteIfPresent(archive);
      await selected.file.rename(archive.path);
      final nextManifest = DatabaseArchiveManifest(
        sourceBytes: sourceBytes,
        sourceSha256: sourceSha256,
        archiveBytes: selected.archiveBytes,
        archiveSha256: archiveSha256,
        verifiedAt: DateTime.now().toUtc().toIso8601String(),
        preprocess: selected.preprocess,
        rawArchiveBytes: rawCandidate.archiveBytes,
        trackArchiveBytes: trackCandidate?.archiveBytes,
      );
      await nextManifest.writeAtomic(captureDirectory);
      await afterManifestCommitted?.call(source);
      await _deleteAll(temporaryFiles);
      await _requireMayContinue();
      await source.delete();
      return const DatabaseArchiveRunResult(archived: true);
    } on DatabaseArchiveCancelled {
      await _deleteAll(temporaryFiles);
      return const DatabaseArchiveRunResult(interrupted: true);
    } catch (_) {
      await _deleteAll(temporaryFiles);
      return const DatabaseArchiveRunResult(failed: true);
    }
  }

  Future<_DatabaseArchiveCandidate> _buildRawCandidate({
    required File source,
    required File archiveTemporary,
    required File verificationTemporary,
    required int sourceBytes,
    required String sourceSha256,
  }) async {
    await codec.compress(
      sourceDatabase: source,
      destinationArchive: archiveTemporary,
    );
    await _requireArchive(archiveTemporary);
    await _requireMayContinue();
    await codec.decompress(
      sourceArchive: archiveTemporary,
      destinationDatabase: verificationTemporary,
    );
    await _requireExactSource(
      source: source,
      restored: verificationTemporary,
      sourceBytes: sourceBytes,
      sourceSha256: sourceSha256,
    );
    final archiveBytes = await archiveTemporary.length();
    await _deleteIfPresent(verificationTemporary);
    return _DatabaseArchiveCandidate(
      preprocess: DatabaseArchivePreprocess.rawV1,
      file: archiveTemporary,
      archiveBytes: archiveBytes,
    );
  }

  Future<_DatabaseArchiveCandidate?> _tryBuildTrackCandidate({
    required File source,
    required File transformedTemporary,
    required File archiveTemporary,
    required File decodedTemporary,
    required File verificationTemporary,
    required int sourceBytes,
    required String sourceSha256,
  }) async {
    final transformer = preprocessor;
    if (transformer == null || !transformer.isSupported) return null;
    try {
      await _requireMayContinue();
      await transformer.transformTrackDelta(
        sourceDatabase: source,
        destinationDatabase: transformedTemporary,
      );
      await _requireMayContinue();
      await codec.compress(
        sourceDatabase: transformedTemporary,
        destinationArchive: archiveTemporary,
      );
      await _requireArchive(archiveTemporary);
      await _requireMayContinue();
      await codec.decompress(
        sourceArchive: archiveTemporary,
        destinationDatabase: decodedTemporary,
      );
      await transformer.restoreTrackDelta(
        sourceDatabase: decodedTemporary,
        destinationDatabase: verificationTemporary,
      );
      await _requireExactSource(
        source: source,
        restored: verificationTemporary,
        sourceBytes: sourceBytes,
        sourceSha256: sourceSha256,
      );
      final archiveBytes = await archiveTemporary.length();
      return _DatabaseArchiveCandidate(
        preprocess: DatabaseArchivePreprocess.trackDeltaV1,
        file: archiveTemporary,
        archiveBytes: archiveBytes,
      );
    } on DatabaseArchiveCancelled {
      rethrow;
    } catch (_) {
      await _deleteIfPresent(archiveTemporary);
      return null;
    } finally {
      await _deleteIfPresent(transformedTemporary);
      await _deleteIfPresent(decodedTemporary);
      await _deleteIfPresent(verificationTemporary);
    }
  }

  Future<void> _requireArchive(File archive) async {
    if (!await archive.exists() || await archive.length() == 0) {
      throw const FileSystemException('ZPAQ encoder produced no output');
    }
  }

  Future<void> _requireExactSource({
    required File source,
    required File restored,
    required int sourceBytes,
    required String sourceSha256,
  }) async {
    if (!await databaseArchiveFilesEqual(source, restored) ||
        !await databaseArchiveFileMatches(
          restored,
          length: sourceBytes,
          sha256Hex: sourceSha256,
        )) {
      throw const FileSystemException(
        'ZPAQ reconstruction differs from source bytes',
      );
    }
  }

  Future<bool> _reconcileCommitted({
    required File source,
    required File archive,
    required File decodedTemporary,
    required File verificationTemporary,
    required DatabaseArchiveManifest manifest,
  }) async {
    if (!await _mayContinue()) return false;
    if (!_canRestore(manifest)) return false;
    if (manifest.preprocess == DatabaseArchivePreprocess.rawV1) {
      await codec.decompress(
        sourceArchive: archive,
        destinationDatabase: verificationTemporary,
      );
    } else {
      await codec.decompress(
        sourceArchive: archive,
        destinationDatabase: decodedTemporary,
      );
      await preprocessor!.restoreTrackDelta(
        sourceDatabase: decodedTemporary,
        destinationDatabase: verificationTemporary,
      );
    }
    final verified =
        await databaseArchiveFilesEqual(source, verificationTemporary) &&
        await databaseArchiveFileMatches(
          verificationTemporary,
          length: manifest.sourceBytes,
          sha256Hex: manifest.sourceSha256,
        );
    if (!verified || !await _mayContinue()) {
      await _deleteIfPresent(decodedTemporary);
      await _deleteIfPresent(verificationTemporary);
      return false;
    }
    await source.delete();
    await _deleteIfPresent(decodedTemporary);
    await _deleteIfPresent(verificationTemporary);
    return true;
  }

  bool _canRestore(DatabaseArchiveManifest manifest) =>
      manifest.preprocess == DatabaseArchivePreprocess.rawV1 ||
      (manifest.preprocess == DatabaseArchivePreprocess.trackDeltaV1 &&
          preprocessor?.isSupported == true);

  Future<void> _requireMayContinue() async {
    if (!await _mayContinue()) throw const DatabaseArchiveCancelled();
  }

  Future<bool> _mayContinue() async {
    final check = canContinue;
    return check == null || await check();
  }
}

class _DatabaseArchiveCandidate {
  const _DatabaseArchiveCandidate({
    required this.preprocess,
    required this.file,
    required this.archiveBytes,
  });

  final String preprocess;
  final File file;
  final int archiveBytes;
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

Future<void> _deleteAll(Iterable<File> files) async {
  for (final file in files) {
    await _deleteIfPresent(file);
  }
}
