import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pw_hevc/pw_ply.dart';

void main(List<String> args) {
  final original = Uint8List.fromList(File(args[0]).readAsBytesSync());
  final sw = Stopwatch()..start();
  final packed = compressPly(original);
  final encodeMs = sw.elapsedMilliseconds;
  sw..reset()..start();
  final restored = decompressPly(packed);
  final decodeMs = sw.elapsedMilliseconds;
  final same = restored.length == original.length &&
      sha256.convert(restored).toString() == sha256.convert(original).toString();
  print('{"original":${original.length},"compressed":${packed.length},'
      '"remaining_pct":${(100 * packed.length / original.length).toStringAsFixed(2)},'
      '"reduction_pct":${(100 - 100 * packed.length / original.length).toStringAsFixed(2)},'
      '"byte_exact_roundtrip":$same,"encode_ms":$encodeMs,"decode_ms":$decodeMs}');
  if (!same) exit(1);
}
