import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_dense/dense_handoff.dart';

void main() {
  late Directory root;
  late Directory model;
  late File fedManifest;
  late Directory plannedImages;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('official_dense_handoff_');
    model = await Directory('${root.path}/sparse').create();
    for (final name in const ['cameras.bin', 'images.bin', 'points3D.bin']) {
      await File('${model.path}/$name').writeAsBytes(utf8.encode(name));
    }
    plannedImages = Directory('${root.path}/dense/images');
    fedManifest = File('${root.path}/official_sfm_fed_frames.jsonl');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> source(int frameId) async {
    final file = File('${root.path}/source_$frameId.jpg');
    await file.writeAsBytes([frameId, frameId + 1, frameId + 2]);
    return file;
  }

  Future<void> writeFedRows(List<Map<String, Object?>> rows) => fedManifest
      .writeAsString(rows.map(jsonEncode).map((row) => '$row\n').join());

  test(
    'freezes the refined sparse model and plans images without copying',
    () async {
      final frame0 = await source(0);
      final frame12 = await source(12);
      await writeFedRows([
        {'frameId': 0, 'jpegPath': frame0.path},
        {'frameId': 12, 'jpegPath': frame12.path},
      ]);

      final handoff = await OfficialDenseHandoff.freeze(
        modelDirectory: model.path,
        fedFramesManifestPath: fedManifest.path,
        materializationDirectory: plannedImages.path,
        registeredImageNames: const ['frame_000012.jpg', 'frame_000000.jpg'],
      );

      expect(handoff.modelFiles.map((file) => file.fileName), [
        'cameras.bin',
        'images.bin',
        'points3D.bin',
      ]);
      expect(handoff.modelFiles.every((file) => file.byteSize > 0), isTrue);
      expect(
        handoff.modelFiles.every(
          (file) => RegExp(r'^[0-9a-f]{64}$').hasMatch(file.sha256),
        ),
        isTrue,
      );
      expect(handoff.fedFramesManifest.byteSize, greaterThan(0));
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(handoff.fedFramesManifest.sha256),
        isTrue,
      );
      expect(handoff.materializationPlan.map((entry) => entry.imageName), [
        'frame_000000.jpg',
        'frame_000012.jpg',
      ]);
      expect(handoff.materializationPlan[0].sourcePath, frame0.path);
      expect(
        handoff.materializationPlan[0].destinationPath,
        '${plannedImages.path}/frame_000000.jpg',
      );
      expect(handoff.materializationPlan[0].byteSize, 3);
      expect(
        RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(handoff.materializationPlan[0].sha256),
        isTrue,
      );

      // This layer returns a plan only. The later native workspace stage owns
      // hard-link/copy execution and must not be pre-empted here.
      expect(await plannedImages.exists(), isFalse);

      expect(
        () =>
            handoff.materializationPlan.add(handoff.materializationPlan.first),
        throwsUnsupportedError,
      );
      expect(
        () => handoff.modelFiles.add(handoff.modelFiles.first),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'fails closed when a required COLMAP model file is absent or empty',
    () async {
      final frame0 = await source(0);
      await writeFedRows([
        {'frameId': 0, 'jpegPath': frame0.path},
      ]);

      await File('${model.path}/points3D.bin').writeAsBytes([]);
      await expectLater(
        OfficialDenseHandoff.freeze(
          modelDirectory: model.path,
          fedFramesManifestPath: fedManifest.path,
          materializationDirectory: plannedImages.path,
          registeredImageNames: const ['frame_000000.jpg'],
        ),
        throwsA(
          isA<DenseHandoffException>().having(
            (error) => error.code,
            'code',
            DenseHandoffError.invalidModel,
          ),
        ),
      );
    },
  );

  test(
    'rejects missing, duplicate, malformed, and absent fed-frame evidence',
    () async {
      final frame0 = await source(0);
      await writeFedRows([
        {'frameId': 0, 'jpegPath': frame0.path},
        {'frameId': 0, 'jpegPath': frame0.path},
      ]);

      Future<void> expectFedFailure() => expectLater(
        OfficialDenseHandoff.freeze(
          modelDirectory: model.path,
          fedFramesManifestPath: fedManifest.path,
          materializationDirectory: plannedImages.path,
          registeredImageNames: const ['frame_000000.jpg'],
        ),
        throwsA(
          isA<DenseHandoffException>().having(
            (error) => error.code,
            'code',
            DenseHandoffError.invalidFedFrames,
          ),
        ),
      );

      await expectFedFailure();

      await writeFedRows([
        {'frameId': 0, 'jpegPath': frame0.path},
      ]);
      await expectLater(
        OfficialDenseHandoff.freeze(
          modelDirectory: model.path,
          fedFramesManifestPath: fedManifest.path,
          materializationDirectory: plannedImages.path,
          registeredImageNames: const ['frame_000001.jpg'],
        ),
        throwsA(isA<DenseHandoffException>()),
      );

      await writeFedRows([
        {'frameId': 1, 'jpegPath': '${root.path}/does-not-exist.jpg'},
      ]);
      await expectLater(
        OfficialDenseHandoff.freeze(
          modelDirectory: model.path,
          fedFramesManifestPath: fedManifest.path,
          materializationDirectory: plannedImages.path,
          registeredImageNames: const ['frame_000001.jpg'],
        ),
        throwsA(isA<DenseHandoffException>()),
      );

      await writeFedRows([
        {'frameId': 'not-an-int', 'jpegPath': frame0.path},
      ]);
      await expectFedFailure();
    },
  );

  test(
    'requires unique canonical registered reconstruction image names',
    () async {
      final frame0 = await source(0);
      await writeFedRows([
        {'frameId': 0, 'jpegPath': frame0.path},
      ]);

      for (final names in const [
        ['capture.jpg'],
        ['frame_0.jpg'],
        ['frame_000000.jpg', 'frame_000000.jpg'],
        <String>[],
      ]) {
        await expectLater(
          OfficialDenseHandoff.freeze(
            modelDirectory: model.path,
            fedFramesManifestPath: fedManifest.path,
            materializationDirectory: plannedImages.path,
            registeredImageNames: names,
          ),
          throwsA(
            isA<DenseHandoffException>().having(
              (error) => error.code,
              'code',
              DenseHandoffError.invalidRegisteredImages,
            ),
          ),
        );
      }
    },
  );
}
