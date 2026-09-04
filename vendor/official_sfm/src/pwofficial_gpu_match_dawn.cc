// pwofficial_gpu_match_dawn.cc — pocketworld cross-platform (Dawn/WGSL) GPU
// descriptor matcher: the ONE matcher implementation shared by iOS (Dawn →
// Metal), Android and HarmonyOS (Dawn → Vulkan). Production sibling of the
// shipped Metal TU pwofficial_gpu_match.mm; that TU is the SEMANTIC GOLD
// STANDARD and is not modified by this file (see the dispatch layer
// pwofficial_gpu_match_dispatch.cc for how the two coexist on iOS).
//
// ── Provenance (2026-09-03) ────────────────────────────────────────────────
// Plain path kernel = the H2 campaign frontier `fusedr128-db` (SR-3D-1
// software-pipelined fused dual-direction subgroup-matrix kernel), taken
// VERBATIM from the WGSL text the harness
// aether_cpp/experiments/portable_frontend_pareto/tools/fair_match_portable_arm.cc
// assembles for kernel "fusedr128-db" (dumped through the harness's own
// assembly path, SHA-256 2e4a7d40b19346852d4fb085d292c8cb160f5c6d6e5b8eb5327662f7af09ae8f),
// with exactly two textual deltas for KNIFE-C chunking:
//   1. Params.pad0 is renamed rowBase and `let rb = U.rowBase + wg.x;`
//      replaces the implicit block index (rowBase == 0 reproduces the
//      frontier bit-for-bit);
//   2. column partials are indexed by the ABSOLUTE row block `rb`.
// That frontier was proven 696/696 byte-identical to native Metal on the two
// 2026-09-02 build-89 12MP sessions (docs/handoffs/2026-09-02-wgsl-matcher-campaign.md).
// Fallback kernel = the harness's `tiled` kernel (dot4U8Packed, one query per
// thread, 64-row shared B tile; SHA-256 of the dumped text
// 1de3662a9afa4edfa2ea87a17507bbd876f74d1d1afea829c481539ce91feea3), same
// rowBase delta. Both kernels are gated by the parity suite (19 frozen
// goldens) and the 696-pair full gate before promotion.
//
// ── Semantics (identical to pwofficial_gpu_match.mm, see its header) ──────
// * best = MAX dot, LOWEST index wins ties; second = max of the remaining
//   multiset; every scan ascends with strict `>`; every merge level combines
//   an ordered lower-index chunk with a higher-index chunk keeping "ours" on
//   ties. Dots are exact integers (< 2^24) in f32 / u32.
// * plain gate (guideMode 0): angular domain, bd = acos(min(best/512², 1)),
//   sd likewise, keep iff bd <= maxDistance(0.7) && bd < maxRatio * sd.
// * guided gate (guideMode 1/2): v1 TWO-PASS structure (one direction per
//   dispatch, mirrored arguments), geometry gate BEFORE top-2 insertion:
//     mode 1 (E/F): symmetric epipolar residual — line2 = M·p1, line1 = Mᵀ·p2,
//                   nom = p2·line2, denom = |line2.xy|² + |line1.xy|²,
//                   accept iff denom > 1e-12 && nom² <= maxResidual·denom;
//     mode 2 (H):   reprojection — h = M·q, reject iff |hz| <= 1e-8, else
//                   accept iff |(hx/hz, hy/hz) − d|² <= maxResidual;
//   distance domain normalized L2 √(2 − 2cos) with the second-best floored
//   by the 131072 dot sentinel (= COLMAP's sentinel distance 512).
//   ⚠️ The guided gate is a near-cancellation and its float algebra is
//   compile-context dependent (pwofficial_gpu_match.mm header: 1,575
//   recombination hypotheses, ZERO bit-reproduce the Metal v1 gate).
//   Bit-parity with Metal is therefore NOT a gate for guided; the accepted
//   criterion is boundary-confined divergence (candidates within ~1e-3
//   relative of the residual threshold, ±1 match/pair scale) + downstream
//   losslessness. Do not "fix" the algebra to chase bits.
// * zero-padding invariant: both descriptor tables (and, when guided, both
//   keypoint tables) are padded to 128-row multiples, zero-filled, on the
//   host; padded rows produce dot == 0 candidates that can never become best
//   nor raise second under strict `>` against best/second initialised to 0.
// * mutual cross-check + ordered pair emission on the host, verbatim.
//
// ── Portable host driver (ported from the Metal TU, standard C++ only) ───
// * KNIFE-C chunked dispatch: env OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS
//   (default 16; 0 = monolithic), _COOL_MS, _FPS30, _ALT, thermal gap
//   OFFICIAL_AETHER_MATCH_GAP_SERIOUS_PCT / _CRITICAL_PCT / _FPS30 — same
//   names, same defaults, same self-calibrating EMA cost model (one EMA per
//   kernel family). Row blocks are independent and column partials are
//   indexed by absolute row block, so any chunking is bit-identical.
// * GPU-HANG-A1 watchdog: wgpu::Instance::WaitAny with a bounded timeout
//   (TimedWaitAny instance feature; env OFFICIAL_AETHER_GPU_MATCH_WAIT_MS,
//   default 30000). Timeout ⇒ rc 7 (retryable), never an unbounded wait.
// * rc classification (same contract as the Metal TU): 0 ok · 1 bad args ·
//   2 GPU/pipeline unavailable · 5 descriptor buffer alloc failed · 6 aux
//   buffer alloc failed · 7 retryable GPU failure (timeout / transient error
//   / device lost with reason Unknown / incomplete output) · 8 permanent
//   (device lost with reason Destroyed or FailedCreation). Vulkan's
//   VK_ERROR_DEVICE_LOST surfaces through Dawn's device-lost callback and
//   lands in the same 7/8 split; Metal's NotPermitted/AccessRevoked codes
//   are NOT observable through Dawn (it abstracts the MTLCommandBuffer
//   error) — documented gap, they degrade to repeated rc 7.
// * Silent-completion guard (Dawn-specific): Dawn's Metal backend does not
//   inspect MTLCommandBuffer.error in its completed handler, so a GPU hang
//   under thermal pressure would "complete" with garbage outputs. Every
//   output slot is pre-filled with INT32_MIN before submission; any sentinel
//   left after readback ⇒ the kernel did not run to completion ⇒ rc 7.
//   The kernels never write INT32_MIN (they write −1 or an index ≥ 0).
// * Buffer pools are grow-only and shared; whole calls are serialised behind
//   one mutex, exactly like the Metal TU.
// * Descriptor residency V1 (env OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1=1,
//   default off) reuses the shared policy header; resident tables are kept
//   in the active kernel's storage format (f32 for the subgroup-matrix
//   kernel, raw u8 for the tiled fallback) and accounted in those bytes.
// * Thermal state: the Metal TU reads NSProcessInfo directly. Here the
//   platform feeds it either through the weak hook
//   pwofficial_platform_thermal_state() (provided on Apple by
//   pwofficial_gpu_match_thermal_apple.mm) or the explicit setter
//   pwdawn_gpu_match_set_thermal_state(0 nominal · 1 fair · 2 serious ·
//   3 critical — the aether_sfm_set_thermal_state scale). Serious/critical
//   drive the chunk target and duty-cycle gaps exactly as on Metal.
//
// ── Kernel selection = the Vulkan lane's V0 / V1 / V2 branch points ──────
//   V0: adapter exposes Subgroups + ChromiumExperimentalSubgroupMatrix with
//       an F32 8×8×8 config, fixed subgroup size 32, ≥512 invocations and
//       ≥32 KiB workgroup storage → `fusedr128-db` (Metal: simdgroup_matrix;
//       Vulkan: VK_KHR_cooperative_matrix, see PhysicalDeviceVk.cpp:533).
//   V1: otherwise → `tiled` with dot4U8Packed lowered to OpUDotKHR
//       (SPV_KHR_integer_dot_product) when VK_KHR_shader_integer_dot_product
//       is present (tint spirv writer builtin_polyfill.cc DotPacked4x8).
//   V2: no integer-dot extension → same `tiled` WGSL, Dawn force-enables
//       Toggle::PolyFillPacked4x8DotProduct (PhysicalDeviceVk.cpp:1225) and
//       the scalar polyfill runs. On Metal dot4U8Packed is always the
//       polyfill, which is why V0 is the iOS production kernel.
//   env OFFICIAL_AETHER_MATCH_DAWN_KERNEL=tiled forces V1/V2 for A/B.
//   Which branch was taken is reported once at init on stderr and through
//   pwdawn_gpu_match_backend_info().
//
// ── Exported C ABI (backend-private names; the public aether_gpu_match_*
//    names are owned by pwofficial_gpu_match_dispatch.cc) ─────────────────
//   pwdawn_gpu_match_gemm_pairs / _resident / _guided / _probe_batch
//   pwdawn_gpu_match_descriptor_residency_invalidate / _clear_session / _stats
//   pwdawn_gpu_match_last_error
//   pwdawn_gpu_match_set_capture_active / _set_preview_fps30 /
//   pwdawn_match_set_ab_phase / pwdawn_gpu_match_set_thermal_state
//   pwdawn_gpu_match_backend_info
// Observation globals aether_match_gpu_ms / aether_match_sleep_ms /
// aether_match_chunks are DEFINED here unless
// PWOFFICIAL_DAWN_OBSERVABLES_EXTERN=1 (the iOS framework build, where the
// Metal TU defines them and both backends accumulate into the same words).
//
// Build: C++17, <webgpu/webgpu_cpp.h> from aether_cpp/third_party/dawn/include
// plus the TARGET's generated headers (host: aether_cpp/build/third_party/dawn/
// gen/include; iOS: aether_cpp/build-ios-device-dawn/third_party/dawn/gen/include).

#include <webgpu/webgpu_cpp.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#if __has_include("aether/sfm/descriptor_residency_policy_v1.h")
#include "aether/sfm/descriptor_residency_policy_v1.h"
#else
#include "../include/aether/sfm/descriptor_residency_policy_v1.h"
#endif

// ── Observation globals (see header) ─────────────────────────────────────
#if defined(PWOFFICIAL_DAWN_OBSERVABLES_EXTERN) && PWOFFICIAL_DAWN_OBSERVABLES_EXTERN
extern "C" double aether_match_gpu_ms;
extern "C" double aether_match_sleep_ms;
extern "C" int aether_match_chunks;
#else
extern "C" double aether_match_gpu_ms = 0.0;
extern "C" double aether_match_sleep_ms = 0.0;
extern "C" int aether_match_chunks = 0;
#endif

// Weak platform hook: Apple provides it from pwofficial_gpu_match_thermal_apple.mm
// (NSProcessInfo.thermalState); other platforms leave it undefined and feed
// the explicit setter instead.
extern "C" __attribute__((weak)) int pwofficial_platform_thermal_state(void);

