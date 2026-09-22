import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/diagnostics/vio_shadow_se3_comparison.dart';

void main() {
  List<double> worldFromCamera({
    double tx = 0,
    double ty = 0,
    double tz = 0,
    double yawDegrees = 0,
  }) {
    final double a = yawDegrees * math.pi / 180.0;
    final double c = math.cos(a);
    final double s = math.sin(a);
    // simd/Flutter platform-channel convention: column-major 4x4.
    return <double>[c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, tx, ty, tz, 1];
  }

  Map<String, Object?> pair({
    required int seq,
    required List<double> arkit,
    double sensorTimestamp = 10,
    double poseTimestamp = 10,
    double qx = 0,
    double qy = 0,
    double qz = 0,
    double qw = 1,
    double tx = 0,
    double ty = 0,
    double tz = 0,
    String referenceTrackingState = 'normal',
    String referenceTrackingReason = 'none',
  }) => <String, Object?>{
    'seq': seq,
    'rawStateCallCompleted': true,
    'rawCameraPoseCallCompleted': true,
    'rawXrslamState': 1,
    'sensorTimestamp': sensorTimestamp,
    'xrslamPoseTimestamp': poseTimestamp,
    'referenceTrackingState': referenceTrackingState,
    'referenceTrackingReason': referenceTrackingReason,
    'referenceWorldFromCamera': arkit,
    'xrslamWorldFromCamera': <String, Object?>{
      'qx': qx,
      'qy': qy,
      'qz': qz,
      'qw': qw,
      'tx': tx,
      'ty': ty,
      'tz': tz,
    },
  };

  test('first valid pair aligns frames and is not a residual sample', () {
    final VioShadowSe3ComparisonAccumulator accumulator =
        VioShadowSe3ComparisonAccumulator();

    accumulator.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 4,
      'poseObservationsOffered': 2,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[
        pair(seq: 1, arkit: worldFromCamera(tx: 7, yawDegrees: 30)),
        pair(seq: 2, arkit: worldFromCamera(tx: 7, yawDegrees: 30)),
      ],
    });

    final VioShadowComparisonSummary summary = accumulator.summary;
    expect(summary.alignmentInitialized, isTrue);
    expect(summary.acceptedPairCount, 2);
    expect(summary.sampleCount, 1);
    expect(summary.translationRmseM, closeTo(0, 1e-12));
    expect(summary.rotationRmseDeg, closeTo(0, 1e-9));
    expect(summary.authority, 'shadow');
    expect(summary.decisionConsumers, 0);
  });

  test(
    'computes aggregate translation and rotation residuals after SE3 alignment',
    () {
      final VioShadowSe3ComparisonAccumulator accumulator =
          VioShadowSe3ComparisonAccumulator();

      accumulator.consumeSnapshot(<String, Object?>{
        'sessionGeneration': 8,
        'poseObservationsOffered': 3,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(seq: 1, arkit: worldFromCamera()),
          pair(seq: 2, arkit: worldFromCamera(tx: 1)),
          pair(seq: 3, arkit: worldFromCamera(tx: 3, yawDegrees: 90)),
        ],
      });

      final VioShadowComparisonSummary summary = accumulator.summary;
      expect(summary.sampleCount, 2);
      expect(summary.translationRmseM, closeTo(math.sqrt(5), 1e-12));
      expect(summary.translationMaxM, closeTo(3, 1e-12));
      expect(summary.rotationRmseDeg, closeTo(90 / math.sqrt(2), 1e-9));
      expect(summary.rotationMaxDeg, closeTo(90, 1e-9));
    },
  );

  test(
    'timestamp mismatches and malformed pairs are attributed but excluded',
    () {
      final VioShadowSe3ComparisonAccumulator accumulator =
          VioShadowSe3ComparisonAccumulator(timestampToleranceSeconds: 0.01);

      accumulator.consumeSnapshot(<String, Object?>{
        'sessionGeneration': 1,
        'poseObservationsOffered': 3,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(
            seq: 1,
            arkit: worldFromCamera(),
            sensorTimestamp: 1,
            poseTimestamp: 1.02,
          ),
          <String, Object?>{
            'seq': 2,
            'sensorTimestamp': 2.0,
            'xrslamPoseTimestamp': 2.0,
            'referenceTrackingState': 'normal',
            'referenceTrackingReason': 'none',
            'referenceWorldFromCamera': <double>[1, 2],
            'xrslamWorldFromCamera': <String, Object?>{},
          },
          pair(seq: 3, arkit: worldFromCamera()),
        ],
      });

      final VioShadowComparisonSummary summary = accumulator.summary;
      expect(summary.pairCount, 3);
      expect(summary.timestampMismatchCount, 1);
      expect(summary.malformedPairCount, 1);
      expect(summary.acceptedPairCount, 1);
      expect(summary.alignmentInitialized, isTrue);
      expect(summary.sampleCount, 0);
      expect(summary.validPairRate, closeTo(1 / 3, 1e-12));
    },
  );

  test('missing and non-finite raw pose timestamps are rejected in Dart', () {
    final VioShadowSe3ComparisonAccumulator accumulator =
        VioShadowSe3ComparisonAccumulator();
    final Map<String, Object?> missing = pair(seq: 1, arkit: worldFromCamera())
      ..['xrslamPoseTimestamp'] = null;
    final Map<String, Object?> invalid = pair(seq: 2, arkit: worldFromCamera())
      ..['xrslamPoseTimestamp'] = double.nan;
    accumulator.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 1,
      'poseObservationsOffered': 2,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[missing, invalid],
    });

    expect(accumulator.summary.timestampInvalidCount, 2);
    expect(accumulator.summary.acceptedPairCount, 0);
    expect(accumulator.summary.alignmentInitialized, isFalse);
  });

  test('non-OK raw pose status is availability evidence, not a pose pair', () {
    final VioShadowSe3ComparisonAccumulator accumulator =
        VioShadowSe3ComparisonAccumulator();
    accumulator.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 1,
      'poseObservationsOffered': 1,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[
        <String, Object?>{
          'seq': 1,
          'rawStateCallCompleted': true,
          'rawCameraPoseCallCompleted': true,
          'rawXrslamState': 0,
          'sensorTimestamp': 1.0,
          'xrslamPoseTimestamp': null,
        },
      ],
    });
    expect(accumulator.summary.schemaValid, isTrue);
    expect(accumulator.summary.acceptedPairCount, 0);
    expect(accumulator.summary.malformedPairCount, 0);
  });

  test(
    'Dart rejects unusable reference tracking and attributes it separately',
    () {
      final VioShadowSe3ComparisonAccumulator accumulator =
          VioShadowSe3ComparisonAccumulator();
      accumulator.consumeSnapshot(<String, Object?>{
        'sessionGeneration': 1,
        'poseObservationsOffered': 3,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(
            seq: 1,
            arkit: worldFromCamera(tx: 50),
            referenceTrackingState: 'limited',
            referenceTrackingReason: 'excessiveMotion',
          ),
          pair(seq: 2, arkit: worldFromCamera()),
          pair(seq: 3, arkit: worldFromCamera(tx: 2)),
        ],
      });

      final VioShadowComparisonSummary summary = accumulator.summary;
      expect(summary.pairCount, 3);
      expect(summary.referenceTrackingRejectedCount, 1);
      expect(summary.acceptedPairCount, 2);
      expect(summary.validPairRate, closeTo(2 / 3, 1e-12));
      expect(summary.sampleCount, 1);
      expect(summary.translationRmseM, closeTo(2, 1e-12));
      expect(summary.toJson()['referenceTrackingRejectedCount'], 1);
    },
  );

  test(
    'repeated snapshot sequences are consumed once and new generation resets',
    () {
      final VioShadowSe3ComparisonAccumulator accumulator =
          VioShadowSe3ComparisonAccumulator();
      final Map<String, Object?> snapshot = <String, Object?>{
        'sessionGeneration': 1,
        'poseObservationsOffered': 2,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(seq: 10, arkit: worldFromCamera()),
          pair(seq: 11, arkit: worldFromCamera(tx: 2)),
        ],
      };

      accumulator.consumeSnapshot(snapshot);
      accumulator.consumeSnapshot(snapshot);
      expect(accumulator.summary.pairCount, 2);
      expect(accumulator.summary.sampleCount, 1);

      accumulator.consumeSnapshot(<String, Object?>{
        'sessionGeneration': 2,
        'poseObservationsOffered': 1,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(seq: 1, arkit: worldFromCamera(tx: 9)),
        ],
      });
      expect(accumulator.summary.pairCount, 1);
      expect(accumulator.summary.sampleCount, 0);
    },
  );

  test('XRSLAM world-from-camera pose is compared without inversion', () {
    final VioShadowSe3ComparisonAccumulator accumulator =
        VioShadowSe3ComparisonAccumulator();
    final double firstHalfYaw = 15 * math.pi / 180;
    final double secondHalfYaw = -20 * math.pi / 180;

    accumulator.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 1,
      'poseObservationsOffered': 2,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[
        pair(
          seq: 1,
          arkit: worldFromCamera(tx: 2, ty: -1, yawDegrees: 30),
          qz: math.sin(firstHalfYaw),
          qw: math.cos(firstHalfYaw),
          tx: 2,
          ty: -1,
        ),
        pair(
          seq: 2,
          arkit: worldFromCamera(tx: -3, ty: 4, yawDegrees: -40),
          qz: math.sin(secondHalfYaw),
          qw: math.cos(secondHalfYaw),
          tx: -3,
          ty: 4,
        ),
      ],
    });

    expect(accumulator.summary.translationRmseM, closeTo(0, 1e-12));
    expect(accumulator.summary.rotationRmseDeg, closeTo(0, 1e-9));
  });

  test(
    'late snapshot from an older generation cannot reset newer aggregates',
    () {
      final VioShadowSe3ComparisonAccumulator accumulator =
          VioShadowSe3ComparisonAccumulator();
      accumulator.consumeSnapshot(<String, Object?>{
        'sessionGeneration': 2,
        'poseObservationsOffered': 2,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(seq: 1, arkit: worldFromCamera()),
          pair(seq: 2, arkit: worldFromCamera(tx: 1)),
        ],
      });

      accumulator.consumeSnapshot(<String, Object?>{
        'sessionGeneration': 1,
        'poseObservationsOffered': 1,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(seq: 99, arkit: worldFromCamera(tx: 99)),
        ],
      });

      expect(accumulator.summary.pairCount, 2);
      expect(accumulator.summary.sampleCount, 1);
      expect(accumulator.summary.translationRmseM, closeTo(1, 1e-12));
    },
  );

  test(
    'summary JSON contains aggregates only, never transient pair payloads',
    () {
      final VioShadowSe3ComparisonAccumulator accumulator =
          VioShadowSe3ComparisonAccumulator();
      accumulator.consumeSnapshot(<String, Object?>{
        'sessionGeneration': 1,
        'poseObservationsOffered': 1,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(seq: 1, arkit: worldFromCamera(tx: 12345)),
        ],
      });

      final Map<String, Object?> json = accumulator.summary.toJson();
      expect(json.containsKey('poseObservations'), isFalse);
      expect(json.containsKey('referenceWorldFromCamera'), isFalse);
      expect(json.containsKey('xrslamWorldFromCamera'), isFalse);
      expect(json.toString(), isNot(contains('12345')));
    },
  );

  test('native drops remain in the denominator and prevent false 100%', () {
    final VioShadowSe3ComparisonAccumulator accumulator =
        VioShadowSe3ComparisonAccumulator();
    accumulator.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 3,
      'poseObservationsOffered': 4,
      'poseObservationsDropped': 2,
      'poseObservations': <Object?>[
        pair(seq: 1, arkit: worldFromCamera()),
        pair(seq: 2, arkit: worldFromCamera()),
      ],
    });

    final VioShadowComparisonSummary summary = accumulator.summary;
    expect(summary.nativeOfferedCount, 4);
    expect(summary.nativeDroppedCount, 2);
    expect(summary.pairCount, 2);
    expect(summary.acceptedPairCount, 2);
    expect(summary.validPairRate, 0.5);
    expect(summary.deliveryRate, 0.5);
    expect(summary.schemaValid, isTrue);
  });

  test('missing or inconsistent native offer ledger fails closed', () {
    final VioShadowSe3ComparisonAccumulator missing =
        VioShadowSe3ComparisonAccumulator();
    missing.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 1,
      'poseObservations': <Object?>[pair(seq: 1, arkit: worldFromCamera())],
    });
    expect(missing.summary.schemaValid, isFalse);

    final VioShadowSe3ComparisonAccumulator impossible =
        VioShadowSe3ComparisonAccumulator();
    impossible.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 1,
      'poseObservationsOffered': 1,
      'poseObservationsDropped': 2,
      'poseObservations': <Object?>[],
    });
    expect(impossible.summary.schemaValid, isFalse);
  });

  test('generation-less raw pairs cannot contaminate a later valid run', () {
    final VioShadowSe3ComparisonAccumulator accumulator =
        VioShadowSe3ComparisonAccumulator();
    accumulator.consumeSnapshot(<String, Object?>{
      'poseObservationsOffered': 1,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[pair(seq: 99, arkit: worldFromCamera())],
    });
    accumulator.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 1,
      'poseObservationsOffered': 1,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[pair(seq: 1, arkit: worldFromCamera())],
    });

    expect(accumulator.summary.schemaValid, isTrue);
    expect(accumulator.summary.pairCount, 1);
    expect(accumulator.summary.acceptedPairCount, 1);
  });

  test('inconsistent raw tracking enum and reason is malformed in Dart', () {
    final VioShadowSe3ComparisonAccumulator accumulator =
        VioShadowSe3ComparisonAccumulator();
    accumulator.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 1,
      'poseObservationsOffered': 1,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[
        pair(
          seq: 1,
          arkit: worldFromCamera(),
          referenceTrackingState: 'normal',
          referenceTrackingReason: 'excessiveMotion',
        ),
      ],
    });

    expect(accumulator.summary.malformedPairCount, 1);
    expect(accumulator.summary.acceptedPairCount, 0);
  });

  test(
    'terminal aggregate survives while transient SE3 alignment is erased',
    () {
      final VioShadowSe3ComparisonAccumulator accumulator =
          VioShadowSe3ComparisonAccumulator();
      accumulator.consumeSnapshot(<String, Object?>{
        'sessionGeneration': 1,
        'poseObservationsOffered': 2,
        'poseObservationsDropped': 0,
        'poseObservations': <Object?>[
          pair(seq: 1, arkit: worldFromCamera()),
          pair(seq: 2, arkit: worldFromCamera(tx: 2)),
        ],
      });

      final VioShadowComparisonSummary terminal = accumulator
          .takeSummaryAndReset();
      expect(terminal.alignmentInitialized, isTrue);
      expect(terminal.sampleCount, 1);
      expect(terminal.translationRmseM, closeTo(2, 1e-12));
      expect(accumulator.summary.schemaValid, isFalse);
      expect(accumulator.summary.alignmentInitialized, isFalse);
      expect(accumulator.summary.pairCount, 0);
    },
  );
}
