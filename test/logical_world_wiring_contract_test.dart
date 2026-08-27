import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String dart = File(
    'lib/official_dome/platform_pose_provider.dart',
  ).readAsStringSync();
  final String swift = File(
    'ios/Runner/OfficialAetherARKitPlugin.swift',
  ).readAsStringSync();

  test('Dart owns lock-world normalization for stream and still poses', () {
    expect(
      dart,
      contains("import '../official_capture/logical_world_frame.dart';"),
    );
    expect(dart, contains('LogicalWorldFrame? _logicalWorldFrame'));
    expect(dart, contains("_decodeFloatList(map['anchorTransform'])"));
    expect(dart, contains('update.toLogicalWorld(extrinsic)'));
    expect(dart, contains('_logicalCameraTransform('));
    expect(dart, contains("'setLogicalWorldDisplayTransform'"));
  });

  test('Swift transports the anchor and only applies the Dart matrix', () {
    expect(swift, contains('"anchorTransform": Self.floatArray('));
    expect(swift, contains('case "setLogicalWorldDisplayTransform":'));
    expect(swift, contains('setCoverageCloudTransform('));
    expect(swift, contains('node.simdTransform = pointCloudTransform'));

    final RegExpMatch? handler = RegExp(
      r'case "setLogicalWorldDisplayTransform":([\s\S]*?)case ',
    ).firstMatch(swift);
    expect(handler, isNotNull);
    final String body = handler!.group(1)!;
    expect(body, isNot(contains('threshold')));
    expect(body, isNot(contains('distance')));
    expect(body, isNot(contains('rotation')));
  });
}
