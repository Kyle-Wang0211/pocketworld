import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_policy.dart';
import 'package:pocketworld_flutter/official_capture/transient_preview_cleanup.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('official-preview-cleanup-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('marked future capture deletes only transient previews', () async {
    final capture = Directory('${root.path}/captures_official/future');
    final highres = Directory('${capture.path}/photos_highres');
    final previews = Directory('${capture.path}/previews');
    final thumbnail = File('${root.path}/scans_official/future.jpg');
    await highres.create(recursive: true);
    await previews.create(recursive: true);
    await thumbnail.parent.create(recursive: true);
    await PhotoArchivePolicy.writeForNewCapture(capture);
    final photo = File('${highres.path}/frame.jpg')
      ..writeAsBytesSync(const [1, 2, 3]);
    final preview = File('${previews.path}/frame.jpg')
      ..writeAsBytesSync(const [4, 5, 6]);
    thumbnail.writeAsBytesSync(const [7, 8, 9]);

    final removed = await removeTransientCapturePreviews(capture);

    expect(removed, isTrue);
    expect(await previews.exists(), isFalse);
    expect(await preview.exists(), isFalse);
    expect(await photo.exists(), isTrue);
    expect(await thumbnail.exists(), isTrue);
  });

  test('unmarked legacy capture is never cleaned', () async {
    final capture = Directory('${root.path}/captures_official/legacy');
    final previews = Directory('${capture.path}/previews');
    await previews.create(recursive: true);
    final preview = File('${previews.path}/frame.jpg')
      ..writeAsBytesSync(const [1, 2, 3]);

    final removed = await removeTransientCapturePreviews(capture);

    expect(removed, isFalse);
    expect(await preview.exists(), isTrue);
  });

  test('draft record is durable before immediate cleanup is requested', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final persisted = page.indexOf('await store.addOrUpdate(record);');
    final cleaned = page.indexOf('removeTransientCapturePreviews(captureDir)');

    expect(persisted, greaterThanOrEqualTo(0));
    expect(cleaned, greaterThan(persisted));
  });

  test('future capture manifest does not publish preview filenames', () {
    final session = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();

    expect(session, isNot(contains('previewFilename:')));
  });
}
