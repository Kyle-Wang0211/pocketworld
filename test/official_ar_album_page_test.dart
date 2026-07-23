import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_card_state.dart';
import 'package:pocketworld_flutter/official_capture/project_photo_album.dart';
import 'package:pocketworld_flutter/ui/official_capture/ar_album_page.dart';

void main() {
  late Directory tempDir;
  late File photo;
  late OfficialProjectPhotoAlbum album;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('official_album_widget_');
    photo = File('${tempDir.path}/photo.jpg')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    album = OfficialProjectPhotoAlbum();
    album.commitVerified(
      jpegPath: photo.path,
      captureTimestamp: 1,
      imageWidth: 4032,
      imageHeight: 3024,
    );
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
    await tester.pumpWidget(
      MaterialApp(
        home: ARAlbumPage(
          projectPhotos: album,
          onDelete: (path) async {
            deleteCalls++;
            album.remove(path);
            await File(path).delete();
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

    await tester.tap(find.text('删除所选').last);
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(album.count, 0);
    expect(photo.existsSync(), isFalse);
  });
}
