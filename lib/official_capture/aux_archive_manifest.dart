import 'dart:convert';
import 'dart:io';

/// 附属物归档清单(`official_aux_archive.json`)。
///
/// 一个 capture 一份,内含若干"包"(bundle)。每个包记录:归档文件的
/// 字节/摘要、容器的字节/摘要、以及**逐个源文件**的路径/字节/摘要。
/// 逐文件摘要既是还原时的校验依据,也是"这批文件确实被无损收进去了"的
/// 证据链 —— 80 帧作品的清单约 7KB,相对省下的 1.32MB 完全值得。
class AuxArchiveManifest {
  const AuxArchiveManifest({required this.bundles});

  static const String schema = 'pw_aux_archive_v1';
  static const String fileName = 'official_aux_archive.json';

  /// 包 id → 包内容。
  final Map<String, AuxArchiveBundle> bundles;

  static Future<AuxArchiveManifest?> read(Directory captureDirectory) async {
    final file = File('${captureDirectory.path}/$fileName');
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['schema'] != schema) return null;
      final rawBundles = decoded['bundles'];
      if (rawBundles is! Map) return null;
      final bundles = <String, AuxArchiveBundle>{};
      for (final entry in rawBundles.entries) {
        final bundle = AuxArchiveBundle.fromJson(entry.value);
        if (bundle == null) return null;
        bundles['${entry.key}'] = bundle;
      }
      return AuxArchiveManifest(bundles: bundles);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeAtomic(Directory captureDirectory) async {
    final target = File('${captureDirectory.path}/$fileName');
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{
        'schema': schema,
        'bundles': <String, Object?>{
          for (final entry in bundles.entries) entry.key: entry.value.toJson(),
        },
      }),
      flush: true,
    );
    await temporary.rename(target.path);
  }

  AuxArchiveManifest withBundle(String id, AuxArchiveBundle bundle) =>
      AuxArchiveManifest(
        bundles: <String, AuxArchiveBundle>{...bundles, id: bundle},
      );
}

class AuxArchiveBundle {
  const AuxArchiveBundle({
    required this.archiveFileName,
    required this.archiveBytes,
    required this.archiveSha256,
    required this.containerBytes,
    required this.containerSha256,
    required this.sourceBytes,
    required this.files,
    required this.verifiedAt,
  });

  final String archiveFileName;
  final int archiveBytes;
  final String archiveSha256;

  /// 未压缩容器(PWSC1)的字节与摘要 —— 解压回来先对它,再逐文件对。
  final int containerBytes;
  final String containerSha256;

  /// 源文件字节合计(用于报表:压缩比 = sourceBytes / archiveBytes)。
  final int sourceBytes;
  final List<AuxArchiveFile> files;
  final String verifiedAt;

  static AuxArchiveBundle? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final files = raw['files'];
    if (files is! List) return null;
    final parsed = <AuxArchiveFile>[];
    for (final entry in files) {
      final file = AuxArchiveFile.fromJson(entry);
      if (file == null) return null;
      parsed.add(file);
    }
    final archiveFileName = raw['archive_file_name'];
    final archiveSha256 = raw['archive_sha256'];
    final containerSha256 = raw['container_sha256'];
    if (archiveFileName is! String ||
        archiveSha256 is! String ||
        containerSha256 is! String) {
      return null;
    }
    return AuxArchiveBundle(
      archiveFileName: archiveFileName,
      archiveBytes: (raw['archive_bytes'] as num?)?.toInt() ?? -1,
      archiveSha256: archiveSha256,
      containerBytes: (raw['container_bytes'] as num?)?.toInt() ?? -1,
      containerSha256: containerSha256,
      sourceBytes: (raw['source_bytes'] as num?)?.toInt() ?? -1,
      files: parsed,
      verifiedAt: '${raw['verified_at'] ?? ''}',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'archive_file_name': archiveFileName,
    'archive_bytes': archiveBytes,
    'archive_sha256': archiveSha256,
    'container_bytes': containerBytes,
    'container_sha256': containerSha256,
    'source_bytes': sourceBytes,
    'file_count': files.length,
    'verified_at': verifiedAt,
    'files': <Object?>[for (final file in files) file.toJson()],
  };
}

class AuxArchiveFile {
  const AuxArchiveFile({
    required this.relativePath,
    required this.bytes,
    required this.sha256,
  });

  /// 相对 capture 目录的路径,例如 `photos_highres/official_tap-210.json`。
  final String relativePath;
  final int bytes;
  final String sha256;

  static AuxArchiveFile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final digest = raw['sha256'];
    final bytes = (raw['bytes'] as num?)?.toInt();
    if (path is! String || digest is! String || bytes == null) return null;
    return AuxArchiveFile(relativePath: path, bytes: bytes, sha256: digest);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'path': relativePath,
    'bytes': bytes,
    'sha256': sha256,
  };
}
