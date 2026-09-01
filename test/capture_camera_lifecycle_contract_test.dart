import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final page = File(
    'lib/ui/official_capture/ar_capture_page.dart',
  ).readAsStringSync();
  final session = File(
    'lib/official_capture/capture_session.dart',
  ).readAsStringSync();
  final provider = File(
    'lib/official_dome/platform_pose_provider.dart',
  ).readAsStringSync();
  final native = File(
    'ios/Runner/OfficialAetherARKitPlugin.swift',
  ).readAsStringSync();

  test('page sends lifecycle intent only through CaptureSession', () {
    expect(page, isNot(contains("invokeMethod<void>('startSession'")));
    expect(page, isNot(contains("invokeMethod<void>('stopSession'")));
    expect(page, contains('session.suspendCameraTransport()'));
    expect(page, contains('_session?.resumeCameraTransport()'));
    expect(page, contains('session.stopCameraTransport()'));
    expect(session, contains('Future<void> suspendCameraTransport()'));
    expect(session, contains('Future<void> resumeCameraTransport()'));
    expect(session, contains('Future<void> stopCameraTransport()'));
    expect(
      provider,
      contains('implements ARPoseProvider, ARPoseTransportLifecycle'),
    );
  });

  test('matcher capture ownership has one Dart writer and no Swift writer', () {
    expect(
      RegExp(r'AetherMatchFlags\.setCaptureActive\(').allMatches(page).length,
      1,
    );
    expect(native, isNot(contains('aether_gpu_match_set_capture_active')));
  });

  test('all committed exits use one coordinator and cannot resume camera', () {
    final closeStart = page.indexOf('Future<void> _onCloseTap()');
    final closeEnd = page.indexOf('Future<void> _onCenterTap()', closeStart);
    final closeBody = page.substring(closeStart, closeEnd);
    final finishStart = page.indexOf('Future<void> _onFinishTap()');
    final finishEnd = page.indexOf(
      'Future<void> _commitCaptureExit({',
      finishStart,
    );
    final finishBody = page.substring(finishStart, finishEnd);

    expect(closeBody, contains('_commitCaptureExit('));
    expect(finishBody, contains('_finalizeRecording('));
    expect(page, contains('_finishCoordinator.captureAdmissionOpen'));
    expect(page, contains('_finishCoordinator.captureRootTombstoned'));
    expect(page, contains('if (_captureAdmissionOpen && _sfmPhase == null)'));
  });

  test('native suppression failure resolves presentation as failed', () {
    final suppressStart = page.indexOf(
      'Future<AcceptedPhotoPresentationOutcome> _suppressPhotoPresentation',
    );
    final suppressEnd = page.indexOf(
      'Future<void> _suppressActivePhotoPresentationForFinish',
      suppressStart,
    );
    final suppressBody = page.substring(suppressStart, suppressEnd);
    final activeEnd = page.indexOf(
      'Future<void> _discardPhotoFeedback',
      suppressEnd,
    );
    final activeBody = page.substring(suppressEnd, activeEnd);

    expect(
      suppressBody,
      contains('acceptedPhotoPresentationOutcomeFromReceipt(receipt)'),
    );
    expect(activeBody, contains('resolvePhotoPresentation'));
  });
}
