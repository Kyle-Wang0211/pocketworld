import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/ui/official_capture/ar_capture_page.dart',
  ).readAsStringSync();

  test('official finish stays tappable but blocks completion below 20', () {
    expect(source, contains('officialCaptureCanFinish('));
    expect(
      source,
      contains("ValueKey<String>('official-minimum-photos-dialog')"),
    );
    expect(source, contains('要结束任务，必须至少拍摄20张照片'));
    expect(source, contains('当前已完成'));
    expect(
      source,
      contains('onFinish: _sfmCaptureReady && !_finalizingRecording'),
    );
  });

  // [2026-07-27 UI 签决] 入场提示改为完成门提示:开拍时不再弹任何"20 张"
  // 横幅(它挡取景框、说的又是用户此刻做不了的事),同一句话只在用户不足
  // 20 张就点完成时出现。断言两头都锁:横幅确实没了 + 文案确实在对话框里。
  test('the multi-angle notice fires only at the under-20 finish gate', () {
    expect(
      source,
      isNot(contains("ValueKey<String>('official-capture-entry-tip')")),
    );
    expect(source, isNot(contains('_entryTipVisible')));

    final dialogStart = source.indexOf(
      "ValueKey<String>('official-minimum-photos-dialog')",
    );
    expect(dialogStart, greaterThanOrEqualTo(0));
    final dialogEnd = source.indexOf('actions:', dialogStart);
    final dialogSource = source.substring(dialogStart, dialogEnd);

    expect(dialogSource, contains('尽量从更多不同角度拍摄照片'));
    expect(dialogSource, contains('完成20张并分析后，点云会覆盖显示在物体上'));
  });

  test(
    'official AR overlay receives only globally published SfM snapshots',
    () {
      final live = File(
        'lib/official_capture/sfm_live_recon.dart',
      ).readAsStringSync();

      expect(live, contains('OfficialLiveSfmPublishPolicy'));
      expect(live, contains("'source': 'streaming_global_ba'"));
      expect(source, contains('_publishOfficialSfmCloudToAr'));
      expect(
        source,
        contains('snapshot.summary[\'source\'] == \'streaming_global_ba\''),
      );
    },
  );

  test('official capture exposes one project image count', () {
    final albumStart = source.indexOf('class _AlbumThumbButton');
    final albumEnd = source.indexOf('class _ShutterButton', albumStart);
    final albumSource = source.substring(albumStart, albumEnd);

    expect(source, isNot(contains('_ProjectImageCountChip(')));
    expect(source, contains('final OfficialProjectPhotoAlbum _projectPhotos'));
    expect(source, contains('_projectPhotos.commitVerified('));
    expect(source, contains('acceptedFrameCount = _projectPhotos.count'));
    // [SIGNED 2026-07-27] 计数徽章改成 RS 同款分子/分母(N/300):上限恒
    // 可见,详见 official_capture_frame_budget_contract_test.dart。
    expect(source, contains(r"'$count/$kOfficialMaximumCaptureFrames'"));
    expect(source, isNot(contains("'\$count 张'")));
    expect(albumSource, contains('required this.count,'));
    expect(albumSource, contains('final int count;'));
    expect(source, isNot(contains(r"'$fed 帧'")));
  });

  test('official album reads the verified project-photo ledger', () {
    final album = File(
      'lib/ui/official_capture/ar_album_page.dart',
    ).readAsStringSync();

    expect(album, contains('OfficialProjectPhotoAlbum'));
    expect(album, contains('widget.projectPhotos.photos'));
    expect(album, isNot(contains('widget.targetPoints.retainedJpegPaths')));
  });

  test(
    'official live global BA is a serial checkpoint in the frame worker',
    () {
      final live = File(
        'lib/official_capture/sfm_live_recon.dart',
      ).readAsStringSync();

      final frameCase = live.indexOf("case 'jpeg_frame':");
      final liveGlobalBa = live.indexOf(
        'final globalResult = session!.globalRefine();',
      );
      final nextWorkerCase = live.indexOf("case 'resume':");
      expect(frameCase, greaterThanOrEqualTo(0));
      expect(liveGlobalBa, greaterThan(frameCase));
      expect(liveGlobalBa, lessThan(nextWorkerCase));
      expect(live, isNot(contains("'cmd': 'global_ba'")));
    },
  );

  test('official finish drains every frame before native final global BA', () {
    final live = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();

    expect(live, contains('sfmFeedCanSendFinalize('));
    expect(live, contains('final summary = s.finalizeAsync();'));
    expect(live, contains("sendSnapshot('refined', summary, ms);"));
  });
}
