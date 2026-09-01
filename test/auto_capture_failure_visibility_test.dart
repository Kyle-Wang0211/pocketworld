import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_failure_visibility.dart';
import 'package:pocketworld_flutter/official_capture/official_highres_reconstruction_input.dart';

void main() {
  test(
    'automatic algorithmic rejections remain internal candidate receipts',
    () {
      for (final failure in <OfficialHighResInputFailure>[
        OfficialHighResInputFailure.actualStillDuplicate,
        OfficialHighResInputFailure.actualStillQualityRejected,
        OfficialHighResInputFailure.actualStillMissingEvidence,
      ]) {
        expect(
          automaticShutterFailureIsUserVisible(failure),
          isFalse,
          reason: failure.name,
        );
      }
    },
  );

  test('automatic candidate failures never become user task failures', () {
    for (final failure in OfficialHighResInputFailure.values) {
      expect(
        automaticShutterFailureIsUserVisible(failure),
        isFalse,
        reason: failure.name,
      );
    }
  });
}
