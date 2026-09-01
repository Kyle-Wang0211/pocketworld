import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_record_store.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_transaction.dart';
import 'package:pocketworld_flutter/official_capture/photo_card_state.dart';
import 'package:pocketworld_flutter/official_capture/project_photo_album.dart';
import 'package:pocketworld_flutter/ui/official_capture/ar_album_page.dart';

void main() {
  late Directory tempDir;
  late File photo;
  late OfficialProjectPhotoAlbum album;
  late AcceptedPhotoRecordStore store;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('official_album_widget_');
    photo = File('${tempDir.path}/photo.jpg')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    album = OfficialProjectPhotoAlbum();
    store = await AcceptedPhotoRecordStore.open(tempDir);
    await store.publish(_record(photo.path), canPublish: () => true);
  });

  tearDown(() {
    album.dispose();
    tempDir.deleteSync(recursive: true);
  });

  testWidgets('shows pending and disconnected states without removing photo', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ARAlbumPage(projectPhotos: album, onDelete: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已收集 1 张'), findsOneWidget);
    expect(find.text('处理中'), findsOneWidget);

    album.updateAnalysisState(photo.path, PhotoCardSfmState.disconnected);
    await tester.pump();

    expect(find.text('已收集 1 张 · 1 未连接'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(album.count, 1);
    expect(photo.existsSync(), isTrue);
  });

  testWidgets('deletes only after explicit select and confirmation', (
    tester,
  ) async {
    var deleteCalls = 0;
    final deletionCommitted = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: ARAlbumPage(
          projectPhotos: album,
          onDelete: (path) async {
            deleteCalls++;
            await deletionCommitted.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择'));
    await tester.pump();
    await tester.tap(find.text('处理中'));
    await tester.pump();
    expect(deleteCalls, 0);

    await tester.tap(find.text('删除所选(1)'));
    await tester.pumpAndSettle();
    expect(deleteCalls, 0);

    await tester.tap(find.widgetWithText(FilledButton, '删除所选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(deleteCalls, 1);
    await tester.runAsync(() async {
      expect(await store.tombstone('album-widget-1'), isTrue);
      if (await photo.exists()) await photo.delete();
      deletionCommitted.complete();
    });
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(album.count, 0);
    expect(photo.existsSync(), isFalse);
  });
}

AcceptedPhotoRecord _record(String jpegPath) => AcceptedPhotoRecord(
  transactionId: 'album-widget-1',
  generation: 1,
  frameId: 'frame-1',
  jpegPath: jpegPath,
  previewPath: '$jpegPath.preview.jpg',
  automaticSelection: false,
  imageWidth: 4032,
  imageHeight: 3024,
  triggerTimestamp: 1,
  captureTimestamp: 1,
  cameraTransform: const <double>[
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ],
  intrinsics: const <double>[2000, 2000, 2016, 1512],
  captureKind: 'arkit_high_res_still',
  poseSyncQuality: 'ar_session_high_res_frame',
  trackingStateName: 'normal',
  gray128Base64: null,
  sample: const <String, Object?>{},
  quality: const <String, Object?>{},
);
