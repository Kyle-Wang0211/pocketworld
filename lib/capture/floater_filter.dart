// floater_filter.dart — 保守孤点过滤纯函数(live 主路径与断点续跑共用)。
//
// 从 ar_capture_page 的 _floaterKeepIndices 逐字提出(2026-07-10,resume
// 对齐战役):算法、常数、护栏一字未改;ar_capture_page 与 sfm_resume 都
// 调这里,保证冷恢复与现场交付的孤点判定逐点一致。零 Flutter 依赖。
//
// ── Orphan floater removal (conservative) ──
// Delete ONLY points with ZERO neighbors inside a HIGH-percentile radius —
// truly isolated speckle, never the dense surface or its (still-connected)
// sparse/edge regions. The radius comes from the cloud's OWN nearest-neighbor
// distribution (scale-invariant across captures) at the 99th percentile ×1.2,
// so legitimately sparse real walls stay above the cull line. O(n) via a hash
// grid (cell = radius → the 27-cell neighborhood covers the search sphere;
// early-exit on the first neighbor keeps the dense majority ~O(1)). Aggressive
// density-relative removal (SOR / small radius) was rejected: on an ~80%-2-view
// cloud it nibbles edges + sparse walls (violates 点更多不能稀疏) and can't kill
// the clustered/ghost floaters anyway. This only removes unambiguous orphans.

import 'dart:math' as math;
import 'dart:typed_data';

const int _kFloaterMinCloud = 2000; // below this, don't filter
const int _kFloaterScaleSample = 4096; // NN-distribution subsample cap
const double _kFloaterPct = 0.99; // radius from this NN percentile
const double _kFloaterRadiusMul = 1.2; // headroom above the percentile

int _floaterCellKey(int cx, int cy, int cz) =>
    (cx & 0x1FFFFF) | ((cy & 0x1FFFFF) << 21) | ((cz & 0x1FFFFF) << 42);

