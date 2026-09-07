import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-07 build 113 事故:合并两条工作树时,`lib/official_dome/` 的 Dart
/// 取了一侧、`ios/Runner/OfficialAetherARKitPlugin.swift` 取了另一侧。两侧各自
/// 自洽,拼在一起后 Dart 读 `evidenceWorldFromCamera` 而 Swift 只发
/// `cameraTransform` —— 位姿解成空数组,`validate()` 判 missingPose,**每一次
/// 快门都失败**,而 1539 个单元测试全绿(它们都没跨过这条通道)。
///
/// 这个契约把通道两端钉在一起:Dart 从 `captureHighResolutionStill` 回包里读的
/// 每一个键,Swift 的 payload 里必须真的存在。纯文本对照,不需要真机。
void main() {
  final dart = File('lib/official_dome/platform_pose_provider.dart');
  final swift = File('ios/Runner/OfficialAetherARKitPlugin.swift');

  test('captureHighResolutionStill 回包的每个键 Swift 都真的发', () {
    expect(dart.existsSync(), isTrue, reason: '${dart.path} 不存在');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} 不存在');

    final dartSrc = dart.readAsStringSync();
    final swiftSrc = swift.readAsStringSync();

    // 只看 captureHighResolutionStill 这一段,避免把别的方法的键算进来。
    final start = dartSrc.indexOf('captureHighResolutionStill(');
    expect(start, greaterThan(0), reason: 'Dart 侧找不到该方法');
    final body = dartSrc.substring(start);
    final end = body.indexOf('\n  @override');
    final scope = end > 0 ? body.substring(0, end) : body;

    final read = RegExp(r"""result\['([A-Za-z0-9_]+)'\]""")
        .allMatches(scope)
        .map((m) => m.group(1)!)
        .toSet();
    expect(read, contains('cameraTransform'), reason: '位姿键必须被读到');
    expect(read, contains('intrinsics'), reason: '内参键必须被读到');

    final missing = <String>[];
    for (final key in read) {
      if (!swiftSrc.contains('"$key"')) missing.add(key);
    }
    expect(
      missing,
      isEmpty,
      reason:
          'Dart 读了这些键但 Swift 的 payload 里没有,通道两端被拆开了:$missing',
    );
  });

  test('Dart 侧的 12MP 请求参数 Swift 都认', () {
    final dartSrc = dart.readAsStringSync();
    final swiftSrc = swift.readAsStringSync();
    final start = dartSrc.indexOf('captureHighResolutionStill(');
    final body = dartSrc.substring(start);
    final end = body.indexOf('\n  @override');
    final scope = end > 0 ? body.substring(0, end) : body;

    final sent = RegExp(r"""args\['([A-Za-z0-9_]+)'\]\s*=""")
        .allMatches(scope)
        .map((m) => m.group(1)!)
        .toSet()
      ..addAll(
        RegExp(r"""^\s*'([A-Za-z0-9_]+)':""", multiLine: true)
            .allMatches(scope)
            .map((m) => m.group(1)!),
      );

    final unknown = <String>[];
    for (final key in sent) {
      if (!swiftSrc.contains('"$key"')) unknown.add(key);
    }
    expect(
      unknown,
      isEmpty,
      reason: 'Dart 发了这些参数但 Swift 不读,会静默失效:$unknown',
    );
  });
}
