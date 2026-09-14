// 原生启动屏的底色必须等于 **Flutter 第一帧** 的底色。
//
// 🔴 2026-09-14 查实的断裂:LaunchScreen.storyboard 写的是暖白 #FAFAFA,注释还
// 声称"与 AetherColors.bg 一致,所以 LaunchScreen → Flutter 交接无闪"。但
// Flutter 的第一帧**不是 Scaffold**,是启动浮层 —— 而浮层早就改成了纯黑
// (splash_overlay.dart:ColoredBox(color: Colors.black) 与 SplashDoorPainter
// 的黑挡板)。没人回头改 storyboard,于是每次冷启动都是整屏白 → 硬切纯黑。
//
// 这条判据把"第一帧的颜色"和"原生启动屏的颜色"绑在一起,断了就判红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String storyboard;
  late String overlaySrc;

  setUpAll(() {
    final sb = File('ios/Runner/Base.lproj/LaunchScreen.storyboard');
    final ov = File('lib/ui/splash_overlay.dart');
    expect(sb.existsSync(), isTrue, reason: '启动屏文件搬家了 —— 先修锚');
    expect(ov.existsSync(), isTrue);
    storyboard = sb.readAsStringSync();
    // 只看代码,不看注释 —— 上面那段解释里就写着 Colors.black。
    overlaySrc = ov
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
  });

  ({double r, double g, double b}) _bg() {
    final m = RegExp(
      r'<color key="backgroundColor" red="([\d.]+)" green="([\d.]+)" blue="([\d.]+)"',
    ).firstMatch(storyboard);
    expect(m, isNotNull, reason: 'storyboard 里找不到 backgroundColor —— 先修锚');
    return (
      r: double.parse(m!.group(1)!),
      g: double.parse(m.group(2)!),
      b: double.parse(m.group(3)!),
    );
  }

  test('锚点自身可读(阳性对照)', () {
    expect(storyboard.contains('key="backgroundColor"'), isTrue);
    expect(_bg().r, inInclusiveRange(0, 1));
  });

  test('🔴 Flutter 第一帧是纯黑(浮层底色)', () {
    expect(
      overlaySrc.contains('color: Colors.black'),
      isTrue,
      reason: '浮层底色改了 —— 那 storyboard 也要跟着改,别只改一边',
    );
  });

  test('🔴 原生启动屏必须同为纯黑 —— 否则每次冷启动都是整屏白闪一下', () {
    final bg = _bg();
    for (final c in <(String, double)>[('red', bg.r), ('green', bg.g), ('blue', bg.b)]) {
      expect(
        c.$2,
        lessThan(0.02),
        reason:
            'LaunchScreen 的 ${c.$1}=${c.$2} 不是黑 —— 原生启动屏与 Flutter '
            '第一帧不同色,交接处会整屏闪一下(这正是 2026-09-14 查实的那一处)',
      );
    }
  });
}
