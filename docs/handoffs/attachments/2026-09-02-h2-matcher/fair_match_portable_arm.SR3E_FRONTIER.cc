// fair_match_portable_arm.cc — H2 harness portable arm: Dawn/WGSL matcher
// with the COMPLETE production semantics (both directions, in-kernel angular
// acos Lowe ratio + absolute threshold with the exact production formulas,
// per-row readback, shared-host mutual cross-check, deterministic ordered
// pairs) on the same immutable fixture as the native arm.
//
// usage: fair_match_portable_arm <fixture_dir> <out_dir> <reps> <warmup>
//                                <ratio> <kernel: naive|tiled>
//
// Gating replicates official_gpu_match.mm pw_match_gemm lines 318-342
// (guideMode==0):
//   init best=0, second=0, index=-1; strict > selection in ascending
//   candidate order; bd = acos(min(best/512^2, 1)); sd likewise;
//   keep iff bd <= maxDistance && bd < maxRatio * sd.
// Dots are exact integers in both arms (u32 dot4U8Packed here, half-GEMM
// f32-accumulate there), and WGSL acos lowers to the same Metal stdlib on
// this host, so ordered pairs are expected byte-identical.
//
// Three kernels:
//   naive — per-thread 4-query full scan (descends from the 2026-08-01
//           subgroup_matrix_matcher_bench packed shader, semantics completed).
//   tiled — SR-1 candidate: 64-row workgroup-shared B tile + one query per
//           thread held in registers; device traffic drops from
//           O(nA * nB) to O(nA/64 * nB) descriptor reads per direction.
//   mma   — SR-2 candidate: mirrors the production Metal v1 kernel structure
//           in WGSL — f32 8x8x8 subgroup matrices (the only exact-integer MMA
//           config Dawn exposes on M3; f16->f16 overflows u8 dot sums
//           constructively), A fragments held per-subgroup, B staged through
//           a 32-row workgroup tile, accumulator staged to workgroup scratch,
//           then the same ascending scalar top-2 scan. Bypasses the Metal
//           dot4U8Packed polyfill entirely.

#include <webgpu/webgpu_cpp.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "fair_match_common.h"

namespace {

std::ostream& operator<<(std::ostream& stream, const wgpu::StringView& value) {
  if (!value.data) return stream;
  if (value.length == WGPU_STRLEN) return stream << value.data;
  return stream.write(value.data, (std::streamsize)value.length);
}

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

// Complete-semantics gating epilogue shared by both kernels (verbatim
// production formulas; INV_SQ_NORM = 1/512^2 = 1/262144).
constexpr char kEpilogue[] = R"(
fn gate(best : u32, second : u32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(f32(best) * INV_SQ_NORM, 1.0));
  let sd = acos(min(f32(second) * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}
)";

constexpr char kCommonDecls[] = R"(
const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
};

@group(0) @binding(0) var<storage, read> A : array<vec4<u32>>;
@group(0) @binding(1) var<storage, read> B : array<vec4<u32>>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
)";

// naive: 4 queries per thread, full ascending scan of B from device memory.
constexpr char kNaiveBody[] = R"(
const QPT : u32 = 4u;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let query0 = gid.x * QPT;
  if (query0 >= U.numA) { return; }
  var query : array<vec4<u32>, 32>; // 4 queries x 8 vec4 words
  var validQuery : array<bool, 4>;
  for (var slot = 0u; slot < QPT; slot = slot + 1u) {
    let row = query0 + slot;
    validQuery[slot] = row < U.numA;
    if (validQuery[slot]) {
      for (var w = 0u; w < 8u; w = w + 1u) {
        query[slot * 8u + w] = A[row * 8u + w];
      }
    }
  }
  var best : array<u32, 4>;
  var second : array<u32, 4>;
  var bestIndex : array<i32, 4>;
  for (var slot = 0u; slot < QPT; slot = slot + 1u) {
    best[slot] = 0u;
    second[slot] = 0u;
    bestIndex[slot] = -1;
  }
  for (var candidate = 0u; candidate < U.numB; candidate = candidate + 1u) {
    var sums : array<u32, 4>;
    for (var slot = 0u; slot < QPT; slot = slot + 1u) { sums[slot] = 0u; }
    for (var w = 0u; w < 8u; w = w + 1u) {
      let bv = B[candidate * 8u + w];
      for (var slot = 0u; slot < QPT; slot = slot + 1u) {
        let qv = query[slot * 8u + w];
        sums[slot] += dot4U8Packed(qv.x, bv.x) + dot4U8Packed(qv.y, bv.y) +
                      dot4U8Packed(qv.z, bv.z) + dot4U8Packed(qv.w, bv.w);
      }
    }
    for (var slot = 0u; slot < QPT; slot = slot + 1u) {
      if (sums[slot] > best[slot]) {
        second[slot] = best[slot];
        best[slot] = sums[slot];
        bestIndex[slot] = i32(candidate);
      } else if (sums[slot] > second[slot]) {
        second[slot] = sums[slot];
      }
    }
  }
  for (var slot = 0u; slot < QPT; slot = slot + 1u) {
    if (validQuery[slot]) {
      Out[query0 + slot] = gate(best[slot], second[slot], bestIndex[slot]);
    }
  }
}
)";

// tiled: one query per thread in registers, B staged through workgroup shared
// memory in 64-row tiles (8 KiB). Ascending tile + in-tile order preserves the
// production first-maximum tie-break.
constexpr char kTiledBody[] = R"(
const WG : u32 = 64u;

var<workgroup> Bsh : array<vec4<u32>, 512>; // 64 rows x 8 vec4 words

@compute @workgroup_size(64)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32) {
  let row = wg.x * WG + lid;
  let valid = row < U.numA;
  var q : array<vec4<u32>, 8>;
  if (valid) {
    for (var w = 0u; w < 8u; w = w + 1u) { q[w] = A[row * 8u + w]; }
  }
  var best = 0u;
  var second = 0u;
  var bestIndex = -1;
  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    let brow = tile0 + lid;
    if (brow < U.numB) {
      for (var w = 0u; w < 8u; w = w + 1u) {
        Bsh[lid * 8u + w] = B[brow * 8u + w];
      }
    }
    workgroupBarrier();
    let lim = min(WG, U.numB - tile0);
    if (valid) {
      for (var c = 0u; c < lim; c = c + 1u) {
        var s = 0u;
        for (var w = 0u; w < 8u; w = w + 1u) {
          let bv = Bsh[c * 8u + w];
          s += dot4U8Packed(q[w].x, bv.x) + dot4U8Packed(q[w].y, bv.y) +
               dot4U8Packed(q[w].z, bv.z) + dot4U8Packed(q[w].w, bv.w);
        }
        if (s > best) {
          second = best;
          best = s;
          bestIndex = i32(tile0 + c);
        } else if (s > second) {
          second = s;
        }
      }
    }
    workgroupBarrier();
    tile0 = tile0 + WG;
  }
  if (valid) { Out[row] = gate(best, second, bestIndex); }
}
)";

// mma: SR-2 — Metal-v1-structure subgroup-matrix kernel. Inputs are u8 values
// expanded to f32 on the host (mirrors the production per-call u8->half
// conversion); dots stay exact integers in f32 (max 8.3M < 2^24).
constexpr char kMmaShader[] = R"(
enable chromium_experimental_subgroup_matrix;
enable subgroups;

alias Left = subgroup_matrix_left<f32, 8, 8>;
alias Right = subgroup_matrix_right<f32, 8, 8>;
alias Res = subgroup_matrix_result<f32, 8, 8>;

const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 64u;  // A rows per workgroup (8 subgroups x 8 rows)
const BT : u32 = 32u;   // B rows per staged tile

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
};

@group(0) @binding(0) var<storage, read> A : array<f32>;
@group(0) @binding(1) var<storage, read> B : array<f32>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;

var<workgroup> Bsh : array<f32, 4096>;    // 32 rows x 128 (16 KiB)
var<workgroup> accSh : array<f32, 2048>;  // 64 rows x 32 cols (8 KiB)
var<workgroup> bestT : array<f32, 64>;
var<workgroup> secondT : array<f32, 64>;
var<workgroup> biT : array<i32, 64>;

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32) {
  let row0 = wg.x * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
  if (lid < WGR) {
    bestT[lid] = 0.0;
    secondT[lid] = 0.0;
    biT[lid] = -1;
  }
  workgroupBarrier();

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var e = lid; e < BT * 128u; e = e + 256u) {
      let brow = tile0 + e / 128u;
      Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
    }
    workgroupBarrier();
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = subgroupMatrixLoad<Right>(&Bsh, (nt * 8u) * 128u + k * 8u,
                                           true, 128u);
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, $ACCOFF$, acc, $ACCCM$, $ACCSTRIDE$u);
    }
    workgroupBarrier();
    if (lid < WGR) {
      let lim = min(BT, U.numB - tile0);
      var best = bestT[lid];
      var second = secondT[lid];
      var bi = biT[lid];
      for (var c = 0u; c < lim; c = c + 1u) {
        let s = accSh[lid * 32u + c];
        if (s > best) {
          second = best;
          best = s;
          bi = i32(tile0 + c);
        } else if (s > second) {
          second = s;
        }
      }
      bestT[lid] = best;
      secondT[lid] = second;
      biT[lid] = bi;
    }
    workgroupBarrier();
    tile0 = tile0 + BT;
  }
  let row = row0 + lid;
  if (lid < WGR && row < U.numA) {
    Out[row] = gatef(bestT[lid], secondT[lid], biT[lid]);
  }
}
)";