namespace {

constexpr int kD = 128;
constexpr uint32_t kMmaRows = 128;   // WGR of the subgroup-matrix kernel
constexpr uint32_t kTiledRows = 64;  // WG of the tiled fallback kernel
constexpr int32_t kOutSentinel = INT32_MIN;
constexpr uint64_t kSlot = 256;      // uniform / storage offset alignment

inline uint64_t RoundUp(uint64_t v, uint64_t m) { return (v + m - 1) / m * m; }

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

std::string SV(wgpu::StringView v) {
  if (!v.data) return std::string();
  if (v.length == WGPU_STRLEN) return std::string(v.data);
  return std::string(v.data, v.length);
}

void Log(const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  std::fprintf(stderr, "[pwofficial_gpu_match_dawn] %s\n", buf);
}

// ── Last error stash (rc=7 bridge to sfm_match_fail.jsonl) ───────────────
std::mutex gLastErrLock;
char gLastErr[192] = {0};

void StashLastError(const std::string& text) {
  std::lock_guard<std::mutex> lk(gLastErrLock);
  std::snprintf(gLastErr, sizeof(gLastErr), "%s", text.c_str());
}

// ── Flags (same meaning as the Metal TU) ─────────────────────────────────
std::atomic<int> gCaptureActive{1};
std::atomic<int> gPreviewFps30{0};
std::atomic<int> gAbPhase{-1};
std::atomic<int> gThermalState{0};  // explicit feed; 0 nominal … 3 critical

int PlatformThermalState() {
  if (pwofficial_platform_thermal_state != nullptr) {
    return pwofficial_platform_thermal_state();
  }
  return gThermalState.load(std::memory_order_relaxed);
}

// ── Env knobs (cached per process, verbatim semantics of the Metal TU) ───
uint64_t CmdWaitTimeoutMs() {
  static const uint64_t v = [] {
    const char* e = getenv("OFFICIAL_AETHER_GPU_MATCH_WAIT_MS");
    if (e != nullptr) {
      const long long ms = atoll(e);
      if (ms > 0) return (uint64_t)ms;
    }
    return (uint64_t)30000;
  }();
  return v;
}

double AbAltValue(const char* key) {
  const char* e = getenv(key);
  return e ? atof(e) : -1.0;
}

double ChunkTargetMs() {
  static double v = -1.0;
  if (v < 0.0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS");
    v = e ? atof(e) : 16.0;
    if (v < 0.0) v = 0.0;
  }
  if (gAbPhase.load(std::memory_order_relaxed) == 1) {
    static const double alt =
        AbAltValue("OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS_ALT");
    if (alt >= 0.0) return alt;
  }
  if (gPreviewFps30.load(std::memory_order_relaxed) == 1) {
    static double v30 = -1.0;
    if (v30 < 0.0) {
      const char* e30 = getenv("OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS_FPS30");
      v30 = e30 ? atof(e30) : 24.0;
      if (v30 < 0.0) v30 = 0.0;
    }
    return v30 > v ? v30 : v;
  }
  return v;
}

double ChunkTargetCoolMs() {
  static double v = -1.0;
  if (v < 0.0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_CHUNK_TARGET_COOL_MS");
    v = e ? atof(e) : 16.0;
    if (v < 0.0) v = 0.0;
  }
  const double hot = ChunkTargetMs();
  return v > hot ? v : hot;
}

bool ThermalHot() {
  if (gCaptureActive.load(std::memory_order_relaxed) == 0) return false;
  const int st = PlatformThermalState();
  return st >= 2;  // serious (2) or critical (3)
}

double ThermalGapPct() {
  if (gCaptureActive.load(std::memory_order_relaxed) == 0) return 0.0;
  const int st = PlatformThermalState();
  if (st == 2) {
    static double v = -1.0;
    if (v < 0.0) {
      const char* e = getenv("OFFICIAL_AETHER_MATCH_GAP_SERIOUS_PCT");
      v = e ? atof(e) : 100.0;
      if (v < 0.0) v = 0.0;
    }
    if (gPreviewFps30.load(std::memory_order_relaxed) == 1) {
      static double v30 = -1.0;
      if (v30 < 0.0) {
        const char* e30 = getenv("OFFICIAL_AETHER_MATCH_GAP_SERIOUS_PCT_FPS30");
        v30 = e30 ? atof(e30) : -1.0;
      }
      return v30 >= 0.0 ? v30 : v * 0.5;
    }
    return v;
  }
  if (st >= 3) {
    static double v = -1.0;
    if (v < 0.0) {
      const char* e = getenv("OFFICIAL_AETHER_MATCH_GAP_CRITICAL_PCT");
      v = e ? atof(e) : 300.0;
      if (v < 0.0) v = 0.0;
    }
    return v;
  }
  return 0.0;
}

bool DescriptorResidencyEnabled() {
  static const bool enabled = [] {
    const char* value = std::getenv("OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1");
    return value && value[0] == '1' && value[1] == '\0';
  }();
  return enabled;
}

uint64_t DescriptorResidencyBudgetBytes() {
  static const uint64_t budget = [] {
    constexpr uint64_t kDefault = UINT64_C(48) * 1024 * 1024;
    const char* value = std::getenv("OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_BYTES");
    if (!value || !value[0]) return kDefault;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(value, &end, 10);
    if (!end || *end != '\0') return kDefault;
    return static_cast<uint64_t>(parsed);
  }();
  return budget;
}

// ══════════════════════════════ WGSL ═════════════════════════════════════

// Plain fused dual-direction kernel: `fusedr128-db` frontier verbatim except
// the two rowBase lines (see header). Bindings: 0 A (f32 rows×128, padded to
// 128-row multiple), 1 B (same), 2 OutAB (i32 × numA), 3 Params, 4 ColP
// (ColPart × numB × numWg), 5 OutBA (i32 × numB; merge entry only).
// [METAL-SHAPE 2026-09-04] 主核改用出货 Metal 核 pw_match_gemm2 的形状。
// 起因(隔离台架,把 tint 生成的 MSL 与手写 Metal 同台交替跑,噪声 ±0.02ms):
//   tint 完整 7.485 / 仅 MMA 4.282 / 手写仅 MMA 3.873
//   ⇒ MMA 段只慢 11%,**扫描段值 2.77ms**,而截断循环体只省 0.86ms
//   ⇒ 1.9ms 是脚手架:扫描临界路径 32 次(行)/128 次(列),只有 160/512 线程在做。
// Metal v2 的形状:每个 SG 只扫**自己那 8 行**,512 线程全参与,临界路径 8+8 次。
// 连带解锁:扫描不再放在 `if (lid < WGR)` 这种发散分支里 ⇒ 控制流对子组一致 ⇒
//   tint 允许 subgroupShuffleXor(此前"必须在子组一致控制流中调用"就是被发散卡死的)。
// 逐字复刻 pw_match_gemm2 的三处语义(它本身是我们逐字节对拍的 oracle):
//   1) 行方向 lcg 两级蝶形,`if (ob > pb)` 严格大于 ⇒ 平局留自己;lcg 升序对应列
//      升序,只有 lcg==0 的结果被读走,那一条恰好是"最小列号胜"。
//   2) 列方向每 lane 独占一列、只扫本 SG 的 8 行 → cp* 线程组内 partial;
//      跨 SG 归并按 sgid 升序 == 行号升序 ⇒ "最小行号胜"保留。
//   3) 分块 top-2 的层次归并与逐元素扫描等价(v2 本就是这么对着 v1 过闸的)。
// 共享内存 30 KiB = Bsh 8(f16)+ accSh 16 + cp* 3×2 ⇒ **只在 mixed 档可用**
//   (f32 档 Bsh 16KiB 会撑到 38KiB 越限),plain 回退档继续用老核。
// 预取回到"循环顶部全线程"(Metal v2 同款),放弃双缓冲重叠 —— 双缓冲正是
//   逼出发散结构、进而锁死子组操作的那个根。
constexpr char kWgslMmaMetalShape[] = R"WGSL(
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
  rowBase : u32,
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

var<workgroup> cpBest : array<f32, 512>;    // kSG(16) x BT(32)
var<workgroup> cpSecond : array<f32, 512>;
var<workgroup> cpIdx : array<i32, 512>;

@compute @workgroup_size(512)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32,
        @builtin(subgroup_invocation_id) lane : u32) {
  let rb = U.rowBase + wg.x;
  let row0 = rb * WGR;
  let lrow = lane >> 2u;
  let lcg = lane & 3u;
  let gRow = row0 + sg * 8u + lrow;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
  var rowBest = 0.0;
  var rowSecond = 0.0;
  var rowBestI = -1;

  var col0 = 0u;
  loop {
    if (col0 >= U.numB) { break; }
    for (var e = lid; e < BT * 128u; e = e + 512u) {
      let brow = col0 + e / 128u;
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

    var pb = 0.0;
    var ps = 0.0;
    var pbi = -1;
    let rbase = (sg * 8u + lrow) * 32u;
    for (var t = 0u; t < 8u; t = t + 1u) {
      let cLoc = lcg * 8u + t;
      let d = accSh[rbase + cLoc];
      if (d > pb) { ps = pb; pb = d; pbi = i32(col0 + cLoc); }
      else if (d > ps) { ps = d; }
    }
    {
      let ob = subgroupShuffleXor(pb, 1u);
      let os = subgroupShuffleXor(ps, 1u);
      let oi = subgroupShuffleXor(pbi, 1u);
      if (ob > pb) { ps = max(os, pb); pb = ob; pbi = oi; }
      else { ps = max(ps, ob); }
    }
    {
      let ob = subgroupShuffleXor(pb, 2u);
      let os = subgroupShuffleXor(ps, 2u);
      let oi = subgroupShuffleXor(pbi, 2u);
      if (ob > pb) { ps = max(os, pb); pb = ob; pbi = oi; }
      else { ps = max(ps, ob); }
    }
    if (lcg == 0u) {
      if (pb > rowBest) { rowSecond = max(rowBest, ps); rowBest = pb; rowBestI = pbi; }
      else { rowSecond = max(rowSecond, pb); }
    }

    var cb = 0.0;
    var cs = 0.0;
    var ci = -1;
    let cbase = sg * 8u * 32u + lane;
    for (var r = 0u; r < 8u; r = r + 1u) {
      let d = accSh[cbase + r * 32u];
      if (d > cb) { cs = cb; cb = d; ci = i32(row0 + sg * 8u + r); }
      else if (d > cs) { cs = d; }
    }
    cpBest[sg * 32u + lane] = cb;
    cpSecond[sg * 32u + lane] = cs;
    cpIdx[sg * 32u + lane] = ci;
    workgroupBarrier();

    // [MERGE-BUTTERFLY 2026-09-04] 跨 SG 归并由「32 线程 × 15 次串行」改为
    // 「512 线程 × 每人 1 个 partial + 4 级蝶形」。
    // Metal v2 在这里用的是串行形态,并注明"并行 shuffle 树试过更慢——串行形态
    // 藏在其他线程的进度后面"。**那个前提在我们这里已经没了**:packed 上传把预取
    // 从 8 次迭代压到 2 次,480 个线程两拍就干完,归并再没东西可藏。
    // 分解实测(隔离台架,删掉本块):现役 6.555 → 4.982,这块值 ~1.5ms。
    // 映射:mcl = lid/16 是列(0..31),ms = lid%16 是 SG 下标;同一列的 16 个线程
    //   落在同一子组的同一半(偶数列 lane 0-15 / 奇数列 lane 16-31),掩码 1/2/4/8
    //   的蝶形不会跨出那一半。**全部 512 线程无条件执行 ⇒ 控制流对子组一致**,
    //   这正是 tint 允许 subgroupShuffleXor 的前提(条件分支里会被拒)。
    // 共享内存读总量不变(512 次 = 32 列 × 16 SG),没有冗余读。
    // 语义:ms 升序 == sg 升序 == 行号升序,`ob > b` 严格大于 ⇒ 平局留自己;
    //   逐级 xor 后 ms==0 那条恰好是"最小行号胜",与串行形态逐字等价。
    let mcl = lid / 16u;
    let ms = lid % 16u;
    var b = cpBest[ms * 32u + mcl];
    var s2 = cpSecond[ms * 32u + mcl];
    var bi = cpIdx[ms * 32u + mcl];
    {
      let ob = subgroupShuffleXor(b, 1u);
      let os = subgroupShuffleXor(s2, 1u);
      let oi = subgroupShuffleXor(bi, 1u);
      if (ob > b) { s2 = max(b, os); b = ob; bi = oi; }
      else { s2 = max(s2, ob); }
    }
    {
      let ob = subgroupShuffleXor(b, 2u);
      let os = subgroupShuffleXor(s2, 2u);
      let oi = subgroupShuffleXor(bi, 2u);
      if (ob > b) { s2 = max(b, os); b = ob; bi = oi; }
      else { s2 = max(s2, ob); }
    }
    {
      let ob = subgroupShuffleXor(b, 4u);
      let os = subgroupShuffleXor(s2, 4u);
      let oi = subgroupShuffleXor(bi, 4u);
      if (ob > b) { s2 = max(b, os); b = ob; bi = oi; }
      else { s2 = max(s2, ob); }
    }
    {
      let ob = subgroupShuffleXor(b, 8u);
      let os = subgroupShuffleXor(s2, 8u);
      let oi = subgroupShuffleXor(bi, 8u);
      if (ob > b) { s2 = max(b, os); b = ob; bi = oi; }
      else { s2 = max(s2, ob); }
    }
    let j = col0 + mcl;
    if (ms == 0u && j < U.numB) {
      ColP[rb * U.numB + j] = ColPart(b, s2, bi);
    }
    col0 = col0 + BT;
  }

  if (lcg == 0u && gRow < U.numA) {
    OutAB[gRow] = gatef(rowBest, rowSecond, rowBestI);
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
    let p = ColP[w * U.numB + c];
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
)WGSL";

constexpr char kWgslMmaFused[] = R"WGSL(
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
  rowBase : u32,
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
  let rb = U.rowBase + wg.x;
  let row0 = rb * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
  var rbest = 0.0;
  var rsecond = 0.0;
  var rbi = -1;
    for (var e = lid; e < BT * 128u; e = e + 512u) {
      let brow = 0u + e / 128u;
      Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
    }

  workgroupBarrier();

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = subgroupMatrixLoad<Right>(&Bsh, (nt * 8u) * 128u + k * 8u, true, 128u);
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, (sg * 8u) * 32u + nt * 8u, acc, false, 32u);
    }
    workgroupBarrier();
    let nextT = tile0 + BT;
    if (nextT < U.numB && lid >= 160u) {
      for (var e = lid - 160u; e < BT * 128u; e = e + 352u) {
        let brow = nextT + e / 128u;
        Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
      }
    }

    if (lid < WGR) {
      // [CONST-BOUND 2026-09-04] 上界用编译期常量 BT,而非 min(BT, numB-tile0)。
      // 运行时上界让 LLVM 无法展开这个 32 次循环(手写 Metal 那边是编译期常量);
      // 隔离台架(tint 生成的 MSL 逐行对拍手写形态)实测这一改 −0.37ms。
      // **语义等价证明**:预取对越界列写的是精确 0(select(0, B[..], brow<numB)),
      // 而这里是严格 `>` ⇒ rbest 初值 0.0 时 `0.0 > 0.0` 为假,补位列永远不会
      // 成为 best/second,tile0+c 也就永远不会被写进 rbi。逐字节闸复验。
      // guided 核**不能同样处理**:那边多一个 guide_ok(q, PtsD[tile0+c]),
      // 补位下标会越界读点云缓冲,零点积的论证覆盖不到它。
      for (var c = 0u; c < BT; c = c + 1u) {
        let s = accSh[lid * 32u + c];
        if (s > rbest) {
          rsecond = rbest; rbest = s; rbi = i32(tile0 + c);
        } else if (s > rsecond) { rsecond = s; }
      }
    }
    if (lid >= WGR && lid < WGR + BT) {
      let cl = lid - WGR;
      let c = tile0 + cl;
      if (c < U.numB) {
        var best = 0.0; var second = 0.0; var bi = -1;
        for (var r = 0u; r < WGR; r = r + 1u) {
          let s = accSh[r * 32u + cl];
          if (s > best) {
            second = best; best = s; bi = i32(row0 + r);
          } else if (s > second) { second = s; }
        }
        ColP[c * U.numWg + rb] = ColPart(best, second, bi);
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
)WGSL";

// Guided gate + guided final gate, shared text for both guided kernels
// (Metal v1 pw_match_gemm lines 340-373 / 385-395 transliterated: same
// expression trees, same operand order).
constexpr char kWgslGuidedCommon[] = R"WGSL(
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
)WGSL";

// Guided, ONE direction per dispatch (v1 two-pass structure): the fused
// kernel's row half (same MMA tile pipeline, same staging schedule, no column
// partials) with the geometry gate inserted before top-2 insertion.
// Bindings: 0 query descriptors (f32, padded), 1 database descriptors, 2 Out
// (i32 × numA), 3 GParams, 4 PtsQ (vec2 × padded query rows), 5 PtsD (vec2 ×
// database rows), 6 M (9 floats row-major, query→database geometry).
constexpr char kWgslMmaGuidedHead[] = R"WGSL(
enable chromium_experimental_subgroup_matrix;
enable subgroups;

alias Left = subgroup_matrix_left<f32, 8, 8>;
alias Right = subgroup_matrix_right<f32, 8, 8>;
alias Res = subgroup_matrix_result<f32, 8, 8>;

const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 128u;
const BT : u32 = 32u;
)WGSL";

constexpr char kWgslMmaGuidedBindings[] = R"WGSL(
@group(0) @binding(0) var<storage, read> A : array<f32>;
@group(0) @binding(1) var<storage, read> B : array<f32>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform> U : GParams;
@group(0) @binding(4) var<storage, read> PtsQ : array<vec2<f32>>;
@group(0) @binding(5) var<storage, read> PtsD : array<vec2<f32>>;
@group(0) @binding(6) var<storage, read> M : array<f32>;

var<workgroup> Bsh : array<f32, 4096>;
var<workgroup> accSh : array<f32, 4096>;
)WGSL";

constexpr char kWgslMmaGuidedMain[] = R"WGSL(
@compute @workgroup_size(512)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32,
        @builtin(subgroup_id) sg : u32) {
  let rb = U.rowBase + wg.x;
  let row0 = rb * WGR;
  let aRow0 = row0 + sg * 8u;
  var aFrag : array<Left, 16>;
  for (var k = 0u; k < 16u; k = k + 1u) {
    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);
  }
  var rbest = 0.0;
  var rsecond = 0.0;
  var rbi = -1;
  var q = vec2<f32>(0.0, 0.0);
  if (lid < WGR) { q = PtsQ[row0 + lid]; }
    for (var e = lid; e < BT * 128u; e = e + 512u) {
      let brow = 0u + e / 128u;
      Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
    }

  workgroupBarrier();

  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = subgroupMatrixLoad<Right>(&Bsh, (nt * 8u) * 128u + k * 8u, true, 128u);
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, (sg * 8u) * 32u + nt * 8u, acc, false, 32u);
    }
    workgroupBarrier();
    let nextT = tile0 + BT;
    if (nextT < U.numB && lid >= 160u) {
      for (var e = lid - 160u; e < BT * 128u; e = e + 352u) {
        let brow = nextT + e / 128u;
        Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
      }
    }

    if (lid < WGR) {
      let lim = min(BT, U.numB - tile0);
      for (var c = 0u; c < lim; c = c + 1u) {
        if (!guide_ok(q, PtsD[tile0 + c])) { continue; }
        let s = accSh[lid * 32u + c];
        if (s > rbest) {
          rsecond = rbest; rbest = s; rbi = i32(tile0 + c);
        } else if (s > rsecond) { rsecond = s; }
      }
    }

    workgroupBarrier();
    tile0 = nextT;
  }
  let row = row0 + lid;
  if (lid < WGR && row < U.numA) {
    Out[row] = gate_guided(rbest, rsecond, rbi);
  }
}
)WGSL";

