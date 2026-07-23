import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const routes = <String, String>{
    'official': 'lib/ui/official_capture/ar_capture_page.dart',
  };

  for (final entry in routes.entries) {
    test('${entry.key} capture fails closed when live SfM cannot start', () {
      final source = File(entry.value).readAsStringSync();

      expect(source, contains('bool _sfmStarting = false;'));
      expect(source, contains('String? _sfmStartFailureText;'));
      expect(source, contains('bool get _sfmCaptureReady =>'));
      expect(source, contains('await _startSfmLiveRecon(session);'));
      expect(
        source,
        isNot(contains('unawaited(_startSfmLiveRecon(session));')),
      );

      // A null worker is how lease contention and native startup failures are
      // reported. Both controls and the persistence path must reject that
      // state, even if invoked programmatically rather than through the UI.
      expect(source, contains('if (recon == null) {'));
      expect(
        source,
        contains('if (session == null || !_sfmCaptureReady) return;'),
      );
      expect(
        source,
        contains('if (!_sfmCaptureReady || _finalizingRecording) return;'),
      );
      expect(source, contains('ready: _sfmCaptureReady,'));
      expect(
        source,
        contains('onFinish: _sfmCaptureReady && !_finalizingRecording'),
      );

      // Failure must be persistent and visible, not log-only or a transient
      // snackbar that can disappear while the broken capture remains active.
      expect(source, contains('if (_sfmStartFailureText != null)'));
      expect(source, contains("'sfm-start-failure-banner-${entry.key}'"));
      expect(source, contains('此次拍摄不会保存'));
    });
  }
}
