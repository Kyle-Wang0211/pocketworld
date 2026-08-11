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

  test('legacy draft reconstruction also preempts cold archive work', () {
    final recon = File('lib/capture/sfm_live_recon.dart').readAsStringSync();

    expect(recon, contains('beginProcessingActivity()'));
    expect(recon, contains('_photoArchiveActivityLease.close()'));
  });

  test(
    'startup discovery is post-frame and marker-filtered by coordinator',
    () {
      final main = File('lib/main.dart').readAsStringSync();
      final runtime = File(
        'lib/official_capture/photo_archive_runtime.dart',
      ).readAsStringSync();
      expect(main, contains('photoArchiveCoordinator.discoverUnderDocuments('));
      expect(main, contains('addPostFrameCallback'));
      expect(main, contains('officialArchiveBackgroundRuntime.initialize()'));
      expect(runtime, contains('MethodChannelArchiveBackgroundScheduler'));
      expect(runtime, contains('OfficialArchiveAuditStore'));
    },
  );

  test('later reconstruction materializes verified archived JPEGs', () {
    final resume = File(
      'lib/official_capture/sfm_resume.dart',
    ).readAsStringSync();

    expect(resume, contains('beginReconstructionActivity('));
    expect(
      resume,
      isNot(contains('await photoArchiveCoordinator.waitForIdle()')),
      reason: 'resumed reconstruction must preempt cold archive immediately',
    );
    expect(resume, contains('PhotoArchiveResolver'));
    expect(resume, contains('photoArchiveCodec'));
    expect(
      resume,
      contains('_materializeArchivedJpegs(captureDir, frameMeta)'),
    );
  });
}
