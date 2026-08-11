// 拍摄页顶栏与相册徽章版式(源码钉子,先例:capture_quality_ramp_test)。
//
// [2026-08-10 用户签决,附截图+手绘]
//   ① 右上角"×"→ 左上角"<",功能不变(仍走 _onCloseTap);
//   ② 相册徽章撤下缩略图照片,改斜杠分数:左上大分子(已拍帧数)+ 斜杠 +
//      右下小 300。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File(
    'lib/ui/official_capture/ar_capture_page.dart',
  ).readAsStringSync();

  test('关闭按钮:左上角"<",不再是右上角"×"', () {
    expect(
      src.contains('Icons.arrow_back_ios_new_rounded'),
      isTrue,
      reason: '关闭按钮图标不是"<"了',
    );
    // 顶栏那行必须左对齐;唯一的 _CloseButton Row 不许回到 end。
    final row = RegExp(
      r'mainAxisAlignment: MainAxisAlignment\.(\w+),\s*\n\s*children: \[_CloseButton',
    ).firstMatch(src);
    expect(row, isNotNull, reason: '找不到关闭按钮所在的 Row');
    expect(
      row!.group(1),
      'start',
      reason: '关闭按钮回到右上角了(MainAxisAlignment.${row.group(1)})',
    );
    // 退出功能不变:仍接 _onCloseTap。
    expect(src.contains('_CloseButton(onTap: _onCloseTap)'), isTrue);
  });

  test('相册徽章:无缩略图照片,斜杠分数(大分子+小分母)', () {
    // 缩略图照片必须撤下 —— 徽章 Stack 里不再画 latestPath 的 Image.file。
    expect(
      RegExp(r'Image\.file\(\s*File\(latestPath!\)').hasMatch(src),
      isFalse,
      reason: '相册徽章还在显示照片缩略图',
    );
    // 斜杠版式在(Transform.rotate 的斜杠 + 左上/右下 Positioned)。
    expect(src.contains('// 斜杠:竖线顺时针转'), isTrue, reason: '斜杠分数版式不在了');
    // 上限恒可见(07-27 签决延续)。
    expect(src.contains(r"'$kOfficialMaximumCaptureFrames'"), isTrue);
  });
}
