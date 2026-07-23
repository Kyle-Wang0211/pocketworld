import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'self and official routes use the same Drafts FAB lifecycle contract',
    () {
      final routes = <String>[
        'lib/ui/capture/ar_capture_page.dart',
        'lib/ui/official_capture/ar_capture_page.dart',
      ];

      for (final path in routes) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('DraftCaptureShell('),
          reason: '$path must keep + visible whenever Drafts is visible',
        );
        expect(
          source,
          contains('_scheduleDraftTerminalExitIfNeeded();'),
          reason:
              '$path must leave temporary Drafts at reconstruction terminal',
        );
        expect(
          source,
          contains('ReconstructionRouteReleaseGate'),
          reason: '$path must serialize terminal teardown and route exit',
        );
        expect(
          source,
          contains('if (recon != null) await recon.dispose();'),
          reason:
              '$path must release the shared reconstruction lease before pop',
        );
        expect(
          source,
          contains('当前任务正在重建'),
          reason: '$path must block a second capture while reconstruction runs',
        );
      }
    },
  );
}