// fused: SR-3A — single variable vs mma: the two mirrored dispatches are
// replaced by ONE grid traversal that maintains the row-wise (A->B) top-2
// in-workgroup AND per-workgroup column partials, plus a deterministic
// ascending merge kernel that reduces the partials into the B->A results
// (the production Metal v2 structure). Tile shapes, f32 MMA, gating and all
// other structure are identical to mma, so any speed delta is attributable
// to bidirectional fusion alone. Exactness: within-workgroup column scans
// ascend over A rows, the merge ascends over workgroups (= ascending A row
// blocks) with strict->, so the first-maximum tie-break is preserved.
constexpr char kFusedShader[] = R"(
enable chromium_experimental_subgroup_matrix;
enable subgroups;

alias Left = subgroup_matrix_left<f32, 8, 8>;
alias Right = subgroup_matrix_right<f32, 8, 8>;
alias Res = subgroup_matrix_result<f32, 8, 8>;

const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 64u;
const BT : u32 = 32u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  pad0 : u32,
  pad1 : u32,
  pad2 : u32,
};

struct ColPart {
  best : f32,
  second : f32,
  idx : i32,
};

@group(0) @binding(0) var<storage, read> A : array<f32>;
@group(0) @binding(1) var<storage, read> B : array<f32>;
@group(0) @binding(2) var<storage, read_write> OutAB : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
@group(0) @binding(4) var<storage, read_write> ColP : array<ColPart>;
@group(0) @binding(5) var<storage, read_write> OutBA : array<i32>;

var<workgroup> Bsh : array<f32, 4096>;
var<workgroup> accSh : array<f32, 2048>;
var<workgroup> bestT : array<f32, 64>;
var<workgroup> secondT : array<f32, 64>;
var<workgroup> biT : array<i32, 64>;

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32) {
  let row0 = wg.x * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
  if (lid < WGR) {
    bestT[lid] = 0.0;
    secondT[lid] = 0.0;
    biT[lid] = -1;
  }
  workgroupBarrier();

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var e = lid; e < BT * 128u; e = e + 256u) {
      let brow = tile0 + e / 128u;
      Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
    }
    workgroupBarrier();
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = subgroupMatrixLoad<Right>(&Bsh, (nt * 8u) * 128u + k * 8u,
                                           true, 128u);
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, $ACCOFF$, acc, $ACCCM$, $ACCSTRIDE$u);
    }
    workgroupBarrier();
    if (lid < WGR) {
      // Row-wise top-2 (A->B), ascending candidate order.
      let lim = min(BT, U.numB - tile0);
      var best = bestT[lid];
      var second = secondT[lid];
      var bi = biT[lid];
      for (var c = 0u; c < lim; c = c + 1u) {
        let s = accSh[lid * 32u + c];
        if (s > best) {
          second = best;
          best = s;
          bi = i32(tile0 + c);
        } else if (s > second) {
          second = s;
        }
      }
      bestT[lid] = best;
      secondT[lid] = second;
      biT[lid] = bi;
    } else if (lid < WGR + BT) {
      // Column partial (B->A restricted to this workgroup's 64 A rows),
      // ascending A-row order. Padded A rows carry zero dots and are never
      // selected by the strict comparison.
      let cl = lid - WGR;
      let c = tile0 + cl;
      if (c < U.numB) {
        var best = 0.0;
        var second = 0.0;
        var bi = -1;
        for (var r = 0u; r < WGR; r = r + 1u) {
          let s = accSh[r * 32u + cl];
          if (s > best) {
            second = best;
            best = s;
            bi = i32(row0 + r);
          } else if (s > second) {
            second = s;
          }
        }
        ColP[c * U.numWg + wg.x] = ColPart(best, second, bi);
      }
    }
    workgroupBarrier();
    tile0 = tile0 + BT;
  }
  let row = row0 + lid;
  if (lid < WGR && row < U.numA) {
    OutAB[row] = gatef(bestT[lid], secondT[lid], biT[lid]);
  }
}

@compute @workgroup_size(64)
fn merge(@builtin(global_invocation_id) gid : vec3<u32>) {
  let c = gid.x;
  if (c >= U.numB) { return; }
  var best = 0.0;
  var second = 0.0;
  var bi = -1;
  for (var w = 0u; w < U.numWg; w = w + 1u) {
    let p = ColP[c * U.numWg + w];
    if (p.best > best) {
      second = max(best, p.second);
      best = p.best;
      bi = p.idx;
    } else {
      second = max(second, p.best);
    }
  }
  OutBA[c] = gatef(best, second, bi);
}
)";

// fusedr template (SR-3B): identical to `fused` except (a) the per-row top-2
// state lives in thread-private registers instead of workgroup arrays (the
// same thread owns the same row across all tiles, so workgroup storage was
// never required — this frees the shared-memory budget that lets WGR=128 fit
// exactly into the 32 KiB Apple limit), and (b) WGR/workgroup-size are
// template parameters so fusedr64 and fusedr128 coexist in one binary for
// mirrored ABBA runs. $WGR$ / $WGSIZE$ / $ACC$ are substituted at startup.
constexpr char kFusedRTemplate[] = R"(
enable chromium_experimental_subgroup_matrix;
enable subgroups;

alias Left = subgroup_matrix_left<f32, 8, 8>;
alias Right = subgroup_matrix_right<f32, 8, 8>;
alias Res = subgroup_matrix_result<f32, 8, 8>;

const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = $WGR$u;
const BT : u32 = 32u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  pad0 : u32,
  pad1 : u32,
  pad2 : u32,
};

struct ColPart {
  best : f32,
  second : f32,
  idx : i32,
};

@group(0) @binding(0) var<storage, read> A : array<f32>;
@group(0) @binding(1) var<storage, read> B : array<f32>;
@group(0) @binding(2) var<storage, read_write> OutAB : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
@group(0) @binding(4) var<storage, read_write> ColP : array<ColPart>;
@group(0) @binding(5) var<storage, read_write> OutBA : array<i32>;

$BSH_DECL$
var<workgroup> accSh : array<f32, $ACC$>;   // WGR rows x 32 cols

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

@compute @workgroup_size($WGSIZE$)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32) {
  let row0 = wg.x * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
$ROWDECL$

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
$STAGE$
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = $RIGHT_LOAD$;
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, $ACCOFF$, acc, $ACCCM$, $ACCSTRIDE$u);
    }
    workgroupBarrier();
$ROWSCAN$$COLSCAN$
    workgroupBarrier();
    tile0 = tile0 + BT;
  }
$OUTAB$
}

@compute @workgroup_size(64)
fn merge(@builtin(global_invocation_id) gid : vec3<u32>) {
  let c = gid.x;
  if (c >= U.numB) { return; }
  var best = 0.0;
  var second = 0.0;
  var bi = -1;
  for (var w = 0u; w < U.numWg; w = w + 1u) {
    let p = ColP[c * U.numWg + w];
    if (p.best > best) {
      second = max(best, p.second);
      best = p.best;
      bi = p.idx;
    } else {
      second = max(second, p.best);
    }
  }
  OutBA[c] = gatef(best, second, bi);
}
)";

// fusedr-db template (SR-3D-1): identical semantics to kFusedRTemplate, but
// the tile loop is software-pipelined: tile 0 is staged in a prologue, then
// each iteration runs {mma; barrier; (top-2 scans of THIS tile || staging of
// the NEXT tile by the otherwise-idle lanes); barrier} — 2 barriers per tile
// instead of 3. Legal because the mma consuming Bsh[tile t] completes before
// the first barrier, so overwriting Bsh with tile t+1 in the same interval as
// the accSh scans (disjoint arrays) has no hazard; the next mma's accSh
// stores sit behind the closing barrier (WAR respected). Scan order (ascending
// candidates within tile, ascending tiles, strict >) is byte-identical.
constexpr char kFusedRDbTemplate[] = R"(
enable chromium_experimental_subgroup_matrix;
enable subgroups;

alias Left = subgroup_matrix_left<f32, 8, 8>;
alias Right = subgroup_matrix_right<f32, 8, 8>;
alias Res = subgroup_matrix_result<f32, 8, 8>;

const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = $WGR$u;
const BT : u32 = 32u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  pad0 : u32,
  pad1 : u32,
  pad2 : u32,
};

struct ColPart {
  best : f32,
  second : f32,
  idx : i32,
};

@group(0) @binding(0) var<storage, read> A : array<f32>;
@group(0) @binding(1) var<storage, read> B : array<f32>;
@group(0) @binding(2) var<storage, read_write> OutAB : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
@group(0) @binding(4) var<storage, read_write> ColP : array<ColPart>;
@group(0) @binding(5) var<storage, read_write> OutBA : array<i32>;

$BSH_DECL$
var<workgroup> accSh : array<f32, $ACC$>;   // WGR rows x 32 cols

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

@compute @workgroup_size($WGSIZE$)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32) {
  let row0 = wg.x * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
$ROWDECL$
$STAGE0$
  workgroupBarrier();

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = $RIGHT_LOAD$;
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, $ACCOFF$, acc, $ACCCM$, $ACCSTRIDE$u);
    }
    workgroupBarrier();
    let nextT = tile0 + BT;
$STAGENEXT$
$ROWSCAN$$COLSCAN$
    workgroupBarrier();
    tile0 = nextT;
  }
$OUTAB$
}