// Tiled fallback (V1/V2): harness `tiled` kernel verbatim + rowBase, with the
// Params struct widened to the shared 32-byte layout. Bindings: 0 A (raw u8
// rows as vec4<u32>), 1 B, 2 Out, 3 Params.
constexpr char kWgslTiledPlain[] = R"WGSL(
const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  rowBase : u32,
  pad1 : u32,
  pad2 : u32,
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
  let row = (U.rowBase + wg.x) * WG + lid;
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
)WGSL";

// Tiled guided (V1/V2 sibling of the MMA guided kernel; same bindings as the
// MMA guided kernel except descriptors are raw u8 vec4<u32>; dots are u32
// and converted to f32 for the guided distance gate — exact, < 2^24).
constexpr char kWgslTiledGuidedHead[] = R"WGSL(
const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
)WGSL";

constexpr char kWgslTiledGuidedBindings[] = R"WGSL(
@group(0) @binding(0) var<storage, read> A : array<vec4<u32>>;
@group(0) @binding(1) var<storage, read> B : array<vec4<u32>>;
@group(0) @binding(2) var<storage, read_write> Out : array<i32>;
@group(0) @binding(3) var<uniform> U : GParams;
@group(0) @binding(4) var<storage, read> PtsQ : array<vec2<f32>>;
@group(0) @binding(5) var<storage, read> PtsD : array<vec2<f32>>;
@group(0) @binding(6) var<storage, read> M : array<f32>;

const WG : u32 = 64u;

var<workgroup> Bsh : array<vec4<u32>, 512>; // 64 rows x 8 vec4 words
)WGSL";

constexpr char kWgslTiledGuidedMain[] = R"WGSL(
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
)WGSL";

struct alignas(16) Params {
  uint32_t numA, numB;
  float maxRatio, maxDistance;
  uint32_t numWg, rowBase, pad1, pad2;
};
struct alignas(16) GParams {
  uint32_t numA, numB;
  float maxRatio, maxDistance;
  uint32_t guideMode, rowBase;
  float maxResidual;
  uint32_t pad0;
};
static_assert(sizeof(Params) == 32, "Params must be 32 bytes");
static_assert(sizeof(GParams) == 32, "GParams must be 32 bytes");
constexpr uint64_t kRowBaseOffset = 20;  // byte offset of rowBase in both

// ══════════════════════ Dawn context (process-wide) ══════════════════════

enum class Backend { kNone, kMma, kTiled };

// Device-loss / error flags written from Dawn callbacks (possibly other
// threads), read under the call lock.
std::atomic<int> gDeviceLostRc{0};   // 0 alive, else 7/8 classification
std::atomic<int> gErrorType{0};      // last uncaptured wgpu::ErrorType seen
std::atomic<bool> gTearingDown{false};

struct PoolBuf {
  wgpu::Buffer buf;
  uint64_t cap = 0;
  wgpu::BufferUsage usage = wgpu::BufferUsage::None;
};

struct Ctx {
  wgpu::Instance instance;
  wgpu::Adapter adapter;
  wgpu::Device device;
  wgpu::Queue queue;
  Backend backend = Backend::kNone;
  std::string adapter_name;
  std::string backend_info;
  bool feat_subgroups = false, feat_sgmatrix = false, feat_packed_dot = false;
  bool feat_timestamp = false, sgcfg_f32_8x8x8 = false;
  // [MIXED-MMA 2026-09-03] f16 operands with an f32 accumulator — the config
  // Metal's own matcher kernel uses (simdgroup_matrix<half> × <half> into
  // simdgroup_matrix<float>). EXACT for u8 descriptors: u8 ≤ 255 is exact in
  // f16 (11-bit significand), each product ≤ 65,025 and the K=128 sum ≤
  // 262,144 (L2 = 512 ⇒ Cauchy–Schwarz) are exact in f32's 24-bit
  // significand, so no scaling is needed and the dots are bit-identical to
  // the f32 path — at f16 operand rate, with Bsh and the A/B load traffic
  // halved. Dawn's Metal backend did not advertise this config
  // (PhysicalDeviceMTL.mm hardcoded two entries); the vendored tree now does.
  bool sgcfg_f16_f32 = false;
  bool mixed = false;  // use the f16-in/f32-out kernel
  bool packed = false; // 描述子以 packed u8 上传(见 PackedWgsl)
  std::vector<uint16_t> scratch16;
  std::vector<uint8_t> padZero;
  // [TS-GPU 2026-09-03] 真 GPU 时间戳(env OFFICIAL_AETHER_MATCH_DAWN_TSGPU=1)。
  // SubmitAndWait 量的是 submit→done 墙钟,含 CPU 侧排队 —— 机器有背景负载时
  // (实测 HydraRenderingService 常驻 ~96%)括号能飘 2ms,0.5ms 级归因不可做。
  // TimestampQuery 量的是 GPU 执行本身,对 CPU 负载免疫。默认关闭:开启后
  // aether_match_gpu_ms 改由时间戳累加(语义更准),分块成本模型同源受益。
  bool ts_on = false;
  wgpu::QuerySet ts_qset;
  wgpu::Buffer ts_resolve, ts_map;
  uint32_t ts_slot = 0;
  static constexpr uint32_t kTsSlots = 64;
  uint32_t subgroup_min = 0, subgroup_max = 0;
  uint32_t lim_storage = 0, lim_invocations = 0, lim_size_x = 0;
  // Pipelines (lazy; a failed compile is remembered so we do not retry).
  wgpu::ComputePipeline p_main, p_merge, p_guided;
  bool tried_main = false, tried_guided = false;
  // Pools (grow-only).
  PoolBuf a{}, b{}, outAB{}, outBA{}, colp{}, uni{}, staging{}, ptsA{}, ptsB{},
      matAB{}, matBA{};
  PoolBuf pbA{}, pbB{}, pbOutAB{}, pbOutBA{}, pbColp{}, pbUni{}, pbStaging{};
  // Host scratch.
  std::vector<float> scratchA, scratchB;
  std::vector<int32_t> sentinel, host;
  // Cost-model EMAs: ms per (row workgroup × 1024 database columns).
  double ema_main = 0.0;    // fused (MMA) or per-direction (tiled) chunks
  double ema_guided = 0.0;  // guided per-direction chunks
};

std::mutex gMatchCallLock;
std::unique_ptr<Ctx> gCtx;
double gLastInitFailMs = -1e12;
int gInitLogged = 0;

void ClearAllDescriptorResidencyForDeviceError();

std::unique_ptr<Ctx> CreateCtx() {
  auto c = std::make_unique<Ctx>();
  // [DIAG 2026-09-03] OFFICIAL_AETHER_MATCH_DAWN_DUMP=1 → Dawn 的 dump_shaders
  // toggle + 设备日志回调,把 tint 生成的 MSL 打到 stderr。仅主机诊断用,
  // 默认关闭、对运行路径零影响。
  static const char* kAllowT = "allow_unsafe_apis";
  static const char* kDumpT = "dump_shaders";
  // [ROBUSTNESS 2026-09-03] tint 的健壮性代码在 MMA 最内层循环里生成:
  // 每次迭代一次 half 矩阵零填充 + 一次边界检查(实测生成的 MSL:
  // `make_filled_simdgroup_matrix<half,8,8>(0.0h)` + `if (off+128*7+8 <= 4096)`),
  // 而手写 Metal 核是原地 `simdgroup_multiply_accumulate(c, a, b, c)`。
  // 我们的索引**由构造保证在界内**:主机把两张描述子表补齐到 128 行倍数并零填充、
  // outAB 按补齐行数超额分配(见本文件头 Zero-padding invariant),Bsh/accSh 的偏移
  // 由 BT/WGR 常量界定。因此关掉健壮性不改变任何读写目标 —— 逐字节等价由
  // parity 19 案例 + 696 对全量闸 + guided 148 案例实测把关。
  static const char* kNoRobust = "disable_robustness";
  static const char* kNoWgInit = "disable_workgroup_init";
  const bool kWantDump = getenv("OFFICIAL_AETHER_MATCH_DAWN_DUMP") != nullptr;
  const char* allow = kAllowT;
  const char* kDbgToggles[2] = {kAllowT, kDumpT};
  wgpu::DawnTogglesDescriptor toggles{};
  toggles.enabledToggleCount = kWantDump ? 2 : 1;
  toggles.enabledToggles = kWantDump ? kDbgToggles : &allow;
  const wgpu::InstanceFeatureName timed = wgpu::InstanceFeatureName::TimedWaitAny;
  wgpu::InstanceDescriptor idesc{};
  idesc.nextInChain = &toggles;
  idesc.requiredFeatureCount = 1;
  idesc.requiredFeatures = &timed;
  c->instance = wgpu::CreateInstance(&idesc);
  if (!c->instance) {
    Log("instance creation failed (TimedWaitAny unavailable?)");
    return nullptr;
  }
  c->feat_packed_dot = c->instance.HasWGSLLanguageFeature(
      wgpu::WGSLLanguageFeatureName::Packed4x8IntegerDotProduct);

  wgpu::RequestAdapterOptions aopts{};
  std::string amsg;
  c->instance.WaitAny(
      c->instance.RequestAdapter(
          &aopts, wgpu::CallbackMode::WaitAnyOnly,
          [&](wgpu::RequestAdapterStatus st, wgpu::Adapter a,
              wgpu::StringView m) {
            if (st == wgpu::RequestAdapterStatus::Success) {
              c->adapter = std::move(a);
            } else {
              amsg = SV(m);
            }
          }),
      UINT64_MAX);
  if (!c->adapter) {
    Log("no adapter: %s", amsg.c_str());
    return nullptr;
  }
  c->feat_subgroups = c->adapter.HasFeature(wgpu::FeatureName::Subgroups);
  c->feat_sgmatrix = c->adapter.HasFeature(
      wgpu::FeatureName::ChromiumExperimentalSubgroupMatrix);
  c->feat_timestamp = c->adapter.HasFeature(wgpu::FeatureName::TimestampQuery);
  {
    wgpu::AdapterInfo info{};
    wgpu::AdapterPropertiesSubgroupMatrixConfigs cfgs{};
    if (c->feat_sgmatrix) info.nextInChain = &cfgs;
    c->adapter.GetInfo(&info);
    c->adapter_name = SV(info.device);
    c->subgroup_min = info.subgroupMinSize;
    c->subgroup_max = info.subgroupMaxSize;
    if (c->feat_sgmatrix) {
      for (size_t i = 0; i < cfgs.configCount; ++i) {
        const wgpu::SubgroupMatrixConfig& k = cfgs.configs[i];
        if (k.componentType == wgpu::SubgroupMatrixComponentType::F16 &&
            k.resultComponentType == wgpu::SubgroupMatrixComponentType::F32 &&
            k.M == 8 && k.N == 8 && k.K == 8) {
          c->sgcfg_f16_f32 = true;
        }
        if (k.componentType == wgpu::SubgroupMatrixComponentType::F32 &&
            k.resultComponentType == wgpu::SubgroupMatrixComponentType::F32 &&
            k.M == 8 && k.N == 8 && k.K == 8) {
          c->sgcfg_f32_8x8x8 = true;
        }
      }
    }
  }
  wgpu::Limits alim{};
  c->adapter.GetLimits(&alim);
  c->lim_storage = alim.maxComputeWorkgroupStorageSize;
  c->lim_invocations = alim.maxComputeInvocationsPerWorkgroup;
  c->lim_size_x = alim.maxComputeWorkgroupSizeX;

  const char* force = getenv("OFFICIAL_AETHER_MATCH_DAWN_KERNEL");
  const bool want_mma = !(force && std::strcmp(force, "tiled") == 0);
  // [ONE-PIPELINE 2026-09-04] 混合精度(f16 操作数 + f32 累加器)是 **默认**:
  // 它逐字节等价于 f32 路径(u8 在 f16 中精确;逐积 ≤65,025、K=128 总和 ≤262,144
  // 均在 f32 的 24 位尾数内精确),主机实测 −11.4%(关健壮性后仍成立,交替 3 轮全胜)。
  // 配置不可用时(未打补丁的 Dawn / 不支持的 GPU)自动退回 f32 —— 输出不变,只是慢些。
  // env OFFICIAL_AETHER_MATCH_DAWN_KERNEL=plain 可强制 f32 做单变量 A/B。
  const bool want_mixed = !(force && std::strcmp(force, "plain") == 0);
  const bool mma_ok = c->feat_subgroups && c->feat_sgmatrix &&
                      c->sgcfg_f32_8x8x8 && c->subgroup_min == 32 &&
                      c->subgroup_max == 32 && c->lim_invocations >= 512 &&
                      c->lim_size_x >= 512 && c->lim_storage >= 32768;
  std::vector<wgpu::FeatureName> feats;
  wgpu::Limits req{};
  wgpu::DeviceDescriptor dd{};
  if (want_mma && mma_ok) {
    c->backend = Backend::kMma;
    feats.push_back(wgpu::FeatureName::Subgroups);
    feats.push_back(wgpu::FeatureName::ChromiumExperimentalSubgroupMatrix);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_TSGPU") && c->feat_timestamp) {
      c->ts_on = true;
      feats.push_back(wgpu::FeatureName::TimestampQuery);
    }
    if (want_mixed && c->sgcfg_f16_f32 && c->adapter.HasFeature(wgpu::FeatureName::ShaderF16)) {
      c->mixed = true;
      c->packed = getenv("OFFICIAL_AETHER_MATCH_DAWN_UNPACKED") == nullptr;
      feats.push_back(wgpu::FeatureName::ShaderF16);
    }
    req.maxComputeWorkgroupStorageSize = alim.maxComputeWorkgroupStorageSize;
    req.maxComputeInvocationsPerWorkgroup =
        alim.maxComputeInvocationsPerWorkgroup;
    req.maxComputeWorkgroupSizeX = alim.maxComputeWorkgroupSizeX;
    dd.requiredLimits = &req;
  } else {
    c->backend = Backend::kTiled;
  }
  dd.requiredFeatureCount = feats.size();
  dd.requiredFeatures = feats.empty() ? nullptr : feats.data();
  // dump_shaders 是**设备级** toggle(Toggles.cpp: ToggleStage::Device),
  // 必须挂在 DeviceDescriptor 上,挂实例无效。
  // 设备级 toggles:健壮性开关(env 可关闭以做单变量 A/B)+ 诊断 dump。
  const bool no_robust = getenv("OFFICIAL_AETHER_MATCH_DAWN_ROBUST") == nullptr;
  std::vector<const char*> dtoggles;
  if (no_robust) {
    dtoggles.push_back(kNoRobust);
    dtoggles.push_back(kNoWgInit);
  }
  if (kWantDump) dtoggles.push_back(kDumpT);
  wgpu::DawnTogglesDescriptor dtog{};
  if (!dtoggles.empty()) {
    dtog.enabledToggleCount = dtoggles.size();
    dtog.enabledToggles = dtoggles.data();
    dd.nextInChain = &dtog;
  }
  dd.SetDeviceLostCallback(
      wgpu::CallbackMode::AllowSpontaneous,
      [](const wgpu::Device&, wgpu::DeviceLostReason reason,
         wgpu::StringView message) {
        if (gTearingDown.load()) return;
        const int rc = (reason == wgpu::DeviceLostReason::Destroyed ||
                        reason == wgpu::DeviceLostReason::FailedCreation)
                           ? 8
                           : 7;
        gDeviceLostRc.store(rc);
        const std::string m = SV(message);
        static std::atomic<long> gLostCount{0};
        const long k = ++gLostCount;
        if (k <= 5 || (k % 100) == 0) {
          Log("device lost #%ld reason=%u rc=%d: %s", k, (unsigned)reason, rc,
              m.c_str());
        }
        StashLastError(std::string("DawnDeviceLost reason=") +
                       std::to_string((unsigned)reason) + " " + m);
      });
  dd.SetUncapturedErrorCallback(
      [](const wgpu::Device&, wgpu::ErrorType type, wgpu::StringView message) {
        gErrorType.store((int)type);
        const std::string m = SV(message);
        static std::atomic<long> gErrCount{0};
        const long k = ++gErrCount;
        if (k <= 5 || (k % 100) == 0) {
          Log("uncaptured error #%ld type=%u: %s", k, (unsigned)type, m.c_str());
        }
        StashLastError(std::string("DawnError type=") +
                       std::to_string((unsigned)type) + " " + m);
      });
  std::string dmsg;
  c->instance.WaitAny(
      c->adapter.RequestDevice(
          &dd, wgpu::CallbackMode::WaitAnyOnly,
          [&](wgpu::RequestDeviceStatus st, wgpu::Device d, wgpu::StringView m) {
            if (st == wgpu::RequestDeviceStatus::Success) {
              c->device = std::move(d);
            } else {
              dmsg = SV(m);
            }
          }),
      UINT64_MAX);
  if (!c->device) {
    Log("device creation failed: %s", dmsg.c_str());
    return nullptr;
  }
  if (kWantDump) {
    // 诊断:把 dump_shaders 的输出(生成的 MSL)接到 stderr。
    c->device.SetLoggingCallback(
        [](wgpu::LoggingType, wgpu::StringView msg) {
          std::fprintf(stderr, "%.*s\n", (int)msg.length, msg.data);
        });
  }
  c->queue = c->device.GetQueue();
  gDeviceLostRc.store(0);
  gErrorType.store(0);
  char info[512];
  std::snprintf(info, sizeof(info),
                "backend=%s adapter=\"%s\" subgroups=%d sgmatrix=%d "
                "f32_8x8x8=%d f16_f32=%d mixed=%d subgroup=[%u,%u] packed_dot=%d timestamp=%d "
                "limits[storage=%u invocations=%u sizeX=%u]%s",
                c->backend == Backend::kMma ? "mma(fusedr128-db,V0)"
                                            : "tiled(dot4U8Packed,V1/V2)",
                c->adapter_name.c_str(), (int)c->feat_subgroups,
                (int)c->feat_sgmatrix, (int)c->sgcfg_f32_8x8x8,
                (int)c->sgcfg_f16_f32, (int)c->mixed, c->subgroup_min,
                c->subgroup_max, (int)c->feat_packed_dot, (int)c->feat_timestamp,
                c->lim_storage, c->lim_invocations, c->lim_size_x,
                (force && std::strcmp(force, "tiled") == 0) ? " (forced tiled)"
                                                            : "");
  c->backend_info = info;
  if (gInitLogged < 3) {
    ++gInitLogged;
    Log("%s", info);
  }
  return c;
}

