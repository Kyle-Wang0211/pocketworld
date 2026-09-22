import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_dense/dense_transaction_manifest.dart';

void main() {
  test('transaction binds model, fed manifest, and JPEG bytes', () {
    final root = Directory.systemTemp.createTempSync('dense-transaction-');
    addTearDown(() => root.deleteSync(recursive: true));
    final model = Directory('${root.path}/sparse')..createSync();
    for (final name in DenseTransactionManifest.modelFileNames) {
      File('${model.path}/$name').writeAsStringSync(name);
    }
    final image = File('${root.path}/frame.jpg')..writeAsBytesSync(<int>[1, 2]);
    final fed = File('${root.path}/official_sfm_fed_frames.jsonl')
      ..writeAsStringSync(
        '${jsonEncode(<String, Object?>{'frameId': 7, 'jpegPath': image.path})}\n',
      );

    DenseTransactionManifest.writeSync(
      stagedModelDirectory: model.path,
      fedFramesManifestPath: fed.path,
      generation: 'generation-1',
    );
    final manifest = DenseTransactionManifest.readAndValidateSync(
      markerPath: '${model.path}/handoff.ready',
      modelDirectory: model.path,
      fedFramesManifestPath: fed.path,
    );
    expect(manifest.generation, 'generation-1');
    expect(manifest.frames[7]!.sha256, hasLength(64));
    expect(
      () =>
          manifest.requireFrameMatchesSync(frameId: 7, sourcePath: image.path),
      returnsNormally,
    );

    image.writeAsBytesSync(<int>[1, 3]);
    expect(
      () =>
          manifest.requireFrameMatchesSync(frameId: 7, sourcePath: image.path),
      throwsFormatException,
    );

    File('${model.path}/cameras.bin').writeAsStringSync('changed');
    expect(
      () => DenseTransactionManifest.readAndValidateSync(
        markerPath: '${model.path}/handoff.ready',
        modelDirectory: model.path,
        fedFramesManifestPath: fed.path,
      ),
      throwsFormatException,
    );
  });
}
