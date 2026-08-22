import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production Swift plugin uses only the official runtime namespace', () {
    final source = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    // 第三参是 setenv 的 overwrite,0 与 1 都算"生产注入"。
    // c1f193b(2026-08-10 DEVICE-AB-UNBLOCK)把 register() 内的 setenv 整块
    // 1 → 0,好让真机 A/B 能用 env 文件覆盖;写死 `1` 的旧正则从此 0 命中,
    // 下面的 isNotEmpty 前置闸随即报红 —— 闸是对的,正则过期了。
    // ⚠️ 别把第三参放成 `[^)]*`:那会连注释里"回滚留档"的 setenv 一起吃进来。
    final expression = RegExp(
      r'^\s*setenv\("([A-Z0-9_]+)",\s*"([^"]*)",\s*[01]\)',
      multiLine: true,
    );
    final keys = expression
        .allMatches(source)
        .map((match) => match.group(1)!)
        .toList();

    expect(keys, isNotEmpty);
    expect(keys, everyElement(startsWith('OFFICIAL_AETHER_')));
    expect(File('ios/Runner/AetherARKitPlugin.swift').existsSync(), isFalse);
  });
}
