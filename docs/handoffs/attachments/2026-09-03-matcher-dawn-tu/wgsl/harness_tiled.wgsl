
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

fn gate(best : u32, second : u32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(f32(best) * INV_SQ_NORM, 1.0));
  let sd = acos(min(f32(second) * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

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
