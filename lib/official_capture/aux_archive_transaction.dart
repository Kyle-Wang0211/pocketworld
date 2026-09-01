/// 附属物归档:拍完就不再变、且不在读取热路径上的文本文件,压起来。
///
/// 两个包(2026-08-14 实测,未命名(8) 80 帧作品):
///   `sidecars_v1`  photos_highres/*.json —— ARKit 逐帧侧车。**91.9% 的字节
///                  是 anchors_world/anchor_ids**(ARKit rawFeaturePoints):
///                  Swift 里是 Float32,却被 JSONSerialization 按 17 位有效
///                  数字打印(`-2.3398427963256836` 用 19 个字符存 4 字节的
///                  信息),而且这批文件**从未被压缩过**。产品同款 ZPAQ 实测
///                  1,831,474 → 511,461 B(**3.58×**,省 1.32MB)。
///   `diag_log_v1`  sfm_match_fail.jsonl —— `observation_only` 的诊断日志,
///                  app 内无任何读者(核里是 open-append-close 每条事件,
///                  没有常驻 fd,所以删源文件绝对安全)。实测 9.61×,省 0.44MB。
///
/// **无损口径 = 逐字节**。容器(PWSC1)只做拼接不做变换;压完立刻解压回读,
/// 容器 sha256 + 逐条目 sha256 全对上才写清单,清单落盘后才删源
/// (source-last)。任何一步不过 = 一个字节不动,下一轮再来。
///
/// 曾考虑把锚点转成 float32 二进制(实测 6.11×,省 1.53MB),**否决**:
/// Swift 打的是 `%.17g` 而不是最短往返表示,要逐字节还原就得在 Dart 里
/// 手写一个 `%.17g` 格式化器并逐文件验证;多出的 0.27MB 只占整件作品
/// 1.2%,不值这个复杂度与风险。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'aux_archive_container.dart';
import 'aux_archive_manifest.dart';
import 'database_archive_codec.dart';
import 'database_archive_transaction.dart'
    show databaseArchiveFilesEqual, databaseArchiveSha256;

typedef AuxArchiveContinueCheck = FutureOr<bool> Function();

const String kAuxSidecarBundleId = 'sidecars_v1';
const String kAuxDiagLogBundleId = 'diag_log_v1';
const String kAuxSidecarArchiveFileName = 'photos_highres_sidecars.zpaq';
const String kAuxDiagLogArchiveFileName = 'sfm_match_fail.jsonl.zpaq';
const String kAuxDiagLogSourceName = 'sfm_match_fail.jsonl';
const String _sidecarDirectoryName = 'photos_highres';

class AuxArchiveRunResult {
  const AuxArchiveRunResult({
    this.applicable = true,
    this.reason,
    this.committedBundles = const <String>[],
    this.deletedBytes = 0,
    this.archiveBytes = 0,
    this.interrupted = false,
    this.failed = false,
  });

  final bool applicable;
  final String? reason;
  final List<String> committedBundles;

  /// 本次真正从磁盘上消失的源字节(不含归档文件本身)。
  final int deletedBytes;

  /// 本次写下的归档字节(净收益 = deletedBytes - archiveBytes)。
  final int archiveBytes;
  final bool interrupted;
  final bool failed;
}

class AuxArchiveTransaction {
  const AuxArchiveTransaction({required this.codec, this.canContinue});

  final DatabaseArchiveCodec codec;
  final AuxArchiveContinueCheck? canContinue;

  Future<AuxArchiveRunResult> archiveCapture(Directory captureDirectory) async {
    if (!codec.isSupported) {
      return const AuxArchiveRunResult(applicable: false, reason: 'codec');
    }
    if (!await _hasDurableFinalArtifacts(captureDirectory)) {
      return const AuxArchiveRunResult(applicable: false, reason: 'not_ready');
    }
    var manifest = await AuxArchiveManifest.read(captureDirectory);
    final committed = <String>[];
    var deleted = 0;
    var archived = 0;
    try {
      for (final bundle in <Future<_BundleOutcome> Function()>[
        () => _runSidecars(captureDirectory, manifest),
        () => _runDiagLog(captureDirectory, manifest),
      ]) {
        await _requireMayContinue();
        final outcome = await bundle();
        if (outcome.bundle == null) continue;
        manifest = (manifest ?? const AuxArchiveManifest(bundles: {}))
            .withBundle(outcome.id!, outcome.bundle!);
        await manifest.writeAtomic(captureDirectory);
        // 清单落盘之后才删源:进程此刻被杀,下一轮凭清单即可还原。
        deleted += await _deleteSources(outcome.sources);
        archived += outcome.bundle!.archiveBytes;
        committed.add(outcome.id!);
      }
    } on DatabaseArchiveCancelled {
      return const AuxArchiveRunResult(interrupted: true);
    } catch (_) {
      return AuxArchiveRunResult(
        failed: true,
        committedBundles: committed,
        deletedBytes: deleted,
        archiveBytes: archived,
      );
    }
    return AuxArchiveRunResult(
      committedBundles: committed,
      deletedBytes: deleted,
      archiveBytes: archived,
    );
  }

