
enable chromium_experimental_subgroup_matrix;
enable subgroups;

alias Left = subgroup_matrix_left<f32, 8, 8>;
alias Right = subgroup_matrix_right<f32, 8, 8>;
alias Res = subgroup_matrix_result<f32, 8, 8>;

const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 128u;
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

var<workgroup> Bsh : array<f32, 4096>; // 32 rows x 128 (16 KiB)
var<workgroup> accSh : array<f32, 4096>;   // WGR rows x 32 cols

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

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
  var rbest = 0.0;
  var rsecond = 0.0;
  var rbi = -1;

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var e = lid; e < BT * 128u; e = e + 512u) {
      let brow = tile0 + e / 128u;
      Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
    }
    workgroupBarrier();
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = subgroupMatrixLoad<Right>(&Bsh, (nt * 8u) * 128u + k * 8u, true, 128u);
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, (sg * 8u) * 32u + nt * 8u, acc, false, 32u);
    }
    workgroupBarrier();
    if (lid < WGR) {
      let lim = min(BT, U.numB - tile0);
      for (var c = 0u; c < lim; c = c + 1u) {
        let s = accSh[lid * 32u + c];
        if (s > rbest) {
          rsecond = rbest; rbest = s; rbi = i32(tile0 + c);
        } else if (s > rsecond) { rsecond = s; }
      }
    }

    workgroupBarrier();
    tile0 = tile0 + BT;
  }
  let row = row0 + lid;
  if (lid < WGR && row < U.numA) {
    OutAB[row] = gatef(rbest, rsecond, rbi);
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