// Whole-process context, created once; torn down and recreated (bounded by
// a 250 ms cooldown) after a device loss.
Ctx* EnsureDawn() {
  if (gCtx && gDeviceLostRc.load() != 0) {
    ClearAllDescriptorResidencyForDeviceError();
    gTearingDown.store(true);
    gCtx.reset();
    gTearingDown.store(false);
    gDeviceLostRc.store(0);
  }
  if (gCtx) return gCtx.get();
  const double now = NowMs();
  if (now - gLastInitFailMs < 250.0) return nullptr;
  gCtx = CreateCtx();
  if (!gCtx) gLastInitFailMs = now;
  return gCtx.get();
}

// ── Shader / pipeline helpers ────────────────────────────────────────────
// Derives the f16-operand / f32-accumulator variant from the single WGSL
// source of truth: only the operand types change. The accumulator (Res),
// accSh, the gate math and the tie-break order are untouched, so the dots
// stay exact (see Ctx::sgcfg_f16_f32) and the output is bit-identical.
// [COLP-TRANSPOSE 2026-09-04] ColP 布局 c-major → rb-major。
// 机制(由 COL-SCAN-4x 实验的变量分解逼出来的):ColP 写在
//   `ColP[c * U.numWg + rb]` —— 一个 lane 组里相邻 lane 的 c 相邻,地址间隔
//   numWg*12 = 768B ⇒ **32 条 lane 命中 32 条不同缓存行**,纯散射写。
//   merge 核读 `ColP[c*U.numWg + w]` 同样散射(相邻 gid.x 间隔 768B)。
// 转置成 `ColP[rb * U.numB + c]` 后两侧都变连续:32 lane × 12B = 384B ≈ 6 行。
// 量化依据:把 partial 数 ×4 使这条流量 ×4,实测 +1.2ms(已扣除预取线程的
//   +0.2ms)⇒ 这条散射流量在 1× 时约值 0.4ms,占总时长 5%。
// 缓冲区大小不变(numWg*numB 项),merge 的遍历顺序不变(w 升序 = 行号升序)
//   ⇒ 「平局取最小行号」逐字保留,输出必须逐字节相同。
// env OFFICIAL_AETHER_MATCH_DAWN_COLPC=1 回到 c-major 做单变量 A/B。
// [NOSCAN-PROBE 2026-09-04] 计时探针(输出作废,只为定价):把两个 top-2 扫描
// 循环截断到 1 次迭代,保留全部 barrier / 预取 / ColP 写 / MMA。
// 差值 = 扫描阶段的真实成本。起因:COL-SCAN-4x 把列扫描迭代 128→32 却零收益,
// 与"扫描阶段 = 128 次迭代长"的模型冲突 ⇒ 先给这个阶段定价再决定要不要重写。
// [BARRIER-PRICE-PROBE 2026-09-04] 计时探针:每块**多加** N 次 workgroupBarrier。
// 删 barrier 会产生竞态、被 harness 的跨 rep 确定性闸拦下(闸是对的);加 barrier
// 不改语义,输出仍逐字节相同,**斜率 = 单次 barrier 的价格**。
// 起因:扫描只值 0.86ms、MMA 约 4.3ms(roofline 86%),余下 ~2.6ms 需要定位;
// Metal v2 每块只有 1 次 threadgroup barrier + 1 次近乎免费的 simdgroup_barrier。
// [STAGE0-PROBE 2026-09-04] 计时探针(输出错但确定,能过跨 rep 确定性闸):
// 预取永远读第 0 块 ⇒ 同样的 8KB 反复命中缓存,差值 = 预取的真实内存成本。
// 记账进度:总 7.8ms = MMA ~4.3(roofline 86%)+ 扫描 0.86 + barrier 0.2 + ?2.4
std::string Stage0Wgsl(const std::string& src) {
  std::string t = src;
  const std::string from = "        let brow = nextT + e / 128u;";
  const size_t p = t.find(from);
  if (p == std::string::npos) return src;
  t.replace(p, from.size(), "        let brow = e / 128u;");
  return t;
}

std::string ExtraBarrierWgsl(const std::string& src, int n) {
  std::string t = src;
  const std::string from =
      "      subgroupMatrixStore(&accSh, (sg * 8u) * 32u + nt * 8u, acc, false, 32u);\n"
      "    }\n"
      "    workgroupBarrier();\n";
  const size_t p = t.find(from);
  if (p == std::string::npos) return src;
  (void)p;
  // 相邻同种 barrier 会被 Metal 编译器合并(实测 +4 相邻 = 零代价)⇒ 必须放到
  // 被 MMA 工作隔开的程序点上:nt 循环每轮末尾加一次(nt 循环对全部 512 线程一致)。
  std::string one =
      "      subgroupMatrixStore(&accSh, (sg * 8u) * 32u + nt * 8u, acc, false, 32u);\n";
  const size_t q = t.find(one);
  if (q == std::string::npos) return src;
  std::string add = one;
  for (int i = 0; i < n; ++i) add += "      workgroupBarrier();\n";
  t.replace(q, one.size(), add);
  return t;
}

std::string NoScanWgsl(const std::string& src) {
  std::string t = src;
  auto rep = [&t](const std::string& from, const std::string& to) {
    const size_t p = t.find(from);
    if (p == std::string::npos) return false;
    t.replace(p, from.size(), to);
    return true;
  };
  bool ok = true;
  ok &= rep("      for (var c = 0u; c < lim; c = c + 1u) {",
            "      for (var c = 0u; c < min(lim, 1u); c = c + 1u) {");
  ok &= rep("        for (var r = 0u; r < WGR; r = r + 1u) {",
            "        for (var r = 0u; r < 1u; r = r + 1u) {");
  if (!ok) return src;
  return t;
}

// [PACKED-DESC 2026-09-04] mma+mixed 档的描述子改为 packed u8(每个 u32 装 4 个),
// 复刻出货 Metal 核 pw_match_gemm2 的 kPacked 分支。
// 定价(隔离测量,不是估的):现役 upload_p50=0.653ms,其中 CPU 侧 u8→f16 转换
//   只占 0.144ms(1M 元素 ×2),其余 0.51ms 是 4MB WriteBuffer 本身。
//   packed 两头都省:转换消失 + 传输 4MB→2MB ⇒ 预计 upload → ~0.26ms。
// A 与 B 缓冲被 plain 核和 guided 核共用,且两边取数行逐字相同 ⇒ 一个变换覆盖两者。
// B:预取时解包(Bsh 仍是 f16),循环上界 BT*128 → BT*32,每次迭代写 4 个 half。
// A:subgroupMatrixLoad 要求内存里就是 f16 ⇒ 照 Metal 的做法先解包进 Bsh 的一个
//   象限,4 轮 × 4 个 SG(Bsh 4096 half = 4 象限 × 1024)。lane 用 lid % 32 算,
//   免得给 guided 核加 builtin 参数。
std::string PackedWgsl(const std::string& src) {
  std::string t = src;
  auto rep_all = [&t](const std::string& from, const std::string& to) {
    size_t p = 0; int n = 0;
    while ((p = t.find(from, p)) != std::string::npos) {
      t.replace(p, from.size(), to);
      p += to.size();
      ++n;
    }
    return n;
  };
  auto rep = [&t](const std::string& from, const std::string& to) {
    const size_t p = t.find(from);
    if (p == std::string::npos) return false;
    t.replace(p, from.size(), to);
    return true;
  };
  bool ok = true;
  ok &= rep("var<storage, read> A : array<f16>", "var<storage, read> A : array<u32>");
  ok &= rep("var<storage, read> B : array<f16>", "var<storage, read> B : array<u32>");
  // B 预取:上界与解包(fused 初始 / fused 双缓冲 / shape 顶部,三处同形)
  ok &= (rep_all("e < BT * 128u", "e < BT * 32u") > 0);
  ok &= (rep_all(
             "      Bsh[e] = select(f16(0.0), B[brow * 128u + (e % 128u)], brow < U.numB);",
             "      let pu = select(0u, B[brow * 32u + (e % 32u)], brow < U.numB);\n"
             "      let po = (e / 32u) * 128u + (e % 32u) * 4u;\n"
             "      Bsh[po] = f16(pu & 255u);\n"
             "      Bsh[po + 1u] = f16((pu >> 8u) & 255u);\n"
             "      Bsh[po + 2u] = f16((pu >> 16u) & 255u);\n"
             "      Bsh[po + 3u] = f16(pu >> 24u);") > 0);
  ok &= (rep_all("        Bsh[e] = select(f16(0.0), B[brow * 128u + (e % 128u)], brow < U.numB);",
             "        let pu = select(0u, B[brow * 32u + (e % 32u)], brow < U.numB);\n"
             "        let po = (e / 32u) * 128u + (e % 32u) * 4u;\n"
             "        Bsh[po] = f16(pu & 255u);\n"
             "        Bsh[po + 1u] = f16((pu >> 8u) & 255u);\n"
             "        Bsh[po + 2u] = f16((pu >> 16u) & 255u);\n"
             "        Bsh[po + 3u] = f16(pu >> 24u);") >= 0);
  ok &= (rep_all("      let brow = 0u + e / 128u;", "      let brow = 0u + e / 32u;") >= 0);
  ok &= (rep_all("      let brow = col0 + e / 128u;", "      let brow = col0 + e / 32u;") >= 0);
  ok &= (rep_all("        let brow = nextT + e / 128u;", "        let brow = nextT + e / 32u;") >= 0);
  // A:解包进 Bsh 象限后再取 fragment(Metal kPacked 的 4 轮 dance 同款)
  ok &= (rep_all(
             "  var aFrag : array<Left, 16>;\n"
             "  for (var k = 0u; k < 16u; k = k + 1u) {\n"
             "    aFrag[k] = subgroupMatrixLoad<Left>(&A, aRow0 * 128u + k * 8u, false, 128u);\n"
             "  }",
             "  var aFrag : array<Left, 16>;\n"
             "  {\n"
             "    let pwv = sg >> 2u;\n"
             "    let pq = (sg & 3u) * 1024u;\n"
             "    let plane = lid % 32u;\n"
             "    for (var w = 0u; w < 4u; w = w + 1u) {\n"
             "      if (w == pwv) {\n"
             "        for (var e = plane; e < 256u; e = e + 32u) {\n"
             "          let u = A[aRow0 * 32u + e];\n"
             "          let o = pq + e * 4u;\n"
             "          Bsh[o] = f16(u & 255u);\n"
             "          Bsh[o + 1u] = f16((u >> 8u) & 255u);\n"
             "          Bsh[o + 2u] = f16((u >> 16u) & 255u);\n"
             "          Bsh[o + 3u] = f16(u >> 24u);\n"
             "        }\n"
             "      }\n"
             "      workgroupBarrier();\n"
             "      if (w == pwv) {\n"
             "        for (var k = 0u; k < 16u; k = k + 1u) {\n"
             "          aFrag[k] = subgroupMatrixLoad<Left>(&Bsh, pq + k * 8u, false, 128u);\n"
             "        }\n"
             "      }\n"
             "      workgroupBarrier();\n"
             "    }\n"
             "  }") > 0);
  if (!ok) return src;
  return t;
}

std::string ColpTransposeWgsl(const std::string& src) {
  std::string t = src;
  auto rep = [&t](const std::string& from, const std::string& to) {
    const size_t p = t.find(from);
    if (p == std::string::npos) return false;
    t.replace(p, from.size(), to);
    return true;
  };
  bool ok = true;
  ok &= rep("        ColP[c * U.numWg + rb] = ColPart(best, second, bi);",
            "        ColP[rb * U.numB + c] = ColPart(best, second, bi);");
  ok &= rep("    let p = ColP[c * U.numWg + w];",
            "    let p = ColP[w * U.numB + c];");
  if (!ok) return src;
  return t;
}

std::string MixedWgsl(const char* src) {
  std::string t(src);
  auto sub = [&t](const std::string& from, const std::string& to) {
    for (size_t p = t.find(from); p != std::string::npos;
         p = t.find(from, p + to.size())) {
      t.replace(p, from.size(), to);
    }
  };
  sub("enable subgroups;", "enable subgroups;\nenable f16;");
  sub("subgroup_matrix_left<f32", "subgroup_matrix_left<f16");
  sub("subgroup_matrix_right<f32", "subgroup_matrix_right<f16");
  sub("var<storage, read> A : array<f32>", "var<storage, read> A : array<f16>");
  sub("var<storage, read> B : array<f32>", "var<storage, read> B : array<f16>");
  sub("var<workgroup> Bsh : array<f32,", "var<workgroup> Bsh : array<f16,");
  sub("select(0.0, B[", "select(f16(0.0), B[");
  return t;
}