  // ── 包一:ARKit 侧车 ────────────────────────────────────────────────

  Future<_BundleOutcome> _runSidecars(
    Directory captureDirectory,
    AuxArchiveManifest? manifest,
  ) async {
    final directory = Directory(
      '${captureDirectory.path}/$_sidecarDirectoryName',
    );
    final present = <File>[];
    if (await directory.exists()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.json')) {
          present.add(entity);
        }
      }
    }
    present.sort((left, right) => left.path.compareTo(right.path));
    final existing = manifest?.bundles[kAuxSidecarBundleId];
    if (present.isEmpty) return const _BundleOutcome.none();

    // 已有归档时把"归档里有、磁盘上没有"的条目带过来,避免重建容器时丢掉
    // 上一轮已经收进去的帧(策展删帧等场景会让两边不同步)。
    final entries = <AuxContainerEntry>[];
    final onDisk = <String>{
      for (final file in present)
        '$_sidecarDirectoryName/${_baseName(file.path)}',
    };
    if (existing != null) {
      for (final entry in await _restoreBundle(captureDirectory, existing)) {
        if (!onDisk.contains(entry.relativePath)) entries.add(entry);
      }
    }
    for (final file in present) {
      entries.add(
        AuxContainerEntry(
          relativePath: '$_sidecarDirectoryName/${_baseName(file.path)}',
          bytes: await file.readAsBytes(),
        ),
      );
    }
    return _commitBundle(
      captureDirectory: captureDirectory,
      id: kAuxSidecarBundleId,
      archiveFileName: kAuxSidecarArchiveFileName,
      entries: entries,
      sources: present,
    );
  }

  // ── 包二:诊断日志(append-only) ──────────────────────────────────

  Future<_BundleOutcome> _runDiagLog(
    Directory captureDirectory,
    AuxArchiveManifest? manifest,
  ) async {
    final source = File('${captureDirectory.path}/$kAuxDiagLogSourceName');
    var length = 0;
    try {
      length = await source.exists() ? await source.length() : 0;
    } on FileSystemException {
      length = 0;
    }
    if (length <= 0) return const _BundleOutcome.none();

    // 日志是 append-only:上一轮归档后核会新建一个只含新行的文件。旧世代
    // 作为**独立条目**保留(而不是拼成一个 blob),这样每一代都仍然满足
    // "逐字节等于当时的源文件";还原 = 按世代序拼接。
    final entries = <AuxContainerEntry>[];
    final existing = manifest?.bundles[kAuxDiagLogBundleId];
    if (existing != null) {
      entries.addAll(await _restoreBundle(captureDirectory, existing));
    }
    entries.add(
      AuxContainerEntry(
        relativePath: _nextDiagGenerationPath(entries),
        bytes: await source.readAsBytes(),
      ),
    );
    return _commitBundle(
      captureDirectory: captureDirectory,
      id: kAuxDiagLogBundleId,
      archiveFileName: kAuxDiagLogArchiveFileName,
      entries: entries,
      sources: <File>[source],
    );
  }

  static String _nextDiagGenerationPath(List<AuxContainerEntry> existing) {
    if (existing.isEmpty) return kAuxDiagLogSourceName;
    var next = 1;
    for (final entry in existing) {
      final suffix = entry.relativePath.split('.').last;
      final parsed = int.tryParse(suffix);
      if (parsed != null && parsed >= next) next = parsed + 1;
    }
    return '$kAuxDiagLogSourceName.$next';
  }

  // ── 提交(压缩 → 解压回读 → 逐条目对账 → 写清单)────────────────

  Future<_BundleOutcome> _commitBundle({
    required Directory captureDirectory,
    required String id,
    required String archiveFileName,
    required List<AuxContainerEntry> entries,
    required List<File> sources,
  }) async {
    final archive = File('${captureDirectory.path}/$archiveFileName');
    final containerTemporary = File('${archive.path}.container.tmp');
    final archiveTemporary = File('${archive.path}.tmp');
    final verifyTemporary = File('${archive.path}.verify.tmp');
    final temporaries = <File>[
      containerTemporary,
      archiveTemporary,
      verifyTemporary,
    ];
    await _deleteAll(temporaries);
    try {
      final container = encodeAuxContainer(entries);
      final containerSha = sha256.convert(container).toString();
      await containerTemporary.writeAsBytes(container, flush: true);
      await _requireMayContinue();

      await codec.compress(
        sourceDatabase: containerTemporary,
        destinationArchive: archiveTemporary,
      );
      if (!await archiveTemporary.exists() ||
          await archiveTemporary.length() == 0) {
        throw const FileSystemException('ZPAQ encoder produced no output');
      }
      await _requireMayContinue();

      await codec.decompress(
        sourceArchive: archiveTemporary,
        destinationDatabase: verifyTemporary,
      );
      if (!await databaseArchiveFilesEqual(
        containerTemporary,
        verifyTemporary,
      )) {
        throw const FileSystemException(
          'ZPAQ reconstruction differs from the container bytes',
        );
      }
      // 逐条目对账:容器整体相同还不够,证据链要能指到每一个文件。
      final restored = decodeAuxContainer(await verifyTemporary.readAsBytes());
      if (restored.length != entries.length) {
        throw const FileSystemException('restored entry count mismatch');
      }
      final expected = <String, String>{
        for (final entry in entries)
          entry.relativePath: sha256.convert(entry.bytes).toString(),
      };
      final files = <AuxArchiveFile>[];
      var sourceBytes = 0;
      for (final entry in restored) {
        final digest = sha256.convert(entry.bytes).toString();
        if (expected[entry.relativePath] != digest) {
          throw FileSystemException(
            'entry digest mismatch',
            entry.relativePath,
          );
        }
        sourceBytes += entry.bytes.length;
        files.add(
          AuxArchiveFile(
            relativePath: entry.relativePath,
            bytes: entry.bytes.length,
            sha256: digest,
          ),
        );
      }
      await _requireMayContinue();

      final archiveBytes = await archiveTemporary.length();
      if (await archive.exists()) await archive.delete();
      await archiveTemporary.rename(archive.path);
      await _deleteAll(temporaries);
      return _BundleOutcome(
        id: id,
        bundle: AuxArchiveBundle(
          archiveFileName: archiveFileName,
          archiveBytes: archiveBytes,
          archiveSha256: await databaseArchiveSha256(archive),
          containerBytes: container.length,
          containerSha256: containerSha,
          sourceBytes: sourceBytes,
          files: files,
          verifiedAt: DateTime.now().toUtc().toIso8601String(),
        ),
        sources: sources,
      );
    } catch (_) {
      await _deleteAll(temporaries);
      rethrow;
    }
  }

  /// 从既有归档还原出条目;任一校验不过 = 抛出,调用方整包放弃(绝不
  /// 拿一个来路不明的容器去覆盖清单)。
  Future<List<AuxContainerEntry>> _restoreBundle(
    Directory captureDirectory,
    AuxArchiveBundle bundle,
  ) async {
    final entries = await restoreAuxBundle(
      captureDirectory: captureDirectory,
      bundle: bundle,
      codec: codec,
    );
    if (entries == null) {
      throw const FileSystemException('existing aux archive failed to restore');
    }
    return entries;
  }

  Future<int> _deleteSources(List<File> sources) async {
    var deleted = 0;
    for (final file in sources) {
      try {
        if (!await file.exists()) continue;
        deleted += await file.length();
        await file.delete();
      } on FileSystemException {
        // 删不掉只是没省到空间,归档已经落盘且校验过,数据不会丢。
      }
    }
    return deleted;
  }

  Future<void> _requireMayContinue() async {
    final check = canContinue;
    if (check != null && !await check()) {
      throw const DatabaseArchiveCancelled();
    }
  }
}

