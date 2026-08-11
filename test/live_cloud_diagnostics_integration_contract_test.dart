import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('four drift diagnostics cross their existing component boundaries', () {
    final dartUi = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final dartDiag = File(
      'lib/official_capture/live_cloud_diagnostics.dart',
    ).readAsStringSync();
    final swift = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();

    for (final token in <String>[
      'live_cloud_receive_v1',
      'live_cloud_compute_done_v1',
      'publish_version',
      'channelArguments',
    ]) {
      expect(dartUi, contains(token), reason: 'missing Dart token $token');
    }
    for (final token in <String>[
      'PW_LIVE_CLOUD_DIAG_V1_20260810',
      'diagReceiveSeq',
    ]) {
      expect(dartDiag, contains(token), reason: 'missing Dart token $token');
    }

    for (final token in <String>[
      'arkit_anchor_delta_v1',
      'live_cloud_render_v1',
      'lockTimeAnchorTransform',
      'diagReceiveSeq',
      'PWLiveCloudDiagnosticBuildId',
    ]) {
      expect(swift, contains(token), reason: 'missing Swift token $token');
    }
  });

  test('diagnostics do not introduce a stale-cloud rejection branch', () {
    final dartUi = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    expect(dartUi, isNot(contains('if (staleAtCompute) return')));
    expect(dartUi, isNot(contains('if (diagStale) return')));
  });

  test('runtime v2 probes sit on boundaries proven active by device logs', () {
    final dartUi = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final dartRecon = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    final swift = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();

    // `preview_skip` from this exact switch arm was present 131 times in the
    // failed capture, so source receipt must be recorded here rather than only
    // behind the UI event listener.
    final previewCase = dartRecon.substring(
      dartRecon.indexOf("case 'preview':"),
      dartRecon.indexOf("case 'live_poses':"),
    );
    expect(previewCase, contains('live_cloud_source_receive_v2'));
    expect(previewCase, contains('diag_source_receive_seq'));

    // The source sequence must survive the UI channel payload and native
    // metadata so one row can be joined all the way to actual render apply.
    expect(dartUi, contains('diag_source_receive_seq'));
    expect(swift, contains('diagSourceReceiveSeq'));

    // Both native method receipt and SceneKit consumption are explicit. The
    // failed capture proved setCoveragePointCloud + the render loop were live.
    final nativeReceiveCase = swift.substring(
      swift.indexOf('case "setCoveragePointCloud":'),
      swift.indexOf('case "setFeaturePointsVisible":'),
    );
    expect(nativeReceiveCase, contains('live_cloud_native_receive_v2'));
    expect(swift, contains('live_cloud_render_v2'));

    // Capture-begin is a proven method-channel boundary (`resource_begin` was
    // present), so it must repeat the exact signed identity for every take.
    final captureBeginCase = swift.substring(
      swift.indexOf('case "telemetryCaptureBegin":'),
      swift.indexOf('case "telemetryCaptureEnd":'),
    );
    expect(captureBeginCase, contains('logCaptureIdentity'));

    // Anchor logging must include a lock baseline and an unavailable-state
    // heartbeat; optional state may never again fail silently.
    expect(swift, contains('arkit_anchor_delta_v2'));
    expect(swift, contains('anchor_state'));
  });
}
