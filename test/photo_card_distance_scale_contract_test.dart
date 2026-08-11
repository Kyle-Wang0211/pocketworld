// AR photo-card scaling contract.
//
// [AR-REGRESSION 2026-07-26] This file previously locked in eaf8706's
// travel-driven curve. That curve made a card's apparent size a function of
// how far the camera had moved from the CAPTURE position, and cancelled
// perspective with currentDistance/captureDistance — so apparent size was
// algebraically independent of the camera-to-card distance. Two user-reported
// device regressions followed: walking up to a card no longer enlarged it (it
// looked like the card was dodging), and backing away no longer produced the
// continuous 1/d shrink that IS the "photo flies out of the lens" effect.
// The contract below is the restored 7410bb9 / 909a6a2 behaviour: a card is a
// solid board in the world, pure perspective up close, with a gentle beta
// falloff only beyond the 1 m anchor.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

void main() {
  final pluginSources = <String, String>{
    'production': File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync(),
  };

  for (final entry in pluginSources.entries) {
    test('${entry.key} AR photo cards use the distance-compensated scale', () {
      final source = entry.value;

      expect(
        source,
        contains('private static let photoCardDistanceAnchorM: Float = 1.0'),
      );
      expect(
        source,
        contains('private static let photoCardDistanceBeta: Float = 0.5'),
      );
      // [SIGNED 2026-07-26] 24 号形态回退:循环不带 name(飞出/躲开回归案)。
      expect(source, contains('for card in photoCardNodes.values'));
      expect(source, isNot(contains('for (name, card) in photoCardNodes')));
      expect(
        source,
        contains('let d = simd_distance(camPos, card.simdWorldPosition)'),
      );
      expect(
        source,
        contains(
          'let s = d > Self.photoCardDistanceAnchorM\n'
          '        ? powf(d / Self.photoCardDistanceAnchorM, '
          'Self.photoCardDistanceBeta)\n'
          '        : 1.0',
        ),
      );

      // The travel-driven curve must not come back: it is what broke both the
      // fly-out effect and close-up inspection.
      expect(source, isNot(contains('photoCardMinVisualScale')));
      expect(source, isNot(contains('photoCardVisualTransitionM')));
      expect(source, isNot(contains('photoCardMaxNodeScale')));
      expect(source, isNot(contains('perspectiveCompensation')));
    });
  }

  test('card is a solid board up close and decays gently past the anchor', () {
    const anchorM = 1.0;
    const beta = 0.5;
    const captureDistanceM = 0.05; // photoCardCloseZ

    double nodeScale(double dM) =>
        dM > anchorM ? math.pow(dM / anchorM, beta).toDouble() : 1.0;

    // Apparent (screen) size relative to the size at capture, where the card
    // fills the viewport: nodeScale(d) * captureDistance / d.
    double apparentScale(double dM) => nodeScale(dM) * captureDistanceM / dM;

    // Up close the card is a plain world object: pure 1/d perspective. This
    // continuous shrink as the user pulls back IS the fly-out effect.
    expect(apparentScale(captureDistanceM), closeTo(1.0, 1e-9));
    expect(apparentScale(0.10), closeTo(0.50, 1e-9));
    expect(apparentScale(0.15), closeTo(0.333, 1e-3));
    expect(apparentScale(0.50), closeTo(0.10, 1e-9));

    // Walking BACK toward a card must make it grow again — the property whose
    // loss the user reported as the card "dodging".
    expect(apparentScale(0.10), greaterThan(apparentScale(0.20)));
    expect(apparentScale(0.20), greaterThan(apparentScale(0.50)));

    // Past the 1 m anchor the beta compensation halves the falloff rate:
    // apparent size goes as d^(beta-1) = d^-0.5 instead of d^-1.
    expect(apparentScale(1.0), closeTo(0.05, 1e-9));
    expect(
      apparentScale(4.0),
      closeTo(0.025, 1e-9),
    ); // d^-0.5: half, not quarter
    // Still monotonically shrinking — no screen-space minimum, no billboard.
    expect(apparentScale(4.0), lessThan(apparentScale(1.0)));
    expect(apparentScale(100.0), lessThan(apparentScale(4.0)));
  });
}
