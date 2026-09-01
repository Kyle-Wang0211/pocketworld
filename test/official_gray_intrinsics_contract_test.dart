import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the exact gray source pinhole matrix crosses Swift into Dart', () {
    final swift = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    final provider = File(
      'lib/official_dome/platform_pose_provider.dart',
    ).readAsStringSync();

    for (final key in <String>[
      'q_graySourceFocalX',
      'q_graySourceFocalY',
      'q_graySourcePrincipalX',
      'q_graySourcePrincipalY',
    ]) {
      expect(swift, contains('payload["$key"]'));
      expect(provider, contains("map['$key']"));
    }
    expect(swift, contains('cameraIntrinsics.columns.2.x'));
    expect(swift, contains('cameraIntrinsics.columns.2.y'));
  });
}
