import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const routes = <String, String>{
    'official': 'lib/ui/official_capture/ar_capture_page.dart',
  };

  for (final entry in routes.entries) {
    test('${entry.key} capture survives a degraded live SfM worker', () {
      final source = File(entry.value).readAsStringSync();

      expect(source, contains('bool _sfmStarting = false;'));
      expect(source, contains('String? _sfmStartFailureText;'));
      expect(source, contains('SfmTerminalGate _sfmProcessingTerminalGate'));
      expect(source, contains('SfmTerminalFailureKind.startupFailed'));
      expect(source, contains('bool get _captureAdmissionOpen =>'));
      expect(source, contains('bool get _liveReconReady =>'));
      expect(source, contains('await _startSfmLiveRecon(session);'));
      expect(
        source,
        isNot(contains('unawaited(_startSfmLiveRecon(session));')),
      );

      // A null worker is reconstruction degradation, not a camera transport
      // failure. It may remove live cloud guidance, but it must never revoke a
      // valid shutter, Finish, or draft-persistence path.
      expect(source, contains('if (recon == null) {'));
      expect(
        source,
        isNot(contains('if (session == null || !_sfmCaptureReady) return;')),
      );
      final admissionStart = source.indexOf(
        '_ShutterAdmission _admitShutterCapture({',
      );
      final admissionEnd = source.indexOf(
        'bool _enqueueShutterCapture({',
        admissionStart,
      );
      final admission = source.substring(admissionStart, admissionEnd);
      expect(admission, contains('!_captureAdmissionOpen'));
      expect(admission, isNot(contains('_sfmStarting')));
      expect(admission, isNot(contains('_sfmStartFailureText')));
      expect(admission, isNot(contains('_sfmRecon')));

      expect(
        source,
        matches(
          RegExp(
            r'Future<void> _onFinishTap\(\) async \{\s*'
            r'if \(!_finishAllowed \|\|\s*_confirmationDialogOpen',
          ),
        ),
      );
      expect(source, contains('ready: _captureAdmissionOpen,'));
      expect(
        source,
        matches(
          RegExp(r'onFinish:\s*_finishAllowed\s*\?\s*_onFinishTap\s*:\s*null'),
        ),
      );

      // Reconstruction faults belong to the processing state. They must not
      // stop automatic capture or cover the capture view with a fatal banner.
      final faultStart = source.indexOf(
        'void _noteSfmInternalFailure(String reason)',
      );
      final faultEnd = source.indexOf(
        'void _markPhotoDisconnected(',
        faultStart,
      );
      final fault = source.substring(faultStart, faultEnd);
      expect(fault, isNot(contains('_stopAutoCapture()')));
      expect(
        source,
        isNot(contains("'sfm-start-failure-banner-${entry.key}'")),
      );
      expect(source, isNot(contains('此次拍摄不会保存')));
    });
  }
}
