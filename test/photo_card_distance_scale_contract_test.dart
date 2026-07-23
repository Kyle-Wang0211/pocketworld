import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final pluginSources = <String, String>{
    'production': File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync(),
  };

  for (final entry in pluginSources.entries) {
    test('${entry.key} AR photo cards use the aggressive distance scale', () {
      final source = entry.value;

      expect(
        source,
        contains('private static let photoCardBaseScale: Float = 1.0'),
      );
      expect(
        source,
        contains('private static let photoCardMinVisualScale: Float = 0.08'),
      );
      expect(
        source,
        contains(
          'private static let photoCardVisualTransitionM: Float = 0.0045',
        ),
      );
      expect(
        source,
        contains('private static let photoCardMaxNodeScale: Float = 2.0'),
      );
      expect(source, contains('for (name, card) in photoCardNodes'));
      expect(
        source,
        contains('let travel = simd_distance(camPos, spec.captureCamPos)'),
      );
      expect(
        source,
        contains(
          'let visualScale = Self.photoCardMinVisualScale + '
          '(1.0 - Self.photoCardMinVisualScale) / '
          '(1.0 + travel / Self.photoCardVisualTransitionM)',
        ),
      );
      expect(
        source,
        contains(
          'let currentDistance = max('
          'simd_distance(camPos, card.simdWorldPosition), 0.001)',
        ),
      );
      expect(
        source,
        contains(
          'let perspectiveCompensation = currentDistance / '
          'max(spec.captureDistance, 0.001)',
        ),
      );
      expect(
        source,
        contains(
          'let s = min(Self.photoCardMaxNodeScale, '
          'Self.photoCardBaseScale * visualScale * '
          'perspectiveCompensation)',
        ),
      );
      expect(source, isNot(contains('photoCardDistanceAnchorM')));
      expect(source, isNot(contains('photoCardDistanceBeta')));
      expect(source, isNot(contains('photoCardFarScale')));
    });
  }

  test('visual curve loses 80% near 3 cm then quickly flattens', () {
    const captureDistanceM = 0.05;
    const minVisualScale = 0.08;
    const transitionM = 0.0045;
    const maxNodeScale = 2.0;

    double targetVisualScale(double travelM) =>
        minVisualScale + (1 - minVisualScale) / (1 + travelM / transitionM);
    double nodeScale(double travelM) {
      final currentDistanceM = captureDistanceM + travelM;
      return (targetVisualScale(travelM) * currentDistanceM / captureDistanceM)
          .clamp(0, maxNodeScale);
    }

    double apparentScale(double travelM) {
      final currentDistanceM = captureDistanceM + travelM;
      return nodeScale(travelM) * captureDistanceM / currentDistanceM;
    }

    expect(apparentScale(0), 1);
    expect(apparentScale(0.03), closeTo(0.20, 0.01));
    expect(apparentScale(0.10), closeTo(0.12, 0.01));
    expect(apparentScale(0.20), closeTo(0.10, 0.01));
    expect(apparentScale(1.0), closeTo(0.084, 0.001));
    // The 2× physical-node compensation cap takes over at long range; the
    // apparent card keeps shrinking slowly instead of holding a screen-space
    // minimum.
    expect(apparentScale(2.0), closeTo(0.049, 0.001));
    expect((apparentScale(2.0) - apparentScale(1.0)).abs(), lessThan(0.04));
  });
}
