// read_archive.dart — 随机访问读取器
//
// 取第 N 帧:查索引 → 定位 N 所在 GOP 的关键帧 → 只解码 K..N 这几个
// access unit(最多 GOP 长度个),输出该帧 NV12。绝不解码整条流。
//
// 用法: dart run bin/read_archive.dart <归档目录> <帧号> <输出.nv12>
// 输出 JSON 里带 decoded_units,证明只解了一个 GOP 的量。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

typedef _DecCreateC = Pointer<Void> Function(
    Int32, Int32, Pointer<Uint8>, Int64);
typedef _DecCreateD = Pointer<Void> Function(int, int, Pointer<Uint8>, int);
typedef _DecodeC = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Int64, Pointer<Uint8>, Pointer<Uint8>);
typedef _DecodeD = int Function(
    Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>);
typedef _DecDestroyC = Void Function(Pointer<Void>);
typedef _DecDestroyD = void Function(Pointer<Void>);

void main(List<String> args) {
  final dir = args[0];
  final target = int.parse(args[1]);
  final outPath = args[2];

  final manifest =
      jsonDecode(File('$dir/manifest.json').readAsStringSync());
  final res = (manifest['resolution'] as String).split('x');
  final w = int.parse(res[0]);
  final h = int.parse(res[1]);

  final entries = File('$dir/photos.pwvi')
      .readAsLinesSync()
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();
  if (target < 0 || target >= entries.length) {
    stderr.writeln('帧号越界');
    exit(2);
  }
  // 定位本 GOP 的关键帧
  var key = target;
  while (key > 0 && entries[key]['keyframe'] != true) {
    key--;
  }

  final libDir = File(Platform.script.toFilePath()).parent.parent.path;
  final lib = DynamicLibrary.open('$libDir/native/libpw_vt_decoder.dylib');
  final decCreate =
      lib.lookupFunction<_DecCreateC, _DecCreateD>('pw_vt_dec_create');
  final decode = lib.lookupFunction<_DecodeC, _DecodeD>('pw_vt_dec_decode');
  final decDestroy =
      lib.lookupFunction<_DecDestroyC, _DecDestroyD>('pw_vt_dec_destroy');

  final stream = File('$dir/photos.hevc').openSync();
  Uint8List au(Map<String, dynamic> e) {
    stream.setPositionSync(e['offset'] as int);
    return stream.readSync(e['len'] as int);
  }

  // 用关键帧 AU 建解码器(内含 VPS/SPS/PPS)
  final keyAu = au(entries[key]);
  final keyPtr = calloc<Uint8>(keyAu.length);
  keyPtr.asTypedList(keyAu.length).setAll(0, keyAu);
  final dec = decCreate(w, h, keyPtr, keyAu.length);
  if (dec == nullptr) {
    stderr.writeln('解码器创建失败');
    exit(1);
  }

  final ySize = w * h;
  final yPtr = calloc<Uint8>(ySize);
  final uvPtr = calloc<Uint8>(ySize ~/ 2);
  var decodedUnits = 0;
  final sw = Stopwatch()..start();
  for (var i = key; i <= target; i++) {
    final data = au(entries[i]);
    final p = calloc<Uint8>(data.length);
    p.asTypedList(data.length).setAll(0, data);
    final st = decode(dec, p, data.length, yPtr, uvPtr);
    calloc.free(p);
    if (st != 0) {
      stderr.writeln('AU $i 解码失败: $st');
      exit(1);
    }
    decodedUnits++;
  }
  sw.stop();
  stream.closeSync();
  decDestroy(dec);

  final sink = File(outPath).openSync(mode: FileMode.write);
  sink.writeFromSync(yPtr.asTypedList(ySize));
  sink.writeFromSync(uvPtr.asTypedList(ySize ~/ 2));
  sink.closeSync();

  print(jsonEncode({
    'frame': target,
    'gop_keyframe': key,
    'decoded_units': decodedUnits,
    'decode_ms': sw.elapsedMilliseconds,
    'source': entries[target]['source'],
  }));
}