class _BundleOutcome {
  const _BundleOutcome({
    required this.id,
    required this.bundle,
    required this.sources,
  });

  const _BundleOutcome.none()
    : id = null,
      bundle = null,
      sources = const <File>[];

  final String? id;
  final AuxArchiveBundle? bundle;
  final List<File> sources;
}

/// 从归档还原一个包的全部条目并逐项校验。失败返回 null(fail closed)。
Future<List<AuxContainerEntry>?> restoreAuxBundle({
  required Directory captureDirectory,
  required AuxArchiveBundle bundle,
  required DatabaseArchiveCodec codec,
}) async {
  if (!codec.isSupported) return null;
  final archive = File('${captureDirectory.path}/${bundle.archiveFileName}');
  final temporary = File('${archive.path}.restore.tmp');
  try {
    if (!await archive.exists()) return null;
    if (await archive.length() != bundle.archiveBytes) return null;
    if (await databaseArchiveSha256(archive) != bundle.archiveSha256) {
      return null;
    }
    if (await temporary.exists()) await temporary.delete();
    await codec.decompress(
      sourceArchive: archive,
      destinationDatabase: temporary,
    );
    final bytes = await temporary.readAsBytes();
    if (bytes.length != bundle.containerBytes) return null;
    if (sha256.convert(bytes).toString() != bundle.containerSha256) return null;
    final entries = decodeAuxContainer(bytes);
    final expected = <String, AuxArchiveFile>{
      for (final file in bundle.files) file.relativePath: file,
    };
    if (entries.length != expected.length) return null;
    for (final entry in entries) {
      final want = expected[entry.relativePath];
      if (want == null || want.bytes != entry.bytes.length) return null;
      if (sha256.convert(entry.bytes).toString() != want.sha256) return null;
    }
    return entries;
  } catch (_) {
    return null;
  } finally {
    try {
      if (await temporary.exists()) await temporary.delete();
    } catch (_) {}
  }
}

String _baseName(String path) => path.split(Platform.pathSeparator).last;

Future<void> _deleteAll(Iterable<File> files) async {
  for (final file in files) {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 临时文件清不掉不影响正确性:下一轮开头会再清一次。
    }
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
