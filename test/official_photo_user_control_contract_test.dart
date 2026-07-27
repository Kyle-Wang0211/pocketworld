import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  test('red photo warning is driven by the project-photo ledger', () {
    expect(captureSource, contains('shouldWarnDisconnected'));
    expect(captureSource, contains('照片未连接'));
    expect(captureSource, contains('请在红色照片附近补拍连接画面'));
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
    expect(deleteSource, contains('_projectPhotos.remove(path)'));
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
