import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'photo_archive_codec.dart';
import 'photo_archive_manifest.dart';
import 'photo_archive_policy.dart';

typedef PhotoArchiveCommitHook = Future<void> Function(File sourceJpeg);
typedef PhotoArchiveContinueCheck = FutureOr<bool> Function();

class PhotoArchiveRunResult {
  const PhotoArchiveRunResult({
    this.archivedNames = const <String>[],
    this.skippedNames = const <String>[],
    this.failedNames = const <String>[],
    this.eligible = true,
    this.paused = false,
  });

  final List<String> archivedNames;
  final List<String> skippedNames;
  final List<String> failedNames;
  final bool eligible;
  final bool paused;
}

/// Executes conservative, sequential archive transactions for one capture.
class PhotoArchiveTransaction {
  const PhotoArchiveTransaction({
    required this.codec,
    this.afterManifestCommitted,
    this.canStartNext,
  });

  final PhotoArchiveCodec codec;
  final PhotoArchiveCommitHook? afterManifestCommitted;
  final PhotoArchiveContinueCheck? canStartNext;

  Future<PhotoArchiveRunResult> archiveCapture(
    Directory captureDirectory,
  ) async {
    final policy = await PhotoArchivePolicy.readCompatible(captureDirectory);
    if (policy == null || !codec.isSupported) {
      return const PhotoArchiveRunResult(eligible: false);
    }
    final candidates = await PhotoArchiveManifest.loadCandidateNames(
      captureDirectory,
    );
    var manifest =
        await PhotoArchiveManifest.read(captureDirectory) ??
        const PhotoArchiveManifest(entries: <String, PhotoArchiveEntry>{});
    final archived = <String>[];
    final skipped = <String>[];
    final failed = <String>[];
    var paused = false;

    for (final name in candidates) {
      if (canStartNext != null && !await canStartNext!()) {
        paused = true;
        break;
      }
      final source = File('${captureDirectory.path}/photos_highres/$name');
      final archive = File('${source.path}.jxl');
      final archiveTemporary = File('${archive.path}.tmp');
      final verificationTemporary = File('${source.path}.verify.tmp');
      try {
        await _deleteIfPresent(archiveTemporary);
        await _deleteIfPresent(verificationTemporary);

        final committed = manifest.entries[name];
        if (committed != null) {
          final reconciled = await _reconcileCommitted(
            name: name,
            source: source,
            archive: archive,
            verificationTemporary: verificationTemporary,
            entry: committed,
          );
          if (reconciled) {
            archived.add(name);
          } else {
            failed.add(name);
          }
          continue;
        }

        if (!await source.exists()) {
          failed.add(name);
          continue;
        }
        final sourceBytes = await source.length();
        final sourceSha256 = await _sha256Of(source);

        await codec.encodeJpeg(
          sourceJpeg: source,
          destinationJxl: archiveTemporary,
        );
        if (!await archiveTemporary.exists()) {
          throw const FileSystemException('JPEG XL encoder produced no output');
        }
        await codec.reconstructJpeg(
          sourceJxl: archiveTemporary,
          destinationJpeg: verificationTemporary,
        );
        if (!await _filesEqual(source, verificationTemporary)) {
          throw const FileSystemException(
            'JPEG XL reconstruction differs from source bytes',
          );
        }
        final archiveBytes = await archiveTemporary.length();
        if (archiveBytes >= sourceBytes) {
          await _deleteIfPresent(archiveTemporary);
          await _deleteIfPresent(verificationTemporary);
          skipped.add(name);
          continue;
        }
        final archiveSha256 = await _sha256Of(archiveTemporary);

        if (await archive.exists()) {
          await archive.delete();
        }
        await archiveTemporary.rename(archive.path);
        final entry = PhotoArchiveEntry(
          sourceRelativePath: 'photos_highres/$name',
          sourceBytes: sourceBytes,
          sourceSha256: sourceSha256,
          archiveRelativePath: 'photos_highres/$name.jxl',
          archiveBytes: archiveBytes,
          archiveSha256: archiveSha256,
          status: PhotoArchiveEntryStatus.verified,
          verifiedAt: DateTime.now().toUtc().toIso8601String(),
        );
        manifest = manifest.withEntry(name, entry);
        await manifest.writeAtomic(captureDirectory);
        await afterManifestCommitted?.call(source);
        await source.delete();
        await _deleteIfPresent(verificationTemporary);
        archived.add(name);
      } catch (_) {
        await _deleteIfPresent(archiveTemporary);
        await _deleteIfPresent(verificationTemporary);
        failed.add(name);
      }
    }

    return PhotoArchiveRunResult(
      archivedNames: List.unmodifiable(archived),
      skippedNames: List.unmodifiable(skipped),
      failedNames: List.unmodifiable(failed),
      paused: paused,
    );
  }

  Future<bool> _reconcileCommitted({
    required String name,
    required File source,
    required File archive,
    required File verificationTemporary,
    required PhotoArchiveEntry entry,
  }) async {
    if (entry.sourceRelativePath != 'photos_highres/$name' ||
        entry.archiveRelativePath != 'photos_highres/$name.jxl' ||
        !await archive.exists() ||
        await archive.length() != entry.archiveBytes ||
        await _sha256Of(archive) != entry.archiveSha256) {
      return false;
    }
    if (!await source.exists()) return true;
    if (await source.length() != entry.sourceBytes ||
        await _sha256Of(source) != entry.sourceSha256) {
      return false;
    }
    await codec.reconstructJpeg(
      sourceJxl: archive,
      destinationJpeg: verificationTemporary,
    );
    if (!await _filesEqual(source, verificationTemporary) ||
        await verificationTemporary.length() != entry.sourceBytes ||
        await _sha256Of(verificationTemporary) != entry.sourceSha256) {
      return false;
    }
    await source.delete();
    await _deleteIfPresent(verificationTemporary);
    return true;
  }
}

Future<String> _sha256Of(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<bool> _filesEqual(File left, File right) async {
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
    // Best effort. A later operation still fails closed while the source stays.
  }
}
