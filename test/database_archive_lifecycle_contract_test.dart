import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new official capture writes database marker before publication', () {
    final source = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();
    final photoMarker = source.indexOf(
      'PhotoArchivePolicy.writeForNewCapture(root)',
    );
    final databaseMarker = source.indexOf(
      'DatabaseArchivePolicy.writeForNewCapture(root)',
    );
    final publish = source.indexOf('_captureDir = root.path');

    expect(photoMarker, greaterThanOrEqualTo(0));
    expect(databaseMarker, greaterThan(photoMarker));
    expect(publish, greaterThan(databaseMarker));
    expect(source, contains('await photoArchiveCoordinator.waitForIdle()'));
  });

  test(
    'official runtime and recovery use the shared database archive codec',
    () {
      final runtime = File(
        'lib/official_capture/photo_archive_runtime.dart',
      ).readAsStringSync();
      final resume = File(
        'lib/official_capture/sfm_resume.dart',
      ).readAsStringSync();
      final mePage = File('lib/ui/me_page.dart').readAsStringSync();

      expect(runtime, contains('ZpaqFfiDatabaseArchiveCodec'));
      expect(runtime, contains('databaseArchiveCodec'));
      expect(resume, contains('DatabaseArchiveResolver'));
      expect(resume, contains('databaseArchiveCodec'));
      expect(resume, contains('await photoArchiveCoordinator.waitForIdle()'));
      expect(
        mePage,
        contains('official_sfm_resume.resolveRecoverableCaptureDir'),
      );
    },
  );

  test(
    'retired self-developed capture pipeline has no database archive hooks',
    () {
      for (final path in const <String>[
        'lib/capture/capture_session.dart',
        'lib/capture/sfm_live_recon.dart',
        'lib/capture/sfm_resume.dart',
        'lib/capture/sparse_ply.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, isNot(contains('DatabaseArchive')));
        expect(source, isNot(contains('official_database_archive')));
        expect(source, isNot(contains('.zpaq')));
      }
    },
  );
}
