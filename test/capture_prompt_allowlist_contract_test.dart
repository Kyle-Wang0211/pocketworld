import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _section(String source, String start, String end) {
  final startAt = source.indexOf(start);
  final endAt = source.indexOf(end, startAt + start.length);
  expect(startAt, greaterThanOrEqualTo(0), reason: 'missing $start');
  expect(endAt, greaterThan(startAt), reason: 'missing $end after $start');
  return source.substring(startAt, endAt);
}

void main() {
  final page = File(
    'lib/ui/official_capture/ar_capture_page.dart',
  ).readAsStringSync();

  test('capture-time prompt surface follows the explicit allowlist', () {
    for (final forbidden in <String>[
      'class _HardRejectToast',
      'class _MotionSpeedToast',
      'class _ParallaxStarvedBanner',
      'class _DisconnectedPhotoBanner',
      '移动太快，慢一点',
      '有一张高分辨率照片未完成',
      '重叠正在降低',
    ]) {
      expect(page, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(
      page,
      contains('capture-transport-failure-banner-official'),
      reason: 'a true camera transport failure remains actionable',
    );
    expect(page, contains('autoCaptureShutterHintText('));
  });

  test('private automatic candidate failures cannot open UI', () {
    final highResFailure = _section(
      page,
      'void _onHighResCaptureFailure(',
      'void _markPhotoCardFailed(',
    );
    final cardFailure = _section(
      page,
      'void _markPhotoCardFailed(',
      'void _advanceSfmStage(',
    );
    final ticketFailure = _section(
      page,
      'void _onShutterTicketError(',
      'Future<void> _deleteRejectedAutomaticCandidate(',
    );
    for (final source in <String>[highResFailure, cardFailure, ticketFailure]) {
      expect(source, isNot(contains('ScaffoldMessenger')));
      expect(source, isNot(contains('showSnackBar')));
      expect(source, isNot(contains('showDialog')));
      expect(source, isNot(contains('_captureQueueFailureText =')));
    }
  });
}
