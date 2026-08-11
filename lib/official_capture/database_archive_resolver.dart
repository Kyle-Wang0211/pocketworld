import 'dart:io';

import 'database_archive_codec.dart';
import 'database_archive_manifest.dart';
import 'database_archive_policy.dart';
import 'database_archive_preprocessor.dart';
import 'database_archive_transaction.dart';
import 'database_recipe_transaction.dart';
import 'sfm_db_regen.dart';

/// Finds or materializes the exact SQLite database used by official recovery.
class DatabaseArchiveResolver {
  const DatabaseArchiveResolver({required this.codec, this.preprocessor});

  final DatabaseArchiveCodec codec;
  final DatabaseArchivePreprocessor? preprocessor;

  Future<bool> isRecoverable(Directory captureDirectory) async {
    final source = _sourceFor(captureDirectory);
    if (await source.exists()) return true;
    // B1 配方化 capture:DB 字节不在盘,但可语义再生。
    if (await DatabaseRecipeManifest.exists(captureDirectory)) return true;
    if (!codec.isSupported ||
        await DatabaseArchivePolicy.readCompatible(captureDirectory) == null) {
      return false;
    }
    final manifest = await DatabaseArchiveManifest.read(captureDirectory);
    if (manifest == null || !_canRestore(manifest)) return false;
    return databaseArchiveFileMatches(
      _archiveFor(captureDirectory),
      length: manifest.archiveBytes,
      sha256Hex: manifest.archiveSha256,
    );
  }

  Future<File?> resolveDatabase(Directory captureDirectory) async {
    final source = _sourceFor(captureDirectory);
    if (await source.exists()) return source;
    // B1 配方化 capture:语义再生(重放生产管线),分钟级,产物落回源路径。
    if (await DatabaseRecipeManifest.exists(captureDirectory)) {
      return _regenerateFromRecipe(captureDirectory, source);
    }
    if (!codec.isSupported ||
        await DatabaseArchivePolicy.readCompatible(captureDirectory) == null) {
      return null;
    }

    final manifest = await DatabaseArchiveManifest.read(captureDirectory);
    if (manifest == null || !_canRestore(manifest)) return null;
    final archive = _archiveFor(captureDirectory);
    if (!await databaseArchiveFileMatches(
      archive,
      length: manifest.archiveBytes,
      sha256Hex: manifest.archiveSha256,
    )) {
      return null;
    }

    final temporary = File('${source.path}.verify.tmp');
    final preprocessedTemporary = File('${source.path}.preprocessed.tmp');
    try {
      await _deleteIfPresent(temporary);
      await _deleteIfPresent(preprocessedTemporary);
      if (manifest.preprocess == DatabaseArchivePreprocess.rawV1) {
        await codec.decompress(
          sourceArchive: archive,
          destinationDatabase: temporary,
        );
      } else {
        await codec.decompress(
          sourceArchive: archive,
          destinationDatabase: preprocessedTemporary,
        );
        await preprocessor!.restoreTrackDelta(
          sourceDatabase: preprocessedTemporary,
          destinationDatabase: temporary,
        );
      }
      if (!await databaseArchiveFileMatches(
        temporary,
        length: manifest.sourceBytes,
        sha256Hex: manifest.sourceSha256,
      )) {
        await _deleteIfPresent(temporary);
        await _deleteIfPresent(preprocessedTemporary);
        return null;
      }
      if (await source.exists()) {
        await _deleteIfPresent(temporary);
        await _deleteIfPresent(preprocessedTemporary);
        return source;
      }
      await temporary.rename(source.path);
      await _deleteIfPresent(preprocessedTemporary);
      return source;
    } catch (_) {
      await _deleteIfPresent(temporary);
      await _deleteIfPresent(preprocessedTemporary);
      return null;
    }
  }

  Future<File?> _regenerateFromRecipe(
      Directory captureDirectory, File source) async {
    final cache = await Directory.systemTemp
        .createTemp('pw_db_regen_${captureDirectory.path.split('/').last}_');
    try {
      final report = await SfmDbRegen.regenerate(
        captureDirectory: captureDirectory,
        targetDbPath: source.path,
        materializeCache: cache,
      );
      if (!report.ok || !await source.exists()) return null;
      return source;
    } catch (_) {
      return null;
    } finally {
      try {
        await cache.delete(recursive: true);
      } catch (_) {}
    }
  }

  bool _canRestore(DatabaseArchiveManifest manifest) =>
      manifest.preprocess == DatabaseArchivePreprocess.rawV1 ||
      (manifest.preprocess == DatabaseArchivePreprocess.trackDeltaV1 &&
          preprocessor?.isSupported == true);

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
