
const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144

struct GParams {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  guideMode : u32,
  rowBase : u32,
  maxResidual : f32,
  pad0 : u32,
};

fn guide_ok(q : vec2<f32>, d : vec2<f32>) -> bool {
  if (U.guideMode == 1u) {
    let p1 = vec3<f32>(q, 1.0);
    let p2 = vec3<f32>(d, 1.0);
    let line2 = vec3<f32>(
        M[0] * p1.x + M[1] * p1.y + M[2],
        M[3] * p1.x + M[4] * p1.y + M[5],
        M[6] * p1.x + M[7] * p1.y + M[8]);
    let line1 = vec3<f32>(
        M[0] * p2.x + M[3] * p2.y + M[6],
        M[1] * p2.x + M[4] * p2.y + M[7],
        M[2] * p2.x + M[5] * p2.y + M[8]);
    let nom = dot(p2, line2);
    let denom = dot(line2.xy, line2.xy) + dot(line1.xy, line1.xy);
    return denom > 1e-12 && nom * nom <= U.maxResidual * denom;
  } else if (U.guideMode == 2u) {
    let hx = M[0] * q.x + M[1] * q.y + M[2];
    let hy = M[3] * q.x + M[4] * q.y + M[5];
    let hz = M[6] * q.x + M[7] * q.y + M[8];
    if (abs(hz) <= 1e-8) {
      return false;
    }
    let delta = vec2<f32>(hx / hz, hy / hz) - d;
    return dot(delta, delta) <= U.maxResidual;
  }
  return true;
}

fn gate_guided(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let secondDot = max(second, 131072.0);
  let bd = sqrt(max(0.0, 2.0 - 2.0 * best * INV_SQ_NORM));
  let sd = sqrt(max(0.0, 2.0 - 2.0 * secondDot * INV_SQ_NORM));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

@group(0) @binding(0) var<storage, read> A : array<vec4<u32>>;
@group(0) @binding(1) var<storage, read> B : array<vec4<u32>>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform> U : GParams;
@group(0) @binding(4) var<storage, read> PtsQ : array<vec2<f32>>;
@group(0) @binding(5) var<storage, read> PtsD : array<vec2<f32>>;
@group(0) @binding(6) var<storage, read> M : array<f32>;

const WG : u32 = 64u;

var<workgroup> Bsh : array<vec4<u32>, 512>; // 64 rows x 8 vec4 words

@compute @workgroup_size(64)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32) {
  let row = (U.rowBase + wg.x) * WG + lid;
  let valid = row < U.numA;
  var q : array<vec4<u32>, 8>;
  var qpt = vec2<f32>(0.0, 0.0);
  if (valid) {
    for (var w = 0u; w < 8u; w = w + 1u) { q[w] = A[row * 8u + w]; }
    qpt = PtsQ[row];
  }
  var best = 0.0;
  var second = 0.0;
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
        if (!guide_ok(qpt, PtsD[tile0 + c])) { continue; }
        var su = 0u;
        for (var w = 0u; w < 8u; w = w + 1u) {
          let bv = Bsh[c * 8u + w];
          su += dot4U8Packed(q[w].x, bv.x) + dot4U8Packed(q[w].y, bv.y) +
                dot4U8Packed(q[w].z, bv.z) + dot4U8Packed(q[w].w, bv.w);
        }
        let s = f32(su);
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
  if (valid) { Out[row] = gate_guided(best, second, bestIndex); }
}
