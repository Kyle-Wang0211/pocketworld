import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production Swift plugin uses only the official runtime namespace', () {
    final source = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    final expression = RegExp(
      r'^\s*setenv\("([A-Z0-9_]+)",\s*"([^"]*)",\s*1\)',
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
