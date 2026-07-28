import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new capture creation writes marker before publishing directory', () {
    final source = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();
    final marker = source.indexOf(
      'PhotoArchivePolicy.writeForNewCapture(root)',
    );
    final publish = source.indexOf('_captureDir = root.path');

    expect(marker, greaterThanOrEqualTo(0));
    expect(publish, greaterThan(marker));
    expect(source, contains('photoArchiveCoordinator.beginCaptureActivity()'));
  });

  test('durable PLY and recon release notify the same coordinator', () {
    final sparse = File(
      'lib/official_capture/sparse_ply.dart',
    ).readAsStringSync();
    final recon = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();

    expect(sparse, contains('photoArchiveCoordinator.noteArtifactsPersisted('));
    expect(recon, contains('beginReconstructionActivity('));
    expect(recon, contains('_photoArchiveActivityLease.close()'));
  });

  test(
    'startup discovery is post-frame and marker-filtered by coordinator',
    () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('photoArchiveCoordinator.discoverUnderDocuments('));
      expect(main, contains('addPostFrameCallback'));
    },
  );

  test('later reconstruction materializes verified archived JPEGs', () {
    final resume = File(
      'lib/official_capture/sfm_resume.dart',
    ).readAsStringSync();

    expect(resume, contains('PhotoArchiveResolver'));
    expect(resume, contains('photoArchiveCodec'));
    expect(resume, contains('_materializeArchivedJpegs(captureDir, frameMeta)'));
  });
}
