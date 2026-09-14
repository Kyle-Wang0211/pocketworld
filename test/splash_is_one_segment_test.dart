// 启动动画必须是**一段**,不是两段。
//
// 🔴 用户 2026-09-14 实机指认:「每次 app 初始的加载 ui,我总感觉是分两段的:
// 一段是加载,一段是打开,中间的卡顿瞬间非常明显」。
//
// 查实(读代码,不是猜):main.dart 里**真的挂了两个** AetherSplashOverlay,
// 串着放 ——
//   ① _AuthGate 那个:fade 档,里面是 SplashSolvingOrb,最短 900ms;
//   ② HomeScreen 那个:directLineDoor 档,里面是 SplashDirectLineField,
//      最短 1200ms,而且还要等 createSharedNativeTexture + DamagedHelmet.glb。
// 两者是**不同的 widget、各自一只 Stopwatch**(splash_solving_orb.dart:77 与
// :433 各 new 了一个)。①淡出 420ms 的那一段里,②已经满不透明地在底下跑,
// 点阵相位对不上 ⇒ 当场跳一下;而这 420ms 又正好压在 AetherAppShell 首次
// build 上。两件事叠在同一个瞬间 = 用户说的那个「卡顿瞬间」。
//
// 判据:**全仓只许有一个浮层实例**,且它就是带开门动画的那一个。
// 这条不看渲染结果看接线 —— 渲染结果里两个黑底浮层长得一模一样,
// 肉眼和 widget test 都分不出是一个还是两个。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> codeLines;

  setUpAll(() {
    // 🔴 判据必须先剥注释 —— 本文件上面这段解释里就写着浮层的名字,
    // 不剥的话我会被自己的注释判红(老教训)。
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        // 定义处本身当然写着这个名字,只查**调用点**。
        .where((f) => !f.path.endsWith('ui/splash_overlay.dart'));
    codeLines = <String>[
      for (final f in files)
        for (final l in f.readAsStringSync().split('\n'))
          if (!l.trimLeft().startsWith('//')) '${f.path}|$l',
    ];
  });

  List<String> get_() => codeLines
      .where((l) => l.split('|')[1].contains('AetherSplashOverlay('))
      .toList();

  test('锚点自身可读(阳性对照)', () {
    expect(
      File('lib/ui/splash_overlay.dart').existsSync(),
      isTrue,
      reason: '浮层改名/搬家了 —— 先修锚,别把它读成回归',
    );
    expect(codeLines, isNotEmpty);
  });

  test('🔴 全仓只许挂一个启动浮层', () {
    final sites = get_();
    expect(
      sites.length,
      1,
      reason:
          '挂了 ${sites.length} 个:\n${sites.join('\n')}\n'
          '两个浮层 = 两只时钟 = 交接处必然跳一下。要加载态请改**同一个**'
          '浮层的可见条件,不要再叠第二个。',
    );
    expect(sites.single.split('|')[0], endsWith('lib/main.dart'));
  });

  test('🔴 那唯一一个必须是带开门动画的档(否则"打开"这一段就没了)', () {
    final src = File('lib/main.dart')
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .toList();
    final at = src.indexWhere((l) => l.contains('AetherSplashOverlay('));
    expect(at, greaterThanOrEqualTo(0));
    final window = src.sublist(at, (at + 6).clamp(0, src.length)).join('\n');
    expect(
      window.contains('SplashExitStyle.directLineDoor'),
      isTrue,
      reason: '退场动画(直线→开门)就是"打开"那一段,它必须长在唯一那个浮层上',
    );
  });

  test('🔴 开门要等真 UI 画过一帧 —— 别让首帧的重活撞在开门那一下', () {
    final src = File('lib/main.dart')
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(src.contains('_shellPainted'), isTrue);
    expect(
      src.contains('addPostFrameCallback'),
      isTrue,
      reason: '"画过一帧"只能由帧回调来判,不能拿又一个定时器去猜',
    );
    expect(
      src.contains('state is CurrentUserSignedIn && !_shellPainted'),
      isTrue,
      reason: '只有登录态有壳要等;登出/服务不可用那两条路没有壳,不许一起卡住',
    );
  });

  test('🔴 兜底闸还在(任何一环卡死都不许把人永久关在浮层后面)', () {
    final src = File('lib/main.dart').readAsStringSync();
    expect(src.contains('_splashForceHidden'), isTrue);
    expect(src.contains('_splashMaxDurationMs'), isTrue);
  });
}