@compute @workgroup_size(64)
fn merge(@builtin(global_invocation_id) gid : vec3<u32>) {
  let c = gid.x;
  if (c >= U.numB) { return; }
  var best = 0.0;
  var second = 0.0;
  var bi = -1;
  for (var w = 0u; w < U.numWg; w = w + 1u) {
    let p = ColP[c * U.numWg + w];
    if (p.best > best) {
      second = max(best, p.second);
      best = p.best;
      bi = p.idx;
    } else {
      second = max(second, p.best);
    }
  }
  OutBA[c] = gatef(best, second, bi);
}
)";

// SR-3E templates (WGR128, BT16 fixed). Two self-contained shaders that do
// NOT share the $ACCOFF$/scan machinery of the frozen -db BT32 frontier, so
// the 696/696 frontier is untouched. Both preserve the exact tie-break: row
// scan ascends candidates within a tile then across ascending tiles with
// strict >; col scan ascends A-rows; padded/out-of-range B rows are zeroed by
// select() and never selected. accSh is 128 rows x 16 cols (stride 16).
//
// $HDR$ expands to the shared prelude (enables, aliases, consts, Params,
// ColPart, bindings, gatef, main signature, aFrag load, register init) and
// the identical merge kernel, so only the tile loop differs between the two.
constexpr char kSr3eHead[] = R"(
enable chromium_experimental_subgroup_matrix;
enable subgroups;

alias Left = subgroup_matrix_left<f32, 8, 8>;
alias Right = subgroup_matrix_right<f32, 8, 8>;
alias Res = subgroup_matrix_result<f32, 8, 8>;

const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 128u;
const BT : u32 = 16u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  pad0 : u32,
  pad1 : u32,
  pad2 : u32,
};

struct ColPart {
  best : f32,
  second : f32,
  idx : i32,
};

@group(0) @binding(0) var<storage, read> A : array<f32>;
@group(0) @binding(1) var<storage, read> B : array<f32>;
@group(0) @binding(2) var<storage, read_write> OutAB : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
@group(0) @binding(4) var<storage, read_write> ColP : array<ColPart>;
@group(0) @binding(5) var<storage, read_write> OutBA : array<i32>;
)";

// Shared merge kernel (identical to -db) + gatef; appended after the tile loop.
constexpr char kSr3eTail[] = R"(
@compute @workgroup_size(64)
fn merge(@builtin(global_invocation_id) gid : vec3<u32>) {
  let c = gid.x;
  if (c >= U.numB) { return; }
  var best = 0.0;
  var second = 0.0;
  var bi = -1;
  for (var w = 0u; w < U.numWg; w = w + 1u) {
    let p = ColP[c * U.numWg + w];
    if (p.best > best) {
      second = max(best, p.second);
      best = p.best;
      bi = p.idx;
    } else {
      second = max(second, p.best);
    }
  }
  OutBA[c] = gatef(best, second, bi);
}
)";

constexpr char kSr3eGatef[] = R"(
fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}
)";

// db16: BT16 SINGLE-buffer control — the -db pipeline at half tile size.
// [mma] barrier [idle-lanes stage next tile || scan lanes scan] barrier.
constexpr char kSr3eDb16Loop[] = R"(
var<workgroup> Bsh : array<f32, 2048>;   // 16 rows x 128 (8 KiB)
var<workgroup> accSh : array<f32, 2048>; // 128 rows x 16 (8 KiB)

@compute @workgroup_size(512)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32) {
  let row0 = wg.x * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
  var rbest = 0.0; var rsecond = 0.0; var rbi = -1;

  // prologue: stage tile 0 (all lanes)
  for (var e = lid; e < BT * 128u; e = e + 512u) {
    let brow = e / 128u;
    Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
  }
  workgroupBarrier();

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var nt = 0u; nt < 2u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = subgroupMatrixLoad<Right>(&Bsh, (nt * 8u) * 128u + k * 8u,
                                           true, 128u);
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, (sg * 8u) * 16u + nt * 8u, acc, false, 16u);
    }
    workgroupBarrier();
    let nextT = tile0 + BT;
    if (nextT < U.numB && lid >= WGR + BT) {
      for (var e = lid - (WGR + BT); e < BT * 128u; e = e + (512u - (WGR + BT))) {
        let brow = nextT + e / 128u;
        Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
      }
    }
    if (lid < WGR) {
      let lim = min(BT, U.numB - tile0);
      for (var c = 0u; c < lim; c = c + 1u) {
        let s = accSh[lid * 16u + c];
        if (s > rbest) { rsecond = rbest; rbest = s; rbi = i32(tile0 + c); }
        else if (s > rsecond) { rsecond = s; }
      }
    } else if (lid < WGR + BT) {
      let cl = lid - WGR;
      let c = tile0 + cl;
      if (c < U.numB) {
        var best = 0.0; var second = 0.0; var bi = -1;
        for (var r = 0u; r < WGR; r = r + 1u) {
          let s = accSh[r * 16u + cl];
          if (s > best) { second = best; best = s; bi = i32(row0 + r); }
          else if (s > second) { second = s; }
        }
        ColP[c * U.numWg + wg.x] = ColPart(best, second, bi);
      }
    }
    workgroupBarrier();
    tile0 = nextT;
  }
  let row = row0 + lid;
  if (lid < WGR && row < U.numA) {
    OutAB[row] = gatef(rbest, rsecond, rbi);
  }
}
)";

// dbuf: BT16 TRUE double-buffer — mma of the current tile and staging of the
// next tile share one barrier interval on DIFFERENT Bsh buffers, so staging
// loads overlap mma compute. [mma(cur) ; stage-next(nxt)] barrier [scan]
// barrier. accSh single-buffered → the post-scan barrier is the accSh WAR.
constexpr char kSr3eDbufLoop[] = R"(
var<workgroup> Bsh : array<f32, 4096>;   // 2 x (16 rows x 128) double buffer
var<workgroup> accSh : array<f32, 2048>; // 128 rows x 16 (8 KiB)

@compute @workgroup_size(512)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32) {
  let row0 = wg.x * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
  var rbest = 0.0; var rsecond = 0.0; var rbi = -1;

  // prologue: stage tile 0 into buffer 0
  for (var e = lid; e < BT * 128u; e = e + 512u) {
    let brow = e / 128u;
    Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
  }
  workgroupBarrier();

  var tile0 = 0u;
  var par = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    let cur = par * 2048u;
    let nxt = (1u - par) * 2048u;
    let nextT = tile0 + BT;
    // mma consumes Bsh[cur]
    for (var nt = 0u; nt < 2u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = subgroupMatrixLoad<Right>(&Bsh, cur + (nt * 8u) * 128u + k * 8u,
                                           true, 128u);
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, (sg * 8u) * 16u + nt * 8u, acc, false, 16u);
    }
    // stage next tile into the OTHER buffer (overlaps mma; no WAR: nxt != cur)
    if (nextT < U.numB) {
      for (var e = lid; e < BT * 128u; e = e + 512u) {
        let brow = nextT + e / 128u;
        Bsh[nxt + e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
      }
    }
    workgroupBarrier();
    if (lid < WGR) {
      let lim = min(BT, U.numB - tile0);
      for (var c = 0u; c < lim; c = c + 1u) {
        let s = accSh[lid * 16u + c];
        if (s > rbest) { rsecond = rbest; rbest = s; rbi = i32(tile0 + c); }
        else if (s > rsecond) { rsecond = s; }
      }
    } else if (lid < WGR + BT) {
      let cl = lid - WGR;
      let c = tile0 + cl;
      if (c < U.numB) {
        var best = 0.0; var second = 0.0; var bi = -1;
        for (var r = 0u; r < WGR; r = r + 1u) {
          let s = accSh[r * 16u + cl];
          if (s > best) { second = best; best = s; bi = i32(row0 + r); }
          else if (s > second) { second = s; }
        }
        ColP[c * U.numWg + wg.x] = ColPart(best, second, bi);
      }
    }
    workgroupBarrier();
    tile0 = nextT;
    par = 1u - par;
  }
  let row = row0 + lid;
  if (lid < WGR && row < U.numA) {
    OutAB[row] = gatef(rbest, rsecond, rbi);
  }
}
)";

// mma16: NON-EXACT DIAGNOSTIC — same structure as mma but f16->f16 subgroup
// matrices with inputs pre-scaled by 1/16 on the host (accumulator stays in
// f16 range; products round). Scores are rescaled by 256 before the gate.
constexpr char kMma16Shader[] = R"(
enable chromium_experimental_subgroup_matrix;
enable subgroups;
enable f16;

alias Left = subgroup_matrix_left<f16, 8, 8>;
alias Right = subgroup_matrix_right<f16, 8, 8>;
alias Res = subgroup_matrix_result<f16, 8, 8>;

const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 64u;
const BT : u32 = 32u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
};

@group(0) @binding(0) var<storage, read> A : array<f16>;
@group(0) @binding(1) var<storage, read> B : array<f16>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;

