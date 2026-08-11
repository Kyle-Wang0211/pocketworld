import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual capture starts when AR warmup wins the session attach race', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final initStart = source.indexOf('Future<void> _initCamera() async');
    final initEnd = source.indexOf(
      'void _checkArWarmup(ARPose pose)',
      initStart,
    );

    expect(initStart, greaterThanOrEqualTo(0));
    expect(initEnd, greaterThan(initStart));
    final initCamera = source.substring(initStart, initEnd);

    // Pose events are subscribed before attach completes, so warmup can win
    // the race while `_session` is still null. Once attach publishes the
    // session, that already-complete warmup must trigger startup again;
    // arming only the fallback leaves the shutter permanently disabled.
    expect(
      initCamera,
      contains(
        'if (_arWarmupComplete) {\n'
        '        unawaited(_startManualCapture());\n'
        '      } else {\n'
        '        _armArWarmupFallback();\n'
        '      }',
      ),
    );
  });
}