wgpu::ShaderModule CompileWgsl(Ctx& c, const std::string& src,
                               const char* what) {
  wgpu::ShaderSourceWGSL s{};
  s.code = src.c_str();
  wgpu::ShaderModuleDescriptor d{};
  d.nextInChain = &s;
  wgpu::ShaderModule m = c.device.CreateShaderModule(&d);
  if (!m) return nullptr;
  bool ok = true;
  std::string err;
  c.instance.WaitAny(
      m.GetCompilationInfo(
          wgpu::CallbackMode::WaitAnyOnly,
          [&](wgpu::CompilationInfoRequestStatus,
              const wgpu::CompilationInfo* ci) {
            if (!ci) return;
            for (size_t i = 0; i < ci->messageCount; ++i) {
              if (ci->messages[i].type == wgpu::CompilationMessageType::Error) {
                ok = false;
                if (err.size() < 400) {
                  err += SV(ci->messages[i].message);
                  err += " | ";
                }
              }
            }
          }),
      UINT64_MAX);
  if (!ok) {
    Log("WGSL compile failed (%s): %s", what, err.c_str());
    StashLastError(std::string("WGSL compile failed: ") + what);
    return nullptr;
  }
  return m;
}

wgpu::ComputePipeline MakePipeline(Ctx& c, wgpu::ShaderModule m,
                                   const char* entry) {
  wgpu::ComputePipelineDescriptor pd{};
  pd.compute.module = m;
  pd.compute.entryPoint = entry;
  return c.device.CreateComputePipeline(&pd);
}

bool EnsureMainPipelines(Ctx& c) {
  if (c.p_main && (c.backend != Backend::kMma || c.p_merge)) return true;
  if (c.tried_main) return false;
  c.tried_main = true;
  if (c.backend == Backend::kMma) {
    // 四道门全绿(parity / 162 / 534 / ABI)后 09-04 翻默认。
    // OFFICIAL_AETHER_MATCH_DAWN_OLDSHAPE=1 回到旧核做单变量 A/B。
    const bool shape = c.mixed &&
                       getenv("OFFICIAL_AETHER_MATCH_DAWN_OLDSHAPE") == nullptr;
    std::string mixed_src =
        c.mixed ? MixedWgsl(shape ? kWgslMmaMetalShape : kWgslMmaFused)
                : std::string();
    if (c.mixed && !shape &&
        getenv("OFFICIAL_AETHER_MATCH_DAWN_COLPC") == nullptr) {
      mixed_src = ColpTransposeWgsl(mixed_src);  // 新核已是 rb-major,不重复转置
    }
    if (c.packed) mixed_src = PackedWgsl(mixed_src);
    if (c.mixed && getenv("OFFICIAL_AETHER_MATCH_DAWN_NOSCAN") != nullptr) {
      mixed_src = NoScanWgsl(mixed_src);
    }
    if (c.mixed && getenv("OFFICIAL_AETHER_MATCH_DAWN_STAGE0") != nullptr) {
      mixed_src = Stage0Wgsl(mixed_src);
    }
    if (const char* nb = getenv("OFFICIAL_AETHER_MATCH_DAWN_XBARRIER")) {
      if (c.mixed) mixed_src = ExtraBarrierWgsl(mixed_src, atoi(nb));
    }
    // 默认关闭:逐字节已验(984 匹配、SHA 同),但收益尚未在干净窗口测得
    // (测时机器有 WeChat ~50% + WindowServer 26%,1 线程臂离散 3.8ms > 信号)。
    // 纪律:未测得收益的改动不进默认路径。OFFICIAL_AETHER_MATCH_DAWN_SCAN2=1 启用。

    wgpu::ShaderModule m = CompileWgsl(
        c, c.mixed ? mixed_src.c_str() : kWgslMmaFused,
        c.mixed ? "mma fused mixed" : "mma fused");
    if (!m) return false;
    c.p_main = MakePipeline(c, m, "main");
    c.p_merge = MakePipeline(c, m, "merge");
    return c.p_main && c.p_merge;
  }
  wgpu::ShaderModule m = CompileWgsl(c, kWgslTiledPlain, "tiled plain");
  if (!m) return false;
  c.p_main = MakePipeline(c, m, "main");
  return (bool)c.p_main;
}

bool EnsureGuidedPipeline(Ctx& c) {
  if (c.p_guided) return true;
  if (c.tried_guided) return false;
  c.tried_guided = true;
  std::string src;
  if (c.backend == Backend::kMma) {
    src = std::string(kWgslMmaGuidedHead) + kWgslGuidedCommon +
          kWgslMmaGuidedBindings + kWgslMmaGuidedMain;
  } else {
    src = std::string(kWgslTiledGuidedHead) + kWgslGuidedCommon +
          kWgslTiledGuidedBindings + kWgslTiledGuidedMain;
  }
  // The GParams struct must precede the U binding and guide_ok must see M/U:
  // WGSL resolves module-scope declarations in any order, so concatenation
  // order only needs to be syntactically valid.
  // Mixed mode uploads the descriptor tables as f16, so the guided kernels
  // must read them as f16 too (the guide matrix M and the residual math stay
  // f32). Without this the guided path reads f16 bytes as f32 and returns 0
  // matches — caught by the ABI test's guided mode2 identity case.
  if (c.mixed) src = MixedWgsl(src.c_str());
  if (c.packed) src = PackedWgsl(src);
  wgpu::ShaderModule m = CompileWgsl(c, src, c.mixed ? "guided mixed" : "guided");
  if (!m) return false;
  c.p_guided = MakePipeline(c, m, "main");
  return (bool)c.p_guided;
}

// ── Buffers ──────────────────────────────────────────────────────────────
wgpu::Buffer PoolGet(Ctx& c, PoolBuf& p, uint64_t need,
                     wgpu::BufferUsage usage) {
  need = RoundUp(std::max<uint64_t>(need, 16), kSlot);
  if (!p.buf || p.cap < need || p.usage != usage) {
    if (p.buf) p.buf.Destroy();
    wgpu::BufferDescriptor d{};
    d.usage = usage;
    d.size = need;
    p.buf = c.device.CreateBuffer(&d);
    p.usage = usage;
    p.cap = p.buf ? need : 0;
  }
  return p.buf;
}

constexpr wgpu::BufferUsage kUsageDesc =
    wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst;
constexpr wgpu::BufferUsage kUsageOut = wgpu::BufferUsage::Storage |
                                        wgpu::BufferUsage::CopyDst |
                                        wgpu::BufferUsage::CopySrc;
constexpr wgpu::BufferUsage kUsageColp = wgpu::BufferUsage::Storage;
constexpr wgpu::BufferUsage kUsageUni =
    wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst;
constexpr wgpu::BufferUsage kUsageStaging =
    wgpu::BufferUsage::MapRead | wgpu::BufferUsage::CopyDst;

// Bytes of one descriptor table in the active kernel's storage format.
uint64_t DescBytes(const Ctx& c, uint32_t n, uint32_t npad) {
  if (c.backend != Backend::kMma) return (uint64_t)n * kD;
  if (c.packed) return (uint64_t)npad * kD;  // u8;npad*128 恒为 4 的倍数
  return (uint64_t)npad * kD * (c.mixed ? sizeof(uint16_t) : sizeof(float));
}

// Uploads n descriptor rows at byte offset off (MMA: u8→f32 expansion into a
// zero-filled npad-row table — the per-call u8→half conversion of the Metal
// TU, exact; tiled: raw u8 rows, the kernel guards rows itself).
void UploadDesc(Ctx& c, wgpu::Buffer buf, uint64_t off, const uint8_t* d,
                uint32_t n, uint32_t npad, std::vector<float>& scratch) {
  if (c.backend == Backend::kMma && c.packed) {
    // 原样传 u8,零 CPU 转换;补位行必须显式清零(A 的补位行会被 aFrag 直接读走)。
    c.queue.WriteBuffer(buf, off, d, (uint64_t)n * kD);
    if (npad > n) {
      const size_t padBytes = (size_t)(npad - n) * kD;
      if (c.padZero.size() < padBytes) c.padZero.assign(padBytes, 0);
      c.queue.WriteBuffer(buf, off + (uint64_t)n * kD, c.padZero.data(), padBytes);
    }
    return;
  }
  if (c.backend == Backend::kMma && c.mixed) {
    // u8 → f16, EXACT (no scaling): every u8 value is representable in f16.
    c.scratch16.assign((size_t)npad * kD, 0);
    const size_t live16 = (size_t)n * kD;
    for (size_t i = 0; i < live16; ++i) {
      const _Float16 v = (_Float16)(float)d[i];
      uint16_t bits;
      std::memcpy(&bits, &v, sizeof(bits));
      c.scratch16[i] = bits;
    }
    c.queue.WriteBuffer(buf, off,
                        reinterpret_cast<const uint8_t*>(c.scratch16.data()),
                        (uint64_t)npad * kD * sizeof(uint16_t));
    return;
  }
  if (c.backend == Backend::kMma) {
    scratch.assign((size_t)npad * kD, 0.0f);
    const size_t live = (size_t)n * kD;
    for (size_t i = 0; i < live; ++i) scratch[i] = (float)d[i];
    c.queue.WriteBuffer(buf, off, reinterpret_cast<const uint8_t*>(scratch.data()),
                        (uint64_t)npad * kD * sizeof(float));
  } else {
    c.queue.WriteBuffer(buf, off, d, (uint64_t)n * kD);
  }
}

void FillSentinel(Ctx& c, wgpu::Buffer buf, uint64_t off, uint32_t n) {
  if (c.sentinel.size() < n) c.sentinel.assign(n, kOutSentinel);
  c.queue.WriteBuffer(buf, off, reinterpret_cast<const uint8_t*>(c.sentinel.data()),
                      (uint64_t)n * sizeof(int32_t));
}

wgpu::BindGroupEntry BE(uint32_t binding, wgpu::Buffer b, uint64_t off,
                        uint64_t size) {
  wgpu::BindGroupEntry e{};
  e.binding = binding;
  e.buffer = b;
  e.offset = off;
  e.size = size;
  return e;
}

wgpu::BindGroup MakeBG(Ctx& c, const wgpu::ComputePipeline& p,
                       const std::vector<wgpu::BindGroupEntry>& entries) {
  wgpu::BindGroupDescriptor d{};
  d.layout = p.GetBindGroupLayout(0);
  d.entryCount = entries.size();
  d.entries = entries.data();
  return c.device.CreateBindGroup(&d);
}

// ── Submission with the bounded watchdog ─────────────────────────────────
int WaitFuture(Ctx& c, wgpu::Future f, const char* what) {
  const uint64_t ms = CmdWaitTimeoutMs();
  const wgpu::WaitStatus ws = c.instance.WaitAny(f, ms * 1000000ull);
  if (ws == wgpu::WaitStatus::TimedOut) {
    static std::atomic<long> gTimeoutCount{0};
    const long k = ++gTimeoutCount;
    if (k <= 5 || (k % 100) == 0) {
      Log("%s wait TIMEOUT #%ld after %llu ms (rc=7)", what, k,
          (unsigned long long)ms);
    }
    StashLastError(std::string("host-side wait timeout after ") +
                   std::to_string((unsigned long long)ms) + " ms (" + what + ")");
    ClearAllDescriptorResidencyForDeviceError();
    return 7;
  }
  if (ws != wgpu::WaitStatus::Success) {
    StashLastError(std::string("WaitAny error (") + what + ")");
    return 7;
  }
  return 0;
}

// Submits one command buffer and waits for completion. *gpu_ms receives the
// submit→done wall window (the cost model's unit; Dawn exposes no per-buffer
// GPU timestamps without a query-set round trip).
int SubmitAndWait(Ctx& c, wgpu::CommandBuffer cb, double* gpu_ms) {
  gErrorType.store(0);
  const double t0 = NowMs();
  c.queue.Submit(1, &cb);
  wgpu::QueueWorkDoneStatus st = wgpu::QueueWorkDoneStatus::Error;
  wgpu::Future f = c.queue.OnSubmittedWorkDone(
      wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::QueueWorkDoneStatus s, wgpu::StringView) { st = s; });
  const int rc = WaitFuture(c, f, "submit");
  if (gpu_ms) *gpu_ms = NowMs() - t0;
  if (rc != 0) return rc;
  const int lost = gDeviceLostRc.load();
  if (lost != 0) {
    ClearAllDescriptorResidencyForDeviceError();
    return lost;
  }
  if (st != wgpu::QueueWorkDoneStatus::Success) {
    static std::atomic<long> gCmdErrCount{0};
    const long k = ++gCmdErrCount;
    if (k <= 5 || (k % 100) == 0) {
      Log("queue work done status=%u (rc=7) #%ld", (unsigned)st, k);
    }
    StashLastError("OnSubmittedWorkDone status != Success");
    ClearAllDescriptorResidencyForDeviceError();
    return 7;
  }
  const int et = gErrorType.load();
  if (et != 0) {
    return et == (int)wgpu::ErrorType::OutOfMemory ? 5 : 7;
  }
  return 0;
}

int ReadbackStaging(Ctx& c, wgpu::Buffer staging, uint64_t bytes, void* dst) {
  bool mapped = false;
  std::string msg;
  wgpu::Future f = staging.MapAsync(
      wgpu::MapMode::Read, 0, (size_t)bytes, wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::MapAsyncStatus s, wgpu::StringView m) {
        mapped = s == wgpu::MapAsyncStatus::Success;
        if (!mapped) msg = SV(m);
      });
  const int rc = WaitFuture(c, f, "map");
  if (rc != 0) return rc;
  if (!mapped) {
    StashLastError("MapAsync failed: " + msg);
    return 7;
  }
  const void* p = staging.GetConstMappedRange(0, (size_t)bytes);
  if (!p) {
    staging.Unmap();
    StashLastError("GetConstMappedRange returned null");
    return 7;
  }
  std::memcpy(dst, p, (size_t)bytes);
  staging.Unmap();
  return 0;
}

// ── KNIFE-C chunked runner (generic over stages) ─────────────────────────
// A stage is one row-chunkable dispatch family: MMA fused (one stage) or
// tiled per-direction (two stages). rowBase for a chunk is written into the
// stage's uniform slot right before the submit (queue-ordered, serial).
struct Stage {
  uint32_t total_groups = 0;
  uint32_t nDb = 0;  // database columns (cost-model scale)
  wgpu::Buffer uni;
  uint64_t uniOff = 0;
  std::function<void(wgpu::ComputePassEncoder&, uint32_t, uint32_t)> encode;
};

// 惰性创建时间戳资源(仅 ts_on 时)。槽位循环使用,读回在整对结束时一次完成。
void TsEnsure(Ctx& c) {
  if (!c.ts_on || c.ts_qset) return;
  wgpu::QuerySetDescriptor qd{};
  qd.type = wgpu::QueryType::Timestamp;
  qd.count = Ctx::kTsSlots;
  c.ts_qset = c.device.CreateQuerySet(&qd);
  wgpu::BufferDescriptor rd{};
  rd.usage = wgpu::BufferUsage::QueryResolve | wgpu::BufferUsage::CopySrc;
  rd.size = (uint64_t)Ctx::kTsSlots * 8;
  c.ts_resolve = c.device.CreateBuffer(&rd);
  wgpu::BufferDescriptor md{};
  md.usage = wgpu::BufferUsage::MapRead | wgpu::BufferUsage::CopyDst;
  md.size = rd.size;
  c.ts_map = c.device.CreateBuffer(&md);
}

