import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_display/progressive_octree_order.dart';

void main() {
  group('Review full point-cloud contract', () {
    test('never thins the persisted PLY', () {
      expect(ReviewPointCloudPolicy.drawStrideFor(0), 1);
      expect(ReviewPointCloudPolicy.drawStrideFor(109287), 1);
      expect(ReviewPointCloudPolicy.drawCountFor(109287), 109287);
    });
  });

  group('Capture stable progressive octree LOD', () {
    final xyz = Float32List.fromList(<double>[
      -1,
      -1,
      -1,
      -0.8,
      -0.8,
      -0.8,
      -1,
      -1,
      1,
      -1,
      1,
      -1,
      -1,
      1,
      1,
      1,
      -1,
      -1,
      1,
      -1,
      1,
      1,
      1,
      -1,
      1,
      1,
      1,
      0.8,
      0.8,
      0.8,
      0,
      0,
      0,
    ]);
    final rgb = Uint8List.fromList(
      List<int>.generate(xyz.length, (i) => i % 251),
    );

    test('is deterministic, complete, and a permutation', () {
      final a = ProgressiveOctreeOrder.build(xyz);
      final b = ProgressiveOctreeOrder.build(xyz);

      expect(a, orderedEquals(b));
      expect(a.length, xyz.length ~/ 3);
      expect(a.toSet().length, xyz.length ~/ 3);
      expect(a.toSet(), Set<int>.from(List<int>.generate(11, (i) => i)));
    });

    test('coarse prefixes cover all root octants before dense refinement', () {
      final order = ProgressiveOctreeOrder.build(xyz);
      final octants = <int>{};
      for (final pointIndex in order.take(9)) {
        final o = pointIndex * 3;
        final octant =
            (xyz[o] >= 0 ? 4 : 0) |
            (xyz[o + 1] >= 0 ? 2 : 0) |
            (xyz[o + 2] >= 0 ? 1 : 0);
        octants.add(octant);
      }
      expect(octants, hasLength(8));
    });

    test('reorders a display copy without mutating reconstruction buffers', () {
      final xyzBefore = Float32List.fromList(xyz);
      final rgbBefore = Uint8List.fromList(rgb);

      final packed = ProgressiveOctreeOrder.reorder(xyz: xyz, rgb: rgb);

      expect(xyz, orderedEquals(xyzBefore));
      expect(rgb, orderedEquals(rgbBefore));
      expect(packed.xyz.length, xyz.length);
      expect(packed.rgb.length, rgb.length);
      expect(packed.sourcePointCount, xyz.length ~/ 3);
      expect(packed.progressiveOrder.length, xyz.length ~/ 3);
    });

    test('every lower capture tier is a prefix of every higher tier', () {
      final order = ProgressiveOctreeOrder.build(xyz);
      final low = order.take(3).toList();
      final medium = order.take(7).toList();
      final full = order.toList();

      expect(medium.take(low.length), orderedEquals(low));
      expect(full.take(medium.length), orderedEquals(medium));
    });
  });
}
