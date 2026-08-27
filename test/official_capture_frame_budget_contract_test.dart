// [SIGNED 2026-07-27] 采集张数预算 20-300 的契约。
//
// 上限不是提示而是硬约束:端上重建的时间/内存曲线只在这个范围验证过。
// 快速连点时预算必须计算 已验证 + 在途 + 排队，不能只看相册里已经落盘
// 的数量，否则同一个事件循环内就能穿透 300 张上限。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/live_sfm_publish_policy.dart';

void main() {
  test('frame budget is 20-300 and the shoot gate follows the cap', () {
    expect(kOfficialMinimumCaptureFrames, 20);
    expect(kOfficialMaximumCaptureFrames, 300);

    // 下限门:满 20 才能结束。
    expect(officialCaptureCanFinish(acceptedFrameCount: 19), isFalse);
    expect(officialCaptureCanFinish(acceptedFrameCount: 20), isTrue);

    // 上限门:299 还能拍,300 拍满即止(不是 301)。
    expect(officialCaptureCanShoot(acceptedFrameCount: 0), isTrue);
    expect(officialCaptureCanShoot(acceptedFrameCount: 299), isTrue);
    expect(officialCaptureCanShoot(acceptedFrameCount: 300), isFalse);
    expect(officialCaptureCanShoot(acceptedFrameCount: 301), isFalse);
  });

  test('capture page shows the RS-style fraction and enforces the cap', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    // 相册上的预算 = 分子/分母,且上限恒可见(不再是 "$count 张",也不再
    // 只在 count>0 时才出现 —— RS 从 0/300 起就显示预算)。
    //
    // [2026-07-27 UI-4] 呈现形式改了、契约没改:分数从右下角黑胶囊挪进
    // 缩略图正中、去掉底色直接压在照片上、并按 RS 拆成上下堆叠的
    // 分子/横线/分母两个 Text。所以这里从"单串"改断言"两段都在"。
    expect(page, contains(r"Text('$count'"));
    expect(page, contains(r"Text('$kOfficialMaximumCaptureFrames'"));
    expect(page, isNot(contains(r"'$count 张'")));
    // 恒可见:不许再退回 count>0 才显示。
    expect(page, isNot(contains('if (count > 0)')));
    // 无底色:数字直接压在照片上,靠阴影保可读性。
    expect(page, contains('class _AlbumCountFraction'));

    // 快门置灰 + 逻辑兜底,两处都走同一个判据函数，并把队列算进预算。
    expect(
      page,
      contains('enabled: ready && shutterQueue.accepting && canShoot'),
    );
    expect(
      page,
      contains('onTap: ready && shutterQueue.accepting && canShoot'),
    );
    expect(
      page,
      contains('projectPhotos.count + shutterQueue.outstandingCount'),
    );
    expect(page, contains('verifiedCount: _projectPhotos.count'));
    expect(
      page,
      contains("ValueKey<String>('official-maximum-photos-dialog')"),
    );

    // 唯一原生拍照入口住在串行 executor；UI tap 只能同步入队。
    expect(
      RegExp(r'await session\.captureSinglePhoto\(').allMatches(page).length,
      1,
    );
    expect(page, contains('Future<void> _executeShutterTicket('));
    final shutterStart = page.indexOf('void _onShutterTap()');
    final shutterEnd = page.indexOf(
      'Future<void> _showMaximumPhotosDialog()',
      shutterStart,
    );
    expect(shutterStart, greaterThanOrEqualTo(0));
    expect(shutterEnd, greaterThan(shutterStart));
    final shutterSource = page.substring(shutterStart, shutterEnd);
    expect(shutterSource, contains('_shutterQueue.enqueue('));
    expect(shutterSource, isNot(contains('await ')));
    expect(shutterSource, isNot(contains('captureSinglePhoto')));
    expect(shutterSource, isNot(contains('TelemetryWriter')));
    expect(shutterSource, isNot(contains('DeviceLog')));
    expect(shutterSource, isNot(contains('_recomputeShutterPace')));
  });
}
