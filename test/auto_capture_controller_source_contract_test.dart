import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('offline AliceVision adapter is absent from production controller', () {
    final source = File(
      'lib/official_capture/auto_capture_controller.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('AliceVisionMotionSegment')));
    expect(source, isNot(contains('_smartMotionSegment')));
    expect(source, isNot(contains('smartSelectionMotionReady:')));

    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    expect(page, isNot(contains('testOnlyAllowLegacySignatureEvidence')));
  });
}