// 开一个带首尾时间戳的 compute pass(ts_on 关闭时退化为普通 pass)。
wgpu::ComputePassEncoder BeginPassTs(Ctx& c, wgpu::CommandEncoder& enc) {
  if (!c.ts_on) return enc.BeginComputePass();
  TsEnsure(c);
  if (c.ts_slot + 2 > Ctx::kTsSlots) return enc.BeginComputePass();
  wgpu::PassTimestampWrites tw{};
  tw.querySet = c.ts_qset;
  tw.beginningOfPassWriteIndex = c.ts_slot;
  tw.endOfPassWriteIndex = c.ts_slot + 1;
  c.ts_slot += 2;
  wgpu::ComputePassDescriptor pd{};
  pd.timestampWrites = &tw;
  return enc.BeginComputePass(&pd);
}

// 把本对累计的 GPU 纳秒读出来(阻塞一次,整对一次)。
double TsDrainMs(Ctx& c) {
  if (!c.ts_on || !c.ts_qset || c.ts_slot == 0) return -1.0;
  const uint32_t used = c.ts_slot;
  c.ts_slot = 0;
  wgpu::CommandEncoder enc = c.device.CreateCommandEncoder();
  enc.ResolveQuerySet(c.ts_qset, 0, used, c.ts_resolve, 0);
  enc.CopyBufferToBuffer(c.ts_resolve, 0, c.ts_map, 0, (uint64_t)used * 8);
  wgpu::CommandBuffer cb = enc.Finish();
  if (SubmitAndWait(c, cb, nullptr) != 0) return -1.0;
  bool done = false;
  wgpu::Future f = c.ts_map.MapAsync(
      wgpu::MapMode::Read, 0, (size_t)used * 8, wgpu::CallbackMode::WaitAnyOnly,
      [&](wgpu::MapAsyncStatus, wgpu::StringView) { done = true; });
  if (WaitFuture(c, f, "ts-map") != 0) return -1.0;
  double total_ns = 0.0;
  if (done) {
    const uint64_t* p =
        static_cast<const uint64_t*>(c.ts_map.GetConstMappedRange(0, (size_t)used * 8));
    if (p) {
      for (uint32_t i = 0; i + 1 < used; i += 2) {
        if (p[i + 1] > p[i]) total_ns += (double)(p[i + 1] - p[i]);
      }
    }
    c.ts_map.Unmap();
  }
  return total_ns / 1e6;
}

int RunStages(Ctx& c, std::vector<Stage>& stages,
              const std::function<void(wgpu::CommandEncoder&)>& finish,
              double* ema) {
  const double chunkTargetMs = ChunkTargetMs();
  if (chunkTargetMs <= 0.0) {
    // Monolithic (kill switch): every stage + finish in ONE submit.
    wgpu::CommandEncoder enc = c.device.CreateCommandEncoder();
    for (Stage& s : stages) {
      const uint32_t zero = 0;
      c.queue.WriteBuffer(s.uni, s.uniOff + kRowBaseOffset,
                          reinterpret_cast<const uint8_t*>(&zero), 4);
      wgpu::ComputePassEncoder pass = BeginPassTs(c, enc);
      s.encode(pass, 0u, s.total_groups);
      pass.End();
    }
    finish(enc);
    wgpu::CommandBuffer cb = enc.Finish();
    const int rc0 = SubmitAndWait(c, cb, nullptr);
    if (rc0 == 0 && c.ts_on) {
      const double ts = TsDrainMs(c);
      if (ts >= 0.0) aether_match_gpu_ms = ts;  // 真 GPU 时间覆盖墙钟
    }
    return rc0;
  }
  for (Stage& s : stages) {
    uint32_t tg0 = 0;
    while (tg0 < s.total_groups) {
      const double target = ThermalHot() ? chunkTargetMs : ChunkTargetCoolMs();
      const double unit = *ema;
      uint32_t want = 8;  // first probe: 8 row groups (~few ms cool)
      if (unit > 0.0) {
        const double perTg = unit * ((double)s.nDb / 1024.0);
        const double ideal = target / (perTg > 1e-6 ? perTg : 1e-6);
        want = ideal < 1.0 ? 1u : (uint32_t)std::min(ideal, 1e9);
      }
      const uint32_t groups =
          want < s.total_groups - tg0 ? want : s.total_groups - tg0;
      c.queue.WriteBuffer(s.uni, s.uniOff + kRowBaseOffset,
                          reinterpret_cast<const uint8_t*>(&tg0), 4);
      wgpu::CommandEncoder enc = c.device.CreateCommandEncoder();
      wgpu::ComputePassEncoder pass = BeginPassTs(c, enc);
      s.encode(pass, tg0, groups);
      pass.End();
      wgpu::CommandBuffer cb = enc.Finish();
      double gpuMs = 0.0;
      const int rc = SubmitAndWait(c, cb, &gpuMs);
      if (rc != 0) return rc;
      if (gpuMs > 0.0 && gpuMs < 10000.0) aether_match_gpu_ms += gpuMs;
      ++aether_match_chunks;
      if (gpuMs > 0.0 && gpuMs < 10000.0) {
        const double u = gpuMs / ((double)groups * ((double)s.nDb / 1024.0));
        const double prev = *ema;
        *ema = prev <= 0.0 ? u : prev * 0.7 + u * 0.3;
      }
      const double gapPct = ThermalGapPct();
      if (gapPct > 0.0 && gpuMs > 0.0) {
        double gapMs = gpuMs * gapPct / 100.0;
        if (gapMs > 250.0) gapMs = 250.0;
        aether_match_sleep_ms += gapMs;
        std::this_thread::sleep_for(
            std::chrono::microseconds((long long)(gapMs * 1000.0)));
      }
      tg0 += groups;
    }
  }
  wgpu::CommandEncoder enc = c.device.CreateCommandEncoder();
  finish(enc);
  wgpu::CommandBuffer cb = enc.Finish();
  const int rcF = SubmitAndWait(c, cb, nullptr);
  if (rcF == 0 && c.ts_on) {
    const double ts = TsDrainMs(c);
    if (ts >= 0.0) aether_match_gpu_ms = ts;  // 真 GPU 时间覆盖墙钟累加
  }
  return rcF;
}

// ── Descriptor residency V1 (backend handles only; policy is shared) ─────
using aether::sfm::DescriptorFormatV1;
using aether::sfm::DescriptorResidencyKeyHashV1;
using aether::sfm::DescriptorResidencyKeyV1;
using aether::sfm::DescriptorResidencyMetadataV1;
using aether::sfm::DescriptorResidencyPolicyV1;

struct ResidencySession {
  explicit ResidencySession(uint64_t budget) : policy(budget) {}
  DescriptorResidencyPolicyV1 policy;
  std::unordered_map<DescriptorResidencyKeyV1, wgpu::Buffer,
                     DescriptorResidencyKeyHashV1>
      buffers;
  uint64_t upload_bytes = 0;
  uint64_t allocation_failures = 0;
  uint64_t device_resets = 0;
};

std::unordered_map<uint64_t, std::unique_ptr<ResidencySession>> gResidency;

ResidencySession* ResidencyFor(uint64_t nonce) {
  auto found = gResidency.find(nonce);
  if (found != gResidency.end()) return found->second.get();
  auto inserted = gResidency.emplace(
      nonce, std::make_unique<ResidencySession>(DescriptorResidencyBudgetBytes()));
  return inserted.first->second.get();
}

void EraseResident(ResidencySession* s,
                   const std::vector<DescriptorResidencyKeyV1>& keys) {
  if (!s) return;
  for (const auto& k : keys) {
    auto it = s->buffers.find(k);
    if (it != s->buffers.end()) {
      if (it->second) it->second.Destroy();
      s->buffers.erase(it);
    }
  }
}

void ClearAllDescriptorResidencyForDeviceError() {
  for (auto& kv : gResidency) {
    kv.second->policy.ClearAll();
    kv.second->buffers.clear();
    ++kv.second->device_resets;
  }
}

// Returns a resident buffer holding the padded table in the active kernel's
// format, or null (caller uploads into the pool instead).
wgpu::Buffer ResidentBuffer(Ctx& c, uint64_t nonce, uint32_t frame,
                            uint32_t generation, const uint8_t* desc,
                            uint32_t n, uint32_t npad, std::vector<float>& scratch) {
  if (!DescriptorResidencyEnabled() || nonce == 0 || !desc || n == 0 ||
      npad < n) {
    return nullptr;
  }
  ResidencySession* s = ResidencyFor(nonce);
  const DescriptorResidencyKeyV1 key{nonce, frame, generation};
  const uint64_t bytes = DescBytes(c, n, npad);
  // The format tag only has to be stable per process (the backend never
  // changes after init): kRawU8 for the tiled table, kHalf as the tag for
  // the f32-expanded subgroup-matrix table.
  const DescriptorResidencyMetadataV1 md{
      n, c.backend == Backend::kMma ? DescriptorFormatV1::kHalf
                                    : DescriptorFormatV1::kRawU8,
      bytes};
  auto access = s->policy.Access(key, md);
  EraseResident(s, access.evicted);
  if (access.hit) {
    auto found = s->buffers.find(key);
    if (found != s->buffers.end() && found->second) return found->second;
    EraseResident(s, s->policy.InvalidateFrame(nonce, frame));
    access = s->policy.Access(key, md);
    EraseResident(s, access.evicted);
  }
  if (!access.admitted) return nullptr;
  wgpu::BufferDescriptor d{};
  d.usage = kUsageDesc;
  d.size = RoundUp(std::max<uint64_t>(bytes, 16), 4);
  wgpu::Buffer buf = c.device.CreateBuffer(&d);
  if (!buf) {
    ++s->allocation_failures;
    EraseResident(s, s->policy.InvalidateFrame(nonce, frame));
    return nullptr;
  }
  UploadDesc(c, buf, 0, desc, n, npad, scratch);
  s->upload_bytes += bytes;
  s->buffers[key] = buf;
  return buf;
}

// ── Mutual cross-check + sentinel guard ──────────────────────────────────
// Returns rc: 0 ok, 7 incomplete output (sentinel survived).
int CrossCheck(const int32_t* mAB, int nA, const int32_t* mBA, int nB,
               uint32_t* out_pairs, int max_pairs, int* out_num) {
  for (int i = 0; i < nA; ++i) {
    if (mAB[i] == kOutSentinel) {
      StashLastError("output incomplete (A->B sentinel survived)");
      return 7;
    }
  }
  for (int j = 0; j < nB; ++j) {
    if (mBA[j] == kOutSentinel) {
      StashLastError("output incomplete (B->A sentinel survived)");
      return 7;
    }
  }
  int n_out = 0;
  for (int i = 0; i < nA; ++i) {
    const int j = mAB[i];
    if (j >= 0 && j < nB && mBA[j] == i) {
      if (out_pairs != nullptr) {
        if (n_out >= max_pairs) break;  // unreachable per contract
        out_pairs[2 * n_out] = (uint32_t)i;
        out_pairs[2 * n_out + 1] = (uint32_t)j;
      }
      ++n_out;
    }
  }
  if (out_num) *out_num = n_out;
  return 0;
}

#if defined(PWOFFICIAL_DAWN_HOST_TEST) && PWOFFICIAL_DAWN_HOST_TEST
std::vector<int32_t> gDbgAB, gDbgBA;
double gDbgUploadMs = 0.0, gDbgSubmitMs = 0.0, gDbgReadbackMs = 0.0;
#endif

