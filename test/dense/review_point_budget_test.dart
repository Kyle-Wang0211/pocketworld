// review_point_budget_test.dart — a cloud above the review point budget is shown as a uniform (octree-ordered)
// prefix; the file and the reported source count stay full. Below the budget nothing changes.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_display/progressive_octree_order.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart';

File _writePly(Directory dir, int n, math.Random rng) {
  final header = 'ply\nformat binary_little_endian 1.0\nelement vertex $n\nproperty float x\nproperty float y\nproperty float z\n'
      'property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n';
  final body = ByteData(n * 15);
  for (var i = 0; i < n; i++) {
    final o = i * 15;
    body.setFloat32(o, rng.nextDouble() * 4 - 2, Endian.little);
    body.setFloat32(o + 4, rng.nextDouble() * 2 - 1, Endian.little);
    body.setFloat32(o + 8, rng.nextDouble() * 6 - 3, Endian.little);
    body.setUint8(o + 12, i % 256);
    body.setUint8(o + 13, (i * 7) % 256);
    body.setUint8(o + 14, (i * 13) % 256);
  }
  final f = File('${dir.path}/cloud_$n.ply');
  f.writeAsBytesSync([...header.codeUnits, ...body.buffer.asUint8List()]);
  return f;
}

void main() {
  test('Potree default point budget is the review budget', () {
    expect(ReviewPointCloudPolicy.kPointBudget, 1000000);
    expect(ReviewPointCloudPolicy.drawCountFor(12122), 12122);
    expect(ReviewPointCloudPolicy.drawCountFor(6922990), 1000000);
  });

  test('above the budget: uniform prefix of the requested size, source count kept, extent preserved', () {
    final dir = Directory.systemTemp.createTempSync('pw_review_budget');
    final rng = math.Random(7);
    final f = _writePly(dir, 2500, rng);
    final c = loadReviewCloudWithBudget(f.path, 1000)!;
    expect(c.count, 1000);
    expect(c.sourceCount, 2500);
    // the octree order puts coarse-level representatives first: the prefix spans the whole cloud
    double mn(int k) {
      var v = double.infinity;
      for (var i = 0; i < c.count; i++) {
        v = math.min(v, c.xyz[i * 3 + k]);
      }
      return v;
    }

    double mx(int k) {
      var v = -double.infinity;
      for (var i = 0; i < c.count; i++) {
        v = math.max(v, c.xyz[i * 3 + k]);
      }
      return v;
    }

    expect(mn(0), lessThan(-1.8)); expect(mx(0), greaterThan(1.8));
    expect(mn(1), lessThan(-0.9)); expect(mx(1), greaterThan(0.9));
    expect(mn(2), lessThan(-2.7)); expect(mx(2), greaterThan(2.7));
    dir.deleteSync(recursive: true);
  });

  test('at or below the budget: identical to the plain loader', () {
    final dir = Directory.systemTemp.createTempSync('pw_review_budget2');
    final f = _writePly(dir, 500, math.Random(3));
    final a = loadSparsePly(f.path)!;
    final b = loadReviewCloudWithBudget(f.path, 1000)!;
    expect(b.count, 500);
    expect(b.sourceCount, 500);
    expect(b.xyz, a.xyz);
    expect(b.rgb, a.rgb);
    dir.deleteSync(recursive: true);
  });
}
