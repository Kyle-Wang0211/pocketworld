import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual and automatic stills share one awaited native commit', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    final admissionStart = source.indexOf(
      '_ShutterAdmission _admitShutterCapture({',
    );
    final admissionEnd = source.indexOf(
      'bool _enqueueShutterCapture({',
      admissionStart,
    );
    expect(admissionStart, greaterThanOrEqualTo(0));
    expect(admissionEnd, greaterThan(admissionStart));

    final admission = source.substring(admissionStart, admissionEnd);
    expect(admission, contains('final ticket = _shutterQueue.enqueue('));
    expect(admission, isNot(contains('HapticFeedback.')));
    expect(admission, isNot(contains('_triggerShutterHaptic')));

    final executeStart = source.indexOf('Future<void> _executeShutterTicket(');
    final executeEnd = source.indexOf(
      'void _onShutterTicketError(',
      executeStart,
    );
    final execute = source.substring(executeStart, executeEnd);
    expect(
      '_commitAcceptedPhotoFeedback(capture, input)'.allMatches(execute),
      hasLength(1),
      reason: 'both modes must converge on one accepted-photo commit',
    );
    expect(
      execute,
      contains('await _commitAcceptedPhotoFeedback(capture, input)'),
      reason: 'the ticket must not finish before the rendered-card receipt',
    );
    expect(execute, isNot(contains('unawaited(() async')));
    expect(execute, isNot(contains('_addAcceptedPhotoCard')));
    expect(execute, isNot(contains('_triggerShutterHaptic')));
    expect(source, isNot(contains('HapticFeedback.heavyImpact()')));
    expect(source, isNot(contains('SystemSound.play(')));
  });

  test('native executor binds request pose, rendered card, and haptic', () {
    final dartProvider = File(
      'lib/official_dome/platform_pose_provider.dart',
    ).readAsStringSync();
    final native = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();

    expect(dartProvider, contains("'stagePhotoFeedback': stagePhotoFeedback"));
    expect(native, contains('case "commitAcceptedPhotoFeedback":'));
    expect(native, contains('case "discardPhotoFeedback":'));
    expect(native, isNot(contains('case "addPhotoCard":')));
    expect(native, contains('stagePhotoFeedback: stagePhotoFeedback'));
    expect(native, contains('stagePhotoCardPlacement('));
    // Geometry AND texture must come from the same request frame. The callee no
    // longer takes an ARCamera, so the invariant is pinned on the values passed
    // rather than on the ARKit type — and the absence of that type is pinned
    // too, so the seam cannot close again silently.
    expect(native, contains('worldFromCamera: requestFrame.camera.transform'));
    expect(
      native,
      contains('viewMatrix: requestFrame.camera.viewMatrix(for: .portrait)'),
    );
    expect(native, contains('sourcePixelBuffer: requestFrame.capturedImage'));
    expect(native, isNot(contains('camera: ARCamera')));
    expect(native, contains('UIImpactFeedbackGenerator(style: .heavy)'));
    expect(native, contains('didRenderScene scene: SCNScene'));
    expect(native, contains('completePhotoFeedbackAfterRender(name: name)'));

    final commitStart = native.indexOf('case "commitAcceptedPhotoFeedback":');
    final commitEnd = native.indexOf(
      'case "discardPhotoFeedback":',
      commitStart,
    );
    expect(commitStart, greaterThanOrEqualTo(0));
    expect(commitEnd, greaterThan(commitStart));
    final commit = native.substring(commitStart, commitEnd);
    expect(commit, isNot(contains('session.currentFrame')));
    expect(
      commit,
      contains('let transactionId = args["transactionId"] as? String'),
    );
    expect(commit, contains('commitAcceptedPhotoFeedback('));
    expect(commit, isNot(contains('result(nil)')));
  });

  test('accepted feedback uses the portable 128 gate and preview texture', () {
    final captureSession = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();
    final native = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();

    final qualityStart = captureSession.indexOf(
      'PhotoBundleStillQuality _evaluateReturnedStill(',
    );
    final qualityEnd = captureSession.indexOf(
      'static String _basename(',
      qualityStart,
    );
    expect(qualityStart, greaterThanOrEqualTo(0));
    expect(qualityEnd, greaterThan(qualityStart));
    final quality = captureSession.substring(qualityStart, qualityEnd);
    expect(
      quality.indexOf('final gray = still.gray128;'),
      lessThan(quality.indexOf('final gray1024 = still.gray1024;')),
      reason:
          'the real-time cross-platform gate must not scan the 1 MP auxiliary plane first',
    );

    final highResStart = native.indexOf(
      'private func captureHighResolutionStill(',
    );
    final highResEnd = native.indexOf(
      '// MARK: - Frame quality plane extract',
      highResStart,
    );
    expect(highResStart, greaterThanOrEqualTo(0));
    expect(highResEnd, greaterThan(highResStart));
    final highRes = native.substring(highResStart, highResEnd);
    expect(highRes, contains('let gray128 = deriveAuxiliary'));
    expect(
      highRes,
      contains('let transform = frame.camera.transform'),
      reason:
          'the SfM payload must keep the exact returned 12MP pose even though request-time UX uses the authorization pose',
    );
    expect(highRes, isNot(contains('gray1024')));
    expect(highRes, isNot(contains('q_gray1024')));
    expect(highRes, contains('texturePath: cardTexturePath'));

    final publishStart = native.indexOf(
      'private func publishProvisionalPhotoFeedback(',
    );
    final publishEnd = native.indexOf(
      'private func completePhotoFeedbackAfterRender(',
      publishStart,
    );
    final publish = native.substring(publishStart, publishEnd);
    expect(publish, contains('texturePath: placement.texturePath'));
    expect(publish, contains('evidencePath: evidencePath'));
  });

  test('the authorized request publishes feedback before the async 12MP call', () {
    final native = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();

    final captureStart = native.indexOf(
      'private func captureHighResolutionStill(',
    );
    final captureEnd = native.indexOf(
      '// MARK: - Frame quality plane extract',
      captureStart,
    );
    expect(captureStart, greaterThanOrEqualTo(0));
    expect(captureEnd, greaterThan(captureStart));
    final capture = native.substring(captureStart, captureEnd);
    final publish = capture.indexOf('stagePhotoCardPlacement(');
    final highResRequest = capture.indexOf(
      'session.captureHighResolutionFrame',
    );
    expect(publish, greaterThanOrEqualTo(0));
    expect(
      publish,
      lessThan(highResRequest),
      reason:
          'the Dart-authorized request, black frame, haptic, and 12MP request must start as one transaction',
    );
    expect(
      capture.substring(highResRequest),
      isNot(contains('stagePhotoCardPlacement(')),
      reason: 'the asynchronous 12MP completion must not replay late feedback',
    );
    final stageStart = native.indexOf('private func stagePhotoCardPlacement(');
    final stageEnd = native.indexOf(
      'private func publishProvisionalPhotoFeedback(',
      stageStart,
    );
    final stage = native.substring(stageStart, stageEnd);
    expect(stage, contains('publishProvisionalPhotoFeedback('));
    expect(stage, contains('dispatchPrecondition(condition: .onQueue(.main))'));

    // The staged in-memory texture must be preferred over the disk route, which
    // survives only as a fallback. Measured 2026-08-30: the disk route costs
    // 14.58 ms on the render thread versus 4.63 ms staged, and needs a file
    // that is still being written at staging time.
    final loadStart = native.indexOf(
      'private func loadPhotoCardTextureWhenReady(',
    );
    final loadEnd = native.indexOf(
      'func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor)',
      loadStart,
    );
    expect(loadStart, greaterThanOrEqualTo(0));
    expect(loadEnd, greaterThan(loadStart));
    final load = native.substring(loadStart, loadEnd);
    expect(load, contains('if let staged = spec.thumbnail'));
    expect(
      load.indexOf('if let staged = spec.thumbnail'),
      lessThan(load.indexOf('CGImageSourceCreateWithURL')),
      reason: 'the disk route is a fallback, never the primary texture source',
    );

    final rendererStart = native.indexOf(
      'func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor)',
    );
    final rendererEnd = native.indexOf(
      'func renderer(\n    _ renderer: SCNSceneRenderer,\n    didRenderScene',
      rendererStart,
    );
    expect(rendererStart, greaterThanOrEqualTo(0));
    expect(rendererEnd, greaterThan(rendererStart));
    final renderer = native.substring(rendererStart, rendererEnd);
    expect(renderer, contains('buildPhotoCardFrame'));
    expect(renderer, contains('loadPhotoCardTextureWhenReady'));
    expect(
      renderer.indexOf('buildPhotoCardFrame'),
      lessThan(renderer.indexOf('loadPhotoCardTextureWhenReady')),
      reason:
          'a missing thumbnail may delay only the photo texture, never the black frame',
    );

    final completionStart = native.indexOf(
      'private func completePhotoFeedbackAfterRender(name: String)',
    );
    final completionEnd = native.indexOf(
      'private func commitAcceptedPhotoFeedback',
      completionStart,
    );
    final completion = native.substring(completionStart, completionEnd);
    expect(completion, contains('transaction.rendered = true'));
    expect(
      completion,
      contains('finishPhotoFeedbackTransaction('),
      reason: 'a rendered accepted transaction must terminate exactly once',
    );
    expect(
      completion.indexOf('transaction.haptic = nil'),
      lessThan(completion.indexOf('finishPhotoFeedbackTransaction(')),
      reason:
          'haptic belongs to the first black-frame render, even while Dart is still validating the private candidate',
    );
  });

  test('removed photo anchors release both render-phase receipts', () {
    final native = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    final removeStart = native.indexOf(
      'func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor)',
    );
    final removeEnd = native.indexOf('\n  deinit {', removeStart);
    expect(removeStart, greaterThanOrEqualTo(0));
    expect(removeEnd, greaterThan(removeStart));
    final remove = native.substring(removeStart, removeEnd);
    expect(remove, contains('photoCardTextureReady.remove(name)'));
    expect(remove, contains('photoFeedbackAwaitingFirstRender.remove(name)'));
  });
}