var<workgroup> Bsh : array<f16, 4096>;    // 32 rows x 128 (8 KiB)
var<workgroup> accSh : array<f16, 2048>;  // 64 rows x 32 cols (4 KiB)
var<workgroup> bestT : array<f32, 64>;
var<workgroup> secondT : array<f32, 64>;
var<workgroup> biT : array<i32, 64>;

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32) {
  let row0 = wg.x * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
  if (lid < WGR) {
    bestT[lid] = 0.0;
    secondT[lid] = 0.0;
    biT[lid] = -1;
  }
  workgroupBarrier();

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var e = lid; e < BT * 128u; e = e + 256u) {
      let brow = tile0 + e / 128u;
      Bsh[e] = select(f16(0.0), B[brow * 128u + (e % 128u)], brow < U.numB);
    }
    workgroupBarrier();
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {
      var acc = Res(f16(0.0));
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = subgroupMatrixLoad<Right>(&Bsh, (nt * 8u) * 128u + k * 8u,
                                           true, 128u);
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, $ACCOFF$, acc, $ACCCM$, $ACCSTRIDE$u);
    }
    workgroupBarrier();
    if (lid < WGR) {
      let lim = min(BT, U.numB - tile0);
      var best = bestT[lid];
      var second = secondT[lid];
      var bi = biT[lid];
      for (var c = 0u; c < lim; c = c + 1u) {
        let s = f32(accSh[lid * 32u + c]) * 256.0; // undo (1/16)^2 scaling
        if (s > best) {
          second = best;
          best = s;
          bi = i32(tile0 + c);
        } else if (s > second) {
          second = s;
        }
      }
      bestT[lid] = best;
      secondT[lid] = second;
      biT[lid] = bi;
    }
    workgroupBarrier();
    tile0 = tile0 + BT;
  }
  let row = row0 + lid;
  if (lid < WGR && row < U.numA) {
    Out[row] = gatef(bestT[lid], secondT[lid], biT[lid]);
  }
}
)";

struct Params {
  uint32_t num_a;
  uint32_t num_b;
  float max_ratio;
  float max_distance;
};

}  // namespace

