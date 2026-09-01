import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production bundle carries an explicit social safety build marker', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('<key>PWSocialProfileSafetyBuildId</key>'));
    expect(
      plist,
      contains('<string>profile-follow-report-block-20260829-v1</string>'),
    );
  });
}
