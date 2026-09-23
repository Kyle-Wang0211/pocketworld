// photo_archive_nv12_test.dart — PhotoArchiveResolver.resolveNv12 (方案甲): the PWVA master frame goes to disk
// as raw NV12 — y plane first, then the interleaved uv plane, tightly packed, exactly what
// PwvaReader.readFrameNv12 hands out and exactly what pwdense_frame_v3_t.nv12_path promises. The platform
// decoder is replaced by PhotoArchiveResolver.debugNv12Reader so the byte order can be pinned on the host.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_resolver.dart';

const int _w = 4, _h = 2; // y = 8 bytes, uv = 4 bytes
const String _name = '0007.jpg';
const String _sha = 'a1b2c3';

Uint8List _y() => Uint8List.fromList(List<int>.generate(_w * _h, (i) => 10 + i));
Uint8List _uv() => Uint8List.fromList(List<int>.generate(_w * _h ~/ 2, (i) => 200 + i));

Future<Directory> _capture({bool withMaster = true}) async {
  final dir = await Directory.systemTemp.createTemp('pw_nv12_');
  final hevc = Directory('${dir.path}/photos_hevc')..createSync(recursive: true);
  File('${hevc.path}/manifest.json').writeAsStringSync(jsonEncode({
    'schema': 'pw_video_archive_v1',
    'codec': 'hevc',
    'resolution': '${_w}x$_h',
    'frame_count': 9,
  }));
  if (withMaster) {
    File('${hevc.path}/master-manifest.json').writeAsStringSync(jsonEncode({
      'schema': 'pw_pwva_master_manifest_v1',
      'stream_sha256': 'deadbeef',
      'frame_count': 9,
      'entries': {
        _name: {'frame': 7, 'source_bytes': 1234, 'source_sha256': _sha},
      },
    }));
  }
  return dir;
}

void main() {
  late Directory capture;
  late Directory cache;
  var calls = 0;
  var lastFrame = -1;

  setUp(() async {
    capture = await _capture();
    cache = Directory('${capture.path}/cache');
    calls = 0;
    lastFrame = -1;
    PhotoArchiveResolver.debugNv12Reader = (hevcDirectory, frame) {
      calls++;
      lastFrame = frame;
      return (y: _y(), uv: _uv(), width: _w, height: _h);
    };
  });

  tearDown(() async {
    PhotoArchiveResolver.debugNv12Reader = null;
    if (capture.existsSync()) await capture.delete(recursive: true);
  });

  test('writes y then uv, tightly packed, and reports the decoder size', () async {
    final r = await const PhotoArchiveResolver(codec: _NeverCodec()).resolveNv12(
      captureDirectory: capture,
      highresFilename: _name,
      cacheDirectory: cache,
    );
    expect(r, isNotNull);
    expect(r!.width, _w);
    expect(r.height, _h);
    expect(lastFrame, 7, reason: 'the frame number comes from the master manifest entry');
    final bytes = r.file.readAsBytesSync();
    expect(bytes.length, _w * _h + (_w * _h ~/ 2));
    expect(bytes.sublist(0, _w * _h), _y());
    expect(bytes.sublist(_w * _h), _uv());
  });

  test('the cache file is the PWVA name plus .nv12, and it lives in the cache dir', () async {
    final r = await const PhotoArchiveResolver(codec: _NeverCodec()).resolveNv12(
      captureDirectory: capture,
      highresFilename: _name,
      cacheDirectory: cache,
    );
    expect(r!.file.path, '${cache.path}/${_sha}_$_name.nv12');
    expect(File('${r.file.path}.tmp').existsSync(), isFalse, reason: 'the temp file is renamed, not left behind');
  });

  test('a second call hits the cache instead of decoding again', () async {
    const resolver = PhotoArchiveResolver(codec: _NeverCodec());
    final first = await resolver.resolveNv12(
        captureDirectory: capture, highresFilename: _name, cacheDirectory: cache);
    final second = await resolver.resolveNv12(
        captureDirectory: capture, highresFilename: _name, cacheDirectory: cache);
    expect(second!.file.path, first!.file.path);
    expect(calls, 1);
  });

  test('a truncated cache file is re-decoded, not handed out', () async {
    const resolver = PhotoArchiveResolver(codec: _NeverCodec());
    final first = await resolver.resolveNv12(
        captureDirectory: capture, highresFilename: _name, cacheDirectory: cache);
    first!.file.writeAsBytesSync(Uint8List(3));
    final second = await resolver.resolveNv12(
        captureDirectory: capture, highresFilename: _name, cacheDirectory: cache);
    expect(calls, 2);
    expect(second!.file.readAsBytesSync().length, _w * _h + (_w * _h ~/ 2));
  });

  test('a frame that is not in the master manifest is not ours -> null', () async {
    final r = await const PhotoArchiveResolver(codec: _NeverCodec()).resolveNv12(
      captureDirectory: capture,
      highresFilename: '0008.jpg',
      cacheDirectory: cache,
    );
    expect(r, isNull);
    expect(calls, 0);
  });

  test('no PWVA master manifest at all (Lepton line) -> null', () async {
    final plain = await _capture(withMaster: false);
    try {
      final r = await const PhotoArchiveResolver(codec: _NeverCodec()).resolveNv12(
        captureDirectory: plain,
        highresFilename: _name,
        cacheDirectory: Directory('${plain.path}/cache'),
      );
      expect(r, isNull);
      expect(calls, 0);
    } finally {
      await plain.delete(recursive: true);
    }
  });
}

class _NeverCodec implements PhotoArchiveCodec {
  const _NeverCodec();
  @override
  bool get isSupported => false;
  @override
  Future<void> encodeJpeg({required File sourceJpeg, required File destinationJxl}) =>
      throw UnsupportedError('not used');
  @override
  Future<void> reconstructJpeg({required File sourceJxl, required File destinationJpeg}) =>
      throw UnsupportedError('not used');
  @override
  void requestCancellation() {}
}
