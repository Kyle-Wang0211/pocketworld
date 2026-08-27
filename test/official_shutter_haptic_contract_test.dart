import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful shared shutter admission emits one heavy impact', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    final admissionStart = source.indexOf(
      '_ShutterAdmission _admitShutterCapture({bool automaticSelection = false})',
    );
    final admissionEnd = source.indexOf(
      'bool _enqueueShutterCapture({bool automaticSelection = false})',
      admissionStart,
    );
    expect(admissionStart, greaterThanOrEqualTo(0));
    expect(admissionEnd, greaterThan(admissionStart));

    final admission = source.substring(admissionStart, admissionEnd);
    expect(admission, contains('final ticket = _shutterQueue.enqueue('));
    expect(admission, contains('if (ticket == null)'));
    expect(admission, contains('_triggerShutterHaptic()'));
    expect(
      admission.indexOf('if (ticket == null)'),
      lessThan(admission.indexOf('_triggerShutterHaptic()')),
    );
  });

  test('haptic is best effort and manual/auto paths do not duplicate it', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    final helperStart = source.indexOf('void _triggerShutterHaptic()');
    final autoStart = source.indexOf('bool _onAutoCaptureStartAnchor()');
    final manualStart = source.indexOf('void _onShutterTap()');
    final admissionStart = source.indexOf(
      '_ShutterAdmission _admitShutterCapture({bool automaticSelection = false})',
    );
    expect(helperStart, greaterThanOrEqualTo(0));
    expect(autoStart, greaterThanOrEqualTo(0));
    expect(manualStart, greaterThan(autoStart));
    expect(admissionStart, greaterThan(manualStart));

    final helper = source.substring(helperStart, autoStart);
    final autoOuter = source.substring(autoStart, manualStart);
    final manualOuter = source.substring(manualStart, admissionStart);
    expect(helper, contains('HapticFeedback.heavyImpact()'));
    expect(helper, contains('.catchError('));
    expect(helper, contains('DeviceLog.log('));
    expect('HapticFeedback.heavyImpact()'.allMatches(source), hasLength(1));
    expect(source, isNot(contains('HapticFeedback.mediumImpact()')));
    expect(autoOuter, isNot(contains('HapticFeedback.')));
    expect(manualOuter, isNot(contains('HapticFeedback.')));
    expect(source, isNot(contains('SystemSound.play(')));
  });
}
