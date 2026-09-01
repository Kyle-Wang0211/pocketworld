import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String native;

  setUpAll(() {
    native = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
  });

  test('photo feedback has one transaction registry and render snapshots', () {
    expect(native, contains('private struct PhotoFeedbackTransaction'));
    expect(native, contains('private final class PhotoCardSpecRegistry'));
    expect(
      native,
      contains('func snapshot(for name: String) -> PhotoCardSpec?'),
    );
    expect(native, contains('Self.photoCardSpecRegistry.snapshot(for: name)'));

    expect(native, isNot(contains('static var photoCardSpecs:')));
    expect(native, isNot(contains('pendingPhotoCardPlacements:')));
    expect(native, isNot(contains('pendingPhotoFeedbackNamesByEvidence:')));
    expect(native, isNot(contains('pendingPhotoFeedbackResults:')));
    expect(native, isNot(contains('pendingPhotoFeedbackHaptics:')));
    expect(native, isNot(contains('pendingPhotoFeedbackTimeouts:')));
    expect(
      native,
      isNot(contains('OfficialAetherARKitPlugin.photoCardSpecs[')),
    );
  });

  test(
    'stage commit discard remove and suppress share transaction identity',
    () {
      expect(
        native,
        contains('let transactionId = args["transactionId"] as? String'),
      );
      expect(
        native,
        contains('let cardTexturePath = args["cardTexturePath"] as? String'),
      );
      expect(native, contains('case "commitAcceptedPhotoFeedback":'));
      expect(native, contains('case "discardPhotoFeedback":'));
      expect(native, contains('case "suppressPhotoFeedbackPresentation":'));
      expect(native, contains('case "removePhotoCard":'));
      expect(native, contains('finishPhotoFeedbackTransaction('));
      expect(native, contains('terminalPhotoFeedbackById'));
      expect(native, contains('transactionId: transactionId'));
      expect(native, contains('"suppressed": true'));
      expect(native, contains('"rendered": false'));
    },
  );

  test('presentation removal requires one conjunctive transaction identity', () {
    final registryStart = native.indexOf(
      'func names(transactionId: String?, evidencePath: String?)',
    );
    final registryEnd = native.indexOf('@discardableResult', registryStart);
    expect(registryStart, greaterThanOrEqualTo(0));
    expect(registryEnd, greaterThan(registryStart));
    final lookup = native.substring(registryStart, registryEnd);
    expect(
      lookup,
      contains(
        'if let transactionId, spec.transactionId != transactionId { return nil }',
      ),
    );
    expect(
      lookup,
      contains(
        'if let evidencePath, spec.evidencePath != evidencePath { return nil }',
      ),
    );

    final removeStart = native.indexOf('private func removePhotoCard(');
    final removeEnd = native.indexOf(
      'private func discardAllPhotoFeedback()',
      removeStart,
    );
    expect(removeStart, greaterThanOrEqualTo(0));
    expect(removeEnd, greaterThan(removeStart));
    final remove = native.substring(removeStart, removeEnd);
    expect(
      remove,
      contains('if let terminal = terminalPhotoFeedbackById[transactionId]'),
    );
    expect(remove, contains('terminal.evidencePath == evidencePath'));
  });

  test(
    'Finish suppression settles the commit and disarms late render work',
    () {
      final suppressStart = native.indexOf(
        'private func suppressPhotoFeedbackPresentation(',
      );
      final suppressEnd = native.indexOf(
        'private func discardStagedPhotoFeedback(',
        suppressStart,
      );
      expect(suppressStart, greaterThanOrEqualTo(0));
      expect(suppressEnd, greaterThan(suppressStart));
      final suppress = native.substring(suppressStart, suppressEnd);
      expect(suppress, contains('outcome: "accepted_suppressed"'));
      expect(suppress, contains('rendered: false'));
      expect(suppress, contains('suppressed: true'));
      expect(suppress, contains('removePresentation: true'));

      final finishStart = native.indexOf(
        'private func finishPhotoFeedbackTransaction(',
      );
      final finishEnd = native.indexOf(
        'private static func photoFeedbackError(',
        finishStart,
      );
      final finish = native.substring(finishStart, finishEnd);
      expect(finish, contains('transaction.timeout?.cancel()'));
      expect(finish, contains('photoFeedbackIdByCard.removeValue'));
      expect(finish, contains('for waiter in transaction.commitResults'));

      final renderStart = native.indexOf(
        'private func completePhotoFeedbackAfterRender(name: String)',
      );
      final renderEnd = native.indexOf(
        'private func commitAcceptedPhotoFeedback(',
        renderStart,
      );
      final render = native.substring(renderStart, renderEnd);
      expect(render, contains('photoFeedbackIdByCard[name]'));
      expect(render, contains('haptic?.impactOccurred()'));
    },
  );

  test('stopSession terminalizes feedback before pausing ARKit', () {
    final stopStart = native.indexOf('private func stopSession()');
    final stopEnd = native.indexOf('// MARK: Lock origin', stopStart);
    expect(stopStart, greaterThanOrEqualTo(0));
    expect(stopEnd, greaterThan(stopStart));
    final stop = native.substring(stopStart, stopEnd);
    final cleanup = stop.indexOf(
      'OfficialAetherARKitPlugin.clearPhotoCards(in: arSession)',
    );
    final pause = stop.indexOf('arSession?.pause()');
    expect(cleanup, greaterThanOrEqualTo(0));
    expect(cleanup, lessThan(pause));
  });

  test(
    'pose telemetry names three distinct instants without exact-exposure claim',
    () {
      final provider = File(
        'lib/official_dome/platform_pose_provider.dart',
      ).readAsStringSync();
      expect(native, contains('"requestWorldFromCamera"'));
      expect(native, contains('"evidenceWorldFromCamera"'));
      expect(native, contains('"cardWorldTransform"'));
      expect(provider, contains("result['requestWorldFromCamera']"));
      expect(provider, contains("result['evidenceWorldFromCamera']"));
      expect(provider, contains("result['cardWorldTransform']"));
      expect(
        native,
        isNot(contains('"cameraTransform": cameraTransform')),
        reason: 'the production result must expose only explicitly named poses',
      );
      expect(native, contains('"authorization_request_frame"'));
      expect(native, contains('"high_resolution_result_frame"'));
      expect(native.toLowerCase(), isNot(contains('exact exposure')));
      expect(native.toLowerCase(), isNot(contains('exact-frame feedback')));
    },
  );

  test('manual card texture is an explicit generated preview path', () {
    final captureSession = File(
      'lib/official_capture/capture_session.dart',
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
    expect(capture, contains('cardTexturePath: String?'));
    expect(capture, contains('texturePath: cardTexturePath'));
    expect(capture, isNot(contains('texturePath: previewPath')));
    expect(captureSession, contains('cardTexturePath: previewJpegPath'));
    expect(
      captureSession,
      contains('poseProvider.saveCurrentFrame(\n          previewSaveSpec,'),
    );
  });

  test(
    'native AR lifecycle does not own matcher or shadow run authorization',
    () {
      expect(native, isNot(contains('aether_gpu_match_set_capture_active')));
      expect(
        native,
        isNot(contains('PwVioTimebase.shared.resumeShadowPipeline()')),
      );
      expect(
        native,
        isNot(contains('PwVioTimebase.shared.suspendShadowPipeline()')),
      );
    },
  );

  test('AR delegate obtains a bounded shadow permit before frame escape', () {
    final start = native.indexOf(
      'func session(_ session: ARSession, didUpdate frame: ARFrame)',
    );
    final end = native.indexOf(
      'func session(_ session: ARSession, didFailWithError',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final callback = native.substring(start, end);
    final permit = callback.indexOf('tryOfferFrame(frame: frame)');
    final escapingClosure = callback.indexOf(
      'PwVioSensorIngress.dispatchQueue.async',
    );
    expect(permit, greaterThanOrEqualTo(0));
    expect(permit, lessThan(escapingClosure));
    expect(callback, contains('consume(permit: permit)'));
    expect(callback, isNot(contains('enqueue(frame: frame)')));
    expect(
      callback,
      isNot(contains('dispatchQueue.async { [frame]')),
      reason: 'the escaping closure may retain only the bounded permit',
    );
  });
}
