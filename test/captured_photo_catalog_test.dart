import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/captured_photo_catalog.dart';

void main() {
  test(
    'disk catalog includes all non-empty JPEGs, independent of curation',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'captured-photo-catalog-',
      );
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final first = File('${dir.path}/cell_0_slot_0_old.jpg');
      final second = File('${dir.path}/cell_0_slot_0_evicted.jpg');
      final empty = File('${dir.path}/unfinished.jpg');
      await first.writeAsBytes(const <int>[1]);
      await second.writeAsBytes(const <int>[2]);
      await first.setLastModified(DateTime.utc(2026, 7, 14, 1));
      await second.setLastModified(DateTime.utc(2026, 7, 14, 2));
      await empty.writeAsBytes(const <int>[]);
      await File('${dir.path}/cell_0_slot_0_evicted.json').writeAsString('{}');
      await File('${dir.path}/frame.sfm-gray').writeAsBytes(const <int>[0]);

      expect(await discoverCapturedPhotoPaths(dir), <String>[
        first.path,
        second.path,
      ]);
    },
  );
}
