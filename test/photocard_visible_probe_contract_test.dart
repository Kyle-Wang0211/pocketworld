// 「相框真正进场景」那一刻的埋点契约。
//
// [2026-09-11 用户令]「在 native addPhotoCard 真正把相框挂进场景的那一刻补一条
// 埋点」。起因:用户报「有两次震动了但是没拍照」。未命名(10) 的账能证明照片
// 没丢(36 震动 = 36 照片 = 36 相框 = 36 帧入重建、hires_still failed=0),却
// **证伪不了**"相框迟迟不出现"那半 —— 因为当时唯一沾边的 `card` 埋点记的是
// 相框**变色**(黑=处理中→白=已注册),不是相框**出现**。
//
// 判据全部先剥注释:本文件描述的 `CACurrentMediaTime` / `UIImage` 之类词
// 在被测文件的注释里大量出现,不剥就会判到自己的注释上(同一个坑
// 2026-08-22 / 09-10 / 09-11 各踩过一次)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _strip(String src) => src
    .split('\n')
    .where(
      (l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
    )
    .join('\n');

void main() {
  late String swift;
  late String dart;
  late List<String> swiftLines;

  setUpAll(() {
    final sf = File('ios/Runner/OfficialAetherARKitPlugin.swift');
    final df = File('lib/ui/official_capture/ar_capture_page.dart');
    expect(sf.existsSync(), isTrue);
    expect(df.existsSync(), isTrue);
    swift = _strip(sf.readAsStringSync());
    dart = _strip(df.readAsStringSync());
    swiftLines = swift.split('\n');
  });

  test('锚点自身可读(阳性对照:锚没了要报锚没了,不是报回归)', () {
    expect(swift.contains('node.addChildNode(container)'), isTrue);
    expect(swift.contains('case "addPhotoCard":'), isTrue);
    expect(dart.contains("invokeMethod<void>('addPhotoCard'"), isTrue);
  });

  test('🔴 两条建卡路径挂进场景的**下一行**就记账', () {
    final attach = <int>[
      for (var i = 0; i < swiftLines.length; i++)
        if (swiftLines[i].contains('node.addChildNode(container)')) i,
    ];
    expect(
      attach.length,
      2,
      reason: '带照片的 buildPhotoCard 与只有黑框的 buildPhotoCardShell,各一处',
    );
    for (final i in attach) {
      final window = swiftLines.sublist(i, (i + 7).clamp(0, swiftLines.length));
      expect(
        window.any((l) => l.contains('logPhotoCardVisible(')),
        isTrue,
        reason: '第 ${i + 1} 行挂进场景后 7 行内没有埋点 —— 埋点必须贴着挂接那一刻',
      );
    }
  });

  test('两种形态分开记:shell(只有黑框)与 photo(带照片)', () {
    expect(swift.contains('kind: "photo"'), isTrue);
    expect(swift.contains('kind: "shell"'), isTrue);
    expect(swift.contains('"photocard_visible"'), isTrue);
  });

  test('🔴 时间戳必须同域(墙钟),不许用 mach 单调钟', () {
    final start = swift.indexOf('private func logPhotoCardVisible(');
    expect(start, greaterThanOrEqualTo(0));
    final body = swift.substring(start, start + 1400);
    expect(
      body.contains('Date().timeIntervalSince1970'),
      isTrue,
      reason: 'Dart 给的是 millisecondsSinceEpoch,只能拿墙钟相减',
    );
    expect(
      body.contains('CACurrentMediaTime'),
      isFalse,
      reason: 'mach 单调钟与 Dart 不同域,相减出来的数没有意义(08-30 时钟域定罪)',
    );
    expect(
      swift.contains('addCalledEpochMs: Date().timeIntervalSince1970'),
      isTrue,
    );
  });

  test('重复挂接不重复记账(重试路径会多次走到 didAdd)', () {
    expect(swift.contains('photoCardVisibleLogged'), isTrue);
    final start = swift.indexOf('private func logPhotoCardVisible(');
    final body = swift.substring(start, start + 1400);
    expect(body.contains('guard !photoCardVisibleLogged.contains(key)'), isTrue);
  });

  test('🔴 Dart 把震动那一刻的墙钟传过去,且震动与通道调用之间没有 await', () {
    expect(dart.contains("'shutterFeedbackEpochMs': feedbackEpochMs"), isTrue);
    final h = dart.indexOf('_triggerShutterHaptic();');
    final c = dart.indexOf("invokeMethod<void>('addPhotoCard'");
    expect(h, greaterThanOrEqualTo(0));
    expect(c, greaterThan(h));
    final between = dart.substring(h, c);
    expect(
      between.contains('await '),
      isFalse,
      reason: '用户底线:震动与黑相框之间不得有 await —— 加埋点不许动这条',
    );
    expect(
      between.contains('DateTime.now().millisecondsSinceEpoch'),
      isTrue,
      reason: '取的必须是震动那一刻,不是通道返回那一刻',
    );
  });
}
