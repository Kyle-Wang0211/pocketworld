// capture_sim.dart — 拍摄期效率门的 Mac 侧测量
// 模拟生产:帧以 300ms 节奏到达(ARKit 高清帧 = CVPixelBuffer),
// 编码走零拷贝路径。测:每帧编码耗时、是否跟得上节奏、峰值滞后。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _CreateC = Pointer<Void> Function(Int32, Int32, Int32, Double, Int64);
typedef _CreateD = Pointer<Void> Function(int, int, int, double, int);
typedef _EncPbC = Int32 Function(Pointer<Void>, Pointer<Void>, Int64, Int64,
    Pointer<Pointer<Uint8>>, Pointer<Int64>, Pointer<Int32>);
typedef _EncPbD = int Function(Pointer<Void>, Pointer<Void>, int, int,
    Pointer<Pointer<Uint8>>, Pointer<Int64>, Pointer<Int32>);
typedef _JpegC = Pointer<Void> Function(
    Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>);
typedef _JpegD = Pointer<Void> Function(
    Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>);
typedef _RelC = Void Function(Pointer<Void>);
typedef _RelD = void Function(Pointer<Void>);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeD = void Function(Pointer<Uint8>);

void main(List<String> args) async {
  final dir = args[0]; // photos_highres 目录
  final cadenceMs = int.parse(args.length > 1 ? args[1] : '300');
  final root = '${Directory.current.path}/native';
  final enc = DynamicLibrary.open('$root/libpw_vt_encoder.dylib');
  final jpg = DynamicLibrary.open('$root/libpw_jpeg_cvpb.dylib');
  final create = enc.lookupFunction<_CreateC, _CreateD>('pw_vt_create');
  final encodePb = enc.lookupFunction<_EncPbC, _EncPbD>('pw_vt_encode_cvpb');
  final freeBuf = enc.lookupFunction<_FreeC, _FreeD>('pw_vt_free');
  final toPb = jpg.lookupFunction<_JpegC, _JpegD>('pw_jpeg_to_bgra_cvpb');
  final release = jpg.lookupFunction<_RelC, _RelD>('pw_cvpb_release');

  final files = Directory(dir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.jpg'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final handle = create(4224, 2376, 8, 0.65, 0);
  final out = calloc<Pointer<Uint8>>();
  final len = calloc<Int64>();
  final key = calloc<Int32>();
  final w = calloc<Int32>();
  final h = calloc<Int32>();

  final decodeMs = <int>[];
  final encodeMs = <int>[];
  final lagMs = <int>[];
  var totalBytes = 0;
  final t0 = DateTime.now();

  for (var i = 0; i < files.length; i++) {
    // 模拟采集节奏:帧在 i*cadence 时刻"到达"
    final due = t0.add(Duration(milliseconds: i * cadenceMs));
    final now = DateTime.now();
    if (due.isAfter(now)) await Future.delayed(due.difference(now));

    final sw = Stopwatch()..start();
    final path = files[i].path.toNativeUtf8();
    final pb = toPb(path, w, h);
    calloc.free(path);
    if (pb == nullptr) throw StateError('decode failed ${files[i].path}');
    final dMs = sw.elapsedMilliseconds;
    sw..reset()..start();
    final st = encodePb(handle, pb, i * cadenceMs, cadenceMs, out, len, key);
    final eMs = sw.elapsedMilliseconds;
    release(pb);
    if (st != 0) throw StateError('encode failed $st');
    totalBytes += len.value;
    freeBuf(out.value);
    decodeMs.add(dMs);
    encodeMs.add(eMs);
    lagMs.add(DateTime.now().difference(due).inMilliseconds);
  }
  encodeMs.sort();
  lagMs.sort();
  int pct(List<int> xs, double p) => xs[(xs.length * p).floor().clamp(0, xs.length - 1)];
  print(jsonEncode({
    'frames': files.length,
    'cadence_ms': cadenceMs,
    'bytes': totalBytes,
    'encode_ms': {'p50': pct(encodeMs, .5), 'p90': pct(encodeMs, .9), 'max': encodeMs.last},
    'jpeg_decode_ms_p50': (decodeMs..sort())[decodeMs.length ~/ 2],
    'frame_lag_ms': {'p50': pct(lagMs, .5), 'p90': pct(lagMs, .9), 'max': lagMs.last},
    'keeps_up': lagMs.last < cadenceMs,
  }));
}
