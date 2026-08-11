import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pw_hevc/pw_sidecar.dart';

void main(List<String> args) {
  final dir = Directory(args[0]);
  final entries = <SidecarEntry>[];
  var total = 0;
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json') && !f.path.endsWith('.jsonl')) continue;
    final bytes = Uint8List.fromList(f.readAsBytesSync());
    entries.add(SidecarEntry(f.uri.pathSegments.last, bytes));
    total += bytes.length;
  }
  final packed = packSidecars(entries);
  final restored = unpackSidecars(Uint8List.fromList(packed));
  var ok = restored.length == entries.length;
  for (final r in restored) {
    final src = entries.firstWhere((e) => e.path == r.path);
    if (sha256.convert(r.bytes).toString() != sha256.convert(src.bytes).toString()) ok = false;
  }
  print('{"files":${entries.length},"original":$total,"packed":${packed.length},'
      '"remaining_pct":${(100 * packed.length / total).toStringAsFixed(1)},'
      '"byte_exact":$ok}');
}
