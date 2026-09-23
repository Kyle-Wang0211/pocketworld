import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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

  /// PWVA 主本帧 → 原始 NV12 文件(方案甲,openspec dense-lossless-speedup-v1)。
  ///
  /// 和 [resolveJpeg] 的 PWVA 回退同一条解码路径,但**不再重编 JPEG**:把解码器交出来的
  /// full-range 4:2:0 双平面直接落盘 —— 先 y(h*w 字节)后 uv((h/2)*w 字节),紧密排列,
  /// 正是 `PwvaReader.readFrameNv12` 的返回值。文件交给 `pwdense_run3` 的
  /// `pwdense_frame_v3_t.nv12_path`。
  ///
  /// 只服务 PWVA 主本帧:不在 master-manifest 里(Lepton 归档 / 新鲜作品)一律返回 null,
  /// 调用方回落 [resolveJpeg]。**盘上是否还有原 JPEG 这里不看**,由调用方决定(生产里
  /// `_gather` 只在原 JPEG 缺失时才来问)。
  ///
  /// 缓存命名与 [resolveJpeg] 的 PWVA 回退同构(`<source_sha256>_<name>` + `.nv12` 后缀),
  /// 同样是「临时文件写完再 rename」的原子落盘;缓存目录由调用方给,随作业一起删。
  Future<({File file, int width, int height})?> resolveNv12({
    required Directory captureDirectory,
    required String highresFilename,
    required Directory cacheDirectory,
  }) async {
    try {
      final master = await PwvaMasterManifest.read(captureDirectory);
      final entry = master?.entries[highresFilename];
      if (master == null || entry == null) return null;
      final reader = debugNv12Reader;
      if (reader == null && !_hevcDecoderAvailable()) return null;
      final hevcPath = '${captureDirectory.path}/photos_hevc';
      final (width, height) = _pwvaResolution(hevcPath);
      if (width <= 0 || height <= 0) return null;
      final expectedBytes = width * height + (width * height ~/ 2);

      await cacheDirectory.create(recursive: true);
      final cached = File(
        '${cacheDirectory.path}/${entry.sourceSha256}_$highresFilename.nv12',
      );
      if (await cached.exists() && await cached.length() == expectedBytes) {
        return (file: cached, width: width, height: height);
      }
      final temporary = File('${cached.path}.tmp');
      await _deleteIfPresent(cached);
      await _deleteIfPresent(temporary);
      final frame = entry.frame;
      final outPath = temporary.path;
      final ok = reader != null
          ? _writeNv12(reader(Directory(hevcPath), frame), outPath)
          : await Isolate.run(() {
              try {
                final r = PwvaReader(
                  Directory(hevcPath),
                  (au) => _makeHevcDecoder(hevcPath, au),
                );
                final decoded = r.readFrameNv12(frame);
                return _writeNv12(
                  (y: decoded.y, uv: decoded.uv, width: r.width, height: r.height),
                  outPath,
                );
              } catch (_) {
                return false;
              }
            });
      if (!ok ||
          !await temporary.exists() ||
          await temporary.length() != expectedBytes) {
        await _deleteIfPresent(temporary);
        return null;
      }
      await temporary.rename(cached.path);
      return (file: cached, width: width, height: height);
    } catch (_) {
      return null;
    }
  }

  /// 仅测试注入:替代「PwvaReader + 平台解码器」这一步,让 [resolveNv12] 的缓存/原子落盘/
  /// 字节顺序可以在主机上被验证。生产恒为 null,走上面的 worker isolate 分支。
  static PwvaNv12FrameReader? debugNv12Reader;
}

/// 测试注入用的帧读取器签名:给 photos_hevc 目录与帧号,返回该帧的 NV12 平面与尺寸。
typedef PwvaNv12FrameReader =
    ({Uint8List y, Uint8List uv, int width, int height}) Function(
      Directory hevcDirectory,
      int frame,
    );

/// 平台 HEVC 解码器。今天只有 Apple 侧(VideoToolbox);Android / 鸿蒙的解码器就位后在这两个
/// 函数里各加一条分支即可,上面的缓存命名、原子落盘、并发骨架一个字都不用改。
bool _hevcDecoderAvailable() => Platform.isIOS || Platform.isMacOS;

HevcFrameDecoder _makeHevcDecoder(String hevcPath, Uint8List keyframeAu) =>
    AppleHevcDecoder(
      width: _pwvaWidth(hevcPath),
      height: _pwvaHeight(hevcPath),
      keyframeAu: keyframeAu,
    );

/// 先 y 后 uv,紧密排列 —— 这就是 `pwdense_frame_v3_t.nv12_path` 约定的文件。
bool _writeNv12(
  ({Uint8List y, Uint8List uv, int width, int height}) planes,
  String path,
) {
  final out = File(path).openSync(mode: FileMode.writeOnly);
  try {
    out.writeFromSync(planes.y);
    out.writeFromSync(planes.uv);
  } finally {
    out.closeSync();
  }
  return true;
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
            keyframeAu: au,
          ),
        );
        final decoded = reader.readFrameNv12(frame);
        writeNv12JpegFile(
          decoded.y,
          decoded.uv,
          width: reader.width,
          height: reader.height,
          path: outPath,
        );
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
