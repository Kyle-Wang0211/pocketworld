// Display-only progressive point ordering.
//
// The hierarchy and "refine under a point budget" model are adapted from
// Potree's octree visibility traversal:
// https://github.com/potree/potree/blob/5636cd471d9eb464969e758be45c44d7613d3859/src/Potree_update_visibility.js
// Potree is BSD-2-Clause; its notice is reproduced in THIRD_PARTY_NOTICES.
//
// This file deliberately returns a reordered COPY. The SfM snapshot, PLY, and
// persisted project point order remain authoritative and untouched.

import 'dart:math' as math;
import 'dart:typed_data';

/// Review is the authoritative inspection surface: it draws every persisted
/// PLY point up to [kPointBudget]. Above it (dense clouds: millions of points;
/// the Dart canvas painter projects and sorts every drawn point every frame,
/// 6.9 M points froze build 161's viewer) it draws the first [kPointBudget]
/// points of the progressive octree order — a spatially uniform prefix, the
/// same Potree budget model this file is adapted from. The PLY itself is never
/// touched (delivery stays full); see `loadReviewCloud` in the viewer page.
abstract final class ReviewPointCloudPolicy {
  /// Potree's default: src/Potree.js (v1.8.2) `export let pointBudget = 1 * 1000 * 1000;`
  static const int kPointBudget = 1 * 1000 * 1000;

  static int drawStrideFor(int pointCount) => 1;

  static int drawCountFor(int pointCount) =>
      math.max(0, math.min(pointCount, kPointBudget));
}

final class ProgressivePointCloud {
  const ProgressivePointCloud({
    required this.xyz,
    required this.rgb,
    required this.progressiveOrder,
    required this.sourcePointCount,
  });

  final Float32List xyz;
  final Uint8List rgb;
  final Int32List progressiveOrder;
  final int sourcePointCount;
}

/// Isolate entry point used when a globally refined capture snapshot is ready.
ProgressivePointCloud buildProgressivePointCloud(
  ({Float32List xyz, Uint8List rgb}) source,
) {
  return ProgressiveOctreeOrder.reorder(xyz: source.xyz, rgb: source.rgb);
}

final class _CellChoice {
  const _CellChoice(this.pointIndex, this.distanceSquared);

  final int pointIndex;
  final double distanceSquared;
}

/// Produces a deterministic, nested octree order.
///
/// Each level contributes one original point nearest every occupied cell
/// centre before a deeper level is considered. Therefore any prefix is a
/// spatially distributed, stable subset of every larger prefix, while the
/// complete order is an exact permutation of the source points.
abstract final class ProgressiveOctreeOrder {
  static const int _maxHierarchyDepth = 10;

  static Int32List build(Float32List xyz) {
    if (xyz.length % 3 != 0) {
      throw ArgumentError.value(
        xyz.length,
        'xyz.length',
        'must contain packed xyz triplets',
      );
    }
    final pointCount = xyz.length ~/ 3;
    if (pointCount == 0) return Int32List(0);

    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (var i = 0; i < pointCount; i++) {
      final x = xyz[i * 3];
      final y = xyz[i * 3 + 1];
      final z = xyz[i * 3 + 2];
      if (!x.isFinite || !y.isFinite || !z.isFinite) continue;
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      minZ = math.min(minZ, z);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      maxZ = math.max(maxZ, z);
    }
    if (!minX.isFinite) {
      return Int32List.fromList(
        List<int>.generate(pointCount, (index) => index),
      );
    }

    final spanX = math.max(maxX - minX, 1e-12);
    final spanY = math.max(maxY - minY, 1e-12);
    final spanZ = math.max(maxZ - minZ, 1e-12);
    final chosen = Uint8List(pointCount);
    final output = Int32List(pointCount);
    var outputCount = 0;

    int quantize(double value, double min, double span, int cells) {
      if (!value.isFinite) return cells >> 1;
      return (((value - min) / span) * cells).floor().clamp(0, cells - 1);
    }

    for (
      var level = 0;
      level <= _maxHierarchyDepth && outputCount < pointCount;
      level++
    ) {
      final cells = 1 << level;
      final choices = <int, _CellChoice>{};
      for (var i = 0; i < pointCount; i++) {
        if (chosen[i] != 0) continue;
        final x = xyz[i * 3];
        final y = xyz[i * 3 + 1];
        final z = xyz[i * 3 + 2];
        final ix = quantize(x, minX, spanX, cells);
        final iy = quantize(y, minY, spanY, cells);
        final iz = quantize(z, minZ, spanZ, cells);
        final key = (ix << (level * 2)) | (iy << level) | iz;
        final centerX = minX + (ix + 0.5) * spanX / cells;
        final centerY = minY + (iy + 0.5) * spanY / cells;
        final centerZ = minZ + (iz + 0.5) * spanZ / cells;
        final dx = x.isFinite ? x - centerX : double.infinity;
        final dy = y.isFinite ? y - centerY : double.infinity;
        final dz = z.isFinite ? z - centerZ : double.infinity;
        final distanceSquared = dx * dx + dy * dy + dz * dz;
        final old = choices[key];
        if (old == null ||
            distanceSquared < old.distanceSquared ||
            (distanceSquared == old.distanceSquared && i < old.pointIndex)) {
          choices[key] = _CellChoice(i, distanceSquared);
        }
      }
      final cellKeys = choices.keys.toList()..sort();
      for (final key in cellKeys) {
        final pointIndex = choices[key]!.pointIndex;
        if (chosen[pointIndex] != 0) continue;
        chosen[pointIndex] = 1;
        output[outputCount++] = pointIndex;
      }
    }

    // Coincident points can share one cell at every finite hierarchy depth.
    // Preserve them too, deterministically, so "full" is truly the full PLY.
    for (var i = 0; i < pointCount; i++) {
      if (chosen[i] == 0) output[outputCount++] = i;
    }
    return output;
  }

  static ProgressivePointCloud reorder({
    required Float32List xyz,
    required Uint8List rgb,
  }) {
    final pointCount = xyz.length ~/ 3;
    if (xyz.length % 3 != 0 || rgb.length < pointCount * 3) {
      throw ArgumentError(
        'xyz and rgb must contain equally sized packed triplets',
      );
    }
    final order = build(xyz);
    final orderedXyz = Float32List(xyz.length);
    final orderedRgb = Uint8List(pointCount * 3);
    for (var outIndex = 0; outIndex < pointCount; outIndex++) {
      final sourceIndex = order[outIndex];
      final sourceOffset = sourceIndex * 3;
      final outputOffset = outIndex * 3;
      orderedXyz[outputOffset] = xyz[sourceOffset];
      orderedXyz[outputOffset + 1] = xyz[sourceOffset + 1];
      orderedXyz[outputOffset + 2] = xyz[sourceOffset + 2];
      orderedRgb[outputOffset] = rgb[sourceOffset];
      orderedRgb[outputOffset + 1] = rgb[sourceOffset + 1];
      orderedRgb[outputOffset + 2] = rgb[sourceOffset + 2];
    }
    return ProgressivePointCloud(
      xyz: orderedXyz,
      rgb: orderedRgb,
      progressiveOrder: order,
      sourcePointCount: pointCount,
    );
  }
}
