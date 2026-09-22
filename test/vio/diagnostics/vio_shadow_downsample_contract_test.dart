import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/diagnostics/vio_shadow_downsample_contract.dart';

void main() {
  test('Dart owns the versioned N×N box half-up reference formula', () {
    expect(kVioShadowDownsampleFormulaBoxNxnHalfUpV1, 'box-nxn-half-up-v1');
    expect(vioShadowDownsampleBoxNxnHalfUp(<int>[0, 0, 0, 0], factor: 2), 0);
    expect(
      vioShadowDownsampleBoxNxnHalfUp(<int>[0, 0, 0, 2], factor: 2),
      1,
      reason: '(sum + floor(area/2)) ~/ area defines half-up rounding',
    );
    expect(
      vioShadowDownsampleBoxNxnHalfUp(<int>[
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ], factor: 3),
      4,
    );
    expect(
      vioShadowDownsampleBoxNxnHalfUp(List<int>.filled(9, 255), factor: 3),
      255,
    );
  });

  test('Dart reference rejects malformed blocks instead of guessing', () {
    expect(
      () => vioShadowDownsampleBoxNxnHalfUp(<int>[1], factor: 0),
      throwsArgumentError,
    );
    expect(
      () => vioShadowDownsampleBoxNxnHalfUp(<int>[1, 2, 3], factor: 2),
      throwsArgumentError,
    );
    expect(
      () => vioShadowDownsampleBoxNxnHalfUp(<int>[0, 0, 0, 256], factor: 2),
      throwsArgumentError,
    );
  });
}
