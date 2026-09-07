import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-07 build 113 事故:合并两条工作树时按**目录归属**裁决,
/// `ios/Runner/OfficialAetherARKitPlugin.swift` 取了我方(只发
/// `cameraTransform`),`lib/official_dome/` 的 Dart 取了对方(读
/// `requestWorldFromCamera` / `evidenceWorldFromCamera` / `cardWorldTransform`)。
/// 两侧各自自洽,拼在一起后三个键都不存在 ⇒ 位姿解成空数组 ⇒
/// `OfficialHighResReconstructionInput.validate()` 判 missingPose ⇒
/// **上机后每一次快门都失败**,而 1539 个单元测试全绿 —— 它们没有一个跨过
/// MethodChannel,对这一整类缺陷结构性失明。
///
/// 目录归属是关于**文件**的规则,通道契约是关于**接口**的。这个测试把接口
/// 两端钉在一起,让"两端来自不同工作树"必然变红。纯文本对照,不需要真机。
void main() {
  final dart = File('lib/official_dome/platform_pose_provider.dart');
  final swift = File('ios/Runner/OfficialAetherARKitPlugin.swift');

  late String dartSrc;
  late String swiftSrc;

  setUpAll(() {
    expect(dart.existsSync(), isTrue, reason: '${dart.path} 不存在');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} 不存在');
    dartSrc = dart.readAsStringSync();
    swiftSrc = swift.readAsStringSync();
  });

  test('Dart 调的每个 channel 方法 Swift 都接', () {
    final methods = RegExp(r"""invoke\w*Method(?:<[^>]*>)?\(\s*'([A-Za-z0-9_]+)'""")
        .allMatches(dartSrc)
        .map((m) => m.group(1)!)
        .toSet();
    expect(methods, contains('captureHighResolutionStill'));
    expect(methods, contains('startSession'));

    final missing = methods.where((m) => !swiftSrc.contains('"$m"')).toList();
    expect(missing, isEmpty, reason: 'Swift 侧没有这些方法的处理分支:$missing');
  });

  test('Dart 读的每个回包键 Swift 都真的发', () {
    final read = <String>{
      ...RegExp(r"""result\['([A-Za-z0-9_]+)'\]""")
          .allMatches(dartSrc)
          .map((m) => m.group(1)!),
      ...RegExp(r"""reply\['([A-Za-z0-9_]+)'\]""")
          .allMatches(dartSrc)
          .map((m) => m.group(1)!),
    };
    // 位姿与内参是 validate() 的判据,少一个就是每张照片都废。
    expect(read, contains('cameraTransform'));
    expect(read, contains('intrinsics'));

    final missing = read.where((k) => !swiftSrc.contains('"$k"')).toList()
      ..sort();
    expect(
      missing,
      isEmpty,
      reason: 'Dart 读了这些键但 Swift 的 payload 里没有,通道两端被拆开了:$missing',
    );
  });

  test('Dart 发的每个请求参数 Swift 都真的读', () {
    final sent = <String>{
      ...RegExp(r"""args\['([A-Za-z0-9_]+)'\]\s*=""")
          .allMatches(dartSrc)
          .map((m) => m.group(1)!),
      ...RegExp(r"""^\s*'([A-Za-z0-9_]+)':""", multiLine: true)
          .allMatches(dartSrc)
          .map((m) => m.group(1)!),
    };
    final unknown = sent.where((k) => !swiftSrc.contains('"$k"')).toList()
      ..sort();
    expect(
      unknown,
      isEmpty,
      reason: 'Dart 发了这些参数但 Swift 不读,会静默失效:$unknown',
    );
  });
}
