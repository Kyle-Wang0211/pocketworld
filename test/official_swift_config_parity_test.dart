import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'official Swift plugin preserves the self pipeline runtime settings',
    () {
      final selfSource = File(
        'ios/Runner/AetherARKitPlugin.swift',
      ).readAsStringSync();
      final officialSource = File(
        'ios/Runner/OfficialAetherARKitPlugin.swift',
      ).readAsStringSync();

      Map<String, String> activeSettings(String source, String prefix) {
        final settings = <String, String>{};
        final expression = RegExp(
          r'^\s*setenv\("([A-Z0-9_]+)",\s*"([^"]*)",\s*1\)',
          multiLine: true,
        );
        for (final match in expression.allMatches(source)) {
          final key = match.group(1)!;
          if (!key.startsWith(prefix)) continue;
          settings[key.substring(prefix.length)] = match.group(2)!;
        }
        return settings;
      }

      final selfSettings = activeSettings(selfSource, 'AETHER_');
      final officialSettings = activeSettings(
        officialSource,
        'OFFICIAL_AETHER_',
      );

      expect(selfSettings, isNotEmpty);
      expect(officialSettings, selfSettings);
    },
  );
}
