import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/project_photo_album.dart';
import 'package:pocketworld_flutter/ui/official_capture/ar_album_page.dart';

void main() {
  final captureSource = File(
    'lib/ui/official_capture/ar_capture_page.dart',
  ).readAsStringSync();
  final albumSource = File(
    'lib/ui/official_capture/ar_album_page.dart',
  ).readAsStringSync();
  final liveSource = File(
    'lib/official_capture/sfm_live_recon.dart',
  ).readAsStringSync();

  testWidgets('official album app bar has a single return control', (
    tester,
  ) async {
    final projectPhotos = OfficialProjectPhotoAlbum();
    addTearDown(projectPhotos.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ARAlbumPage(projectPhotos: projectPhotos, onDelete: (_) async {}),
      ),
    );

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.text('选择'), findsOneWidget);
    expect(find.text('返回补拍'), findsNothing);
  });

  test(
    'official album exposes analysis states and explicit user selection',
    () {
      expect(albumSource, contains('analysisState'));
      expect(albumSource, contains('未连接'));
      expect(albumSource, contains('处理中'));
      expect(albumSource, contains('低视差（PocketWorld 辅助提示）'));
      expect(albumSource, contains('选择'));
      expect(albumSource, contains('删除所选'));
      expect(albumSource, contains('返回补拍'));
    },
  );

  test('disconnected count and red state are driven by the project ledger', () {
    expect(albumSource, contains('projectPhotos.disconnectedCount'));
    expect(albumSource, contains('未连接'));
    expect(albumSource, contains('PhotoCardSfmState.disconnected'));
    expect(
      File('lib/official_capture/project_photo_album.dart').readAsStringSync(),
      contains('shouldWarnDisconnected'),
    );
  });

  test('SfM rejection marks the retained photo red instead of removing it', () {
    final rejectedFrameStart = captureSource.indexOf(
      "event is SfmLiveFrameFed",
    );
    // [增量D 2026-07-28] 旧边界标记 `if (event is SfmLiveArbitrateDone)` 随
    // L1/L2 残件清理删除;改用事件泵下一个稳定锚点(setState 开头)切片。
    final rejectedFrameEnd = captureSource.indexOf(
      'setState(() {',
      rejectedFrameStart,
    );
    final rejectedFrameSource = captureSource.substring(
      rejectedFrameStart,
      rejectedFrameEnd,
    );

    expect(
      rejectedFrameSource,
      contains('_markPhotoDisconnected(event.jpegPath!, event.result)'),
    );
    expect(
      captureSource,
      contains('const state = PhotoCardSfmState.disconnected'),
    );
    expect(rejectedFrameSource, isNot(contains('_markPhotoCardFailed(')));
    expect(rejectedFrameSource, isNot(contains('removePhotoCard')));
  });

  test('only explicit user deletion withdraws the photo from live SfM', () {
    final deleteStart = captureSource.indexOf(
      'Future<void> _deleteProjectPhoto',
    );
    final deleteEnd = captureSource.indexOf(
      'Future<bool> _writeCardThumbnail',
      deleteStart,
    );
    final deleteSource = captureSource.substring(deleteStart, deleteEnd);

    expect(deleteSource, contains('await recon.removePhoto('));
    expect(
      deleteSource,
      contains('await session.tombstoneCanonicalPhoto(path)'),
    );
    expect(deleteSource, isNot(contains('_projectPhotos.remove(path)')));
    expect(liveSource, contains('Future<bool> removePhoto(String jpegPath)'));
    expect(liveSource, contains("'cmd': 'remove_frame'"));
    expect(liveSource, contains('session!.removeFrame(frameId)'));
  });

  test(
    'draft manifest receives every project photo instead of a curated subset',
    () {
      expect(
        captureSource,
        matches(
          RegExp(
            r'session\.writeProjectPhotoBundleManifest\(\s*'
            r'_projectPhotos\.paths,\s*\)',
          ),
        ),
      );
      expect(
        captureSource,
        isNot(contains('session.writePhotoBundleManifest(curatedFrames)')),
      );
    },
  );
}
