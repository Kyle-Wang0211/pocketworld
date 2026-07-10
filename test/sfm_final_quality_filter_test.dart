import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/aether_sfm_ffi.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';

void main() {
  test('drops only time-far two-view points and compacts observations', () {
    final input = AetherSfmPointsTracked(
      Float32List.fromList(<double>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]),
      Uint8List.fromList(<int>[10, 11, 12, 20, 21, 22, 30, 31, 32, 40, 41, 42]),
      Int32List.fromList(<int>[0, 2, 4, 7, 9]),
      Int32List.fromList(<int>[0, 12, 0, 13, 0, 13, 14, 2, 14]),
      Float32List.fromList(
        List<double>.generate(18, (index) => index.toDouble()),
      ),
    );

    final result = filterFinalSpatialTwoViewPoints(input, temporalK: 12);

    expect(result.removed, 1);
    expect(result.points.count, 3);
    expect(
      result.points.xyz,
      Float32List.fromList(<double>[0, 1, 2, 6, 7, 8, 9, 10, 11]),
    );
    expect(
      result.points.rgb,
      Uint8List.fromList(<int>[10, 11, 12, 30, 31, 32, 40, 41, 42]),
    );
    expect(result.points.obsOffsets, Int32List.fromList(<int>[0, 2, 5, 7]));
    expect(
      result.points.obsFrameIds,
      Int32List.fromList(<int>[0, 12, 0, 13, 14, 2, 14]),
    );
    expect(
      result.points.obsXY,
      Float32List.fromList(<double>[
        0,
        1,
        2,
        3,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
      ]),
    );
  });
}