int main(int argc, char** argv) {
  if (argc != 7) {
    std::fprintf(stderr,
                 "usage: %s <fixture_dir> <out_dir> <reps> <warmup> <ratio> "
                 "<kernel: naive|tiled>\n",
                 argv[0]);
    return 1;
  }
  const std::string fixture_dir = argv[1];
  const std::string out_dir = argv[2];
  const int reps = std::atoi(argv[3]);
  const int warmup = std::atoi(argv[4]);
  const float ratio = (float)std::atof(argv[5]);
  const std::string kernel = argv[6];
  if (kernel != "naive" && kernel != "tiled" && kernel != "mma" &&
      kernel != "mma16" && kernel != "fused" &&
      kernel.rfind("fusedr", 0) != 0 && kernel.rfind("fusedd", 0) != 0) {
    std::fprintf(stderr, "FAIL unknown kernel %s\n", kernel.c_str());
    return 1;
  }
  const bool fused = kernel == "fused";
  uint32_t wgr = 0;
  bool direct_b = false;
  bool probe_row = false, probe_col = false;
  std::string kernel_base = kernel;
  if (kernel.size() > 4 && kernel.substr(kernel.size() - 4) == "-row") {
    probe_row = true;
    kernel_base = kernel.substr(0, kernel.size() - 4);
  } else if (kernel.size() > 4 && kernel.substr(kernel.size() - 4) == "-col") {
    probe_col = true;
    kernel_base = kernel.substr(0, kernel.size() - 4);
  }
  // SR-3C1 B layout: transposed-B (-tb) stores B as [dim][row] so Right
  // subgroup-matrix loads become contiguous row-major reads (colMajor=false).
  bool tb = false;
  if (kernel_base.size() > 3 &&
      kernel_base.substr(kernel_base.size() - 3) == "-tb") {
    tb = true;
    kernel_base = kernel_base.substr(0, kernel_base.size() - 3);
  }
  // SR-3D schedule knives: -db pipelines the tile loop (prologue stage, then
  // per tile {mma; barrier; scan || stage-next; barrier} = 2 barriers/tile
  // instead of 3; the scan lanes read accSh while the idle lanes stage the
  // NEXT B tile into Bsh, legal because the mma consuming the current tile
  // finished before the preceding barrier). -xb is the cost probe: split the
  // staging loop in half with one extra (semantically inert) barrier between
  // the halves = 4 barriers/tile, so the per-barrier cost is measurable as
  // (xb - base)/tiles.
  // SR-3E budget-feasible pipelines (WGR128 fixed; BT halved to 16 so the
  // shared-memory account permits either a double-buffered B tile or an
  // apples-to-apples single-buffer control at the same tile size):
  //   -db16 : BT16 single-buffer db-style pipeline (isolates the tile-size
  //           penalty of halving BT: 512 tiles instead of 256, doubled
  //           barriers, smaller 8x16 mma tiles).
  //   -dbuf : BT16 TRUE double-buffer — two Bsh buffers so the staging of the
  //           NEXT tile issues in the SAME barrier interval as the mma of the
  //           current tile (different buffers, no WAR), letting staging loads
  //           overlap mma compute instead of the (long) column scan.
  // Budget (WGR128): dbuf = 2*(16*128*4)=16384 Bsh + (128*16*4)=8192 accSh =
  // 24576 B < 32768; db16 = 8192 + 8192 = 16384 B. Both self-contained (do
  // NOT touch the frozen -db BT32 frontier assembly). Attribution:
  //   BT16 penalty = db16 - db ; dbuf gain = dbuf - db16 ; net = dbuf - db.
  int sr3e = 0;  // 0 none, 1 db16, 2 dbuf
  if (kernel_base.size() > 5 &&
      kernel_base.substr(kernel_base.size() - 5) == "-db16") {
    sr3e = 1;
    kernel_base = kernel_base.substr(0, kernel_base.size() - 5);
  } else if (kernel_base.size() > 5 &&
             kernel_base.substr(kernel_base.size() - 5) == "-dbuf") {
    sr3e = 2;
    kernel_base = kernel_base.substr(0, kernel_base.size() - 5);
  }
  bool db = false, xb = false;
  if (kernel_base.size() > 3 &&
      kernel_base.substr(kernel_base.size() - 3) == "-db") {
    db = true;
    kernel_base = kernel_base.substr(0, kernel_base.size() - 3);
  } else if (kernel_base.size() > 3 &&
             kernel_base.substr(kernel_base.size() - 3) == "-xb") {
    xb = true;
    kernel_base = kernel_base.substr(0, kernel_base.size() - 3);
  }
  // SR-3C0 accSh layout: 0 = row-major stride 32 (baseline), 1 = row-major
  // stride 33 (bank-conflict diagnostic), 2 = transposed [col][row].
  int acc_layout = 0;
  if (kernel_base.size() > 4 &&
      kernel_base.substr(kernel_base.size() - 4) == "-s33") {
    acc_layout = 1;
    kernel_base = kernel_base.substr(0, kernel_base.size() - 4);
  } else if (kernel_base.size() > 5 &&
             kernel_base.substr(kernel_base.size() - 5) == "-tacc") {
    acc_layout = 2;
    kernel_base = kernel_base.substr(0, kernel_base.size() - 5);
  }
  if (kernel_base.rfind("fusedr", 0) == 0 ||
      kernel_base.rfind("fusedd", 0) == 0) {
    // Strict numeric tail: atoi silently swallows trailing junk (e.g. a
    // mis-ordered suffix like "fusedr128-tb-db" would parse as plain 128 with
    // tb dropped), so reject any non-digit remainder outright.
    const std::string tail = kernel_base.substr(6);
    if (tail.empty() ||
        tail.find_first_not_of("0123456789") != std::string::npos) {
      std::fprintf(stderr, "FAIL unparsed kernel suffix in %s (base %s)\n",
                   kernel.c_str(), kernel_base.c_str());
      return 1;
    }
    wgr = (uint32_t)std::atoi(tail.c_str());
    direct_b = kernel_base[5] == 'd';
  }
  if ((probe_row || probe_col) && wgr == 0) {
    std::fprintf(stderr, "FAIL probe suffix only valid on fusedr/fusedd\n");
    return 1;
  }
  if ((db || xb) && (wgr == 0 || direct_b || probe_row || probe_col)) {
    std::fprintf(stderr,
                 "FAIL -db/-xb only valid on staged fusedr without probes\n");
    return 1;
  }
  if (sr3e != 0 &&
      (wgr != 128 || db || xb || direct_b || tb || probe_row || probe_col ||
       acc_layout != 0)) {
    std::fprintf(stderr,
                 "FAIL -db16/-dbuf only valid as plain fusedr128 (budget "
                 "fixes WGR=128, BT=16; no other suffix)\n");
    return 1;
  }
  if ((kernel_base.rfind("fusedr", 0) == 0 ||
       kernel_base.rfind("fusedd", 0) == 0) &&
      (wgr == 0 || wgr % 8 != 0 || wgr > 256)) {
    std::fprintf(stderr, "FAIL bad WGR in kernel %s\n", kernel.c_str());
    return 1;
  }
  const bool fused_family = fused || wgr != 0;
  // mma16 is a NON-EXACT DIAGNOSTIC: u8 values are exactly representable in
  // f16, but the 1/16 scaling needed to keep the f16->f16 accumulator in
  // range makes products round (16-bit significands into 11 bits). It only
  // measures the f16 subgroup-matrix speed ceiling on this backend; its
  // output must NOT be promoted and is expected to differ from the exact
  // reference.
  const bool mma16 = kernel == "mma16";
  const bool mma = kernel == "mma" || mma16 || fused_family;

  const fairmatch::Fixture f = fairmatch::LoadFixture(fixture_dir);

  // Empty-table contract: production never hands the matcher an empty side
  // (add_frame skips n==0 frames; the native ABI returns rc=1). The portable
  // wrapper mirrors that as an explicit early return — zero-sized GPU buffers
  // must never reach Dawn validation.
  if (f.na == 0 || f.nb == 0) {
    fairmatch::WriteFileBytes(out_dir + "/portable_" + kernel + "_pairs.bin",
                              "", 0);
    std::printf(
        "PORTABLE_RESULT {\"arm\":\"portable_wgsl_%s\",\"count\":0,"
        "\"pairs_sha256\":\"%s\",\"empty_input_early_return\":true}\n",
        kernel.c_str(), fairmatch::Sha256Hex("", 0).c_str());
    return 0;
  }

  // ── Dawn setup ──
  constexpr auto kTimedWaitAny = wgpu::InstanceFeatureName::TimedWaitAny;
  const char* allow_unsafe = "allow_unsafe_apis";
  wgpu::DawnTogglesDescriptor toggles{};
  toggles.enabledToggleCount = 1;
  toggles.enabledToggles = &allow_unsafe;
  wgpu::InstanceDescriptor instance_descriptor{
      .nextInChain = mma ? &toggles : nullptr,
      .requiredFeatureCount = 1,
      .requiredFeatures = &kTimedWaitAny,
  };
  wgpu::Instance instance = wgpu::CreateInstance(&instance_descriptor);
  if (!instance) return 2;
  if (!instance.HasWGSLLanguageFeature(
          wgpu::WGSLLanguageFeatureName::Packed4x8IntegerDotProduct)) {
    std::fprintf(stderr, "FAIL packed 4x8 dot WGSL feature unavailable\n");
    return 3;
  }
  wgpu::Adapter adapter;
  wgpu::RequestAdapterOptions adapter_options{};
  instance.WaitAny(instance.RequestAdapter(
                       &adapter_options, wgpu::CallbackMode::WaitAnyOnly,
                       [&](wgpu::RequestAdapterStatus status,
                           wgpu::Adapter value, wgpu::StringView message) {
                         if (status == wgpu::RequestAdapterStatus::Success) {
                           adapter = std::move(value);
                         } else {
                           std::cerr << "adapter: " << message << '\n';
                         }
                       }),
                   UINT64_MAX);
  if (!adapter) return 4;
  wgpu::AdapterInfo info{};
  adapter.GetInfo(&info);
  std::cout << "PORTABLE_ARM gpu=" << info.device << " kernel=" << kernel
            << " na=" << f.na << " nb=" << f.nb << " ratio=" << ratio << '\n';

  std::vector<wgpu::FeatureName> mma_features = {
      wgpu::FeatureName::Subgroups,
      wgpu::FeatureName::ChromiumExperimentalSubgroupMatrix,
      wgpu::FeatureName::ShaderF16,
  };
  const bool has_ts = adapter.HasFeature(wgpu::FeatureName::TimestampQuery);
  if (has_ts) mma_features.push_back(wgpu::FeatureName::TimestampQuery);
  if (mma) {
    if (!adapter.HasFeature(wgpu::FeatureName::ChromiumExperimentalSubgroupMatrix) ||
        !adapter.HasFeature(wgpu::FeatureName::Subgroups) ||
        info.subgroupMinSize != 32 || info.subgroupMaxSize != 32) {
      std::fprintf(stderr,
                   "FAIL mma kernel needs subgroup matrix + fixed subgroup "
                   "size 32 (min=%u max=%u)\n",
                   info.subgroupMinSize, info.subgroupMaxSize);
      return 40;
    }
  }

  wgpu::DeviceDescriptor device_descriptor{};
  wgpu::Limits mma_limits{};
  if (mma) {
    device_descriptor.requiredFeatureCount = mma_features.size();
    device_descriptor.requiredFeatures = mma_features.data();
    wgpu::Limits adapter_limits{};
    adapter.GetLimits(&adapter_limits);
    mma_limits.maxComputeWorkgroupStorageSize =
        adapter_limits.maxComputeWorkgroupStorageSize;
    mma_limits.maxComputeInvocationsPerWorkgroup =
        adapter_limits.maxComputeInvocationsPerWorkgroup;
    mma_limits.maxComputeWorkgroupSizeX =
        adapter_limits.maxComputeWorkgroupSizeX;
    device_descriptor.requiredLimits = &mma_limits;
    // SR-3B/B2 capability gate: WGR*4 threads and (staged Bsh 16 KiB +
    // accSh WGR*128 B) workgroup storage; Direct-B drops the Bsh term. On a
    // miss, fall back to WGR64 staged deterministically and say so.
    if (wgr != 0) {
      const uint32_t need_threads = wgr * 4;
      const uint32_t need_storage = (direct_b ? 0u : 16384u) + wgr * 128u;
      if (adapter_limits.maxComputeInvocationsPerWorkgroup < need_threads ||
          adapter_limits.maxComputeWorkgroupSizeX < need_threads ||
          adapter_limits.maxComputeWorkgroupStorageSize < need_storage) {
        std::printf(
            "SR3B_CAPABILITY_BLOCKED need threads=%u storage=%u, have "
            "invocations=%u sizeX=%u storage=%u -> deterministic fallback to "
            "fusedr64\n",
            need_threads, need_storage,
            adapter_limits.maxComputeInvocationsPerWorkgroup,
            adapter_limits.maxComputeWorkgroupSizeX,
            adapter_limits.maxComputeWorkgroupStorageSize);
        wgr = 64;
        direct_b = false;
      }
    }
  }
  device_descriptor.SetUncapturedErrorCallback(
      [](const wgpu::Device&, wgpu::ErrorType type, wgpu::StringView message) {
        std::cerr << "device error " << (uint32_t)type << ": " << message
                  << '\n';
        std::exit(30);
      });
  wgpu::Device device;
  instance.WaitAny(adapter.RequestDevice(
                       &device_descriptor, wgpu::CallbackMode::WaitAnyOnly,
                       [&](wgpu::RequestDeviceStatus status, wgpu::Device value,
                           wgpu::StringView message) {
                         if (status == wgpu::RequestDeviceStatus::Success) {
                           device = std::move(value);
                         } else {
                           std::cerr << "device: " << message << '\n';
                         }
                       }),
                   UINT64_MAX);
  if (!device) return 5;
  wgpu::Queue queue = device.GetQueue();

  // ── pipeline (timed once) ──
  const double t_pipe0 = NowMs();
  auto replace_all = [](std::string s, const std::string& k,
                        const std::string& v) {
    size_t at = 0;
    while ((at = s.find(k, at)) != std::string::npos) {
      s.replace(at, k.size(), v);
      at += v.size();
    }
    return s;
  };
  // mma pads both tables to a 64-row multiple so per-subgroup A-fragment
  // loads stay in-bounds in both dispatch directions (zero rows are inert:
  // dot 0 never beats the strict-> selection and padded rows are never
  // emitted). Uniforms keep the true row counts. Computed before shader
  // assembly because transposed-B variants bake PADB into WGSL.
  const uint32_t arow_block = wgr != 0 ? wgr : 64;
  const uint32_t pad_a =
      mma ? ((f.na + arow_block - 1) / arow_block) * arow_block : f.na;
  const uint32_t pad_b = mma ? ((f.nb + 63) / 64) * 64 : f.nb;

  std::string shader_src;
  if (sr3e != 0) {
    // SR-3E: fixed WGR128/BT16, no placeholder substitution (self-contained).
    shader_src = std::string(kSr3eHead) + kSr3eGatef +
                 (sr3e == 2 ? kSr3eDbufLoop : kSr3eDb16Loop) + kSr3eTail;
  } else if (wgr != 0) {
    shader_src = replace_all(db ? kFusedRDbTemplate : kFusedRTemplate, "$WGR$",
                             std::to_string(wgr));
    shader_src = replace_all(shader_src, "$WGSIZE$", std::to_string(wgr * 4));
    const uint32_t acc_elems = acc_layout == 1 ? wgr * 33 : wgr * 32;
    shader_src = replace_all(shader_src, "$ACC$", std::to_string(acc_elems));
    std::string acc_off, acc_cm, acc_stride, row_read, col_read;
    if (acc_layout == 0) {
      acc_off = "(sg * 8u) * 32u + nt * 8u";
      acc_cm = "false";
      acc_stride = "32";
      row_read = "accSh[lid * 32u + c]";
      col_read = "accSh[r * 32u + cl]";
    } else if (acc_layout == 1) {
      acc_off = "(sg * 8u) * 33u + nt * 8u";
      acc_cm = "false";
      acc_stride = "33";
      row_read = "accSh[lid * 33u + c]";
      col_read = "accSh[r * 33u + cl]";
    } else {
      // transposed [col][row]: element (row, col) at accSh[col*WGR + row]
      acc_off = "(nt * 8u) * WGR + sg * 8u";
      acc_cm = "true";
      acc_stride = std::to_string(wgr);
      row_read = "accSh[c * WGR + lid]";
      col_read = "accSh[cl * WGR + r]";
    }
    shader_src = replace_all(shader_src, "$ACCOFF$", acc_off);
    shader_src = replace_all(shader_src, "$ACCCM$", acc_cm);
    shader_src = replace_all(shader_src, "$ACCSTRIDE$", acc_stride);
    const char* rowdecl =
        "  var rbest = 0.0;\n  var rsecond = 0.0;\n  var rbi = -1;";
    const std::string rowscan = std::string(
        "    if (lid < WGR) {\n"
        "      let lim = min(BT, U.numB - tile0);\n"
        "      for (var c = 0u; c < lim; c = c + 1u) {\n"
        "        let s = ") + row_read + ";\n"
        "        if (s > rbest) {\n"
        "          rsecond = rbest; rbest = s; rbi = i32(tile0 + c);\n"
        "        } else if (s > rsecond) { rsecond = s; }\n"
        "      }\n"
        "    }\n";
    const std::string colscan = std::string(
        "    if (lid >= WGR && lid < WGR + BT) {\n"
        "      let cl = lid - WGR;\n"
        "      let c = tile0 + cl;\n"
        "      if (c < U.numB) {\n"
        "        var best = 0.0; var second = 0.0; var bi = -1;\n"
        "        for (var r = 0u; r < WGR; r = r + 1u) {\n"
        "          let s = ") + col_read + ";\n"
        "          if (s > best) {\n"
        "            second = best; best = s; bi = i32(row0 + r);\n"
        "          } else if (s > second) { second = s; }\n"
        "        }\n"
        "        ColP[c * U.numWg + wg.x] = ColPart(best, second, bi);\n"
        "      }\n"
        "    }\n";
    const char* outab =
        "  let row = row0 + lid;\n"
        "  if (lid < WGR && row < U.numA) {\n"
        "    OutAB[row] = gatef(rbest, rsecond, rbi);\n"
        "  }";
    shader_src = replace_all(shader_src, "$ROWDECL$", probe_col ? "" : rowdecl);
    shader_src = replace_all(shader_src, "$ROWSCAN$", probe_col ? "" : rowscan);
    shader_src = replace_all(shader_src, "$COLSCAN$", probe_row ? "" : colscan);
    shader_src = replace_all(shader_src, "$OUTAB$", probe_col ? "" : outab);
    // PADB (padded B row count) is only referenced by transposed-B variants.
    const std::string padb = std::to_string(pad_b);
    if (direct_b && !tb) {
      shader_src = replace_all(shader_src, "$BSH_DECL$", "");
      shader_src = replace_all(shader_src, "$STAGE$", "");
      shader_src = replace_all(
          shader_src, "$RIGHT_LOAD$",
          "subgroupMatrixLoad<Right>(&B, (tile0 + nt * 8u) * 128u + k * 8u, "
          "true, 128u)");
    } else if (direct_b && tb) {
      // D1: contiguous Right loads straight from resident transposed B; no
      // Bsh staging, no staging barrier.
      shader_src = replace_all(shader_src, "$BSH_DECL$", "");
      shader_src = replace_all(shader_src, "$STAGE$", "");
      shader_src = replace_all(
          shader_src, "$RIGHT_LOAD$",
          "subgroupMatrixLoad<Right>(&B, (k * 8u) * " + padb +
          "u + tile0 + nt * 8u, false, " + padb + "u)");
    } else {
      // Staged branches (plain row-major tile, or S1 transposed tile).
      // stage_loop(lo, hi, tvar): one all-lane staging loop over Bsh element
      // range [lid+lo, hi) at workgroup stride, reading B rows of tile
      // `tvar`. Used to build the normal single-loop stage, the -xb probe
      // (split in half around one extra inert barrier), and the -db prologue.
      const std::string wgsize = std::to_string(wgr * 4);
      auto stage_loop = [&](const std::string& lo, const std::string& hi,
                            const std::string& tvar) {
        const std::string start = lo == "0" ? "lid" : "lid + " + lo;
        if (tb) {
          return "    for (var e = " + start + "; e < " + hi +
                 "; e = e + " + wgsize + "u) {\n"
                 "      let d = e / 32u;\n"
                 "      let cl = e % 32u;\n"
                 "      Bsh[e] = select(0.0, B[d * " + padb + "u + " + tvar +
                 " + cl], " + tvar + " + cl < U.numB);\n"
                 "    }\n";
        }
        return "    for (var e = " + start + "; e < " + hi +
               "; e = e + " + wgsize + "u) {\n"
               "      let brow = " + tvar + " + e / 128u;\n"
               "      Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], "
               "brow < U.numB);\n"
               "    }\n";
      };
      shader_src = replace_all(
          shader_src, "$BSH_DECL$",
          tb ? "var<workgroup> Bsh : array<f32, 4096>; // 128 dims x 32 cols"
             : "var<workgroup> Bsh : array<f32, 4096>; // 32 rows x 128 "
               "(16 KiB)");
      if (db) {
        // SR-3D-1: prologue stages tile 0 with every lane; in-loop staging of
        // tile nextT is done by the lanes the scans leave idle
        // (lid >= WGR+BT), sharing the scans' barrier interval.
        const uint32_t scanl = wgr + 32;
        const std::string sl = std::to_string(scanl);
        const std::string st = std::to_string(wgr * 4 - scanl);
        std::string next_body;
        if (tb) {
          next_body =
              "      for (var e = lid - " + sl + "u; e < BT * 128u; "
              "e = e + " + st + "u) {\n"
              "        let d = e / 32u;\n"
              "        let cl = e % 32u;\n"
              "        Bsh[e] = select(0.0, B[d * " + padb +
              "u + nextT + cl], nextT + cl < U.numB);\n"
              "      }\n";
        } else {
          next_body =
              "      for (var e = lid - " + sl + "u; e < BT * 128u; "
              "e = e + " + st + "u) {\n"
              "        let brow = nextT + e / 128u;\n"
              "        Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], "
              "brow < U.numB);\n"
              "      }\n";
        }
        shader_src = replace_all(shader_src, "$STAGE0$",
                                 stage_loop("0", "BT * 128u", "0u"));
        shader_src = replace_all(
            shader_src, "$STAGENEXT$",
            "    if (nextT < U.numB && lid >= " + sl + "u) {\n" + next_body +
            "    }\n");
      } else if (xb) {
        shader_src = replace_all(
            shader_src, "$STAGE$",
            stage_loop("0", "BT * 64u", "tile0") + "    workgroupBarrier();\n" +
                stage_loop("BT * 64u", "BT * 128u", "tile0") +
                "    workgroupBarrier();");
      } else {
        shader_src = replace_all(
            shader_src, "$STAGE$",
            stage_loop("0", "BT * 128u", "tile0") + "    workgroupBarrier();");
      }
      shader_src = replace_all(
          shader_src, "$RIGHT_LOAD$",
          tb ? "subgroupMatrixLoad<Right>(&Bsh, (k * 8u) * 32u + nt * 8u, "
               "false, 32u)"
             : "subgroupMatrixLoad<Right>(&Bsh, (nt * 8u) * 128u + k * 8u, "
               "true, 128u)");
    }
  } else {
    shader_src =
        fused   ? std::string(kFusedShader)
        : mma16 ? std::string(kMma16Shader)
        : mma   ? std::string(kMmaShader)
                : std::string(kCommonDecls) + kEpilogue +
                      (kernel == "naive" ? kNaiveBody : kTiledBody);
    // The legacy mma/fused/mma16 shaders carry the acc-layout placeholders
    // too, but only the fusedr path substituted them — the raw `$` reached
    // the WGSL parser and every legacy mma-family kernel RUN-FAILed (this,
    // not Dawn feature drift, was the 2026-09-02 breakage). Pin them to the
    // baseline row-major stride-32 layout.
    shader_src = replace_all(shader_src, "$ACCOFF$", "(sg * 8u) * 32u + nt * 8u");
    shader_src = replace_all(shader_src, "$ACCCM$", "false");
    shader_src = replace_all(shader_src, "$ACCSTRIDE$", "32");
  }
  wgpu::ShaderSourceWGSL source{};
  source.code = shader_src.c_str();
  wgpu::ShaderModuleDescriptor shader_descriptor{};
  shader_descriptor.nextInChain = &source;
  const wgpu::ShaderModule shader =
      device.CreateShaderModule(&shader_descriptor);
  bool shader_ok = true;
  instance.WaitAny(
      shader.GetCompilationInfo(wgpu::CallbackMode::WaitAnyOnly,
                                [&](wgpu::CompilationInfoRequestStatus,
                                    const wgpu::CompilationInfo* ci) {
                                  if (!ci) return;
                                  for (size_t i = 0; i < ci->messageCount; ++i) {
                                    if (ci->messages[i].type ==
                                        wgpu::CompilationMessageType::Error) {
                                      shader_ok = false;
                                      std::cerr << "WGSL error: "
                                                << ci->messages[i].message
                                                << '\n';
                                    }
                                  }
                                }),
      UINT64_MAX);
  if (!shader_ok) return 6;
  wgpu::ComputePipelineDescriptor pipeline_descriptor{};
  pipeline_descriptor.compute.module = shader;
  pipeline_descriptor.compute.entryPoint = "main";
  const wgpu::ComputePipeline pipeline =
      device.CreateComputePipeline(&pipeline_descriptor);
  if (!pipeline) return 7;
  wgpu::ComputePipeline merge_pipeline;
  if (fused_family) {
    wgpu::ComputePipelineDescriptor merge_descriptor{};
    merge_descriptor.compute.module = shader;
    merge_descriptor.compute.entryPoint = "merge";
    merge_pipeline = device.CreateComputePipeline(&merge_descriptor);
    if (!merge_pipeline) return 8;
  }
  const double pipeline_ms = NowMs() - t_pipe0;


  const uint64_t elem = mma16 ? 2 : sizeof(float);
  const uint64_t a_bytes =
      mma ? (uint64_t)pad_a * 128 * elem : (uint64_t)f.a.size();
  const uint64_t b_bytes =
      mma ? (uint64_t)pad_b * 128 * elem : (uint64_t)f.b.size();
  const uint64_t out_ab_bytes = (uint64_t)f.na * sizeof(int32_t);
  const uint64_t out_ba_bytes = (uint64_t)f.nb * sizeof(int32_t);

  int count = -1;
  std::string digest;
  std::vector<uint32_t> final_pairs;
  std::vector<double> wall, prep_v, gpu_v, map_v, host_v;
  std::vector<double> split_main_v, split_merge_v;
  std::string dir_ab, dir_ba;
  uint64_t colp_bytes_report = 0;
  const bool tb_resident = std::getenv("FAIR_TB_RESIDENT") != nullptr;
  wgpu::Buffer resident_b_buf;
  double last_transpose_ms = 0.0;
  const bool split_timing =
      fused_family && std::getenv("FAIR_SPLIT_TIMING") != nullptr;

  auto run_once = [&](bool record) {
    const double t0 = NowMs();
    // Per-rep buffer creation + upload mirrors the production ABI, which
    // creates MTLBuffers and converts descriptors on every call.
    auto make_storage = [&](const void* data, uint64_t bytes) {
      wgpu::BufferDescriptor d{
          .usage = wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst,
          .size = bytes,
      };
      wgpu::Buffer buffer = device.CreateBuffer(&d);
      queue.WriteBuffer(buffer, 0, data, bytes);
      return buffer;
    };
    wgpu::Buffer a_buf, b_buf;
    if (mma16) {
      // Diagnostic: u8 exactly representable in f16, then scaled by 1/16 so
      // the f16 accumulator cannot overflow (products round — non-exact).
      std::vector<_Float16> fa((size_t)pad_a * 128, (_Float16)0.0f);
      std::vector<_Float16> fb((size_t)pad_b * 128, (_Float16)0.0f);
      for (size_t i = 0; i < f.a.size(); ++i)
        fa[i] = (_Float16)((float)f.a[i] * 0.0625f);
      for (size_t i = 0; i < f.b.size(); ++i)
        fb[i] = (_Float16)((float)f.b[i] * 0.0625f);
      a_buf = make_storage(fa.data(), a_bytes);
      b_buf = make_storage(fb.data(), b_bytes);
    } else if (mma) {
      // Per-rep u8->f32 expansion mirrors the production ABI's per-call
      // u8->half conversion and is charged to prep time. Transposed-B (-tb)
      // builds B as [dim][row]; in resident mode the transposed buffer is
      // created once outside the reps and reused (per-image amortization),
      // while cold mode pays transpose+upload every call.
      std::vector<float> fa((size_t)pad_a * 128, 0.0f);
      for (size_t i = 0; i < f.a.size(); ++i) fa[i] = (float)f.a[i];
      a_buf = make_storage(fa.data(), a_bytes);
      if (tb && tb_resident && resident_b_buf) {
        b_buf = resident_b_buf;
      } else if (tb) {
        const double t_tp0 = NowMs();
        std::vector<float> bt((size_t)pad_b * 128, 0.0f);
        for (uint32_t r = 0; r < f.nb; ++r)
          for (uint32_t d = 0; d < 128; ++d)
            bt[(size_t)d * pad_b + r] = (float)f.b[(size_t)r * 128 + d];
        last_transpose_ms = NowMs() - t_tp0;
        b_buf = make_storage(bt.data(), b_bytes);
        if (tb_resident) resident_b_buf = b_buf;
      } else {
        std::vector<float> fb((size_t)pad_b * 128, 0.0f);
        for (size_t i = 0; i < f.b.size(); ++i) fb[i] = (float)f.b[i];
        b_buf = make_storage(fb.data(), b_bytes);
      }
    } else {
      a_buf = make_storage(f.a.data(), a_bytes);
      b_buf = make_storage(f.b.data(), b_bytes);
    }
    wgpu::BufferDescriptor od{
        .usage = wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc,
        .size = out_ab_bytes,
    };
    wgpu::Buffer out_ab = device.CreateBuffer(&od);
    od.size = out_ba_bytes;
    wgpu::Buffer out_ba = device.CreateBuffer(&od);
    Params pab{f.na, f.nb, ratio, 0.7f};
    Params pba{f.nb, f.na, ratio, 0.7f};
    auto make_uniform = [&](const Params& p) {
      wgpu::BufferDescriptor d{
          .usage = wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst,
          .size = sizeof(Params),
      };
      wgpu::Buffer buffer = device.CreateBuffer(&d);
      queue.WriteBuffer(buffer, 0, &p, sizeof(Params));
      return buffer;
    };
    wgpu::Buffer u_ab = make_uniform(pab);
    wgpu::Buffer u_ba = make_uniform(pba);
    wgpu::BufferDescriptor sd{
        .usage = wgpu::BufferUsage::CopyDst | wgpu::BufferUsage::MapRead,
        .size = out_ab_bytes + out_ba_bytes,
    };
    wgpu::Buffer staging = device.CreateBuffer(&sd);

    auto make_bind_group = [&](wgpu::Buffer lhs, uint64_t lhs_bytes,
                               wgpu::Buffer rhs, uint64_t rhs_bytes,
                               wgpu::Buffer output, uint64_t out_bytes,
                               wgpu::Buffer uniform) {
      const std::array entries = {
          wgpu::BindGroupEntry{
              .binding = 0, .buffer = lhs, .offset = 0, .size = lhs_bytes},
          wgpu::BindGroupEntry{
              .binding = 1, .buffer = rhs, .offset = 0, .size = rhs_bytes},
          wgpu::BindGroupEntry{
              .binding = 2, .buffer = output, .offset = 0, .size = out_bytes},
          wgpu::BindGroupEntry{.binding = 3,
                               .buffer = uniform,
                               .offset = 0,
                               .size = sizeof(Params)},
      };
      wgpu::BindGroupDescriptor d{
          .layout = pipeline.GetBindGroupLayout(0),
          .entryCount = entries.size(),
          .entries = entries.data(),
      };
      return device.CreateBindGroup(&d);
    };
    wgpu::BindGroup g_ab, g_ba, g_fmain, g_fmerge;
    wgpu::Buffer colp, u_f;
    if (fused_family) {
      struct FusedParams {
        uint32_t na, nb;
        float ratio_v, maxd;
        uint32_t nwg, p0, p1, p2;
      };
      const uint32_t nwg = pad_a / arow_block;
      FusedParams fp{f.na, f.nb, ratio, 0.7f, nwg, 0, 0, 0};
      wgpu::BufferDescriptor ud{
          .usage = wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst,
          .size = sizeof(FusedParams),
      };
      u_f = device.CreateBuffer(&ud);
      queue.WriteBuffer(u_f, 0, &fp, sizeof(fp));
      const uint64_t colp_bytes = (uint64_t)f.nb * nwg * 12;
      colp_bytes_report = colp_bytes;
      wgpu::BufferDescriptor cd{
          .usage = wgpu::BufferUsage::Storage,
          .size = colp_bytes,
      };
      colp = device.CreateBuffer(&cd);
      std::vector<wgpu::BindGroupEntry> main_entries = {
          wgpu::BindGroupEntry{
              .binding = 0, .buffer = a_buf, .offset = 0, .size = a_bytes},
          wgpu::BindGroupEntry{
              .binding = 1, .buffer = b_buf, .offset = 0, .size = b_bytes},
          wgpu::BindGroupEntry{.binding = 3,
                               .buffer = u_f,
                               .offset = 0,
                               .size = sizeof(FusedParams)},
      };
      if (!probe_col) {
        main_entries.push_back(wgpu::BindGroupEntry{.binding = 2,
                                                    .buffer = out_ab,
                                                    .offset = 0,
                                                    .size = out_ab_bytes});
      }
      if (!probe_row) {
        main_entries.push_back(wgpu::BindGroupEntry{
            .binding = 4, .buffer = colp, .offset = 0, .size = colp_bytes});
      }
      wgpu::BindGroupDescriptor md{
          .layout = pipeline.GetBindGroupLayout(0),
          .entryCount = main_entries.size(),
          .entries = main_entries.data(),
      };
      g_fmain = device.CreateBindGroup(&md);
      const std::array merge_entries = {
          wgpu::BindGroupEntry{.binding = 3,
                               .buffer = u_f,
                               .offset = 0,
                               .size = sizeof(FusedParams)},
          wgpu::BindGroupEntry{
              .binding = 4, .buffer = colp, .offset = 0, .size = colp_bytes},
          wgpu::BindGroupEntry{.binding = 5,
                               .buffer = out_ba,
                               .offset = 0,
                               .size = out_ba_bytes},
      };
      if (!probe_row) {
        wgpu::BindGroupDescriptor gd{
            .layout = merge_pipeline.GetBindGroupLayout(0),
            .entryCount = merge_entries.size(),
            .entries = merge_entries.data(),
        };
        g_fmerge = device.CreateBindGroup(&gd);
      }
    } else {
      g_ab = make_bind_group(a_buf, a_bytes, b_buf, b_bytes, out_ab,
                             out_ab_bytes, u_ab);
      g_ba = make_bind_group(b_buf, b_bytes, a_buf, a_bytes, out_ba,
                             out_ba_bytes, u_ba);
    }
    const double t_prep = NowMs();

    const uint32_t wg_ab = kernel == "naive" ? (f.na + 255) / 256
                           : mma             ? pad_a / 64
                                             : (f.na + 63) / 64;
    const uint32_t wg_ba = kernel == "naive" ? (f.nb + 255) / 256
                           : mma             ? pad_b / 64
                                             : (f.nb + 63) / 64;
    if (split_timing) {
      // Diagnostic per-pass GPU timestamps inside ONE command buffer (no
      // extra Submit/WaitAny between stages — the earlier two-submit variant
      // contaminated the split with queue-sync overhead and is retired).
      if (!has_ts) {
        std::fprintf(stderr, "FAIL FAIR_SPLIT_TIMING needs TimestampQuery\n");
        std::exit(33);
      }
      wgpu::QuerySetDescriptor qd{.type = wgpu::QueryType::Timestamp,
                                  .count = 4};
      wgpu::QuerySet qs = device.CreateQuerySet(&qd);
      wgpu::BufferDescriptor rd{
          .usage = wgpu::BufferUsage::QueryResolve | wgpu::BufferUsage::CopySrc,
          .size = 4 * sizeof(uint64_t)};
      wgpu::Buffer resolve = device.CreateBuffer(&rd);
      wgpu::BufferDescriptor tsd{
          .usage = wgpu::BufferUsage::CopyDst | wgpu::BufferUsage::MapRead,
          .size = 4 * sizeof(uint64_t)};
      wgpu::Buffer ts_staging = device.CreateBuffer(&tsd);

      wgpu::CommandEncoder encoder = device.CreateCommandEncoder();
      wgpu::PassTimestampWrites tw1{.querySet = qs,
                                    .beginningOfPassWriteIndex = 0,
                                    .endOfPassWriteIndex = 1};
      wgpu::ComputePassDescriptor pd1{};
      pd1.timestampWrites = &tw1;
      wgpu::ComputePassEncoder p1 = encoder.BeginComputePass(&pd1);
      p1.SetPipeline(pipeline);
      p1.SetBindGroup(0, g_fmain);
      p1.DispatchWorkgroups(pad_a / arow_block);
      p1.End();
      wgpu::PassTimestampWrites tw2{.querySet = qs,
                                    .beginningOfPassWriteIndex = 2,
                                    .endOfPassWriteIndex = 3};
      wgpu::ComputePassDescriptor pd2{};
      pd2.timestampWrites = &tw2;
      wgpu::ComputePassEncoder p2 = encoder.BeginComputePass(&pd2);
      if (!probe_row) {
        p2.SetPipeline(merge_pipeline);
        p2.SetBindGroup(0, g_fmerge);
        p2.DispatchWorkgroups((f.nb + 63) / 64);
      }
      p2.End();
      encoder.ResolveQuerySet(qs, 0, 4, resolve, 0);
      encoder.CopyBufferToBuffer(resolve, 0, ts_staging, 0,
                                 4 * sizeof(uint64_t));
      encoder.CopyBufferToBuffer(out_ab, 0, staging, 0, out_ab_bytes);
      encoder.CopyBufferToBuffer(out_ba, 0, staging, out_ab_bytes,
                                 out_ba_bytes);
      const wgpu::CommandBuffer command = encoder.Finish();
      queue.Submit(1, &command);
      instance.WaitAny(queue.OnSubmittedWorkDone(
                           wgpu::CallbackMode::WaitAnyOnly,
                           [](wgpu::QueueWorkDoneStatus, wgpu::StringView) {}),
                       UINT64_MAX);
      bool ts_mapped = false;
      instance.WaitAny(
          ts_staging.MapAsync(wgpu::MapMode::Read, 0, 4 * sizeof(uint64_t),
                              wgpu::CallbackMode::WaitAnyOnly,
                              [&](wgpu::MapAsyncStatus st, wgpu::StringView) {
                                ts_mapped = st == wgpu::MapAsyncStatus::Success;
                              }),
          UINT64_MAX);
      if (ts_mapped) {
        const uint64_t* t =
            (const uint64_t*)ts_staging.GetConstMappedRange(0, 32);
        split_main_v.push_back((double)(t[1] - t[0]) / 1e6);
        split_merge_v.push_back((double)(t[3] - t[2]) / 1e6);
        ts_staging.Unmap();
      }
    } else {
      wgpu::CommandEncoder encoder = device.CreateCommandEncoder();
      wgpu::ComputePassEncoder pass = encoder.BeginComputePass();
      if (fused_family) {
        pass.SetPipeline(pipeline);
        pass.SetBindGroup(0, g_fmain);
        pass.DispatchWorkgroups(pad_a / arow_block);
        if (!probe_row) {
          pass.SetPipeline(merge_pipeline);
          pass.SetBindGroup(0, g_fmerge);
          pass.DispatchWorkgroups((f.nb + 63) / 64);
        }
      } else {
        pass.SetPipeline(pipeline);
        pass.SetBindGroup(0, g_ab);
        pass.DispatchWorkgroups(wg_ab);
        pass.SetBindGroup(0, g_ba);
        pass.DispatchWorkgroups(wg_ba);
      }
      pass.End();
      encoder.CopyBufferToBuffer(out_ab, 0, staging, 0, out_ab_bytes);
      encoder.CopyBufferToBuffer(out_ba, 0, staging, out_ab_bytes,
                                 out_ba_bytes);
      const wgpu::CommandBuffer command = encoder.Finish();
      queue.Submit(1, &command);
      instance.WaitAny(queue.OnSubmittedWorkDone(
                           wgpu::CallbackMode::WaitAnyOnly,
                           [](wgpu::QueueWorkDoneStatus, wgpu::StringView) {}),
                       UINT64_MAX);
    }
    const double t_gpu = NowMs();

    bool mapped = false;
    instance.WaitAny(
        staging.MapAsync(wgpu::MapMode::Read, 0, out_ab_bytes + out_ba_bytes,
                         wgpu::CallbackMode::WaitAnyOnly,
                         [&](wgpu::MapAsyncStatus status, wgpu::StringView m) {
                           mapped = status == wgpu::MapAsyncStatus::Success;
                           if (!mapped) std::cerr << "map: " << m << '\n';
                         }),
        UINT64_MAX);
    if (!mapped) std::exit(31);
    const int32_t* mapped_ptr =
        (const int32_t*)staging.GetConstMappedRange(0,
                                                    out_ab_bytes + out_ba_bytes);
    const double t_map = NowMs();

    const int32_t* mAB = mapped_ptr;
    const int32_t* mBA = mapped_ptr + f.na;
    const std::string d_ab =
        probe_col ? "(probe-col)"
                  : fairmatch::Sha256Hex(mAB, (size_t)f.na * sizeof(int32_t));
    const std::string d_ba =
        probe_row ? "(probe-row)"
                  : fairmatch::Sha256Hex(mBA, (size_t)f.nb * sizeof(int32_t));
    std::vector<uint32_t> pairs;
    if (!probe_row && !probe_col) {
      pairs = fairmatch::MutualPairs(mAB, f.na, mBA, f.nb);
    }
    staging.Unmap();
    const double t_host = NowMs();

    if (record) {
      if (dir_ab.empty()) {
        dir_ab = d_ab;
        dir_ba = d_ba;
      } else if (dir_ab != d_ab || dir_ba != d_ba) {
        std::fprintf(stderr,
                     "FAIL direction maps not deterministic across reps\n");
        std::exit(34);
      }
      const int n = (int)(pairs.size() / 2);
      const std::string d = fairmatch::Sha256Hex(
          pairs.data(), pairs.size() * sizeof(uint32_t));
      if (count < 0) {
        count = n;
        digest = d;
        final_pairs = pairs;
      } else if (n != count || d != digest) {
        std::fprintf(stderr,
                     "FAIL portable output not deterministic across reps\n");
        std::exit(32);
      }
      prep_v.push_back(t_prep - t0);
      gpu_v.push_back(t_gpu - t_prep);

      map_v.push_back(t_map - t_gpu);
      host_v.push_back(t_host - t_map);
      wall.push_back(t_host - t0);
      std::printf(
          "  rep complete_ms=%.3f prep=%.3f gpu=%.3f map=%.3f host=%.3f "
          "count=%d\n",
          t_host - t0, t_prep - t0, t_gpu - t_prep, t_map - t_gpu,
          t_host - t_map, n);
    }
  };

  for (int i = 0; i < warmup; ++i) run_once(false);
  for (int i = 0; i < reps; ++i) run_once(true);

  fairmatch::WriteFileBytes(out_dir + "/portable_" + kernel + "_pairs.bin",
                            final_pairs.data(),
                            final_pairs.size() * sizeof(uint32_t));
  std::printf(
      "PORTABLE_RESULT {\"arm\":\"portable_wgsl_%s\",\"count\":%d,"
      "\"pairs_sha256\":\"%s\",\"pipeline_ms\":%.3f,\"wall_ms\":[%s],"
      "\"p50_ms\":%.3f,\"p95_ms\":%.3f,\"gpu_p50_ms\":%.3f,"
      "\"colp_bytes\":%llu,\"transpose_ms\":%.3f,\"tb_resident\":%d,"
      "\"outab_sha256\":\"%s\",\"outba_sha256\":\"%s\"",
      kernel.c_str(), count, digest.c_str(), pipeline_ms,
      fairmatch::JoinMs(wall).c_str(), fairmatch::Percentile(wall, 0.5),
      fairmatch::Percentile(wall, 0.95), fairmatch::Percentile(gpu_v, 0.5),
      (unsigned long long)colp_bytes_report, last_transpose_ms,
      tb_resident ? 1 : 0, dir_ab.c_str(), dir_ba.c_str());
  if (split_timing) {
    std::printf(",\"gpu_main_pass_p50_ms\":%.3f,\"gpu_merge_pass_p50_ms\":%.3f",
                fairmatch::Percentile(split_main_v, 0.5),
                fairmatch::Percentile(split_merge_v, 0.5));
  }
  std::printf("}\n");
  return 0;
}
