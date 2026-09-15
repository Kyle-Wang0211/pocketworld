// dense_live_cloud_test.dart — the live display copy of a running dense job: the stride is fixed by the plan
// (framesPlanned x n / budget), the accumulated copy stays inside the review point budget, the full counts stay
// full, and every addChunk hands the painter a new typed-list identity.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/dense_live_cloud.dart';
import 'package:pocketworld_flutter/point_cloud_display/progressive_octree_order.dart';

({Float32List xyz, Uint8List rgb}) _chunk(int n, {double base = 0}) {
  final xyz = Float32List(n * 3);
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    xyz[i * 3] = base + i;
    xyz[i * 3 + 1] = base + i + 0.5;
    xyz[i * 3 + 2] = base + i + 0.25;
    rgb[i * 3] = i % 256;
    rgb[i * 3 + 1] = (i * 3) % 256;
    rgb[i * 3 + 2] = (i * 7) % 256;
  }
  return (xyz: xyz, rgb: rgb);
}

void main() {
  test('framesPlanned 100 x 50k points: stride 5, accumulated copy inside the review budget', () {
    final live = DenseLiveCloud(framesPlanned: 100);
    expect(live.budget, ReviewPointCloudPolicy.kPointBudget);
    expect(live.budget, 1000000);
    expect(live.strideFor(50000), 5); // ceil(100 * 50000 / 1e6)
    expect(live.isEmpty, isTrue);

    final c = _chunk(50000);
    for (var f = 0; f < 100; f++) {
      live.addChunk(frameIndex: f, xyz: c.xyz, rgb: c.rgb);
    }
    expect(live.frames, 100);
    expect(live.sourcePoints, 5000000); // full delivery count, not the displayed subset
    expect(live.points, 1000000); // ceil(50000/5) per frame x 100
    expect(live.points, lessThanOrEqualTo(ReviewPointCloudPolicy.kPointBudget));
    expect(live.xyz.length, live.points * 3);
    expect(live.rgb.length, live.points * 3);
    expect(live.isEmpty, isFalse);
    expect(live.lastFrameIndex, 99);
  });

  test('framesPlanned 1 (unknown): every point is kept, in arrival order', () {
    final live = DenseLiveCloud();
    expect(live.framesPlanned, 1);
    expect(live.strideFor(50000), 1);
    final a = _chunk(3, base: 100);
    final b = _chunk(2, base: 200);
    live.addChunk(frameIndex: 7, xyz: a.xyz, rgb: a.rgb);
    live.addChunk(frameIndex: 8, xyz: b.xyz, rgb: b.rgb);
    expect(live.frames, 2);
    expect(live.points, 5);
    expect(live.sourcePoints, 5);
    expect(live.xyz, Float32List.fromList(<double>[...a.xyz, ...b.xyz]));
    expect(live.rgb, Uint8List.fromList(<int>[...a.rgb, ...b.rgb]));
    expect(live.lastFrameIndex, 8);
  });

  test('the stride takes the same source points for xyz and rgb', () {
    final live = DenseLiveCloud(framesPlanned: 10, budget: 100);
    expect(live.strideFor(50), 5); // ceil(10 * 50 / 100)
    final c = _chunk(50);
    live.addChunk(frameIndex: 0, xyz: c.xyz, rgb: c.rgb);
    expect(live.points, 10); // ceil(50 / 5)
    for (var i = 0; i < live.points; i++) {
      final src = i * 5;
      expect(live.xyz[i * 3], c.xyz[src * 3]);
      expect(live.xyz[i * 3 + 1], c.xyz[src * 3 + 1]);
      expect(live.xyz[i * 3 + 2], c.xyz[src * 3 + 2]);
      expect(live.rgb[i * 3], c.rgb[src * 3]);
      expect(live.rgb[i * 3 + 1], c.rgb[src * 3 + 1]);
      expect(live.rgb[i * 3 + 2], c.rgb[src * 3 + 2]);
    }
  });

  test('xyz/rgb identity changes on every addChunk and is stable between chunks', () {
    final live = DenseLiveCloud(framesPlanned: 2);
    final before = live.xyz;
    final beforeRgb = live.rgb;
    expect(identical(live.xyz, before), isTrue);
    final c = _chunk(4);
    live.addChunk(frameIndex: 0, xyz: c.xyz, rgb: c.rgb);
    expect(identical(live.xyz, before), isFalse);
    expect(identical(live.rgb, beforeRgb), isFalse);
    final first = live.xyz;
    expect(identical(live.xyz, first), isTrue); // no copy churn between chunks
    live.addChunk(frameIndex: 1, xyz: c.xyz, rgb: c.rgb);
    expect(identical(live.xyz, first), isFalse);
  });

  test('an empty chunk still counts as a frame and still republishes', () {
    final live = DenseLiveCloud(framesPlanned: 3);
    final c = _chunk(2);
    live.addChunk(frameIndex: 0, xyz: c.xyz, rgb: c.rgb);
    final before = live.xyz;
    live.addChunk(frameIndex: 1, xyz: Float32List(0), rgb: Uint8List(0));
    expect(live.frames, 2);
    expect(live.points, 2);
    expect(live.sourcePoints, 2);
    expect(identical(live.xyz, before), isFalse);
    expect(live.xyz, before); // same contents
  });

  test('more frames than planned: the budget clamp holds', () {
    final live = DenseLiveCloud(framesPlanned: 2, budget: 1000);
    final c = _chunk(600);
    for (var f = 0; f < 6; f++) {
      live.addChunk(frameIndex: f, xyz: c.xyz, rgb: c.rgb);
    }
    expect(live.frames, 6);
    expect(live.sourcePoints, 3600);
    expect(live.points, lessThanOrEqualTo(1000));
    expect(live.xyz.length, live.points * 3);
    expect(live.rgb.length, live.points * 3);
  });
}