/// Survivor indices after orphan removal. Returns ALL indices (no-op) on any
/// degeneracy or a too-small cloud — always errs toward keeping points.
/// 带 [obsOffsets](CSR,长度 n+1)时,track 观测数 ≥3 的稳定点直接保护
/// 不参与近邻测试(与 live 交付路径同参数)。
({Int32List keep, double radius, int protectedStable, int ms})
floaterKeepIndices(Float32List xyz, {Int32List? obsOffsets}) {
  final sw = Stopwatch()..start();
  final n = xyz.length ~/ 3;
  Int32List allIdx() {
    final a = Int32List(n);
    for (var i = 0; i < n; i++) {
      a[i] = i;
    }
    return a;
  }

  ({Int32List keep, double radius, int protectedStable, int ms}) allKeep() => (
    keep: allIdx(),
    radius: 0,
    protectedStable: 0,
    ms: sw.elapsedMilliseconds,
  );
  if (n < _kFloaterMinCloud) {
    return allKeep();
  }
  var minX = xyz[0], minY = xyz[1], minZ = xyz[2];
  var maxX = xyz[0], maxY = xyz[1], maxZ = xyz[2];
  for (var i = 1; i < n; i++) {
    final x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
    if (z < minZ) minZ = z;
    if (z > maxZ) maxZ = z;
  }
  final ex = maxX - minX, ey = maxY - minY, ez = maxZ - minZ;
  final diag = math.sqrt(ex * ex + ey * ey + ez * ez);
  if (!(diag > 0)) {
    return allKeep();
  }
  Map<int, List<int>> build(double cell) {
    final g = <int, List<int>>{};
    final inv = 1.0 / cell;
    for (var i = 0; i < n; i++) {
      final cx = ((xyz[i * 3] - minX) * inv).floor();
      final cy = ((xyz[i * 3 + 1] - minY) * inv).floor();
      final cz = ((xyz[i * 3 + 2] - minZ) * inv).floor();
      (g[_floaterCellKey(cx, cy, cz)] ??= <int>[]).add(i);
    }
    return g;
  }

  // 1) Estimate the nearest-neighbor distance distribution on a coarse grid.
  final c0 = diag / math.pow(n, 1 / 3);
  if (!(c0 > 0)) {
    return allKeep();
  }
  final g0 = build(c0);
  final inv0 = 1.0 / c0;
  final stride = (n / _kFloaterScaleSample).ceil().clamp(1, n);
  final nn = <double>[];
  for (var i = 0; i < n; i += stride) {
    final cx = ((xyz[i * 3] - minX) * inv0).floor();
    final cy = ((xyz[i * 3 + 1] - minY) * inv0).floor();
    final cz = ((xyz[i * 3 + 2] - minZ) * inv0).floor();
    var best = double.infinity;
    for (var a = -1; a <= 1; a++) {
      for (var b = -1; b <= 1; b++) {
        for (var c = -1; c <= 1; c++) {
          final lst = g0[_floaterCellKey(cx + a, cy + b, cz + c)];
          if (lst == null) continue;
          for (final j in lst) {
            if (j == i) continue;
            final dx = xyz[i * 3] - xyz[j * 3];
            final dy = xyz[i * 3 + 1] - xyz[j * 3 + 1];
            final dz = xyz[i * 3 + 2] - xyz[j * 3 + 2];
            final d2 = dx * dx + dy * dy + dz * dz;
            if (d2 < best) best = d2;
          }
        }
      }
    }
    if (best.isFinite) nn.add(math.sqrt(best));
  }
  if (nn.isEmpty) {
    return allKeep();
  }
  nn.sort();
  final p = nn[(nn.length * _kFloaterPct).floor().clamp(0, nn.length - 1)];
  final radius = p * _kFloaterRadiusMul;
  if (!(radius > 0)) {
    return allKeep();
  }
  // 2) Keep points with >=1 neighbor within `radius` (cell = radius so the
  //    27-cell neighborhood covers the sphere); delete zero-neighbor orphans.
  final r2 = radius * radius;
  final g = build(radius);
  final invR = 1.0 / radius;
  final keep = <int>[];
  var protectedStable = 0;
  for (var i = 0; i < n; i++) {
    if (obsOffsets != null &&
        obsOffsets.length == n + 1 &&
        obsOffsets[i + 1] - obsOffsets[i] >= 3) {
      keep.add(i);
      protectedStable++;
      continue;
    }
    final cx = ((xyz[i * 3] - minX) * invR).floor();
    final cy = ((xyz[i * 3 + 1] - minY) * invR).floor();
    final cz = ((xyz[i * 3 + 2] - minZ) * invR).floor();
    var found = false;
    for (var a = -1; a <= 1 && !found; a++) {
      for (var b = -1; b <= 1 && !found; b++) {
        for (var c = -1; c <= 1 && !found; c++) {
          final lst = g[_floaterCellKey(cx + a, cy + b, cz + c)];
          if (lst == null) continue;
          for (final j in lst) {
            if (j == i) continue;
            final dx = xyz[i * 3] - xyz[j * 3];
            final dy = xyz[i * 3 + 1] - xyz[j * 3 + 1];
            final dz = xyz[i * 3 + 2] - xyz[j * 3 + 2];
            if (dx * dx + dy * dy + dz * dz <= r2) {
              found = true;
              break;
            }
          }
        }
      }
    }
    if (found) keep.add(i);
  }
  sw.stop();
  return (
    keep: Int32List.fromList(keep),
    radius: radius,
    protectedStable: protectedStable,
    ms: sw.elapsedMilliseconds,
  );
}

/// 按 [keepIdx] 压实 xyz+rgb(live 交付与 resume 持久化共用的紧凑拷贝)。
({Float32List xyz, Uint8List rgb}) compactXyzRgbByIndices(
  Float32List xyz,
  Uint8List rgb,
  Int32List keepIdx,
) {
  final m = keepIdx.length;
  final fxyz = Float32List(m * 3);
  final frgb = Uint8List(m * 3);
  for (var k = 0; k < m; k++) {
    final i = keepIdx[k];
    fxyz[k * 3] = xyz[i * 3];
    fxyz[k * 3 + 1] = xyz[i * 3 + 1];
    fxyz[k * 3 + 2] = xyz[i * 3 + 2];
    frgb[k * 3] = rgb[i * 3];
    frgb[k * 3 + 1] = rgb[i * 3 + 1];
    frgb[k * 3 + 2] = rgb[i * 3 + 2];
  }
  return (xyz: fxyz, rgb: frgb);
}
