import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'photo_archive_codec.dart';
import 'photo_archive_manifest.dart';
import 'photo_archive_policy.dart';
import 'pwva_master.dart';

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
    this.codecsByName = const <String, PhotoArchiveCodec>{},
    this.afterManifestCommitted,
    this.canStartNext,
  });

  final PhotoArchiveCodec codec;
  final Map<String, PhotoArchiveCodec> codecsByName;
  final PhotoArchiveCommitHook? afterManifestCommitted;
  final PhotoArchiveContinueCheck? canStartNext;

  Future<PhotoArchiveRunResult> archiveCapture(
    Directory captureDirectory,
  ) async {
    final policy = await PhotoArchivePolicy.readCompatible(captureDirectory);
    if (policy == null) {
      return const PhotoArchiveRunResult(eligible: false);
    }
    final selectedCodec = codecsByName.isEmpty
        ? codec
        : codecsByName[policy.codec];
    if (selectedCodec == null || !selectedCodec.isSupported) {
      return const PhotoArchiveRunResult(eligible: false);
    }
    final candidates = await PhotoArchiveManifest.loadCandidateNames(
      captureDirectory,
    );
    final existingManifest = await PhotoArchiveManifest.read(captureDirectory);
    if (existingManifest != null && !existingManifest.matchesPolicy(policy)) {
      return const PhotoArchiveRunResult(eligible: false);
    }
    var manifest =
        existingManifest ??
        PhotoArchiveManifest.forPolicy(
          policy,
          entries: const <String, PhotoArchiveEntry>{},
        );
    // PWVA 主本已接管的帧:源 JPEG 依授权流程删除,Lepton 按 skipped 处理。
    final pwvaMastered = await PwvaMasterManifest.readNames(captureDirectory);
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
      final archive = File('${source.path}${policy.archiveSuffix}');
      final archiveTemporary = File('${archive.path}.tmp');
      final verificationTemporary = File('${source.path}.verify.tmp');
      try {
        await _deleteIfPresent(archiveTemporary);
        await _deleteIfPresent(verificationTemporary);
        await _requireCanContinue();

        final committed = manifest.entries[name];
        if (committed != null) {
          final reconciled = await _reconcileCommitted(
            name: name,
            source: source,
            archive: archive,
            verificationTemporary: verificationTemporary,
            entry: committed,
            codec: selectedCodec,
            archiveRelativePath: 'photos_highres/$name${policy.archiveSuffix}',
          );
          if (reconciled) {
            archived.add(name);
          } else {
            failed.add(name);
          }
          continue;
        }

        if (!await source.exists()) {
          if (pwvaMastered.contains(name)) {
            skipped.add(name);
          } else {
            failed.add(name);
          }
          continue;
        }
        final sourceBytes = await source.length();
        final sourceSha256 = await _sha256Of(source);
        await _requireCanContinue();

        await selectedCodec.encodeJpeg(
          sourceJpeg: source,
          destinationJxl: archiveTemporary,
        );
        await _requireCanContinue();
        if (!await archiveTemporary.exists()) {
          throw const FileSystemException('photo encoder produced no output');
        }
        await selectedCodec.reconstructJpeg(
          sourceJxl: archiveTemporary,
          destinationJpeg: verificationTemporary,
        );
        await _requireCanContinue();
        if (!await _filesEqual(source, verificationTemporary)) {
          throw const FileSystemException(
            'photo reconstruction differs from source bytes',
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
        await _requireCanContinue();

        if (await archive.exists()) {
          await archive.delete();
        }
        await archiveTemporary.rename(archive.path);
        final entry = PhotoArchiveEntry(
          sourceRelativePath: 'photos_highres/$name',
          sourceBytes: sourceBytes,
          sourceSha256: sourceSha256,
          archiveRelativePath: 'photos_highres/$name${policy.archiveSuffix}',
          archiveBytes: archiveBytes,
          archiveSha256: archiveSha256,
          status: PhotoArchiveEntryStatus.verified,
          verifiedAt: DateTime.now().toUtc().toIso8601String(),
        );
        manifest = manifest.withEntry(name, entry);
        await manifest.writeAtomic(captureDirectory);
        await afterManifestCommitted?.call(source);
        await _requireCanContinue();
        await source.delete();
        await _deleteIfPresent(verificationTemporary);
        archived.add(name);
      } on PhotoArchiveCancelled {
        await _deleteIfPresent(archiveTemporary);
        await _deleteIfPresent(verificationTemporary);
        paused = true;
        break;
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

  Future<void> _requireCanContinue() async {
    if (canStartNext != null && !await canStartNext!()) {
      throw const PhotoArchiveCancelled();
    }
  }

  Future<bool> _reconcileCommitted({
    required String name,
    required File source,
    required File archive,
    required File verificationTemporary,
    required PhotoArchiveEntry entry,
    required PhotoArchiveCodec codec,
    required String archiveRelativePath,
  }) async {
    if (entry.sourceRelativePath != 'photos_highres/$name' ||
        entry.archiveRelativePath != archiveRelativePath ||
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
    await _requireCanContinue();
    await codec.reconstructJpeg(
      sourceJxl: archive,
      destinationJpeg: verificationTemporary,
    );
    if (!await _filesEqual(source, verificationTemporary) ||
        await verificationTemporary.length() != entry.sourceBytes ||
        await _sha256Of(verificationTemporary) != entry.sourceSha256) {
      return false;
    }
    await _requireCanContinue();
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