// ══════════════════════════ plain match ══════════════════════════════════
int MatchPairsImpl(const uint8_t* dA, int nA, const uint8_t* dB, int nB,
                   double max_ratio, uint32_t* out_pairs, int max_pairs,
                   int* out_num, uint64_t nonce = 0, uint32_t frameA = 0,
                   uint32_t genA = 0, uint32_t frameB = 0, uint32_t genB = 0) {
  if (out_num) *out_num = 0;
  if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
  if (out_pairs != nullptr && max_pairs <= 0) return 1;
  Ctx* cp = EnsureDawn();
  if (!cp) return 2;
  Ctx& c = *cp;
  if (!EnsureMainPipelines(c)) return 2;
  const double tStart = NowMs();

  const uint32_t nAu = (uint32_t)nA, nBu = (uint32_t)nB;
  const uint32_t nApad = (uint32_t)RoundUp(nAu, 128);
  const uint32_t nBpad = (uint32_t)RoundUp(nBu, 128);
  const uint64_t aBytes = DescBytes(c, nAu, nApad);
  const uint64_t bBytes = DescBytes(c, nBu, nBpad);

  wgpu::Buffer aBuf = ResidentBuffer(c, nonce, frameA, genA, dA, nAu, nApad,
                                     c.scratchA);
  wgpu::Buffer bBuf = ResidentBuffer(c, nonce, frameB, genB, dB, nBu, nBpad,
                                     c.scratchB);
  const bool aRes = (bool)aBuf, bRes = (bool)bBuf;
  if (!aBuf) aBuf = PoolGet(c, c.a, aBytes, kUsageDesc);
  if (!bBuf) bBuf = PoolGet(c, c.b, bBytes, kUsageDesc);
  if (!aBuf || !bBuf) return 5;
  if (!aRes) UploadDesc(c, aBuf, 0, dA, nAu, nApad, c.scratchA);
  if (!bRes) UploadDesc(c, bBuf, 0, dB, nBu, nBpad, c.scratchB);

  const uint64_t outABBytes = (uint64_t)nAu * 4, outBABytes = (uint64_t)nBu * 4;
  wgpu::Buffer outAB = PoolGet(c, c.outAB, outABBytes, kUsageOut);
  wgpu::Buffer outBA = PoolGet(c, c.outBA, outBABytes, kUsageOut);
  wgpu::Buffer uni = PoolGet(c, c.uni, 2 * kSlot, kUsageUni);
  wgpu::Buffer staging =
      PoolGet(c, c.staging, outABBytes + outBABytes, kUsageStaging);
  if (!outAB || !outBA || !uni || !staging) return 6;
  FillSentinel(c, outAB, 0, nAu);
  FillSentinel(c, outBA, 0, nBu);

  float maxRatio = (float)max_ratio;
  if (maxRatio <= 0.0f) maxRatio = 0.8f;
  const float maxDistance = 0.7f;  // colmap SiftMatchingOptions::max_distance

  std::vector<Stage> stages;
  std::function<void(wgpu::CommandEncoder&)> finish;
  wgpu::BindGroup bgMain, bgMerge, bgBA;
  const double tUpload = NowMs();
  if (c.backend == Backend::kMma) {
    const uint32_t numWg = nApad / kMmaRows;
    const uint64_t colBytes = (uint64_t)nBu * numWg * 12;
    wgpu::Buffer colp = PoolGet(c, c.colp, colBytes, kUsageColp);
    if (!colp) return 6;
    const Params p{nAu, nBu, maxRatio, maxDistance, numWg, 0u, 0u, 0u};
    c.queue.WriteBuffer(uni, 0, reinterpret_cast<const uint8_t*>(&p), sizeof(p));
    bgMain = MakeBG(c, c.p_main,
                    {BE(0, aBuf, 0, aBytes), BE(1, bBuf, 0, bBytes),
                     BE(2, outAB, 0, outABBytes), BE(3, uni, 0, sizeof(Params)),
                     BE(4, colp, 0, colBytes)});
    bgMerge = MakeBG(c, c.p_merge,
                     {BE(3, uni, 0, sizeof(Params)), BE(4, colp, 0, colBytes),
                      BE(5, outBA, 0, outBABytes)});
    if (!bgMain || !bgMerge) return 6;
    Stage s;
    s.total_groups = numWg;
    s.nDb = nBu;
    s.uni = uni;
    s.uniOff = 0;
    s.encode = [&](wgpu::ComputePassEncoder& pass, uint32_t, uint32_t groups) {
      pass.SetPipeline(c.p_main);
      pass.SetBindGroup(0, bgMain);
      pass.DispatchWorkgroups(groups);
    };
    stages.push_back(s);
    finish = [&](wgpu::CommandEncoder& enc) {
      wgpu::ComputePassEncoder pass = enc.BeginComputePass();
      pass.SetPipeline(c.p_merge);
      pass.SetBindGroup(0, bgMerge);
      pass.DispatchWorkgroups((nBu + 63) / 64);
      pass.End();
      enc.CopyBufferToBuffer(outAB, 0, staging, 0, outABBytes);
      enc.CopyBufferToBuffer(outBA, 0, staging, outABBytes, outBABytes);
    };
  } else {
    const Params pab{nAu, nBu, maxRatio, maxDistance, 0u, 0u, 0u, 0u};
    const Params pba{nBu, nAu, maxRatio, maxDistance, 0u, 0u, 0u, 0u};
    c.queue.WriteBuffer(uni, 0, reinterpret_cast<const uint8_t*>(&pab), sizeof(pab));
    c.queue.WriteBuffer(uni, kSlot, reinterpret_cast<const uint8_t*>(&pba),
                        sizeof(pba));
    bgMain = MakeBG(c, c.p_main,
                    {BE(0, aBuf, 0, aBytes), BE(1, bBuf, 0, bBytes),
                     BE(2, outAB, 0, outABBytes), BE(3, uni, 0, sizeof(Params))});
    bgBA = MakeBG(c, c.p_main,
                  {BE(0, bBuf, 0, bBytes), BE(1, aBuf, 0, aBytes),
                   BE(2, outBA, 0, outBABytes), BE(3, uni, kSlot, sizeof(Params))});
    if (!bgMain || !bgBA) return 6;
    Stage sab, sba;
    sab.total_groups = (nAu + kTiledRows - 1) / kTiledRows;
    sab.nDb = nBu;
    sab.uni = uni;
    sab.uniOff = 0;
    sab.encode = [&](wgpu::ComputePassEncoder& pass, uint32_t, uint32_t groups) {
      pass.SetPipeline(c.p_main);
      pass.SetBindGroup(0, bgMain);
      pass.DispatchWorkgroups(groups);
    };
    sba.total_groups = (nBu + kTiledRows - 1) / kTiledRows;
    sba.nDb = nAu;
    sba.uni = uni;
    sba.uniOff = kSlot;
    sba.encode = [&](wgpu::ComputePassEncoder& pass, uint32_t, uint32_t groups) {
      pass.SetPipeline(c.p_main);
      pass.SetBindGroup(0, bgBA);
      pass.DispatchWorkgroups(groups);
    };
    stages.push_back(sab);
    stages.push_back(sba);
    finish = [&](wgpu::CommandEncoder& enc) {
      enc.CopyBufferToBuffer(outAB, 0, staging, 0, outABBytes);
      enc.CopyBufferToBuffer(outBA, 0, staging, outABBytes, outBABytes);
    };
  }
  int rc = RunStages(c, stages, finish, &c.ema_main);
  if (rc != 0) return rc;
  const double tSubmit = NowMs();
  c.host.resize((size_t)nAu + nBu);
  rc = ReadbackStaging(c, staging, outABBytes + outBABytes, c.host.data());
  if (rc != 0) return rc;
  const int32_t* mAB = c.host.data();
  const int32_t* mBA = c.host.data() + nAu;
#if defined(PWOFFICIAL_DAWN_HOST_TEST) && PWOFFICIAL_DAWN_HOST_TEST
  gDbgAB.assign(mAB, mAB + nAu);
  gDbgBA.assign(mBA, mBA + nBu);
  gDbgUploadMs = tUpload - tStart;
  gDbgSubmitMs = tSubmit - tUpload;
  gDbgReadbackMs = NowMs() - tSubmit;
#else
  (void)tStart;
  (void)tUpload;
  (void)tSubmit;
#endif
  return CrossCheck(mAB, nA, mBA, nB, out_pairs, max_pairs, out_num);
}

// ══════════════════════════ guided match (v1 two-pass) ═══════════════════
int MatchGuidedImpl(const uint8_t* dA, int nA, const float* xyA,
                    const uint8_t* dB, int nB, const float* xyB,
                    double max_ratio, const float* matrixAB,
                    const float* matrixBA, uint32_t guideMode,
                    float maxResidual, uint32_t* out_pairs, int max_pairs,
                    int* out_num) {
  if (out_num) *out_num = 0;
  if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
  if (out_pairs != nullptr && max_pairs <= 0) return 1;
  if (guideMode == 0u || guideMode > 2u) return 1;
  if (!xyA || !xyB || !matrixAB || !matrixBA || maxResidual <= 0.0f) return 1;
  Ctx* cp = EnsureDawn();
  if (!cp) return 2;
  Ctx& c = *cp;
  if (!EnsureGuidedPipeline(c)) return 2;
  const double tStart = NowMs();

  const uint32_t nAu = (uint32_t)nA, nBu = (uint32_t)nB;
  const uint32_t nApad = (uint32_t)RoundUp(nAu, 128);
  const uint32_t nBpad = (uint32_t)RoundUp(nBu, 128);
  const uint64_t aBytes = DescBytes(c, nAu, nApad);
  const uint64_t bBytes = DescBytes(c, nBu, nBpad);
  wgpu::Buffer aBuf = PoolGet(c, c.a, aBytes, kUsageDesc);
  wgpu::Buffer bBuf = PoolGet(c, c.b, bBytes, kUsageDesc);
  if (!aBuf || !bBuf) return 5;
  UploadDesc(c, aBuf, 0, dA, nAu, nApad, c.scratchA);
  UploadDesc(c, bBuf, 0, dB, nBu, nBpad, c.scratchB);

  // Keypoints padded like the descriptors (zero-filled): padded query rows
  // read in-bounds points whose verdict is irrelevant (never written).
  const uint64_t ptsABytes = (uint64_t)nApad * 2 * sizeof(float);
  const uint64_t ptsBBytes = (uint64_t)nBpad * 2 * sizeof(float);
  wgpu::Buffer ptsA = PoolGet(c, c.ptsA, ptsABytes, kUsageDesc);
  wgpu::Buffer ptsB = PoolGet(c, c.ptsB, ptsBBytes, kUsageDesc);
  wgpu::Buffer matAB = PoolGet(c, c.matAB, 48, kUsageDesc);
  wgpu::Buffer matBA = PoolGet(c, c.matBA, 48, kUsageDesc);
  if (!ptsA || !ptsB || !matAB || !matBA) return 6;
  {
    std::vector<float>& sa = c.scratchA;
    sa.assign((size_t)nApad * 2, 0.0f);
    std::memcpy(sa.data(), xyA, (size_t)nAu * 2 * sizeof(float));
    c.queue.WriteBuffer(ptsA, 0, reinterpret_cast<const uint8_t*>(sa.data()),
                        ptsABytes);
    std::vector<float>& sb = c.scratchB;
    sb.assign((size_t)nBpad * 2, 0.0f);
    std::memcpy(sb.data(), xyB, (size_t)nBu * 2 * sizeof(float));
    c.queue.WriteBuffer(ptsB, 0, reinterpret_cast<const uint8_t*>(sb.data()),
                        ptsBBytes);
    float m[12] = {0};
    std::memcpy(m, matrixAB, 9 * sizeof(float));
    c.queue.WriteBuffer(matAB, 0, reinterpret_cast<const uint8_t*>(m), 48);
    std::memcpy(m, matrixBA, 9 * sizeof(float));
    c.queue.WriteBuffer(matBA, 0, reinterpret_cast<const uint8_t*>(m), 48);
  }
  const uint64_t outABBytes = (uint64_t)nAu * 4, outBABytes = (uint64_t)nBu * 4;
  wgpu::Buffer outAB = PoolGet(c, c.outAB, outABBytes, kUsageOut);
  wgpu::Buffer outBA = PoolGet(c, c.outBA, outBABytes, kUsageOut);
  wgpu::Buffer uni = PoolGet(c, c.uni, 2 * kSlot, kUsageUni);
  wgpu::Buffer staging =
      PoolGet(c, c.staging, outABBytes + outBABytes, kUsageStaging);
  if (!outAB || !outBA || !uni || !staging) return 6;
  FillSentinel(c, outAB, 0, nAu);
  FillSentinel(c, outBA, 0, nBu);

  float maxRatio = (float)max_ratio;
  if (maxRatio <= 0.0f) maxRatio = 0.8f;
  const float maxDistance = 0.7f;
  const GParams pab{nAu, nBu, maxRatio, maxDistance, guideMode, 0u, maxResidual, 0u};
  const GParams pba{nBu, nAu, maxRatio, maxDistance, guideMode, 0u, maxResidual, 0u};
  c.queue.WriteBuffer(uni, 0, reinterpret_cast<const uint8_t*>(&pab), sizeof(pab));
  c.queue.WriteBuffer(uni, kSlot, reinterpret_cast<const uint8_t*>(&pba), sizeof(pba));
  wgpu::BindGroup bgAB = MakeBG(
      c, c.p_guided,
      {BE(0, aBuf, 0, aBytes), BE(1, bBuf, 0, bBytes), BE(2, outAB, 0, outABBytes),
       BE(3, uni, 0, sizeof(GParams)), BE(4, ptsA, 0, ptsABytes),
       BE(5, ptsB, 0, ptsBBytes), BE(6, matAB, 0, 48)});
  wgpu::BindGroup bgBA = MakeBG(
      c, c.p_guided,
      {BE(0, bBuf, 0, bBytes), BE(1, aBuf, 0, aBytes), BE(2, outBA, 0, outBABytes),
       BE(3, uni, kSlot, sizeof(GParams)), BE(4, ptsB, 0, ptsBBytes),
       BE(5, ptsA, 0, ptsABytes), BE(6, matBA, 0, 48)});
  if (!bgAB || !bgBA) return 6;
  const uint32_t rows = c.backend == Backend::kMma ? kMmaRows : kTiledRows;
  std::vector<Stage> stages;
  Stage sab, sba;
  sab.total_groups = (nAu + rows - 1) / rows;
  sab.nDb = nBu;
  sab.uni = uni;
  sab.uniOff = 0;
  sab.encode = [&](wgpu::ComputePassEncoder& pass, uint32_t, uint32_t groups) {
    pass.SetPipeline(c.p_guided);
    pass.SetBindGroup(0, bgAB);
    pass.DispatchWorkgroups(groups);
  };
  sba.total_groups = (nBu + rows - 1) / rows;
  sba.nDb = nAu;
  sba.uni = uni;
  sba.uniOff = kSlot;
  sba.encode = [&](wgpu::ComputePassEncoder& pass, uint32_t, uint32_t groups) {
    pass.SetPipeline(c.p_guided);
    pass.SetBindGroup(0, bgBA);
    pass.DispatchWorkgroups(groups);
  };
  stages.push_back(sab);
  stages.push_back(sba);
  auto finish = [&](wgpu::CommandEncoder& enc) {
    enc.CopyBufferToBuffer(outAB, 0, staging, 0, outABBytes);
    enc.CopyBufferToBuffer(outBA, 0, staging, outABBytes, outBABytes);
  };
  const double tUpload = NowMs();
  int rc = RunStages(c, stages, finish, &c.ema_guided);
  if (rc != 0) return rc;
  const double tSubmit = NowMs();
  c.host.resize((size_t)nAu + nBu);
  rc = ReadbackStaging(c, staging, outABBytes + outBABytes, c.host.data());
  if (rc != 0) return rc;
  const int32_t* mAB = c.host.data();
  const int32_t* mBA = c.host.data() + nAu;
#if defined(PWOFFICIAL_DAWN_HOST_TEST) && PWOFFICIAL_DAWN_HOST_TEST
  gDbgAB.assign(mAB, mAB + nAu);
  gDbgBA.assign(mBA, mBA + nBu);
  gDbgUploadMs = tUpload - tStart;
  gDbgSubmitMs = tSubmit - tUpload;
  gDbgReadbackMs = NowMs() - tSubmit;
#else
  (void)tStart;
  (void)tUpload;
  (void)tSubmit;
#endif
  return CrossCheck(mAB, nA, mBA, nB, out_pairs, max_pairs, out_num);
}

