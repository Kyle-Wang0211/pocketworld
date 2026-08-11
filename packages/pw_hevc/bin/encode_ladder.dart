// encode_ladder.dart — 生产形态的 Dart FFI 编码路径(macOS = iOS 同一 C API)
//
// 证明目标:压缩管线的全部编排逻辑在 Dart,平台层只有一个 C shim,
// 零 Swift。本脚本用与 ffmpeg 阶梯完全相同的输入与参数驱动同一个
// VideoToolbox 引擎,输出尺寸应与 ffmpeg 结果同量级(等价性检查)。
//
// 用法: dart run bin/encode_ladder.dart <nv12文件> <宽> <高> <gop> <质量0-1> <输出.h265>

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _CreateC = Pointer<Void> Function(
    Int32, Int32, Int32, Double, Int64);
typedef _CreateD = Pointer<Void> Function(int, int, int, double, int);
typedef _EncodeC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>,
    Int64, Int64, Pointer<Pointer<Uint8>>, Pointer<Int64>, Pointer<Int32>);
typedef _EncodeD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>,
    int, int, Pointer<Pointer<Uint8>>, Pointer<Int64>, Pointer<Int32>);
typedef _FlushC = Int32 Function(Pointer<Void>);
typedef _FlushD = int Function(Pointer<Void>);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeD = void Function(Pointer<Uint8>);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);

void main(List<String> args) {
  if (args.length != 6) {
    stderr.writeln('用法: encode_ladder <nv12> <w> <h> <gop> <quality> <out>');
    exit(2);
  }
  final nv12Path = args[0];
  final w = int.parse(args[1]);
  final h = int.parse(args[2]);
  final gop = int.parse(args[3]);
  final quality = double.parse(args[4]);
  final outPath = args[5];

  final lib = DynamicLibrary.open(
      '${File(Platform.script.toFilePath()).parent.parent.path}/native/libpw_vt_encoder.dylib');
  final create = lib.lookupFunction<_CreateC, _CreateD>('pw_vt_create');
  final encode = lib.lookupFunction<_EncodeC, _EncodeD>('pw_vt_encode_nv12');
  final flush = lib.lookupFunction<_FlushC, _FlushD>('pw_vt_flush');
  final freeBuf = lib.lookupFunction<_FreeC, _FreeD>('pw_vt_free');
  final destroy = lib.lookupFunction<_DestroyC, _DestroyD>('pw_vt_destroy');

  final enc = create(w, h, gop, quality, 0);
  if (enc == nullptr) {
    stderr.writeln('编码器创建失败(分辨率 ${w}x$h 可能被拒)');
    exit(1);
  }

  final frameBytes = w * h * 3 ~/ 2;
  final ySize = w * h;
  final raw = File(nv12Path).openSync();
  final total = raw.lengthSync();
  final frameCount = total ~/ frameBytes;

  final yPtr = calloc<Uint8>(ySize);
  final uvPtr = calloc<Uint8>(ySize ~/ 2);
  final outData = calloc<Pointer<Uint8>>();
  final outLen = calloc<Int64>();
  final outKey = calloc<Int32>();

  final sink = File(outPath).openSync(mode: FileMode.write);
  var written = 0;
  var keyframes = 0;
  final sw = Stopwatch()..start();

  for (var i = 0; i < frameCount; i++) {
    final frame = raw.readSync(frameBytes);
    yPtr.asTypedList(ySize).setAll(0, frame.sublist(0, ySize));
    uvPtr.asTypedList(ySize ~/ 2).setAll(0, frame.sublist(ySize));
    final st = encode(enc, yPtr, uvPtr, i * 300, 300, outData, outLen, outKey);
    if (st != 0) {
      stderr.writeln('帧 $i 编码失败: OSStatus $st');
      exit(1);
    }
    final n = outLen.value;
    sink.writeFromSync(outData.value.asTypedList(n));
    written += n;
    if (outKey.value == 1) keyframes++;
    freeBuf(outData.value);
  }
  flush(enc);
  sink.closeSync();
  raw.closeSync();
  destroy(enc);
  sw.stop();

  print('{"schema":"pw_dart_ffi_encode_v1","frames":$frameCount,'
      '"keyframes":$keyframes,"bytes":$written,'
      '"encode_ms_per_frame":${(sw.elapsedMilliseconds / frameCount).toStringAsFixed(1)},'
      '"gop":$gop,"quality":$quality,"resolution":"${w}x$h"}');
}
