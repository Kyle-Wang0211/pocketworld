import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/maintenance/capture_source_cleanup.dart';

void main() {
  test(
    'keeps sparse PLY and project index while trimming only caps below cutoff',
    () async {
      final documents = await Directory.systemTemp.createTemp(
        'capture-source-cleanup-',
      );
      addTearDown(() async {
        if (await documents.exists()) await documents.delete(recursive: true);
      });

      final records = <Map<String, Object?>>[
        <String, Object?>{'id': 'cap_29', 'name': '\u672a\u547d\u540d(29)'},
        <String, Object?>{'id': 'cap_30', 'name': '\u672a\u547d\u540d(30)'},
        <String, Object?>{'id': 'cap_8', 'name': '\u672a\u547d\u540d(8)'},
        <String, Object?>{'id': 'remote-id', 'name': 'Cloud capture'},
      ];
      final recordsFile = File('${documents.path}/scan_records.json');
      await recordsFile.writeAsString(jsonEncode(records), flush: true);

      final cap29 = Directory('${documents.path}/captures/cap_29');
      final cap30 = Directory('${documents.path}/captures/cap_30');
      final cap8 = Directory('${documents.path}/captures/cap_8');
      await cap29.create(recursive: true);
      await cap30.create(recursive: true);
      await cap8.create(recursive: true);
      await File('${cap29.path}/sfm_sparse.ply').writeAsString('ply\n');
      await File(
        '${cap29.path}/sfm_live.db',
      ).writeAsBytes(List<int>.filled(5, 1));
      await Directory('${cap29.path}/photos_highres').create();
      await File(
        '${cap29.path}/photos_highres/photo.jpg',
      ).writeAsBytes(List<int>.filled(7, 2));
      await File('${cap30.path}/sfm_sparse.ply').writeAsString('ply\n');
      await File(
        '${cap30.path}/photo.jpg',
      ).writeAsBytes(List<int>.filled(11, 3));
      await File(
        '${cap8.path}/photo.jpg',
      ).writeAsBytes(List<int>.filled(13, 4));

      final result = await cleanCaptureSourcesBefore(
        documentsDirectory: documents,
        cutoff: 30,
      );

      expect(result.cleanedCaptureNumbers, <int>[8, 29]);
      expect(result.preservedSparseCaptureNumbers, <int>[29]);
      expect(result.missingSparseCaptureNumbers, <int>[8]);
      expect(result.deletedBytes, 25);
      expect(result.errors, isEmpty);
      expect(
        await File('${cap29.path}/sfm_sparse.ply').readAsString(),
        'ply\n',
      );
      expect(await cap29.list().map((entry) => entry.path).toList(), <String>[
        '${cap29.path}/sfm_sparse.ply',
      ]);
      expect(await File('${cap30.path}/photo.jpg').length(), 11);
      expect(await cap8.list().isEmpty, isTrue);
      expect(jsonDecode(await recordsFile.readAsString()), records);
    },
  );
}
