import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:pw_hevc/pwva.dart';
import 'package:pw_hevc/pwva_apple.dart';

import 'photo_archive_codec.dart';
import 'photo_archive_manifest.dart';
import 'photo_archive_policy.dart';
import 'pwva_master.dart';

/// Resolves an authoritative high-resolution JPEG without weakening integrity.
class PhotoArchiveResolver {
  const PhotoArchiveResolver({
    required this.codec,
    this.codecsByName = const <String, PhotoArchiveCodec>{},
  });

  final PhotoArchiveCodec codec;
  final Map<String, PhotoArchiveCodec> codecsByName;

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

    final manifest = await PhotoArchiveManifest.read(captureDirectory);
    final entry = manifest?.entries[highresFilename];
    if (manifest == null || entry == null) {
      // PWVA 主本回退:该帧的主本是 photos_hevc 码流,物化=解码→重编 JPEG。
      return _resolveFromPwvaMaster(
        captureDirectory: captureDirectory,
        highresFilename: highresFilename,
        cacheDirectory: cacheDirectory,
      );
    }
    final selectedCodec = codecsByName.isEmpty
        ? codec
        : codecsByName[manifest.codec];
    if (selectedCodec == null || !selectedCodec.isSupported) return null;
    final expectedArchiveRelativePath =
        'photos_highres/$highresFilename${_archiveSuffix(manifest.codec)}';
    if (entry.sourceRelativePath != 'photos_highres/$highresFilename' ||
        entry.archiveRelativePath != expectedArchiveRelativePath) {
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
      await selectedCodec.reconstructJpeg(
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

/// PWVA 主本物化:按 master-manifest 找到帧号,解码该帧(只解其 GOP)并
/// 重编成 JPEG 写入缓存。像素级重编码——消费者(SfM 喂帧/取色)只需要
/// 像素,不依赖源字节;缓存键含源 sha,天然免疫陈旧。
Future<File?> _resolveFromPwvaMaster({
  required Directory captureDirectory,
  required String highresFilename,
  required Directory cacheDirectory,
}) async {
  if (!(Platform.isIOS || Platform.isMacOS)) return null;
  try {
    final master = await PwvaMasterManifest.read(captureDirectory);
    final entry = master?.entries[highresFilename];
    if (master == null || entry == null) return null;
    await cacheDirectory.create(recursive: true);
    final cached = File(
      '${cacheDirectory.path}/${entry.sourceSha256}_$highresFilename',
    );
    if (await cached.exists() && await cached.length() > 0) return cached;
    final temporary = File('${cached.path}.tmp');
    await _deleteIfPresent(cached);
    await _deleteIfPresent(temporary);
    final hevcPath = '${captureDirectory.path}/photos_hevc';
    final frame = entry.frame;
    final outPath = temporary.path;
    final ok = await Isolate.run(() {
      try {
        final reader = PwvaReader(
            Directory(hevcPath),
            (au) => AppleHevcDecoder(
                width: _pwvaWidth(hevcPath),
                height: _pwvaHeight(hevcPath),
                keyframeAu: au));
        final decoded = reader.readFrameNv12(frame);
        writeNv12JpegFile(decoded.y, decoded.uv,
            width: reader.width, height: reader.height, path: outPath);
        return true;
      } catch (_) {
        return false;
      }
    });
    if (!ok || !await temporary.exists() || await temporary.length() == 0) {
      await _deleteIfPresent(temporary);
      return null;
    }
    await temporary.rename(cached.path);
    return cached;
  } catch (_) {
    return null;
  }
}

int _pwvaWidth(String hevcPath) => _pwvaResolution(hevcPath).$1;
int _pwvaHeight(String hevcPath) => _pwvaResolution(hevcPath).$2;

(int, int) _pwvaResolution(String hevcPath) {
  // manifest 与 PwvaReader 构造读的是同一文件;这里只为解码器工厂取宽高。
  final file = File('$hevcPath/manifest.json');
  final json = file.readAsStringSync();
  final res = (RegExp(r'"resolution":\s*"(\d+)x(\d+)"').firstMatch(json))!;
  return (int.parse(res.group(1)!), int.parse(res.group(2)!));
}

String _archiveSuffix(String codec) =>
    codec == PhotoArchivePolicy.leptonCodec ? '.lep' : '.jxl';

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
