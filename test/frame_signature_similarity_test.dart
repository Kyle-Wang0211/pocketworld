import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_quality/frame_signature_similarity.dart';

void main() {
  test('Aether byte signature similarity is one minus mean absolute delta', () {
    expect(
      aetherFrameSignatureSimilarity(
        current: Uint8List.fromList(<int>[0, 128, 255]),
        previous: Uint8List.fromList(<int>[0, 128, 255]),
      ),
      1.0,
    );
    expect(
      aetherFrameSignatureSimilarity(
        current: Uint8List.fromList(<int>[255, 128, 0]),
        previous: Uint8List.fromList(<int>[0, 128, 255]),
      ),
      closeTo(1 / 3, 1e-12),
    );
  });

  test('missing or incompatible baseline is unknown rather than redundant', () {
    expect(
      aetherFrameSignatureSimilarity(
        current: Uint8List.fromList(<int>[1]),
        previous: Uint8List(0),
      ),
      isNull,
    );
    expect(
      aetherFrameSignatureSimilarity(
        current: Uint8List.fromList(<int>[1, 2]),
        previous: Uint8List.fromList(<int>[1]),
      ),
      isNull,
    );
  });
}