// ══════════════════════════ probe batch ══════════════════════════════════
// Same contract as the Metal TU's aether_gpu_match_probe_batch: K candidates
// scored INDEPENDENTLY (own buffer regions, own dispatches), sharing only the
// GPU submissions; grouped by the same cost model / thermal targets. rc 0 =
// every candidate scored; 7/8 = whole remaining batch aborted (caller fails
// OPEN). WebGPU compute passes serialise dispatches, so — unlike the Metal
// concurrent encoders — the win here is only the removed CPU↔GPU round
// trips.
int ProbeBatchImpl(const uint8_t* dA, int nA, const uint8_t* const* dBs,
                   const int* nBs, int n_cands, double max_ratio,
                   int* out_counts) {
  if (!dA || !dBs || !nBs || !out_counts || nA <= 0 || n_cands <= 0) return 1;
  for (int k = 0; k < n_cands; ++k) {
    if (!dBs[k] || nBs[k] <= 0) return 1;
    out_counts[k] = 0;
  }
  Ctx* cp = EnsureDawn();
  if (!cp) return 2;
  Ctx& c = *cp;
  if (!EnsureMainPipelines(c)) return 2;
  const bool mma = c.backend == Backend::kMma;
  const uint32_t nAu = (uint32_t)nA;
  const uint32_t nApad = (uint32_t)RoundUp(nAu, 128);
  const uint32_t numWg = nApad / kMmaRows;
  const uint64_t aBytes = DescBytes(c, nAu, nApad);
  const uint64_t outABBytes = (uint64_t)nAu * 4;
  const uint64_t outABSlot = RoundUp(outABBytes, kSlot);
  const uint32_t uniPerCand = mma ? 1u : 2u;

  struct Cand {
    uint32_t nB, nBpad;
    uint64_t bOff, bBytes, outBAOff, outBABytes, colOff, colBytes, uniOff,
        stgOff;
    wgpu::BindGroup bgMain, bgMerge, bgBA;
    double units;
  };
  std::vector<Cand> cands((size_t)n_cands);
  uint64_t bTotal = 0, outBATotal = 0, colTotal = 0, stgTotal = 0;
  for (int k = 0; k < n_cands; ++k) {
    Cand& cd = cands[(size_t)k];
    cd.nB = (uint32_t)nBs[k];
    cd.nBpad = (uint32_t)RoundUp(cd.nB, 128);
    cd.bBytes = DescBytes(c, cd.nB, cd.nBpad);
    cd.bOff = bTotal;
    bTotal += RoundUp(cd.bBytes, kSlot);
    cd.outBABytes = (uint64_t)cd.nB * 4;
    cd.outBAOff = outBATotal;
    outBATotal += RoundUp(cd.outBABytes, kSlot);
    cd.colBytes = mma ? (uint64_t)cd.nB * numWg * 12 : 16;
    cd.colOff = colTotal;
    colTotal += RoundUp(cd.colBytes, kSlot);
    cd.uniOff = (uint64_t)k * uniPerCand * kSlot;
    cd.stgOff = stgTotal;
    stgTotal += outABBytes + cd.outBABytes;
    cd.units = mma ? (double)numWg * ((double)cd.nB / 1024.0)
                   : (double)((nAu + 63) / 64) * ((double)cd.nB / 1024.0) +
                         (double)((cd.nB + 63) / 64) * ((double)nAu / 1024.0);
  }
  wgpu::Buffer aBuf = PoolGet(c, c.pbA, aBytes, kUsageDesc);
  wgpu::Buffer bBuf = PoolGet(c, c.pbB, bTotal, kUsageDesc);
  if (!aBuf || !bBuf) return 5;
  UploadDesc(c, aBuf, 0, dA, nAu, nApad, c.scratchA);
  for (int k = 0; k < n_cands; ++k) {
    const Cand& cd = cands[(size_t)k];
    UploadDesc(c, bBuf, cd.bOff, dBs[k], cd.nB, cd.nBpad, c.scratchB);
  }
  wgpu::Buffer outAB = PoolGet(c, c.pbOutAB, outABSlot * (uint64_t)n_cands, kUsageOut);
  wgpu::Buffer outBA = PoolGet(c, c.pbOutBA, outBATotal, kUsageOut);
  wgpu::Buffer colp = PoolGet(c, c.pbColp, colTotal, kUsageColp);
  wgpu::Buffer uni = PoolGet(c, c.pbUni, (uint64_t)n_cands * uniPerCand * kSlot,
                             kUsageUni);
  wgpu::Buffer staging = PoolGet(c, c.pbStaging, stgTotal, kUsageStaging);
  if (!outAB || !outBA || !colp || !uni || !staging) return 6;

  float maxRatio = (float)max_ratio;
  if (maxRatio <= 0.0f) maxRatio = 0.8f;
  const float maxDistance = 0.7f;
  for (int k = 0; k < n_cands; ++k) {
    Cand& cd = cands[(size_t)k];
    FillSentinel(c, outAB, (uint64_t)k * outABSlot, nAu);
    FillSentinel(c, outBA, cd.outBAOff, cd.nB);
    if (mma) {
      const Params p{nAu, cd.nB, maxRatio, maxDistance, numWg, 0u, 0u, 0u};
      c.queue.WriteBuffer(uni, cd.uniOff, reinterpret_cast<const uint8_t*>(&p),
                          sizeof(p));
      cd.bgMain = MakeBG(
          c, c.p_main,
          {BE(0, aBuf, 0, aBytes), BE(1, bBuf, cd.bOff, cd.bBytes),
           BE(2, outAB, (uint64_t)k * outABSlot, outABBytes),
           BE(3, uni, cd.uniOff, sizeof(Params)), BE(4, colp, cd.colOff, cd.colBytes)});
      cd.bgMerge = MakeBG(c, c.p_merge,
                          {BE(3, uni, cd.uniOff, sizeof(Params)),
                           BE(4, colp, cd.colOff, cd.colBytes),
                           BE(5, outBA, cd.outBAOff, cd.outBABytes)});
      if (!cd.bgMain || !cd.bgMerge) return 6;
    } else {
      const Params pab{nAu, cd.nB, maxRatio, maxDistance, 0u, 0u, 0u, 0u};
      const Params pba{cd.nB, nAu, maxRatio, maxDistance, 0u, 0u, 0u, 0u};
      c.queue.WriteBuffer(uni, cd.uniOff, reinterpret_cast<const uint8_t*>(&pab),
                          sizeof(pab));
      c.queue.WriteBuffer(uni, cd.uniOff + kSlot,
                          reinterpret_cast<const uint8_t*>(&pba), sizeof(pba));
      cd.bgMain = MakeBG(c, c.p_main,
                         {BE(0, aBuf, 0, aBytes), BE(1, bBuf, cd.bOff, cd.bBytes),
                          BE(2, outAB, (uint64_t)k * outABSlot, outABBytes),
                          BE(3, uni, cd.uniOff, sizeof(Params))});
      cd.bgBA = MakeBG(c, c.p_main,
                       {BE(0, bBuf, cd.bOff, cd.bBytes), BE(1, aBuf, 0, aBytes),
                        BE(2, outBA, cd.outBAOff, cd.outBABytes),
                        BE(3, uni, cd.uniOff + kSlot, sizeof(Params))});
      if (!cd.bgMain || !cd.bgBA) return 6;
    }
  }

  auto runGroup = [&](int c0, int c1) -> int {
    wgpu::CommandEncoder enc = c.device.CreateCommandEncoder();
    wgpu::ComputePassEncoder pass = enc.BeginComputePass();
    for (int k = c0; k < c1; ++k) {
      const Cand& cd = cands[(size_t)k];
      if (mma) {
        pass.SetPipeline(c.p_main);
        pass.SetBindGroup(0, cd.bgMain);
        pass.DispatchWorkgroups(numWg);
        pass.SetPipeline(c.p_merge);
        pass.SetBindGroup(0, cd.bgMerge);
        pass.DispatchWorkgroups((cd.nB + 63) / 64);
      } else {
        pass.SetPipeline(c.p_main);
        pass.SetBindGroup(0, cd.bgMain);
        pass.DispatchWorkgroups((nAu + 63) / 64);
        pass.SetBindGroup(0, cd.bgBA);
        pass.DispatchWorkgroups((cd.nB + 63) / 64);
      }
    }
    pass.End();
    for (int k = c0; k < c1; ++k) {
      const Cand& cd = cands[(size_t)k];
      enc.CopyBufferToBuffer(outAB, (uint64_t)k * outABSlot, staging, cd.stgOff,
                             outABBytes);
      enc.CopyBufferToBuffer(outBA, cd.outBAOff, staging, cd.stgOff + outABBytes,
                             cd.outBABytes);
    }
    wgpu::CommandBuffer cb = enc.Finish();
    double gpuMs = 0.0;
    const int rc = SubmitAndWait(c, cb, &gpuMs);
    if (rc != 0) return rc;
    if (gpuMs > 0.0 && gpuMs < 10000.0) aether_match_gpu_ms += gpuMs;
    ++aether_match_chunks;
    // No EMA update from the probe batch (its per-unit cost differs from the
    // full-pair chunks the EMA calibrates) — same rule as the Metal TU.
    const double gapPct = ThermalGapPct();
    if (gapPct > 0.0 && gpuMs > 0.0) {
      double gapMs = gpuMs * gapPct / 100.0;
      if (gapMs > 250.0) gapMs = 250.0;
      aether_match_sleep_ms += gapMs;
      std::this_thread::sleep_for(
          std::chrono::microseconds((long long)(gapMs * 1000.0)));
    }
    return 0;
  };
  const double chunkTargetMs = ChunkTargetMs();
  double estCap = 0.0;
  if (chunkTargetMs > 0.0) {
    const double target = ThermalHot() ? chunkTargetMs : ChunkTargetCoolMs();
    estCap = c.ema_main > 0.0 ? target / c.ema_main : 0.0;
  }
  int g0 = 0;
  double gUnits = 0.0;
  for (int k = 0; k < n_cands; ++k) {
    const double cu = cands[(size_t)k].units;
    if (k > g0 && estCap > 0.0 && gUnits + cu > estCap) {
      const int rc = runGroup(g0, k);
      if (rc != 0) return rc;
      g0 = k;
      gUnits = 0.0;
    }
    gUnits += cu;
  }
  if (g0 < n_cands) {
    const int rc = runGroup(g0, n_cands);
    if (rc != 0) return rc;
  }
  c.host.resize((size_t)(stgTotal / 4));
  const int rrc = ReadbackStaging(c, staging, stgTotal, c.host.data());
  if (rrc != 0) return rrc;
  for (int k = 0; k < n_cands; ++k) {
    const Cand& cd = cands[(size_t)k];
    const int32_t* mAB = c.host.data() + cd.stgOff / 4;
    const int32_t* mBA = mAB + nAu;
    int n_out = 0;
    const int rc = CrossCheck(mAB, nA, mBA, (int)cd.nB, nullptr, 0, &n_out);
    if (rc != 0) return rc;
    out_counts[k] = n_out;
  }
  return 0;
}

}  // namespace

// ═══════════════════════════ exported C ABI ══════════════════════════════

extern "C" int pwdawn_gpu_match_last_error(char* buf, int cap) {
  if (!buf || cap <= 0) return 0;
  std::lock_guard<std::mutex> lk(gLastErrLock);
  const int n = std::snprintf(buf, (size_t)cap, "%s", gLastErr);
  return n < 0 ? 0 : (n < cap ? n : cap - 1);
}

extern "C" void pwdawn_match_set_ab_phase(int phase) {
  gAbPhase.store(phase, std::memory_order_relaxed);
}
extern "C" void pwdawn_gpu_match_set_capture_active(int active) {
  gCaptureActive.store(active ? 1 : 0, std::memory_order_relaxed);
}
extern "C" void pwdawn_gpu_match_set_preview_fps30(int on) {
  gPreviewFps30.store(on ? 1 : 0, std::memory_order_relaxed);
}
extern "C" void pwdawn_gpu_match_set_thermal_state(int state) {
  gThermalState.store((state >= 0 && state <= 3) ? state : 0,
                      std::memory_order_relaxed);
}
extern "C" int pwdawn_gpu_match_get_capture_active(void) {
  return gCaptureActive.load(std::memory_order_relaxed);
}

#if !(defined(PWOFFICIAL_DAWN_OBSERVABLES_EXTERN) && PWOFFICIAL_DAWN_OBSERVABLES_EXTERN)
// Dart-side race gate reader (see the Metal TU): on builds without the Metal
// TU this backend owns the public symbol.
extern "C" __attribute__((used, visibility("default"))) int
aether_gpu_match_get_capture_active(void) {
  return gCaptureActive.load(std::memory_order_relaxed);
}
#endif

// Initialises Dawn if needed and copies a one-line backend description into
// buf ("backend=mma(...) adapter=... "). Returns bytes written (0 = no GPU).
extern "C" int pwdawn_gpu_match_backend_info(char* buf, int cap) {
  if (!buf || cap <= 0) return 0;
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  Ctx* c = EnsureDawn();
  if (!c) {
    buf[0] = 0;
    return 0;
  }
  const int n = std::snprintf(buf, (size_t)cap, "%s", c->backend_info.c_str());
  return n < 0 ? 0 : (n < cap ? n : cap - 1);
}

extern "C" int pwdawn_gpu_match_gemm_pairs(const uint8_t* dA, int nA,
                                           const uint8_t* dB, int nB,
                                           double max_ratio,
                                           uint32_t* out_pairs, int max_pairs,
                                           int* out_num_matches) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  return MatchPairsImpl(dA, nA, dB, nB, max_ratio, out_pairs, max_pairs,
                        out_num_matches);
}

extern "C" int pwdawn_gpu_match_gemm_pairs_resident(
    uint64_t session_nonce, uint32_t frame_a, uint32_t generation_a,
    const uint8_t* dA, int nA, uint32_t frame_b, uint32_t generation_b,
    const uint8_t* dB, int nB, double max_ratio, uint32_t* out_pairs,
    int max_pairs, int* out_num_matches) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  return MatchPairsImpl(dA, nA, dB, nB, max_ratio, out_pairs, max_pairs,
                        out_num_matches, session_nonce, frame_a, generation_a,
                        frame_b, generation_b);
}

extern "C" void pwdawn_gpu_match_descriptor_residency_invalidate(
    uint64_t session_nonce, uint32_t frame_ordinal) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  auto found = gResidency.find(session_nonce);
  if (found == gResidency.end()) return;
  EraseResident(found->second.get(),
                found->second->policy.InvalidateFrame(session_nonce, frame_ordinal));
}

extern "C" void pwdawn_gpu_match_descriptor_residency_clear_session(
    uint64_t session_nonce) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  auto found = gResidency.find(session_nonce);
  if (found == gResidency.end()) return;
  found->second->policy.ClearSession(session_nonce);
  for (auto& kv : found->second->buffers) {
    if (kv.second) kv.second.Destroy();
  }
  found->second->buffers.clear();
  gResidency.erase(found);
}

extern "C" int pwdawn_gpu_match_descriptor_residency_stats(
    uint64_t session_nonce, uint64_t* hits, uint64_t* misses,
    uint64_t* evictions, uint64_t* stale_replacements, uint64_t* upload_bytes,
    uint64_t* resident_bytes, uint64_t* resident_entries,
    uint64_t* allocation_failures, uint64_t* device_resets) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  uint64_t values[9] = {0};
  auto found = gResidency.find(session_nonce);
  if (found != gResidency.end()) {
    const auto stats = found->second->policy.stats();
    values[0] = stats.hits;
    values[1] = stats.misses;
    values[2] = stats.evictions;
    values[3] = stats.stale_replacements;
    values[4] = found->second->upload_bytes;
    values[5] = found->second->policy.resident_bytes();
    values[6] = found->second->policy.size();
    values[7] = found->second->allocation_failures;
    values[8] = found->second->device_resets;
  }
  uint64_t* outputs[9] = {hits,           misses,           evictions,
                          stale_replacements, upload_bytes, resident_bytes,
                          resident_entries, allocation_failures, device_resets};
  for (size_t i = 0; i < 9; ++i) {
    if (outputs[i]) *outputs[i] = values[i];
  }
  return found == gResidency.end() ? 0 : 1;
}

extern "C" int pwdawn_gpu_match_probe_batch(const uint8_t* dA, int nA,
                                            const uint8_t* const* dBs,
                                            const int* nBs, int n_cands,
                                            double max_ratio, int* out_counts) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  return ProbeBatchImpl(dA, nA, dBs, nBs, n_cands, max_ratio, out_counts);
}

extern "C" int pwdawn_gpu_match_gemm_pairs_guided(
    const uint8_t* dA, int nA, const float* xyA, const uint8_t* dB, int nB,
    const float* xyB, double max_ratio, const float* matrixAB,
    const float* matrixBA, int guide_mode, float max_residual,
    uint32_t* out_pairs, int max_pairs, int* out_num_matches) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  if (guide_mode < 0) return 1;
  return MatchGuidedImpl(dA, nA, xyA, dB, nB, xyB, max_ratio, matrixAB,
                         matrixBA, (uint32_t)guide_mode, max_residual,
                         out_pairs, max_pairs, out_num_matches);
}

#if defined(PWOFFICIAL_DAWN_HOST_TEST) && PWOFFICIAL_DAWN_HOST_TEST
// Host-test-only hooks (never compiled into the framework): raw direction
// maps of the last call (parity suite triple golden) and the call's timing
// split (upload / submit→done / readback).
extern "C" void pwdawn_gpu_match_debug_last_dirmaps(const int32_t** ab, int* na,
                                                    const int32_t** ba, int* nb) {
  if (ab) *ab = gDbgAB.data();
  if (na) *na = (int)gDbgAB.size();
  if (ba) *ba = gDbgBA.data();
  if (nb) *nb = (int)gDbgBA.size();
}
extern "C" void pwdawn_gpu_match_debug_last_timing(double* upload_ms,
                                                   double* submit_ms,
                                                   double* readback_ms) {
  if (upload_ms) *upload_ms = gDbgUploadMs;
  if (submit_ms) *submit_ms = gDbgSubmitMs;
  if (readback_ms) *readback_ms = gDbgReadbackMs;
}
#endif
