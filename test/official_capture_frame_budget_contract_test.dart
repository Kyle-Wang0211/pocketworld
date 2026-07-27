// [SIGNED 2026-07-27] 采集张数预算 20-300 的契约。
//
// 上限不是提示而是硬约束:端上重建的时间/内存曲线只在这个范围验证过,
// 超出即无保障。所以三处必须同源于 officialCaptureCanShoot —— 相册徽章
// 的分子/分母(RS 同款)、快门置灰、_onShutterTap 的逻辑兜底。任何一处
// 被改回"只提示不拦"或写死数字,本测试必须失败。
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

    // 相册徽章 = 分子/分母,且上限恒可见(不再是 "$count 张",也不再
    // 只在 count>0 时才出现 —— RS 从 0/300 起就显示预算)。
    expect(page, contains(r"'$count/$kOfficialMaximumCaptureFrames'"));
    expect(page, isNot(contains(r"'$count 张'")));

    // 快门置灰 + 逻辑兜底,两处都走同一个判据函数。
    expect(page, contains('enabled: ready && canShoot'));
    expect(page, contains('onTap: ready && canShoot ? onShutter : null'));
    expect(
      page,
      contains(
        'if (!officialCaptureCanShoot(acceptedFrameCount: '
        '_projectPhotos.count)) {',
      ),
    );
    expect(
      page,
      contains("ValueKey<String>('official-maximum-photos-dialog')"),
    );

    // 唯一拍照入口仍是 _onShutterTap(卡点覆盖完整的前提)。
    expect(
      RegExp(r'await session\.captureSinglePhoto\(\)').allMatches(page).length,
      1,
    );
  });
}
