/// 侧车按需物化:归档之后,唯一还要读侧车的路径(SfmDbRegen 重放重建)
/// 通过它拿到一个"能像从前一样按文件名读"的目录。
///
/// 物化目标**故意放在 capture 目录之外**(系统临时目录):放回
/// `photos_highres/` 会被冷归档协调器再次看见,于是压→删→再物化,来回空转。
library;

import 'dart:io';

import 'aux_archive_manifest.dart';
import 'aux_archive_transaction.dart';
import 'database_archive_codec.dart';

/// 一次侧车读取会话。`directory` 里按原文件名放着侧车;用完 [dispose]。
class SidecarSession {
  SidecarSession._(this.directory, this._temporary);

  final Directory directory;
  final Directory? _temporary;

  /// 侧车是从归档里物化出来的(而不是本来就在磁盘上)。
  bool get materialized => _temporary != null;

  Future<void> dispose() async {
    final temporary = _temporary;
    if (temporary == null) return;
    try {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    } on FileSystemException {
      // 临时目录由系统回收,清不掉不影响正确性。
    }
  }
}

class AuxArchiveResolver {
  const AuxArchiveResolver({required this.codec});

  final DatabaseArchiveCodec codec;

  /// 未归档 → 直接返回 `photos_highres`;已归档 → 解压校验后物化到临时目录。
  /// 两者都拿不到时返回 null(调用方 fail closed)。
  Future<SidecarSession?> openSidecars(Directory captureDirectory) async {
    final live = Directory('${captureDirectory.path}/photos_highres');
    try {
      if (await live.exists()) {
        await for (final entity in live.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.json')) {
            return SidecarSession._(live, null);
          }
        }
      }
    } on FileSystemException {
      // 落到归档路径。
    }

    final manifest = await AuxArchiveManifest.read(captureDirectory);
    final bundle = manifest?.bundles[kAuxSidecarBundleId];
    if (bundle == null) return null;
    final entries = await restoreAuxBundle(
      captureDirectory: captureDirectory,
      bundle: bundle,
      codec: codec,
    );
    if (entries == null) return null;

    Directory? scratch;
    try {
      scratch = await Directory.systemTemp.createTemp('pw_sidecars_');
      for (final entry in entries) {
        final name = entry.relativePath.split('/').last;
        await File('${scratch.path}/$name')
            .writeAsBytes(entry.bytes, flush: true);
      }
      return SidecarSession._(scratch, scratch);
    } catch (_) {
      final created = scratch;
      if (created != null) {
        try {
          if (await created.exists()) await created.delete(recursive: true);
        } catch (_) {}
      }
      return null;
    }
  }
}
