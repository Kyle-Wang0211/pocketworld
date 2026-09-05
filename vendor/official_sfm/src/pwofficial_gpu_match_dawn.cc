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
constexpr uint32_t kBlockedRows = 64;  // WGR of the universal (no-subgroup) kernel
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

// [COLCHUNK 2026-09-05] 按列分块(默认关,先做单变量 A/B)。
// 机制:现役按**行**分块 —— 104 个工作组切成 5 份、每份只有 21 个,摊到 A16 的
// GPU 核上每个 dispatch 尾部都要空转一截。实测拟合出**每多一个 dispatch ≈ +2.5ms**,
// 而单次 dispatch(monolithic)= 59.3ms、5 个 dispatch = 69.6ms,差 10.4ms(15%)。
// 按列切之后每个 dispatch 仍然发**全部** 104 个工作组(满并行、无尾部),
// 只是各自处理一段列 ⇒ **dispatch 次数不变、抢占粒度不变、热态间隔逻辑不变**,
// 纯赚。行向 top-2 靠 RowP 跨 dispatch 读-改-写(每组独占自己的行,无竞争)。
// 默认**开**;env OFFICIAL_AETHER_MATCH_DAWN_ROWCHUNK=1 回到按行分块做单变量 A/B。
bool kColChunk = getenv("OFFICIAL_AETHER_MATCH_DAWN_ROWCHUNK") == nullptr;

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
  // [COLCHUNK 2026-09-05] 复用原来的两个 pad 位,结构体布局与偏移全不变
  // (numA0 numB4 maxRatio8 maxDistance12 numWg16 rowBase20 colBase24 colSpan28)。
  colBase : u32,
  colSpan : u32,
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
// [COLCHUNK 2026-09-05] 行向 top-2 的跨 dispatch 持久化。按列分块后一个工作组
// 只看到部分列,行向最优必须跨 dispatch 累加。**每个工作组独占自己那 128 行**
// ⇒ 无跨组竞争,读-改-写即可,不需要像 ColP 那样再来一趟归并。
@group(0) @binding(6) var<storage, read_write> RowP : array<ColPart>;

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

  if (U.colBase != 0u && lcg == 0u && gRow < U.numA) {
    let rp = RowP[gRow];
    rowBest = rp.best;
    rowSecond = rp.second;
    rowBestI = rp.idx;
  }
  var col0 = U.colBase;
  let colEnd = min(U.colBase + U.colSpan, U.numB);
  loop {
    if (col0 >= colEnd) { break; }
    for (var e = lid; e < BT * 128u; e = e + 512u) {
      let brow = col0 + e / 128u;
      Bsh[e] = select(0.0, B[brow * 128u + (e % 128u)], brow < U.numB);
    }
    workgroupBarrier();

    // [ILP4 2026-09-04] 循环交换:nt 与 k 对调,4 个累加器同时推进。
    // 原形态的内层是**16 次串行依赖的 MMA**(每次都等上一次的 acc);交换后变成
    // **4 条独立累加链**,载入次数 / MMA 次数 / store 次数**一次不变**,只多 3 个
    // 累加器(每 lane +6 个 32 位寄存器)。手写 Metal 台架实测 −3.9% ~ −5.8%。
    // 线索来自 llama.cpp 的 mul_mm(ma[4] × mb[2] → c_res[8],8 条独立链);
    // **原生出货核与我们原来一样是单链**,所以这一刀是超越而不是追平。
    var acc0 = Res(0.0);
    var acc1 = Res(0.0);
    var acc2 = Res(0.0);
    var acc3 = Res(0.0);
    for (var k = 0u; k < 16u; k = k + 1u) {
      let b0 = subgroupMatrixLoad<Right>(&Bsh, (0u * 8u) * 128u + k * 8u, true, 128u);
      let b1 = subgroupMatrixLoad<Right>(&Bsh, (1u * 8u) * 128u + k * 8u, true, 128u);
      let b2 = subgroupMatrixLoad<Right>(&Bsh, (2u * 8u) * 128u + k * 8u, true, 128u);
      let b3 = subgroupMatrixLoad<Right>(&Bsh, (3u * 8u) * 128u + k * 8u, true, 128u);
      acc0 = subgroupMatrixMultiplyAccumulate(aFrag[k], b0, acc0);
      acc1 = subgroupMatrixMultiplyAccumulate(aFrag[k], b1, acc1);
      acc2 = subgroupMatrixMultiplyAccumulate(aFrag[k], b2, acc2);
      acc3 = subgroupMatrixMultiplyAccumulate(aFrag[k], b3, acc3);
    }
    subgroupMatrixStore(&accSh, (sg * 8u) * 32u + 0u * 8u, acc0, false, 32u);
    subgroupMatrixStore(&accSh, (sg * 8u) * 32u + 1u * 8u, acc1, false, 32u);
    subgroupMatrixStore(&accSh, (sg * 8u) * 32u + 2u * 8u, acc2, false, 32u);
    subgroupMatrixStore(&accSh, (sg * 8u) * 32u + 3u * 8u, acc3, false, 32u);
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
    RowP[gRow] = ColPart(rowBest, rowSecond, rowBestI);
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

// ── [UNIVERSAL 2026-09-05] 通用核:所有系统所有机型同一套,下限即上限 ──────
// 用户红线:不按硬件分叉。所以这个核**不用** subgroup_matrix(A13 / Mali / Adreno 没有)、
// **不用任何 subgroup 操作**(宽度 4~128 各家不同)、**不用 f16**(Vulkan 侧非普遍)、
// 只吃 WebGPU 的默认合同:256 线程 / 16 KiB 线程组内存 / 核心 WGSL。
//
// 为什么它有机会快过原生 MMA 核:metal-benchmarks 实测 simdgroup_matrix 在 Apple GPU 上
// **不比 FMA 峰值快**(只是降寄存器压力的调度便利);原生核 8192² 24ms = A16 FMA 峰值的 40%。
// 而现役 tiled 核用 dot4U8Packed(Apple 上 polyfill 成 1/4 速率的整数乘)且零寄存器分块,
// 所以慢 8.5x。这里换成 **f32 FMA + 4x4 寄存器分块 + 线程组 vec4 分块**:
//   u8 在 f32 里精确、逐积 ≤65025、K=128 总和 ≤8.3M < 2^24 ⇒ 与 MMA 路径**逐字节相同**。
//
// 形态:每工作组 64 行(WGR)× 全部列;每 tile 64 列(BT);K 分 4 段 × 32(KC)。
//   16 KiB 单一缓冲 S 分相复用:GEMM 相 [0,512)=A 段 [k][row/4]、[512,1024)=B 段 [k][col/4],
//   都按 k 为行、vec4 为列存 ⇒ 内层每 k 只要 2 次 vec4 载入换 16 次 FMA(0.125 载入/FMA),
//   16 个连续 lane 读 16 个连续 vec4,零 bank 冲突。扫描相 [0,1024)=acc [row][col/4]。
// top-2 语义逐字复刻 MMA 核:列升序 + 严格 > ⇒ 最小列号胜;行升序 + 严格 > ⇒ 最小行号胜;
//   ColP 仍是 rb-major、merge 核原文照抄 ⇒ 跨工作组归并 tie-break 不变。
// 支持 COLCHUNK(colBase/colSpan + RowP),host 侧走与 mma 完全相同的路径。
constexpr char kWgslBlockedPlain[] = R"WGSL(
const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 64u;
const BT : u32 = 64u;
const KC : u32 = 32u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  rowBase : u32,
  colBase : u32,
  colSpan : u32,
};

struct ColPart {
  best : f32,
  second : f32,
  idx : i32,
};

@group(0) @binding(0) var<storage, read> A : array<u32>;
@group(0) @binding(1) var<storage, read> B : array<u32>;
@group(0) @binding(2) var<storage, read_write> OutAB : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
@group(0) @binding(4) var<storage, read_write> ColP : array<ColPart>;
@group(0) @binding(5) var<storage, read_write> OutBA : array<i32>;
@group(0) @binding(6) var<storage, read_write> RowP : array<ColPart>;

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

var<workgroup> S : array<vec4<f32>, 1024>;

@compute @workgroup_size(256)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32) {
  let rb = U.rowBase + wg.x;
  let row0 = rb * WGR;
  let tr = lid / 16u;
  let tc = lid % 16u;

  let myRow = row0 + lid;
  var rowBest = 0.0;
  var rowSecond = 0.0;
  var rowBestI = -1;
  if (U.colBase != 0u && lid < WGR && myRow < U.numA) {
    let rp = RowP[myRow];
    rowBest = rp.best;
    rowSecond = rp.second;
    rowBestI = rp.idx;
  }

  var col0 = U.colBase;
  let colEnd = min(U.colBase + U.colSpan, U.numB);
  loop {
    if (col0 >= colEnd) { break; }

    var acc0 = vec4<f32>(0.0);
    var acc1 = vec4<f32>(0.0);
    var acc2 = vec4<f32>(0.0);
    var acc3 = vec4<f32>(0.0);

    for (var kc = 0u; kc < 4u; kc = kc + 1u) {
      workgroupBarrier();
      // 暂存:线程 0..127 负责 A、128..255 负责 B;每线程取同一 w 下连续 4 行的
      // 4 个 u32,写出 4 个**完整** vec4(k = w*4+j,j=0..3)。不对分量做运行时索引写。
      {
        let side = lid / 128u;
        let t = lid % 128u;
        let w = t / 16u;
        let q = t % 16u;
        let base = q * 4u;
        var x0 = 0u; var x1 = 0u; var x2 = 0u; var x3 = 0u;
        if (side == 0u) {
          let g = row0 + base;
          x0 = select(0u, A[(g + 0u) * 32u + kc * 8u + w], g + 0u < U.numA);
          x1 = select(0u, A[(g + 1u) * 32u + kc * 8u + w], g + 1u < U.numA);
          x2 = select(0u, A[(g + 2u) * 32u + kc * 8u + w], g + 2u < U.numA);
          x3 = select(0u, A[(g + 3u) * 32u + kc * 8u + w], g + 3u < U.numA);
        } else {
          let g = col0 + base;
          x0 = select(0u, B[(g + 0u) * 32u + kc * 8u + w], g + 0u < U.numB);
          x1 = select(0u, B[(g + 1u) * 32u + kc * 8u + w], g + 1u < U.numB);
          x2 = select(0u, B[(g + 2u) * 32u + kc * 8u + w], g + 2u < U.numB);
          x3 = select(0u, B[(g + 3u) * 32u + kc * 8u + w], g + 3u < U.numB);
        }
        let o = side * 512u + (w * 4u) * 16u + q;
        S[o + 0u * 16u] = vec4<f32>(f32(x0 & 255u), f32(x1 & 255u), f32(x2 & 255u), f32(x3 & 255u));
        S[o + 1u * 16u] = vec4<f32>(f32((x0 >> 8u) & 255u), f32((x1 >> 8u) & 255u), f32((x2 >> 8u) & 255u), f32((x3 >> 8u) & 255u));
        S[o + 2u * 16u] = vec4<f32>(f32((x0 >> 16u) & 255u), f32((x1 >> 16u) & 255u), f32((x2 >> 16u) & 255u), f32((x3 >> 16u) & 255u));
        S[o + 3u * 16u] = vec4<f32>(f32(x0 >> 24u), f32(x1 >> 24u), f32(x2 >> 24u), f32(x3 >> 24u));
      }
      workgroupBarrier();
      for (var k = 0u; k < KC; k = k + 1u) {
        let a4 = S[k * 16u + tr];
        let b4 = S[512u + k * 16u + tc];
        acc0 = acc0 + a4.x * b4;
        acc1 = acc1 + a4.y * b4;
        acc2 = acc2 + a4.z * b4;
        acc3 = acc3 + a4.w * b4;
      }
    }
    workgroupBarrier();
    S[(tr * 4u + 0u) * 16u + tc] = acc0;
    S[(tr * 4u + 1u) * 16u + tc] = acc1;
    S[(tr * 4u + 2u) * 16u + tc] = acc2;
    S[(tr * 4u + 3u) * 16u + tc] = acc3;
    workgroupBarrier();

    if (lid < WGR) {
      for (var v = 0u; v < 16u; v = v + 1u) {
        let d = S[lid * 16u + v];
        let c0 = i32(col0 + v * 4u);
        if (d.x > rowBest) { rowSecond = rowBest; rowBest = d.x; rowBestI = c0; }
        else if (d.x > rowSecond) { rowSecond = d.x; }
        if (d.y > rowBest) { rowSecond = rowBest; rowBest = d.y; rowBestI = c0 + 1; }
        else if (d.y > rowSecond) { rowSecond = d.y; }
        if (d.z > rowBest) { rowSecond = rowBest; rowBest = d.z; rowBestI = c0 + 2; }
        else if (d.z > rowSecond) { rowSecond = d.z; }
        if (d.w > rowBest) { rowSecond = rowBest; rowBest = d.w; rowBestI = c0 + 3; }
        else if (d.w > rowSecond) { rowSecond = d.w; }
      }
    } else if (lid < 2u * WGR) {
      let c = lid - WGR;
      let q = c / 4u;
      let m = c % 4u;
      var cb = 0.0;
      var cs = 0.0;
      var ci = -1;
      for (var r = 0u; r < WGR; r = r + 1u) {
        let d = S[r * 16u + q][m];
        if (d > cb) { cs = cb; cb = d; ci = i32(row0 + r); }
        else if (d > cs) { cs = d; }
      }
      let gc = col0 + c;
      if (gc < U.numB) { ColP[rb * U.numB + gc] = ColPart(cb, cs, ci); }
    }
    col0 = col0 + BT;
  }

  if (lid < WGR && myRow < U.numA) {
    RowP[myRow] = ColPart(rowBest, rowSecond, rowBestI);
    OutAB[myRow] = gatef(rowBest, rowSecond, rowBestI);
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

// [UNIVERSAL-84 2026-09-05] 8x4 / 128 线程变体:每 k 3 次 vec4 载入换 32 次 FMA
// (载入/FMA 从 0.125 降到 0.094),且扫描时 128 线程无人闲置。其余与基核逐字相同。
constexpr char kWgslBlocked84[] = R"WGSL(
const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 64u;
const BT : u32 = 64u;
const KC : u32 = 32u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  rowBase : u32,
  colBase : u32,
  colSpan : u32,
};

struct ColPart {
  best : f32,
  second : f32,
  idx : i32,
};

@group(0) @binding(0) var<storage, read> A : array<u32>;
@group(0) @binding(1) var<storage, read> B : array<u32>;
@group(0) @binding(2) var<storage, read_write> OutAB : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
@group(0) @binding(4) var<storage, read_write> ColP : array<ColPart>;
@group(0) @binding(5) var<storage, read_write> OutBA : array<i32>;
@group(0) @binding(6) var<storage, read_write> RowP : array<ColPart>;

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

var<workgroup> S : array<vec4<f32>, 1024>;

@compute @workgroup_size(128)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32) {
  let rb = U.rowBase + wg.x;
  let row0 = rb * WGR;
  let tr = lid / 16u;
  let tc = lid % 16u;

  let myRow = row0 + lid;
  var rowBest = 0.0;
  var rowSecond = 0.0;
  var rowBestI = -1;
  if (U.colBase != 0u && lid < WGR && myRow < U.numA) {
    let rp = RowP[myRow];
    rowBest = rp.best;
    rowSecond = rp.second;
    rowBestI = rp.idx;
  }

  var col0 = U.colBase;
  let colEnd = min(U.colBase + U.colSpan, U.numB);
  loop {
    if (col0 >= colEnd) { break; }

    var acc0 = vec4<f32>(0.0);
    var acc1 = vec4<f32>(0.0);
    var acc2 = vec4<f32>(0.0);
    var acc3 = vec4<f32>(0.0);
    var acc4 = vec4<f32>(0.0);
    var acc5 = vec4<f32>(0.0);
    var acc6 = vec4<f32>(0.0);
    var acc7 = vec4<f32>(0.0);

    for (var kc = 0u; kc < 4u; kc = kc + 1u) {
      workgroupBarrier();
      // 暂存:线程 0..127 负责 A、128..255 负责 B;每线程取同一 w 下连续 4 行的
      // 4 个 u32,写出 4 个**完整** vec4(k = w*4+j,j=0..3)。不对分量做运行时索引写。
      for (var side = 0u; side < 2u; side = side + 1u) {
        let w = lid / 16u;
        let q = lid % 16u;
        let base = q * 4u;
        var x0 = 0u; var x1 = 0u; var x2 = 0u; var x3 = 0u;
        if (side == 0u) {
          let g = row0 + base;
          x0 = select(0u, A[(g + 0u) * 32u + kc * 8u + w], g + 0u < U.numA);
          x1 = select(0u, A[(g + 1u) * 32u + kc * 8u + w], g + 1u < U.numA);
          x2 = select(0u, A[(g + 2u) * 32u + kc * 8u + w], g + 2u < U.numA);
          x3 = select(0u, A[(g + 3u) * 32u + kc * 8u + w], g + 3u < U.numA);
        } else {
          let g = col0 + base;
          x0 = select(0u, B[(g + 0u) * 32u + kc * 8u + w], g + 0u < U.numB);
          x1 = select(0u, B[(g + 1u) * 32u + kc * 8u + w], g + 1u < U.numB);
          x2 = select(0u, B[(g + 2u) * 32u + kc * 8u + w], g + 2u < U.numB);
          x3 = select(0u, B[(g + 3u) * 32u + kc * 8u + w], g + 3u < U.numB);
        }
        let o = side * 512u + (w * 4u) * 16u + q;
        S[o + 0u * 16u] = vec4<f32>(f32(x0 & 255u), f32(x1 & 255u), f32(x2 & 255u), f32(x3 & 255u));
        S[o + 1u * 16u] = vec4<f32>(f32((x0 >> 8u) & 255u), f32((x1 >> 8u) & 255u), f32((x2 >> 8u) & 255u), f32((x3 >> 8u) & 255u));
        S[o + 2u * 16u] = vec4<f32>(f32((x0 >> 16u) & 255u), f32((x1 >> 16u) & 255u), f32((x2 >> 16u) & 255u), f32((x3 >> 16u) & 255u));
        S[o + 3u * 16u] = vec4<f32>(f32(x0 >> 24u), f32(x1 >> 24u), f32(x2 >> 24u), f32(x3 >> 24u));
      }
      workgroupBarrier();
      for (var k = 0u; k < KC; k = k + 1u) {
        let al = S[k * 16u + tr * 2u];
        let ah = S[k * 16u + tr * 2u + 1u];
        let b4 = S[512u + k * 16u + tc];
        acc0 = acc0 + al.x * b4;
        acc1 = acc1 + al.y * b4;
        acc2 = acc2 + al.z * b4;
        acc3 = acc3 + al.w * b4;
        acc4 = acc4 + ah.x * b4;
        acc5 = acc5 + ah.y * b4;
        acc6 = acc6 + ah.z * b4;
        acc7 = acc7 + ah.w * b4;
      }
    }
    workgroupBarrier();
    S[(tr * 8u + 0u) * 16u + tc] = acc0;
    S[(tr * 8u + 1u) * 16u + tc] = acc1;
    S[(tr * 8u + 2u) * 16u + tc] = acc2;
    S[(tr * 8u + 3u) * 16u + tc] = acc3;
    S[(tr * 8u + 4u) * 16u + tc] = acc4;
    S[(tr * 8u + 5u) * 16u + tc] = acc5;
    S[(tr * 8u + 6u) * 16u + tc] = acc6;
    S[(tr * 8u + 7u) * 16u + tc] = acc7;
    workgroupBarrier();

    if (lid < WGR) {
      for (var v = 0u; v < 16u; v = v + 1u) {
        let d = S[lid * 16u + v];
        let c0 = i32(col0 + v * 4u);
        if (d.x > rowBest) { rowSecond = rowBest; rowBest = d.x; rowBestI = c0; }
        else if (d.x > rowSecond) { rowSecond = d.x; }
        if (d.y > rowBest) { rowSecond = rowBest; rowBest = d.y; rowBestI = c0 + 1; }
        else if (d.y > rowSecond) { rowSecond = d.y; }
        if (d.z > rowBest) { rowSecond = rowBest; rowBest = d.z; rowBestI = c0 + 2; }
        else if (d.z > rowSecond) { rowSecond = d.z; }
        if (d.w > rowBest) { rowSecond = rowBest; rowBest = d.w; rowBestI = c0 + 3; }
        else if (d.w > rowSecond) { rowSecond = d.w; }
      }
    } else if (lid < 2u * WGR) {
      let c = lid - WGR;
      let q = c / 4u;
      let m = c % 4u;
      var cb = 0.0;
      var cs = 0.0;
      var ci = -1;
      for (var r = 0u; r < WGR; r = r + 1u) {
        let d = S[r * 16u + q][m];
        if (d > cb) { cs = cb; cb = d; ci = i32(row0 + r); }
        else if (d > cs) { cs = d; }
      }
      let gc = col0 + c;
      if (gc < U.numB) { ColP[rb * U.numB + gc] = ColPart(cb, cs, ci); }
    }
    col0 = col0 + BT;
  }

  if (lid < WGR && myRow < U.numA) {
    RowP[myRow] = ColPart(rowBest, rowSecond, rowBestI);
    OutAB[myRow] = gatef(rowBest, rowSecond, rowBestI);
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

// [DIRECT 2026-09-05] 通用核的"去线程组暂存"形态(env OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT=1)。
// 依据(一手):Arm Mali OpenCL Developer Guide 6.1 §3.7 / "Use of local or private memory":
//   "If you allocate local or private memory, it is allocated in global memory. Moving data from
//    global to local memory typically does not improve performance." /
//   "Some code copies data into a local or private memory, processes it, then writes it out again.
//    This code wastes both performance and power by performing these copies." /
//   "If you remove copy operations to or from these memories, also remove the associated barriers."
// Arm Compute Library 的 Mali GEMM(gemm_mm_reshaped_only_rhs_*)正是这么写的:不用 __local,
// 右矩阵预先 reshape/转置,内层全靠寄存器分块 + 向量载入。
// 这里:A/B 各做一次预转置到 f32 [k][row/4] 布局(xpose 入口),主循环三次 vec4 全局载入喂 32 次 FMA,
// GEMM 段零 barrier;S 只留给 64x64 结果交换的扫描段。算术与 8x4+PIPEB 逐 FMA 同源 ⇒ 逐字节同。
// Mate 10 起因:13312² 7234ms = 峰值的 ~3%,而载入/FMA 配比在纸面上并不缺;可疑项正是暂存+barrier。
constexpr char kWgslXpose[] = R"WGSL(
struct XParams { n4 : u32, p1 : u32, p2 : u32, p3 : u32, };
@group(0) @binding(0) var<storage, read> Src : array<u32>;
@group(0) @binding(3) var<uniform> X : XParams;
@group(0) @binding(7) var<storage, read_write> Dst : array<vec4<f32>>;
// 线程 i:q = 行四元组(相邻线程相邻 q ⇒ 写合并),w = 32 个 u32 字之一(k = 4w..4w+3)。
// 源缓冲已按 n4*4 行零补位(见 UploadDesc),越界由构造排除。
@compute @workgroup_size(64)
fn xpose(@builtin(global_invocation_id) gid : vec3<u32>) {
  let n4 = X.n4;
  let i = gid.x;
  if (i >= n4 * 32u) { return; }
  let q = i % n4;
  let w = i / n4;
  let x0 = Src[(4u * q + 0u) * 32u + w];
  let x1 = Src[(4u * q + 1u) * 32u + w];
  let x2 = Src[(4u * q + 2u) * 32u + w];
  let x3 = Src[(4u * q + 3u) * 32u + w];
  let o = (w * 4u) * n4 + q;
  Dst[o + 0u * n4] = vec4<f32>(f32(x0 & 255u), f32(x1 & 255u), f32(x2 & 255u), f32(x3 & 255u));
  Dst[o + 1u * n4] = vec4<f32>(f32((x0 >> 8u) & 255u), f32((x1 >> 8u) & 255u), f32((x2 >> 8u) & 255u), f32((x3 >> 8u) & 255u));
  Dst[o + 2u * n4] = vec4<f32>(f32((x0 >> 16u) & 255u), f32((x1 >> 16u) & 255u), f32((x2 >> 16u) & 255u), f32((x3 >> 16u) & 255u));
  Dst[o + 3u * n4] = vec4<f32>(f32(x0 >> 24u), f32(x1 >> 24u), f32(x2 >> 24u), f32(x3 >> 24u));
}
)WGSL";

constexpr char kWgslBlocked84Direct[] = R"WGSL(
const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 64u;
const BT : u32 = 64u;
const KD : u32 = 128u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  rowBase : u32,
  colBase : u32,
  colSpan : u32,
};

struct ColPart {
  best : f32,
  second : f32,
  idx : i32,
};

@group(0) @binding(0) var<storage, read> A : array<u32>;
@group(0) @binding(1) var<storage, read> B : array<u32>;
@group(0) @binding(2) var<storage, read_write> OutAB : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
@group(0) @binding(4) var<storage, read_write> ColP : array<ColPart>;
@group(0) @binding(5) var<storage, read_write> OutBA : array<i32>;
@group(0) @binding(6) var<storage, read_write> RowP : array<ColPart>;
@group(0) @binding(7) var<storage, read> At : array<vec4<f32>>;
@group(0) @binding(8) var<storage, read> Bt : array<vec4<f32>>;

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

var<workgroup> S : array<vec4<f32>, 1024>;

@compute @workgroup_size(128)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32) {
  let rb = U.rowBase + wg.x;
  let row0 = rb * WGR;
  let tr = lid / 16u;
  let tc = lid % 16u;
  let rowPad4 = ((U.numA + 63u) / 64u) * 16u;
  let colPad4 = ((U.numB + 127u) / 128u) * 32u;
  let rq = row0 / 4u + tr * 2u;

  let myRow = row0 + lid;
  var rowBest = 0.0;
  var rowSecond = 0.0;
  var rowBestI = -1;
  if (U.colBase != 0u && lid < WGR && myRow < U.numA) {
    let rp = RowP[myRow];
    rowBest = rp.best;
    rowSecond = rp.second;
    rowBestI = rp.idx;
  }

  var col0 = U.colBase;
  let colEnd = min(U.colBase + U.colSpan, U.numB);
  loop {
    if (col0 >= colEnd) { break; }
    let cq = col0 / 4u + tc;

    var acc0 = vec4<f32>(0.0);
    var acc1 = vec4<f32>(0.0);
    var acc2 = vec4<f32>(0.0);
    var acc3 = vec4<f32>(0.0);
    var acc4 = vec4<f32>(0.0);
    var acc5 = vec4<f32>(0.0);
    var acc6 = vec4<f32>(0.0);
    var acc7 = vec4<f32>(0.0);

    var b4 = Bt[cq];
    for (var k = 0u; k < KD; k = k + 1u) {
      let al = At[k * rowPad4 + rq];
      let ah = At[k * rowPad4 + rq + 1u];
      let bn = Bt[min(k + 1u, KD - 1u) * colPad4 + cq];
      acc0 = acc0 + al.x * b4;
      acc1 = acc1 + al.y * b4;
      acc2 = acc2 + al.z * b4;
      acc3 = acc3 + al.w * b4;
      acc4 = acc4 + ah.x * b4;
      acc5 = acc5 + ah.y * b4;
      acc6 = acc6 + ah.z * b4;
      acc7 = acc7 + ah.w * b4;
      b4 = bn;
    }
    workgroupBarrier();
    S[(tr * 8u + 0u) * 16u + tc] = acc0;
    S[(tr * 8u + 1u) * 16u + tc] = acc1;
    S[(tr * 8u + 2u) * 16u + tc] = acc2;
    S[(tr * 8u + 3u) * 16u + tc] = acc3;
    S[(tr * 8u + 4u) * 16u + tc] = acc4;
    S[(tr * 8u + 5u) * 16u + tc] = acc5;
    S[(tr * 8u + 6u) * 16u + tc] = acc6;
    S[(tr * 8u + 7u) * 16u + tc] = acc7;
    workgroupBarrier();

    if (lid < WGR) {
      for (var v = 0u; v < 16u; v = v + 1u) {
        let d = S[lid * 16u + v];
        let c0 = i32(col0 + v * 4u);
        if (d.x > rowBest) { rowSecond = rowBest; rowBest = d.x; rowBestI = c0; }
        else if (d.x > rowSecond) { rowSecond = d.x; }
        if (d.y > rowBest) { rowSecond = rowBest; rowBest = d.y; rowBestI = c0 + 1; }
        else if (d.y > rowSecond) { rowSecond = d.y; }
        if (d.z > rowBest) { rowSecond = rowBest; rowBest = d.z; rowBestI = c0 + 2; }
        else if (d.z > rowSecond) { rowSecond = d.z; }
        if (d.w > rowBest) { rowSecond = rowBest; rowBest = d.w; rowBestI = c0 + 3; }
        else if (d.w > rowSecond) { rowSecond = d.w; }
      }
    } else if (lid < 2u * WGR) {
      let c = lid - WGR;
      let q = c / 4u;
      let m = c % 4u;
      var cb = 0.0;
      var cs = 0.0;
      var ci = -1;
      for (var r = 0u; r < WGR; r = r + 1u) {
        let d = S[r * 16u + q][m];
        if (d > cb) { cs = cb; cb = d; ci = i32(row0 + r); }
        else if (d > cs) { cs = d; }
      }
      let gc = col0 + c;
      if (gc < U.numB) { ColP[rb * U.numB + gc] = ColPart(cb, cs, ci); }
    }
    col0 = col0 + BT;
  }

  if (lid < WGR && myRow < U.numA) {
    RowP[myRow] = ColPart(rowBest, rowSecond, rowBestI);
    OutAB[myRow] = gatef(rowBest, rowSecond, rowBestI);
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

// [UNIVERSAL-88 2026-09-05] 8x8 / 64 线程:16 条独立累加链,每 k 4 次载入换 64 次 FMA。
// 依据:8x4/128 线程的纯 FMA 地板(90.4)优于 4x4/256(100.2)—— 线程数不是瓶颈,链数才是。
// 代价:扫描变两趟(64 线程先行后列)。
constexpr char kWgslBlocked88[] = R"WGSL(
const INV_SQ_NORM : f32 = 0.000003814697265625; // 1/262144
const WGR : u32 = 64u;
const BT : u32 = 64u;
const KC : u32 = 32u;

struct Params {
  numA : u32,
  numB : u32,
  maxRatio : f32,
  maxDistance : f32,
  numWg : u32,
  rowBase : u32,
  colBase : u32,
  colSpan : u32,
};

struct ColPart {
  best : f32,
  second : f32,
  idx : i32,
};

@group(0) @binding(0) var<storage, read> A : array<u32>;
@group(0) @binding(1) var<storage, read> B : array<u32>;
@group(0) @binding(2) var<storage, read_write> OutAB : array<i32>;
@group(0) @binding(3) var<uniform> U : Params;
@group(0) @binding(4) var<storage, read_write> ColP : array<ColPart>;
@group(0) @binding(5) var<storage, read_write> OutBA : array<i32>;
@group(0) @binding(6) var<storage, read_write> RowP : array<ColPart>;

fn gatef(best : f32, second : f32, bestIndex : i32) -> i32 {
  if (bestIndex < 0) { return -1; }
  let bd = acos(min(best * INV_SQ_NORM, 1.0));
  let sd = acos(min(second * INV_SQ_NORM, 1.0));
  if (bd <= U.maxDistance && bd < U.maxRatio * sd) { return bestIndex; }
  return -1;
}

var<workgroup> S : array<vec4<f32>, 1024>;

@compute @workgroup_size(64)
fn main(@builtin(workgroup_id) wg : vec3<u32>,
        @builtin(local_invocation_index) lid : u32) {
  let rb = U.rowBase + wg.x;
  let row0 = rb * WGR;
  let tr = lid / 8u;
  let tc = lid % 8u;

  let myRow = row0 + lid;
  var rowBest = 0.0;
  var rowSecond = 0.0;
  var rowBestI = -1;
  if (U.colBase != 0u && lid < WGR && myRow < U.numA) {
    let rp = RowP[myRow];
    rowBest = rp.best;
    rowSecond = rp.second;
    rowBestI = rp.idx;
  }

  var col0 = U.colBase;
  let colEnd = min(U.colBase + U.colSpan, U.numB);
  loop {
    if (col0 >= colEnd) { break; }

    var acc0 = vec4<f32>(0.0);
    var acc1 = vec4<f32>(0.0);
    var acc2 = vec4<f32>(0.0);
    var acc3 = vec4<f32>(0.0);
    var acc4 = vec4<f32>(0.0);
    var acc5 = vec4<f32>(0.0);
    var acc6 = vec4<f32>(0.0);
    var acc7 = vec4<f32>(0.0);
    var acd0 = vec4<f32>(0.0);
    var acd1 = vec4<f32>(0.0);
    var acd2 = vec4<f32>(0.0);
    var acd3 = vec4<f32>(0.0);
    var acd4 = vec4<f32>(0.0);
    var acd5 = vec4<f32>(0.0);
    var acd6 = vec4<f32>(0.0);
    var acd7 = vec4<f32>(0.0);

    for (var kc = 0u; kc < 4u; kc = kc + 1u) {
      workgroupBarrier();
      // 暂存:线程 0..127 负责 A、128..255 负责 B;每线程取同一 w 下连续 4 行的
      // 4 个 u32,写出 4 个**完整** vec4(k = w*4+j,j=0..3)。不对分量做运行时索引写。
      for (var pair = 0u; pair < 4u; pair = pair + 1u) {
        let side = pair / 2u;
        let t = lid + (pair % 2u) * 64u;
        let w = t / 16u;
        let q = t % 16u;
        let base = q * 4u;
        var x0 = 0u; var x1 = 0u; var x2 = 0u; var x3 = 0u;
        if (side == 0u) {
          let g = row0 + base;
          x0 = select(0u, A[(g + 0u) * 32u + kc * 8u + w], g + 0u < U.numA);
          x1 = select(0u, A[(g + 1u) * 32u + kc * 8u + w], g + 1u < U.numA);
          x2 = select(0u, A[(g + 2u) * 32u + kc * 8u + w], g + 2u < U.numA);
          x3 = select(0u, A[(g + 3u) * 32u + kc * 8u + w], g + 3u < U.numA);
        } else {
          let g = col0 + base;
          x0 = select(0u, B[(g + 0u) * 32u + kc * 8u + w], g + 0u < U.numB);
          x1 = select(0u, B[(g + 1u) * 32u + kc * 8u + w], g + 1u < U.numB);
          x2 = select(0u, B[(g + 2u) * 32u + kc * 8u + w], g + 2u < U.numB);
          x3 = select(0u, B[(g + 3u) * 32u + kc * 8u + w], g + 3u < U.numB);
        }
        let o = side * 512u + (w * 4u) * 16u + q;
        S[o + 0u * 16u] = vec4<f32>(f32(x0 & 255u), f32(x1 & 255u), f32(x2 & 255u), f32(x3 & 255u));
        S[o + 1u * 16u] = vec4<f32>(f32((x0 >> 8u) & 255u), f32((x1 >> 8u) & 255u), f32((x2 >> 8u) & 255u), f32((x3 >> 8u) & 255u));
        S[o + 2u * 16u] = vec4<f32>(f32((x0 >> 16u) & 255u), f32((x1 >> 16u) & 255u), f32((x2 >> 16u) & 255u), f32((x3 >> 16u) & 255u));
        S[o + 3u * 16u] = vec4<f32>(f32(x0 >> 24u), f32(x1 >> 24u), f32(x2 >> 24u), f32(x3 >> 24u));
      }
      workgroupBarrier();
      for (var k = 0u; k < KC; k = k + 1u) {
        let al = S[k * 16u + tr * 2u];
        let ah = S[k * 16u + tr * 2u + 1u];
        let b4 = S[512u + k * 16u + tc * 2u];
        let bh = S[512u + k * 16u + tc * 2u + 1u];
        acc0 = acc0 + al.x * b4;
        acc1 = acc1 + al.y * b4;
        acc2 = acc2 + al.z * b4;
        acc3 = acc3 + al.w * b4;
        acc4 = acc4 + ah.x * b4;
        acc5 = acc5 + ah.y * b4;
        acc6 = acc6 + ah.z * b4;
        acc7 = acc7 + ah.w * b4;
        acd0 = acd0 + al.x * bh;
        acd1 = acd1 + al.y * bh;
        acd2 = acd2 + al.z * bh;
        acd3 = acd3 + al.w * bh;
        acd4 = acd4 + ah.x * bh;
        acd5 = acd5 + ah.y * bh;
        acd6 = acd6 + ah.z * bh;
        acd7 = acd7 + ah.w * bh;
      }
    }
    workgroupBarrier();
    S[(tr * 8u + 0u) * 16u + tc * 2u] = acc0;
    S[(tr * 8u + 1u) * 16u + tc * 2u] = acc1;
    S[(tr * 8u + 2u) * 16u + tc * 2u] = acc2;
    S[(tr * 8u + 3u) * 16u + tc * 2u] = acc3;
    S[(tr * 8u + 4u) * 16u + tc * 2u] = acc4;
    S[(tr * 8u + 5u) * 16u + tc * 2u] = acc5;
    S[(tr * 8u + 6u) * 16u + tc * 2u] = acc6;
    S[(tr * 8u + 7u) * 16u + tc * 2u] = acc7;
    S[(tr * 8u + 0u) * 16u + tc * 2u + 1u] = acd0;
    S[(tr * 8u + 1u) * 16u + tc * 2u + 1u] = acd1;
    S[(tr * 8u + 2u) * 16u + tc * 2u + 1u] = acd2;
    S[(tr * 8u + 3u) * 16u + tc * 2u + 1u] = acd3;
    S[(tr * 8u + 4u) * 16u + tc * 2u + 1u] = acd4;
    S[(tr * 8u + 5u) * 16u + tc * 2u + 1u] = acd5;
    S[(tr * 8u + 6u) * 16u + tc * 2u + 1u] = acd6;
    S[(tr * 8u + 7u) * 16u + tc * 2u + 1u] = acd7;
    workgroupBarrier();

    if (lid < WGR) {
      for (var v = 0u; v < 16u; v = v + 1u) {
        let d = S[lid * 16u + v];
        let c0 = i32(col0 + v * 4u);
        if (d.x > rowBest) { rowSecond = rowBest; rowBest = d.x; rowBestI = c0; }
        else if (d.x > rowSecond) { rowSecond = d.x; }
        if (d.y > rowBest) { rowSecond = rowBest; rowBest = d.y; rowBestI = c0 + 1; }
        else if (d.y > rowSecond) { rowSecond = d.y; }
        if (d.z > rowBest) { rowSecond = rowBest; rowBest = d.z; rowBestI = c0 + 2; }
        else if (d.z > rowSecond) { rowSecond = d.z; }
        if (d.w > rowBest) { rowSecond = rowBest; rowBest = d.w; rowBestI = c0 + 3; }
        else if (d.w > rowSecond) { rowSecond = d.w; }
      }
    }
    workgroupBarrier();
    if (lid < WGR) {
      let c = lid;
      let q = c / 4u;
      let m = c % 4u;
      var cb = 0.0;
      var cs = 0.0;
      var ci = -1;
      for (var r = 0u; r < WGR; r = r + 1u) {
        let d = S[r * 16u + q][m];
        if (d > cb) { cs = cb; cb = d; ci = i32(row0 + r); }
        else if (d > cs) { cs = d; }
      }
      let gc = col0 + c;
      if (gc < U.numB) { ColP[rb * U.numB + gc] = ColPart(cb, cs, ci); }
    }
    col0 = col0 + BT;
  }

  if (lid < WGR && myRow < U.numA) {
    RowP[myRow] = ColPart(rowBest, rowSecond, rowBestI);
    OutAB[myRow] = gatef(rowBest, rowSecond, rowBestI);
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
  // [COLCHUNK 2026-09-05] 原 pad1/pad2 改作列分块参数;布局与大小不变。
  uint32_t numWg, rowBase, colBase, colSpan;
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
constexpr uint64_t kColBaseOffset = 24;  // Params::colBase
constexpr uint64_t kColSpanOffset = 28;  // Params::colSpan
constexpr uint64_t kRowBaseOffset = 20;  // byte offset of rowBase in both

// ══════════════════════ Dawn context (process-wide) ══════════════════════

enum class Backend { kNone, kMma, kTiled, kBlocked };

// [FINGERPRINT-LABEL 2026-09-05] 指纹里的核名必须与实际选核形态一致:Mate 10 首跑报出
// "blocked(fma4x4,V3)",而默认早已是 8x4+PIPEB —— 指纹说了假话。与 EnsureBlockedPipeline 的
// 选核逻辑读同一组 env,同源不会再漂。
static const char* BlockedLabel() {
  if (std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT") != nullptr) {
    const bool g = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_G") != nullptr;
    const bool tx = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_TEX") != nullptr;
    const bool k44 = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_44") != nullptr;
    static std::string lbl;
    const bool nopb = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_NOPB") != nullptr;
    const bool txa = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_TEXA") != nullptr;
    const bool sm = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_SCANMEM") != nullptr;
    const bool fm = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_FMA") != nullptr;
    const bool w128 = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_W128") != nullptr;
    const bool psc = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_PSCAN") != nullptr;
    const bool pk = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_PACKED") != nullptr;
    const bool h16 = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_F16") != nullptr;
    const bool tm = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_TMAP") != nullptr;
    const bool tb = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_TAILB") != nullptr;
    const char* un = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_UNROLL");
    const char* uh = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_UNROLLH");
    const bool pa = std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_PIPEA") != nullptr;
    lbl = std::string("blocked(") + (k44 ? "fma4x4" : "fma8x4") + "+direct" + (g ? "g" : "") + (tx ? "+tex" : "") + (txa ? "+texa" : "") + (nopb ? "+nopb" : "") + (sm ? "+scanmem" : "") + (fm ? "+fma" : "") + (w128 ? "+w128" : "") + (psc ? "+pscan" : "") + (pk ? "+packed" : "") + (h16 ? "+f16" : "") + (tm ? "+tmap" : "") + (tb ? "+tailb" : "") + (un ? std::string("+unroll") + un : std::string("")) + (uh ? std::string("+unrollh") + uh : std::string("")) + (pa ? "+pipea" : "") + ",V4)";
    return lbl.c_str();
  }
  if (std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_88") != nullptr) return "blocked(fma8x8,V3)";
  if (std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_44") != nullptr) return "blocked(fma4x4,V3)";
  if (std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_PIPE") != nullptr) return "blocked(fma8x4+pipe,V3)";
  if (std::getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_NOPIPEB") != nullptr) return "blocked(fma8x4,V3)";
  return "blocked(fma8x4+pipeb,V3)";
}
// [UNIVERSAL 2026-09-05] 主路径(mma / blocked)每工作组的行数;两者共用同一条 host 路径。
uint32_t gBlockedRows = kBlockedRows;  // [DIRECT-44-W128] 选核时可改为 32
inline uint32_t MainRows(Backend b) {
  return b == Backend::kBlocked ? gBlockedRows : kMmaRows;
}
// [COLCHUNK-ALIGN 2026-09-05] 列分块的 span 必须是**该核 tile 宽度**的整数倍,
// 否则 tile 跨过 chunk 边界,同一列被两个 dispatch 各扫一次:第二次
// `d > rowSecond` 为真 ⇒ second 被抬到等于 best ⇒ ratio 判负 ⇒ 匹配丢失。
// EMA 按时序选 span,所以表现为**非确定性**(设备上一轮对一轮错)。
// mma 核 BT=32,通用核 BT=64。
inline uint32_t MainTileCols(Backend b) {
  return b == Backend::kBlocked ? 64u : 32u;
}

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
  wgpu::ComputePipeline p_xpose;  // [DIRECT] A/B → f32 [k][row/4] 预转置
  bool direct = false;            // [DIRECT] 主核走 At/Bt(绑定 7/8),GEMM 段无线程组暂存
  bool direct_g = false;          // [DIRECT-G] 扫描交换也走全局暂存 Scr(绑定 9),核内无 var<workgroup>
  bool direct_tex = false;        // [DIRECT-TEX] B 侧走 rgba32float 纹理(绑定 8 变纹理)
  bool direct_texa = false;       // [DIRECT-TEXA] A 侧走纹理(绑定 7 变纹理)
  bool direct_packed = false;     // [DIRECT-PACKED] At/Bt 存 u8 打包,载入字节 ÷4
  bool feat_f16 = false;          // [DIRECT-F16] 设备已带 ShaderF16
  bool direct_f16 = false;        // [DIRECT-F16] At/Bt 存 vec4<f16>,载入字节 ÷2
  wgpu::Texture atTex; uint32_t atTexW = 0;               // [DIRECT-TEXA] MatchPairs 路径
  wgpu::Texture pbAtTex; uint32_t pbAtTexW = 0;           // [DIRECT-TEXA] ProbeBatch 路径
  wgpu::Texture btTex; uint32_t btTexW = 0;               // [DIRECT-TEX] MatchPairs 路径的纹理缓存
  std::vector<wgpu::Texture> pbTex; std::vector<uint32_t> pbTexW;  // [DIRECT-TEX] ProbeBatch 每候选
  bool tried_main = false, tried_guided = false;
  // Pools (grow-only).
  PoolBuf a{}, b{}, outAB{}, outBA{}, colp{}, rowp{}, uni{}, staging{}, ptsA{}, ptsB{},
      matAB{}, matBA{};
  PoolBuf pbA{}, pbB{}, pbOutAB{}, pbOutBA{}, pbColp{}, pbRowp{}, pbUni{}, pbStaging{};
  PoolBuf at{}, bt{}, pbAt{}, pbBt{}, pbXUni{};  // [DIRECT]
  PoolBuf scr{}, pbScr{};                         // [DIRECT-G]
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
#if !defined(__APPLE__)
  // [NO-NULL-ADAPTER 2026-09-05] 非 Apple 平台只接受 Vulkan。起因:Mate 10(麒麟 970,
  // 有 vulkan.kirin970.so、Vulkan 1.1)上 Dawn 把请求交给了 **Null 后端**(软件空操作),
  // rc=0、0.5ms、count=1、sha 是垃圾 —— 指纹抓到了 adapter="Null backend",但 RESULT
  // 长得像成功。这是产品级的静默失败形态。显式指定 Vulkan 后,拒绝原因会进回调消息。
  aopts.backendType = wgpu::BackendType::Vulkan;
#endif
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
    // [NO-NULL-ADAPTER 2026-09-05] Null 后端一律拒绝:它会"成功"地吐出垃圾。
    // 走无 GPU 路径(EnsureDawn 返回 nullptr ⇒ 管线 fail-closed),并留指纹。
    if (info.backendType == wgpu::BackendType::Null) {
      Log("adapter is the Null backend — refusing (would silently return garbage)");
      if (const char* home = std::getenv("HOME")) {
        const std::string fp = std::string(home) + "/Documents/matcher_backend.jsonl";
        if (FILE* f = std::fopen(fp.c_str(), "a")) {
          std::fprintf(f, "{\"adapter_refused\":\"Null backend\"}\n");
          std::fclose(f);
        }
      }
      c->adapter = nullptr;
      return nullptr;
    }
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
  // [IOS-SUBGROUP-VENDOR 2026-09-04] 🔴 这道闸曾让**每一台 iPhone**都无条件回退 tiled。
  // Dawn 在 iOS 上把 vendorId 硬写成 0(metal/PhysicalDeviceMTL.mm 的 IOS 分支
  // GetDevicePCIInfo:`*ids = PCIIDs{0, 0}`),于是 gpu_info::IsApple() 为假,
  // subgroup size 被报成 [4,64] 而不是 Apple GPU 真实的 [32,32] —— 而同一个文件里
  // 上游自己的注释正引着 Apple 的话 "on all Apple GPUs, it is equal to 32"。
  // 后果:09-04 首次上机,A16 上每对 8192² 要 205ms(同尺寸原生 Metal 24ms,8.5×),
  // 指纹显示 kernel=tiled —— 我们优化了一整天的 MMA 核在设备上一次都没执行过。
  // iOS 上不存在非 Apple 的 GPU;macOS 上 Dawn 自己也是按设备名里的 "Apple" 认厂商的
  // (kVendors/GetVendorIdFromVendors),所以这里用同一判据放行,判据强度与上游一致。
  // 仍然要求 [min,max] 真的把 32 夹在中间 —— 核是按 32 lane 写死的,这个要求不放松。
  const bool apple_gpu = c->adapter_name.find("Apple") != std::string::npos;
  const bool sg32 = (c->subgroup_min == 32 && c->subgroup_max == 32) ||
                    (apple_gpu && c->subgroup_min <= 32 && c->subgroup_max >= 32);
  const bool mma_ok = c->feat_subgroups && c->feat_sgmatrix &&
                      c->sgcfg_f32_8x8x8 && sg32 &&
                      c->lim_invocations >= 512 &&
                      c->lim_size_x >= 512 && c->lim_storage >= 32768;
  std::vector<wgpu::FeatureName> feats;
  wgpu::Limits req{};
  wgpu::DeviceDescriptor dd{};
  // [DIRECT-F16] 只在 env 明示时申请 f16 存储/算术特性(可选特性,不进默认合同)。
  if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_F16") != nullptr &&
      c->adapter.HasFeature(wgpu::FeatureName::ShaderF16)) {
    feats.push_back(wgpu::FeatureName::ShaderF16);
    c->feat_f16 = true;
  }
  // [UNIVERSAL 2026-09-05] 通用核只吃默认合同,不要任何特性/限制。
  // [ONE-KERNEL 2026-09-05 用户裁决] 产品路径三端一律通用核 blocked,mma 不再是默认。
  // mma 只在 env OFFICIAL_AETHER_MATCH_DAWN_KERNEL=mma 时显式选用 —— 留作对拍 oracle
  // (parity / fullgate 仍用它与冻结金标准互证),不进产品路径。
  // 代价已知:A14+ 上通用核比 mma 慢约 33%(13312² 93.5 vs 70ms);换来的是
  // A13 / Mali / Adreno / A16 跑同一份字节的 WGSL、同一套闸、同一份输出。
  const bool want_mma_explicit = force && std::strcmp(force, "mma") == 0;
  const bool want_tiled_explicit = force && std::strcmp(force, "tiled") == 0;
  if (!want_mma_explicit && !want_tiled_explicit) {
    c->backend = Backend::kBlocked;
    c->packed = true;
    c->mixed = false;
  } else if (want_mma_explicit && mma_ok) {
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
  } else if (force && std::strcmp(force, "tiled") == 0) {
    c->backend = Backend::kTiled;
  } else {
    // [UNIVERSAL-FALLBACK 2026-09-05] 没有 MMA(A13 / Mali / Adreno)时默认落通用核,
    // 不再落 tiled:Adreno 660 实测 tiled 3202ms vs blocked 430ms(8192²),逐字节相同。
    // tiled 只在 env OFFICIAL_AETHER_MATCH_DAWN_KERNEL=tiled 时显式选用(保留为对照)。
    c->backend = Backend::kBlocked;
    c->packed = true;
    c->mixed = false;
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
  if (!c->device && c->backend == Backend::kMma) {
    // [MMA-DEGRADE 2026-09-04] 安全网:放宽上面那道闸之后,若某机型确实拿不到
    // MMA 所需的特性/限制,原来的行为是 EnsureDawn 返回 nullptr ⇒ 整个 Dawn
    // 匹配器不可用 ⇒ 管线逐对跳过(注释明写"绝不 CPU 暴力回退")⇒ **点数静默变少**。
    // 那是最坏的失败形态。改为降级重试 tiled:慢,但结果仍逐字节正确。
    Log("MMA device creation failed (%s); degrading to blocked", dmsg.c_str());
    c->backend = Backend::kBlocked;
    c->packed = true;
    c->mixed = false;
    c->ts_on = false;
    dd.requiredFeatureCount = 0;
    dd.requiredFeatures = nullptr;
    dd.requiredLimits = nullptr;
    dmsg.clear();
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
  }
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
                c->backend == Backend::kMma     ? "mma(fusedr128-db,V0)"
                : c->backend == Backend::kBlocked ? BlockedLabel()
                                                  : "tiled(dot4U8Packed,V1/V2)",
                c->adapter_name.c_str(), (int)c->feat_subgroups,
                (int)c->feat_sgmatrix, (int)c->sgcfg_f32_8x8x8,
                (int)c->sgcfg_f16_f32, (int)c->mixed, c->subgroup_min,
                c->subgroup_max, (int)c->feat_packed_dot, (int)c->feat_timestamp,
                c->lim_storage, c->lim_invocations, c->lim_size_x,
                (force && std::strcmp(force, "tiled") == 0) ? " (forced tiled)"
                                                            : "");
  c->backend_info = info;
  // [DEVICE-FINGERPRINT 2026-09-04] 电脑侧必须能读出设备**到底选了哪个核**和适配器能力。
  // 起因:09-04 首次上机,A16 上每对 8192x8192 要 205ms,而同尺寸原生 Metal 只要 24ms
  // (8.5x);同一份核在 M3 Pro 上是 0.986x。没有这一行就分不清两件事 ——
  // 「设备回退到了 tiled 整数路径」还是「MMA 核在 A16 上就是慢」。
  // 只在 Dawn 初始化时写一次;纯观测,失败不抛。banner 里含引号,所以逐字段落 JSON。
  if (const char* home = std::getenv("HOME")) {
    const std::string fp = std::string(home) + "/Documents/matcher_backend.jsonl";
    if (FILE* f = std::fopen(fp.c_str(), "a")) {
      std::fprintf(f,
                   "{\"dawn_init\":1,\"kernel\":\"%s\",\"adapter\":\"%s\","
                   "\"subgroups\":%d,\"sgmatrix\":%d,\"f32_8x8x8\":%d,"
                   "\"f16_f32\":%d,\"mixed\":%d,\"subgroup_min\":%u,"
                   "\"subgroup_max\":%u,\"packed_dot\":%d,\"storage\":%u,"
                   "\"invocations\":%u,\"sizeX\":%u}\n",
                   c->backend == Backend::kMma     ? "mma(fusedr128-db,V0)"
                   : c->backend == Backend::kBlocked ? BlockedLabel()
                                                     : "tiled(dot4U8Packed,V1/V2)",
                   c->adapter_name.c_str(), (int)c->feat_subgroups,
                   (int)c->feat_sgmatrix, (int)c->sgcfg_f32_8x8x8,
                   (int)c->sgcfg_f16_f32, (int)c->mixed, c->subgroup_min,
                   c->subgroup_max, (int)c->feat_packed_dot, c->lim_storage,
                   c->lim_invocations, c->lim_size_x);
      std::fclose(f);
    }
  }
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
// [ANCHOR-ALARM 2026-09-05] 锚点失配必须**在设备上也看得见**。
// 09-05 一天里 NOSCAN / Stage0 / ExtraBarrier 三个探针都被查出早已静默退化,
// 而设备侧读到的"扫描只值 1.5%""B 流量零成本""barrier 零成本"全部作废 ——
// 因为 app 的 stderr 传不回电脑。现在同一条告警也追加进 matcher_backend.jsonl,
// 电脑侧 devicectl copy from 就能看到,不用开 app。
void AnchorAlarm(const char* what, const char* detail) {
  std::fprintf(stderr, "[pwofficial_gpu_match_dawn] 🔴 锚点失配:%s %s\n", what,
               detail ? detail : "");
  if (const char* home = std::getenv("HOME")) {
    const std::string fp = std::string(home) + "/Documents/matcher_backend.jsonl";
    if (FILE* f = std::fopen(fp.c_str(), "a")) {
      std::fprintf(f, "{\"anchor_mismatch\":\"%s\",\"detail\":\"%s\"}\n", what,
                   detail ? detail : "");
      std::fclose(f);
    }
  }
}

std::string Stage0Wgsl(const std::string& src) {
  std::string t = src;
  // [ANCHOR-FIX 2026-09-05] 旧锚点是形状刀之前的预取行,早已不存在 ⇒ 探针静默死亡,
  // 设备上据此读出"B 流量零成本"的假结论。现役预取是 packed u32 形态的 pr0。
  const std::string from = "    let pr0 = nextT + pe0 / 32u;";
  const size_t p = t.find(from);
  if (p == std::string::npos) { AnchorAlarm("Stage0Wgsl", "静默退化为 no-op"); return src; }
  t.replace(p, from.size(), "    let pr0 = pe0 / 32u;");
  return t;
}

std::string ExtraBarrierWgsl(const std::string& src, int n) {
  std::string t = src;
  // [ANCHOR-FIX 2026-09-05] 旧锚点是**循环交换之前**的单累加器 store
  // ("+ nt * 8u, acc"),ILP4 之后变成 acc0..acc3 四条 ⇒ 探针静默死亡,
  // 设备上据此读出"barrier 零成本"的假结论。改锚在第 4 条 store 上,在它之后加 N 次。
  const std::string one =
      "    subgroupMatrixStore(&accSh, (sg * 8u) * 32u + 3u * 8u, acc3, false, 32u);\n";
  const size_t q = t.find(one);
  if (q == std::string::npos) {
    AnchorAlarm("ExtraBarrierWgsl", "静默退化为 no-op");
    return src;
  }
  std::string add = one;
  for (int i = 0; i < n; ++i) add += "    workgroupBarrier();\n";
  t.replace(q, one.size(), add);
  return t;
}


std::string NoScanWgsl(const std::string& src) {
  std::string t = src;
  auto rep = [&t](const std::string& from, const std::string& to) {
    const size_t p = t.find(from);
    if (p == std::string::npos) {
      // 逐锚点报告:只说"这个变换失配"不够,得说清是哪一条,否则每次都要重查。
      AnchorAlarm("NoScanWgsl", from.c_str());
      return false;
    }
    t.replace(p, from.size(), to);
    return true;
  };
  bool ok = true;
  // [ANCHOR-FIX 2026-09-04] 常量上界那一刀把 `c < lim` 改成了 `c < BT`,
  // 这个锚点从此再没命中过 —— 而 `if (!ok) return src;` 让它**静默退化**,
  // 于是设备侧读出"扫描只值 1.5%"这种不存在的结论(输出 sha 竟然没变就是铁证)。
  // 🔴 锚点两次改错的教训:这两条原本写的是**旧形状核 kWgslMmaFused** 的循环
  // (`c < lim` / `r < WGR`),而现役是 metal-shape 核 kWgslMmaMetalShape —— 它的
  // 两个扫描是每 lane 各 8 次(行向 t、列向 r),后面接蝶形归并。
  // 定位方法:锚点必须从 **mixed_src 实际来源的那个 R"WGSL(...)" 串**里取,
  // 不能从文件里 grep 到的第一处同名循环取(那可能在别的核里)。
  ok &= rep("    for (var t = 0u; t < 8u; t = t + 1u) {",
            "    for (var t = 0u; t < 1u; t = t + 1u) {");
  ok &= rep("    for (var r = 0u; r < 8u; r = r + 1u) {",
            "    for (var r = 0u; r < 1u; r = r + 1u) {");
  if (!ok) { AnchorAlarm("NoScanWgsl", "静默退化为 no-op"); return src; }
  return t;
}

// [BLOAD-PROBE 2026-09-05] 计时探针(输出作废,只为定价):把 4 条 B fragment 载入
// 整体提到 k 循环**外**,MMA / store / barrier 条数一条不变 ⇒ 差值 = 载入的全部奖金,
// 也就是"纯 MMA 地板"。Mac 上这条量到载入只占 GEMM 14.6%(砍一半只兑现 4%),
// 据此判死了 R2 寄存器分块。A16 的访存画像完全不同(packed 值 26%、形状刀值 37.5%),
// 所以必须在设备上重量一次,不能拿 Mac 的结论外推。
std::string BLoadHoistWgsl(const std::string& src) {
  std::string t = src;
  const std::string from =
      "    for (var k = 0u; k < 16u; k = k + 1u) {\n"
      "      let b0 = subgroupMatrixLoad<Right>(&Bsh, (0u * 8u) * 128u + k * 8u, true, 128u);\n"
      "      let b1 = subgroupMatrixLoad<Right>(&Bsh, (1u * 8u) * 128u + k * 8u, true, 128u);\n"
      "      let b2 = subgroupMatrixLoad<Right>(&Bsh, (2u * 8u) * 128u + k * 8u, true, 128u);\n"
      "      let b3 = subgroupMatrixLoad<Right>(&Bsh, (3u * 8u) * 128u + k * 8u, true, 128u);\n";
  const std::string to =
      "    let b0 = subgroupMatrixLoad<Right>(&Bsh, (0u * 8u) * 128u, true, 128u);\n"
      "    let b1 = subgroupMatrixLoad<Right>(&Bsh, (1u * 8u) * 128u, true, 128u);\n"
      "    let b2 = subgroupMatrixLoad<Right>(&Bsh, (2u * 8u) * 128u, true, 128u);\n"
      "    let b3 = subgroupMatrixLoad<Right>(&Bsh, (3u * 8u) * 128u, true, 128u);\n"
      "    for (var k = 0u; k < 16u; k = k + 1u) {\n";
  const size_t p = t.find(from);
  if (p == std::string::npos) {
    std::fprintf(stderr,
                 "[pwofficial_gpu_match_dawn] 🔴 BLoadHoistWgsl 锚点未命中\n");
    return src;
  }
  t.replace(p, from.size(), to);
  return t;
}

// [HALFLOAD-PROBE 2026-09-05] 计时探针(输出作废,只为定价):每 k 只载入 2 个
// B fragment,后两个 MMA 改用 aFrag[15-k] 当第二"行块"的替身 —— 于是
// **MMA/store/barrier 条数一条不变、常驻 A 仍是 16 块**,唯一变量 = 载入 4→2。
// 它测的正是 R2(真两行块)能拿到的**上限收益**,而不必先付 32 块常驻 A 的代价。
// Mac 上这条量到 −4.0%,而真 R2 赔 +20% ⇒ 判死。A16 载入更贵(19.2% vs 14.6%),
// 所以在设备上重判一次;用 15-k 而不是同一个 aFrag[k],是为了防编译器 CSE 掉两条 MMA。
std::string HalfLoadWgsl(const std::string& src) {
  std::string t = src;
  auto rep = [&t](const std::string& from, const std::string& to) {
    const size_t p = t.find(from);
    if (p == std::string::npos) {
      AnchorAlarm("HalfLoadWgsl", from.c_str());
      return false;
    }
    t.replace(p, from.size(), to);
    return true;
  };
  bool ok = true;
  ok &= rep("      let b2 = subgroupMatrixLoad<Right>(&Bsh, (2u * 8u) * 128u + k * 8u, true, 128u);\n"
            "      let b3 = subgroupMatrixLoad<Right>(&Bsh, (3u * 8u) * 128u + k * 8u, true, 128u);\n",
            "");
  ok &= rep("      acc2 = subgroupMatrixMultiplyAccumulate(aFrag[k], b2, acc2);\n"
            "      acc3 = subgroupMatrixMultiplyAccumulate(aFrag[k], b3, acc3);\n",
            "      acc2 = subgroupMatrixMultiplyAccumulate(aFrag[15u - k], b0, acc2);\n"
            "      acc3 = subgroupMatrixMultiplyAccumulate(aFrag[15u - k], b1, acc3);\n");
  if (!ok) return src;
  return t;
}

// [MERGE1-PROBE 2026-09-05] 计时探针(输出作废,只为定价):把跨工作组归并的
// 内层循环截断到 1 次。13312² 时 numWg = nA/WGR = 104,归并每列要扫 104 项、
// 共 138 万次读(16.6 MB,rb-major 布局下是合并访问)。它是分块之后**另一个
// dispatch**,此前从没定过价 —— NOSCAN 只覆盖核内的两个扫描,覆盖不到它。
std::string Merge1Wgsl(const std::string& src) {
  std::string t = src;
  const std::string from = "  for (var w = 0u; w < U.numWg; w = w + 1u) {";
  const std::string to   = "  for (var w = 0u; w < min(U.numWg, 1u); w = w + 1u) {";
  const size_t p = t.find(from);
  if (p == std::string::npos) {
    AnchorAlarm("Merge1Wgsl", "锚点未命中");
    return src;
  }
  t.replace(p, from.size(), to);
  return t;
}

// [BSTORE-PROBE 2026-09-05] 可行性 + 定价探针:B fragment **直接从存储缓冲读**,
// 不再经过 Bsh。必须与 UNPACKED 同开(那时 B 在存储里就是 f16)。
//
// 依据:设备侧 stage0 探针测出**从全局读 B 的流量成本 ≈ 0**(13312 时整个 B 只有
// 1.7MB,全在 SLC 里)。而每个工作组都要把整个 B 解包写进 Bsh 一遍 —— 104 个
// 工作组 × 13312 × 128 = 1.77 亿次线程组写,外加每块两次 barrier。
// A 侧本来就是 `subgroupMatrixLoad<Left>(&A, ...)` 直读存储缓冲的,B 没有理由不能。
// 索引对齐:Bsh 里 (nt*8) 行对应 B 的 (tile0 + nt*8) 行,步长同为 128,transpose 同为 true。
std::string BStoreWgsl(const std::string& src) {
  std::string t = src;
  int hit = 0;
  for (int nt = 0; nt < 4; ++nt) {
    char from[160], to[160];
    std::snprintf(from, sizeof(from),
                  "subgroupMatrixLoad<Right>(&Bsh, (%du * 8u) * 128u + k * 8u, true, 128u)",
                  nt);
    std::snprintf(to, sizeof(to),
                  "subgroupMatrixLoad<Right>(&B, (col0 + %du * 8u) * 128u + k * 8u, true, 128u)",
                  nt);
    const size_t p = t.find(from);
    if (p == std::string::npos) continue;
    t.replace(p, std::strlen(from), to);
    ++hit;
  }
  if (hit != 4) {
    AnchorAlarm("BStoreWgsl", "四条 B 载入没全部命中");
    return src;
  }
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
  if (!ok) { AnchorAlarm("PackedWgsl", "静默退化为 no-op"); return src; }
  return t;
}

// [NOAPRO-PROBE 2026-09-05] 计时探针(输出作废,只为定价):砍掉 A 的解包前奏
// (4 轮 × 每轮 4 个 SG 活 12 个闲 + 8 次 barrier),只保留 16 次 fragment 载入。
// 起因:按列分块之后,**每个 dispatch 的 104 个工作组都要重跑一遍这段前奏**,
// 而实测每多一个 dispatch 仍有 ~1ms 落在提交内(尾部空转已被按列分块消除)。
// 若这段占大头,解法是:B 仍打包(上传便宜),A 改成 f16 直存 —— 前奏整段消失。
std::string NoAProWgsl(const std::string& src) {
  std::string t = src;
  const std::string head = "  {\n    let pwv = sg >> 2u;\n";
  const size_t p = t.find(head);
  if (p == std::string::npos) {
    AnchorAlarm("NoAProWgsl", "前奏头未命中");
    return src;
  }
  const std::string tail = "      workgroupBarrier();\n    }\n  }";
  const size_t q = t.find(tail, p);
  if (q == std::string::npos) {
    AnchorAlarm("NoAProWgsl", "前奏尾未命中");
    return src;
  }
  const std::string repl =
      "  {\n"
      "    let pq = (sg & 3u) * 1024u;\n"
      // 保留一次对 A 的引用,否则 binding 0 会被自动派生的布局裁掉
      // (Dawn 报 \"binding index 0 not present in the bind group layout\")。
      "    if (lid == 0u) { Bsh[0] = f16(A[aRow0 * 32u] & 255u); }\n"
      "    workgroupBarrier();\n"
      "    for (var k = 0u; k < 16u; k = k + 1u) {\n"
      "      aFrag[k] = subgroupMatrixLoad<Left>(&Bsh, pq + k * 8u, false, 128u);\n"
      "    }\n"
      "  }";
  t.replace(p, q + tail.size() - p, repl);
  return t;
}

// ── [UNIVERSAL 2026-09-05] 通用核的三个变换:两把尺子 + 一把刀 ─────────────
// 尺子(输出作废,只为定价):BLK_NOSCAN 截断两个扫描;BLK_NOSTAGE 砍掉整段暂存
// (保留一次对 A/B 的引用,免得 binding 被自动布局裁掉)。
// 刀(逐字节无损):BLK_UNROLL 把 KC=32 的 k 循环手工展开 —— 那篇 WebGPU 优化记录里
// 3x 的来源就是它("让编译器不必初始化/递增循环变量,并放出指令级并行")。
std::string BlkNoScanWgsl(const std::string& src) {
  std::string t = src;
  int hit = 0;
  auto rep = [&](const std::string& from, const std::string& to) {
    const size_t p = t.find(from);
    if (p == std::string::npos) { AnchorAlarm("BlkNoScanWgsl", from.c_str()); return; }
    t.replace(p, from.size(), to); ++hit;
  };
  rep("      for (var v = 0u; v < 16u; v = v + 1u) {",
      "      for (var v = 0u; v < 1u; v = v + 1u) {");
  rep("      for (var r = 0u; r < WGR; r = r + 1u) {",
      "      for (var r = 0u; r < 1u; r = r + 1u) {");
  return hit == 2 ? t : src;
}

std::string BlkNoStageWgsl(const std::string& src) {
  std::string t = src;
  // [ANCHOR-FIX 2026-09-05] 4x4 的暂存头是 `{ let side = lid / 128u;`,8x4 是 `for (var side ...`,
  // 8x8 是 `for (var pair ...` —— 三种都认。此前只认第一种 ⇒ 在 8x4 上静默 no-op,
  // Adreno 上一度读出"暂存零成本"的假数(sha 没变就是铁证)。
  const char* heads[] = {"      {\n        let side = lid / 128u;\n",
                         "      for (var side = 0u; side < 2u; side = side + 1u) {\n",
                         "      for (var pair = 0u; pair < 4u; pair = pair + 1u) {\n"};
  std::string head;
  size_t p = std::string::npos;
  for (const char* h : heads) { p = t.find(h); if (p != std::string::npos) { head = h; break; } }
  const std::string tail = "        S[o + 3u * 16u] = vec4<f32>(f32(x0 >> 24u), f32(x1 >> 24u), f32(x2 >> 24u), f32(x3 >> 24u));\n      }\n";
  const size_t q = (p == std::string::npos) ? std::string::npos : t.find(tail, p);
  if (p == std::string::npos || q == std::string::npos) {
    AnchorAlarm("BlkNoStageWgsl", "暂存块首尾未命中");
    return src;
  }
  t.replace(p, q + tail.size() - p,
            "      if (lid == 0u) { S[0] = vec4<f32>(f32(A[row0 * 32u] & 255u), f32(B[col0 * 32u] & 255u), 0.0, 0.0); }\n");
  return t;
}

// 刀(逐字节无损):BLK_PIPE 把 k+1 的两次 vec4 载入提前到本步 FMA 之前发出。
// 依据:内层占 83%、每 k 2 次线程组载入换 16 次 FMA,而 AGX 的线程组载入没有 scoreboard。
std::string BlkPipeWgsl(const std::string& src) {
  std::string t = src;
  // [ANCHOR-FIX 2026-09-05] 原只认 4x4 的 `let a4/b4` 循环;8x4 是 `al/ah/b4` ⇒ 静默 no-op,
  // Adreno 上一度读出"PIPE 零收益"的假数。现在两种形态都认。
  const std::string from84 =
      "      for (var k = 0u; k < KC; k = k + 1u) {\n"
      "        let al = S[k * 16u + tr * 2u];\n"
      "        let ah = S[k * 16u + tr * 2u + 1u];\n"
      "        let b4 = S[512u + k * 16u + tc];\n";
  const size_t p84 = t.find(from84);
  if (p84 != std::string::npos) {
    t.replace(p84, from84.size(),
      "      var al = S[tr * 2u];\n"
      "      var ah = S[tr * 2u + 1u];\n"
      "      var b4 = S[512u + tc];\n"
      "      for (var k = 0u; k < KC; k = k + 1u) {\n"
      "        let kn = min(k + 1u, KC - 1u);\n"
      "        let aln = S[kn * 16u + tr * 2u];\n"
      "        let ahn = S[kn * 16u + tr * 2u + 1u];\n"
      "        let bn = S[512u + kn * 16u + tc];\n");
    const std::string tail84 = "        acc7 = acc7 + ah.w * b4;\n      }\n";
    const size_t q84 = t.find(tail84, p84);
    if (q84 == std::string::npos) { AnchorAlarm("BlkPipeWgsl", "8x4 循环尾未命中"); return src; }
    t.replace(q84, tail84.size(),
              "        acc7 = acc7 + ah.w * b4;\n"
              "        al = aln; ah = ahn; b4 = bn;\n"
              "      }\n");
    return t;
  }
  const std::string from =
      "      for (var k = 0u; k < KC; k = k + 1u) {\n"
      "        let a4 = S[k * 16u + tr];\n"
      "        let b4 = S[512u + k * 16u + tc];\n";
  const size_t p = t.find(from);
  if (p == std::string::npos) { AnchorAlarm("BlkPipeWgsl", "k 循环头未命中(4x4/8x4 都不是)"); return src; }
  const std::string to =
      "      var a4 = S[tr];\n"
      "      var b4 = S[512u + tc];\n"
      "      for (var k = 0u; k < KC; k = k + 1u) {\n"
      "        let kn = min(k + 1u, KC - 1u);\n"
      "        let an = S[kn * 16u + tr];\n"
      "        let bn = S[512u + kn * 16u + tc];\n";
  t.replace(p, from.size(), to);
  const std::string tail =
      "        acc3 = acc3 + a4.w * b4;\n"
      "      }\n";
  const size_t q = t.find(tail, p);
  if (q == std::string::npos) { AnchorAlarm("BlkPipeWgsl", "k 循环尾未命中"); return src; }
  t.replace(q, tail.size(),
            "        acc3 = acc3 + a4.w * b4;\n"
            "        a4 = an; b4 = bn;\n"
            "      }\n");
  return t;
}

// 刀(逐字节无损):BLK_FMA 把 `acc = acc + a * b` 改成显式 fma()。
// 依据:内层 3 次载入换 32 次 FMA 仍只到 FMA 峰值 32% —— 若编译器没融合,
// 这个数正好等于 ALU 峰值的 64%。对精确整数,fma 是单次舍入 ⇒ 输出不变。
std::string BlkFmaWgsl(const std::string& src) {
  std::string t = src;
  int n = 0;
  for (int i = 0; i < 8; ++i) {
    for (const char* src_name : {"a4", "al", "ah"}) {
      for (const char* comp : {"x", "y", "z", "w"}) {
        char from[96], to[96];
        std::snprintf(from, sizeof(from), "acc%d = acc%d + %s.%s * b4;", i, i, src_name, comp);
        std::snprintf(to, sizeof(to), "acc%d = fma(vec4<f32>(%s.%s), b4, acc%d);", i, src_name, comp, i);
        for (size_t p = t.find(from); p != std::string::npos; p = t.find(from, p + 1)) {
          t.replace(p, std::strlen(from), to); ++n;
        }
      }
    }
  }
  if (n == 0) { AnchorAlarm("BlkFmaWgsl", "一条 FMA 都没命中"); return src; }
  return t;
}

// 尺子(输出作废):BLK_NOLOAD 把内层三次线程组载入换成只依赖 k 的寄存器值
// ⇒ 这个结构的**纯 FMA 地板**。差值 = 载入(含无 scoreboard 的延迟)的全部成本。
// [DIRECT-44 2026-09-05] 由 DIRECT 8x4 文本派生 4x4/256 线程形态(env BLK_DIRECT=1 + BLK_44=1)。
// 动机:Arm 指南 "Every thread has 64 32-bit working registers … more than 64 → spill";
// chips&cheese 实测 Bifrost >32 寄存器占用率减半。8x4 的 8 个 vec4 累加器 + 4 个 vec4 载入 ≈ 48+,
// 4x4 只要 16+8。锚点全部来自本文件自有的 kWgslBlocked84Direct 文本。
std::string DirectTo44Wgsl(const std::string& src) {
  std::string t = src;
  struct Sub { const char* from; const char* to; };
  const Sub subs[] = {
    {"@compute @workgroup_size(128)\nfn main(", "@compute @workgroup_size(256)\nfn main("},
    {"  let rq = row0 / 4u + tr * 2u;\n", "  let rq = row0 / 4u + tr;\n"},
    {"    var acc4 = vec4<f32>(0.0);\n    var acc5 = vec4<f32>(0.0);\n    var acc6 = vec4<f32>(0.0);\n    var acc7 = vec4<f32>(0.0);\n", ""},
    {"      let al = At[k * rowPad4 + rq];\n      let ah = At[k * rowPad4 + rq + 1u];\n", "      let al = At[k * rowPad4 + rq];\n"},
    {"      acc4 = acc4 + ah.x * b4;\n      acc5 = acc5 + ah.y * b4;\n      acc6 = acc6 + ah.z * b4;\n      acc7 = acc7 + ah.w * b4;\n", ""},
    {"    S[(tr * 8u + 0u) * 16u + tc] = acc0;\n    S[(tr * 8u + 1u) * 16u + tc] = acc1;\n    S[(tr * 8u + 2u) * 16u + tc] = acc2;\n    S[(tr * 8u + 3u) * 16u + tc] = acc3;\n    S[(tr * 8u + 4u) * 16u + tc] = acc4;\n    S[(tr * 8u + 5u) * 16u + tc] = acc5;\n    S[(tr * 8u + 6u) * 16u + tc] = acc6;\n    S[(tr * 8u + 7u) * 16u + tc] = acc7;\n",
     "    S[(tr * 4u + 0u) * 16u + tc] = acc0;\n    S[(tr * 4u + 1u) * 16u + tc] = acc1;\n    S[(tr * 4u + 2u) * 16u + tc] = acc2;\n    S[(tr * 4u + 3u) * 16u + tc] = acc3;\n"},
  };
  for (const Sub& sb : subs) {
    const size_t p = t.find(sb.from);
    if (p == std::string::npos) { AnchorAlarm("DirectTo44Wgsl", sb.from); return src; }
    t.replace(p, std::strlen(sb.from), sb.to);
  }
  return t;
}

// [DIRECT-G 2026-09-05] 由 DIRECT 文本派生:连扫描段的 64x64 结果交换也不用线程组内存,改写到每个
// workgroup 自己的全局暂存 Scr(绑定 9,numWg × 1024 vec4);核里不再有任何 var<workgroup>。
// 动机:chips&cheese 在 G52 上实测 "Each Shader Core can only have one workgroup with local memory
// allocated" —— 若 G72 同理,DIRECT 留着的 16 KiB S 仍把每核占用率锁在一个 workgroup。
// Mali 上 local 本就是 global(Arm 指南 §3.7),这里零代价;A16/Adreno 上扫描段只占 ~9%。
// 同步:workgroupBarrier 只管线程组内存,存储缓冲的组内可见性要 storageBarrier。
std::string DirectToGlobalScratchWgsl(const std::string& src) {
  std::string t = src;
  struct Sub { const char* from; const char* to; };
  // [ANCHOR 2026-09-05] 8x4 与 4x4(DirectTo44Wgsl 之后)两种形态都认:Mate 10 上 44+G 叠加时锚点未命中
  // → 静默退回无 G 的核而 C++ 仍绑 Scr → 管线失败(125ms 无 sha 的假读数)。每个变换对每种形态验活性。
  const Sub common[] = {
    {"@group(0) @binding(8) var<storage, read> Bt : array<vec4<f32>>;\n",
     "@group(0) @binding(8) var<storage, read> Bt : array<vec4<f32>>;\n"
     "@group(0) @binding(9) var<storage, read_write> Scr : array<vec4<f32>>;\n"},
    {"var<workgroup> S : array<vec4<f32>, 1024>;\n", ""},
    {"        let d = S[lid * 16u + v];\n", "        let d = Scr[sb + lid * 16u + v];\n"},
    {"        let d = S[r * 16u + q][m];\n", "        let d = Scr[sb + r * 16u + q][m];\n"},
  };
  for (const Sub& sb : common) {
    const size_t p = t.find(sb.from);
    if (p == std::string::npos) { AnchorAlarm("DirectToGlobalScratchWgsl", sb.from); return src; }
    t.replace(p, std::strlen(sb.from), sb.to);
  }
  // rq 行(两种形态)之后插入 sb
  {
    const char* rq84 = "  let rq = row0 / 4u + tr * 2u;\n";
    const char* rq44 = "  let rq = row0 / 4u + tr;\n";
    size_t p = t.find(rq84); const char* hit = rq84;
    if (p == std::string::npos) { p = t.find(rq44); hit = rq44; }
    if (p == std::string::npos) { AnchorAlarm("DirectToGlobalScratchWgsl", "rq 行未命中"); return src; }
    t.insert(p + std::strlen(hit), "  let sb = wg.x * 1024u;\n");
  }
  // 结果交换块(两种形态)
  {
    const char* blk84 =
        "    workgroupBarrier();\n    S[(tr * 8u + 0u) * 16u + tc] = acc0;\n    S[(tr * 8u + 1u) * 16u + tc] = acc1;\n    S[(tr * 8u + 2u) * 16u + tc] = acc2;\n    S[(tr * 8u + 3u) * 16u + tc] = acc3;\n    S[(tr * 8u + 4u) * 16u + tc] = acc4;\n    S[(tr * 8u + 5u) * 16u + tc] = acc5;\n    S[(tr * 8u + 6u) * 16u + tc] = acc6;\n    S[(tr * 8u + 7u) * 16u + tc] = acc7;\n    workgroupBarrier();\n";
    const char* to84 =
        "    storageBarrier();\n    Scr[sb + (tr * 8u + 0u) * 16u + tc] = acc0;\n    Scr[sb + (tr * 8u + 1u) * 16u + tc] = acc1;\n    Scr[sb + (tr * 8u + 2u) * 16u + tc] = acc2;\n    Scr[sb + (tr * 8u + 3u) * 16u + tc] = acc3;\n    Scr[sb + (tr * 8u + 4u) * 16u + tc] = acc4;\n    Scr[sb + (tr * 8u + 5u) * 16u + tc] = acc5;\n    Scr[sb + (tr * 8u + 6u) * 16u + tc] = acc6;\n    Scr[sb + (tr * 8u + 7u) * 16u + tc] = acc7;\n    storageBarrier();\n";
    const char* blk44 =
        "    workgroupBarrier();\n    S[(tr * 4u + 0u) * 16u + tc] = acc0;\n    S[(tr * 4u + 1u) * 16u + tc] = acc1;\n    S[(tr * 4u + 2u) * 16u + tc] = acc2;\n    S[(tr * 4u + 3u) * 16u + tc] = acc3;\n    workgroupBarrier();\n";
    const char* to44 =
        "    storageBarrier();\n    Scr[sb + (tr * 4u + 0u) * 16u + tc] = acc0;\n    Scr[sb + (tr * 4u + 1u) * 16u + tc] = acc1;\n    Scr[sb + (tr * 4u + 2u) * 16u + tc] = acc2;\n    Scr[sb + (tr * 4u + 3u) * 16u + tc] = acc3;\n    storageBarrier();\n";
    size_t p = t.find(blk84);
    if (p != std::string::npos) t.replace(p, std::strlen(blk84), to84);
    else {
      p = t.find(blk44);
      if (p == std::string::npos) { AnchorAlarm("DirectToGlobalScratchWgsl", "结果交换块未命中(8x4/4x4 都不是)"); return src; }
      t.replace(p, std::strlen(blk44), to44);
    }
  }
  if (t.find("S[") != std::string::npos) { AnchorAlarm("DirectToGlobalScratchWgsl", "残留 S[ 引用"); return src; }
  return t;
}

// [DIRECT-TEX 2026-09-05] 由 DIRECT 文本派生:B 侧改走纹理(rgba32float,x = 列四元组,y = k)。
// 依据:Arm Compute Library 的 Mali GEMM 提供 export_to_cl_image 路径(RHS 经 read_image 取),
// chips&cheese 实测 Bifrost 纹理通路 26 B/拍、载入通路 16 B/拍 —— 若 Mali 上 DIRECT 是 LSU 受限,
// 把 B 挪到纹理缓存等于再开一条带宽。textureLoad 返回原样 f32,逐字节同源。
std::string DirectToTexWgsl(const std::string& src) {
  std::string t = src;
  struct Sub { const char* from; const char* to; };
  const Sub head = {"@group(0) @binding(8) var<storage, read> Bt : array<vec4<f32>>;\n",
                    "@group(0) @binding(8) var BtT : texture_2d<f32>;\n"};
  {
    const size_t p = t.find(head.from);
    if (p == std::string::npos) { AnchorAlarm("DirectToTexWgsl", head.from); return src; }
    t.replace(p, std::strlen(head.from), head.to);
  }
  // 两种循环形态:带 B 预取(b4/bn)或 NOPB(每 k 直接取 b4)
  const Sub pipeb[] = {
    {"    var b4 = Bt[cq];\n", "    var b4 = textureLoad(BtT, vec2<i32>(i32(cq), 0), 0);\n"},
    {"      let bn = Bt[min(k + 1u, KD - 1u) * colPad4 + cq];\n",
     "      let bn = textureLoad(BtT, vec2<i32>(i32(cq), i32(min(k + 1u, KD - 1u))), 0);\n"},
  };
  const Sub nopb = {"      let b4 = Bt[k * colPad4 + cq];\n",
                    "      let b4 = textureLoad(BtT, vec2<i32>(i32(cq), i32(k)), 0);\n"};
  if (t.find(pipeb[0].from) != std::string::npos) {
    for (const Sub& sb : pipeb) {
      const size_t p = t.find(sb.from);
      if (p == std::string::npos) { AnchorAlarm("DirectToTexWgsl", sb.from); return src; }
      t.replace(p, std::strlen(sb.from), sb.to);
    }
  } else {
    const size_t p = t.find(nopb.from);
    if (p == std::string::npos) { AnchorAlarm("DirectToTexWgsl", "循环形态未命中(pipeb/nopb 都不是)"); return src; }
    t.replace(p, std::strlen(nopb.from), nopb.to);
  }
  if (t.find("Bt[") != std::string::npos) { AnchorAlarm("DirectToTexWgsl", "残留 Bt[ 引用"); return src; }
  return t;
}

// [DIRECT-TEX] 由 Bt 缓冲拷贝出的纹理(宽 = nBpad/4 texel,高 = 128 k)。按尺寸缓存,尺寸变了重建。
wgpu::TextureView EnsureBtTexture(Ctx& c, wgpu::Texture& tex, uint32_t& texW, uint32_t colPad4) {
  if (!tex || texW != colPad4) {
    if (tex) tex.Destroy();
    wgpu::TextureDescriptor d{};
    d.dimension = wgpu::TextureDimension::e2D;
    d.size = {colPad4, 128u, 1u};
    d.format = wgpu::TextureFormat::RGBA32Float;
    d.usage = wgpu::TextureUsage::TextureBinding | wgpu::TextureUsage::CopyDst;
    tex = c.device.CreateTexture(&d);
    texW = tex ? colPad4 : 0;
  }
  return tex ? tex.CreateView() : wgpu::TextureView();
}
void EncodeBtToTexture(wgpu::CommandEncoder& enc, wgpu::Buffer bt, wgpu::Texture tex, uint32_t colPad4) {
  wgpu::TexelCopyBufferInfo src{};
  src.buffer = bt;
  src.layout.offset = 0;
  src.layout.bytesPerRow = colPad4 * 16u;  // nBpad*4,恒为 256 的倍数(nBpad 是 128 的倍数)
  src.layout.rowsPerImage = 128u;
  wgpu::TexelCopyTextureInfo dst{};
  dst.texture = tex;
  wgpu::Extent3D ext{colPad4, 128u, 1u};
  enc.CopyBufferToTexture(&src, &dst, &ext);
}

// [DIRECT-NOPB 2026-09-05] 去掉 B 的一拍预取(b4/bn 只留 b4):8x4 形态少 4 个寄存器(48→44),
// 赌 Bifrost 64 寄存器线;两种形态(8x4 / 4x4)都认。
std::string DirectNoPipeBWgsl(const std::string& src) {
  std::string t = src;
  struct Sub { const char* from; const char* to; };
  const Sub subs[] = {
    {"    var b4 = Bt[cq];\n    for (var k = 0u; k < KD; k = k + 1u) {\n",
     "    for (var k = 0u; k < KD; k = k + 1u) {\n      let b4 = Bt[k * colPad4 + cq];\n"},
    {"      let bn = Bt[min(k + 1u, KD - 1u) * colPad4 + cq];\n", ""},
    {"      b4 = bn;\n", ""},
  };
  for (const Sub& sb : subs) {
    const size_t p = t.find(sb.from);
    if (p == std::string::npos) { AnchorAlarm("DirectNoPipeBWgsl", sb.from); return src; }
    t.replace(p, std::strlen(sb.from), sb.to);
  }
  return t;
}
// [DIRECT-PIPEA 2026-09-05] 4x4 形态上把 A 也提前一拍(al/aln),与 B 的预取对称:16 acc + 16 载入 = 32 寄存器。
// 只认 4x4 文本(8x4 会到 56+,越线)。
std::string DirectPipeAWgsl(const std::string& src) {
  std::string t = src;
  struct Sub { const char* from; const char* to; };
  // 形态 A:带 B 预取(var b4 = Bt[cq]; for { let al = ...; let bn = ...; ... b4 = bn; })
  const Sub pipeb[] = {
    {"    var b4 = Bt[cq];\n    for (var k = 0u; k < KD; k = k + 1u) {\n      let al = At[k * rowPad4 + rq];\n",
     "    var b4 = Bt[cq];\n    var al = At[rq];\n    for (var k = 0u; k < KD; k = k + 1u) {\n      let aln = At[min(k + 1u, KD - 1u) * rowPad4 + rq];\n"},
    {"      b4 = bn;\n", "      b4 = bn;\n      al = aln;\n"},
  };
  // 形态 B:NOPB 之后(for { let b4 = Bt[k*colPad4+cq]; let al = ...; ... })—— 09-05 深夜发现此前在 NOPB 上静默 no-op
  const Sub nopb[] = {
    {"    for (var k = 0u; k < KD; k = k + 1u) {\n      let b4 = Bt[k * colPad4 + cq];\n      let al = At[k * rowPad4 + rq];\n",
     "    var al = At[rq];\n    for (var k = 0u; k < KD; k = k + 1u) {\n      let b4 = Bt[k * colPad4 + cq];\n      let aln = At[min(k + 1u, KD - 1u) * rowPad4 + rq];\n"},
    {"      acc3 = acc3 + al.w * b4;\n    }\n", "      acc3 = acc3 + al.w * b4;\n      al = aln;\n    }\n"},
  };
  const Sub* subs = (t.find(pipeb[0].from) != std::string::npos) ? pipeb : nopb;
  for (int i = 0; i < 2; ++i) {
    const size_t p = t.find(subs[i].from);
    if (p == std::string::npos) { AnchorAlarm("DirectPipeAWgsl", subs[i].from); return src; }
    t.replace(p, std::strlen(subs[i].from), subs[i].to);
  }
  if (t.find("let ah = At[") != std::string::npos) { AnchorAlarm("DirectPipeAWgsl", "只认 4x4 形态(发现 ah)"); return src; }
  return t;
}

// [DIRECT-TEXA 2026-09-05] A 也走纹理(x = 行四元组,y = k),与 TEX(B 走纹理)对称;两种形态、有无 PIPEA 都认。
// 动机:Mali 的 LSU 16 B/拍、纹理 26 B/拍;44 形态每 k 一次 A 载入 + 一次 B 载入,把 A 也搬到纹理管线,
// 看两条通路并行是否再抬一档。逐字节同源(textureLoad 原样返回 f32)。
static void ReplaceAll(std::string& t, const std::string& from, const std::string& to) {
  size_t p = 0;
  while ((p = t.find(from, p)) != std::string::npos) { t.replace(p, from.size(), to); p += to.size(); }
}
std::string DirectToTexAWgsl(const std::string& src) {
  std::string t = src;
  const std::string head = "@group(0) @binding(7) var<storage, read> At : array<vec4<f32>>;\n";
  const size_t p = t.find(head);
  if (p == std::string::npos) { AnchorAlarm("DirectToTexAWgsl", "At 声明未命中"); return src; }
  t.replace(p, head.size(), "@group(0) @binding(7) var AtT : texture_2d<f32>;\n");
  ReplaceAll(t, "At[k * rowPad4 + rq + 1u]", "textureLoad(AtT, vec2<i32>(i32(rq + 1u), i32(k)), 0)");
  ReplaceAll(t, "At[k * rowPad4 + rq]", "textureLoad(AtT, vec2<i32>(i32(rq), i32(k)), 0)");
  ReplaceAll(t, "At[min(k + 1u, KD - 1u) * rowPad4 + rq]", "textureLoad(AtT, vec2<i32>(i32(rq), i32(min(k + 1u, KD - 1u))), 0)");
  ReplaceAll(t, "At[rq]", "textureLoad(AtT, vec2<i32>(i32(rq), 0), 0)");
  if (t.find("At[") != std::string::npos) { AnchorAlarm("DirectToTexAWgsl", "残留 At[ 引用"); return src; }
  return t;
}

// [DIRECT-SCANMEM 2026-09-05] 行扫描状态(rowBest/rowSecond/rowBestI)不再跨 GEMM 循环活着:
// 每个 tile 的扫描段开头从 RowP 读回(首 tile 且 colBase==0 时置零),扫描完立刻写回 RowP;
// 循环外的收尾只做 gate。少 3 个跨循环活寄存器,赌 Bifrost 的 ≤32 满占用率线。语义逐字节同:
// 同一批值、同一顺序,只是中途落地了一次。两种形态(8x4/4x4)都认。
std::string DirectScanMemWgsl(const std::string& src) {
  std::string t = src;
  struct Sub { const char* from; const char* to; };
  const Sub subs[] = {
    {"  let myRow = row0 + lid;\n"
     "  var rowBest = 0.0;\n"
     "  var rowSecond = 0.0;\n"
     "  var rowBestI = -1;\n"
     "  if (U.colBase != 0u && lid < WGR && myRow < U.numA) {\n"
     "    let rp = RowP[myRow];\n"
     "    rowBest = rp.best;\n"
     "    rowSecond = rp.second;\n"
     "    rowBestI = rp.idx;\n"
     "  }\n",
     "  let myRow = row0 + lid;\n"},
    {"    if (lid < WGR) {\n"
     "      for (var v = 0u; v < 16u; v = v + 1u) {\n",
     "    if (lid < WGR) {\n"
     "      var rowBest = 0.0;\n"
     "      var rowSecond = 0.0;\n"
     "      var rowBestI = -1;\n"
     "      if (!(U.colBase == 0u && col0 == 0u) && myRow < U.numA) {\n"
     "        let rp = RowP[myRow];\n"
     "        rowBest = rp.best;\n"
     "        rowSecond = rp.second;\n"
     "        rowBestI = rp.idx;\n"
     "      }\n"
     "      for (var v = 0u; v < 16u; v = v + 1u) {\n"},
    {"        if (d.w > rowBest) { rowSecond = rowBest; rowBest = d.w; rowBestI = c0 + 3; }\n"
     "        else if (d.w > rowSecond) { rowSecond = d.w; }\n"
     "      }\n"
     "    } else if (lid < 2u * WGR) {\n",
     "        if (d.w > rowBest) { rowSecond = rowBest; rowBest = d.w; rowBestI = c0 + 3; }\n"
     "        else if (d.w > rowSecond) { rowSecond = d.w; }\n"
     "      }\n"
     "      if (myRow < U.numA) { RowP[myRow] = ColPart(rowBest, rowSecond, rowBestI); }\n"
     "    } else if (lid < 2u * WGR) {\n"},
    {"  if (lid < WGR && myRow < U.numA) {\n"
     "    RowP[myRow] = ColPart(rowBest, rowSecond, rowBestI);\n"
     "    OutAB[myRow] = gatef(rowBest, rowSecond, rowBestI);\n"
     "  }\n",
     "  if (lid < WGR && myRow < U.numA) {\n"
     "    let rp = RowP[myRow];\n"
     "    OutAB[myRow] = gatef(rp.best, rp.second, rp.idx);\n"
     "  }\n"},
  };
  for (const Sub& sb : subs) {
    const size_t p = t.find(sb.from);
    if (p == std::string::npos) { AnchorAlarm("DirectScanMemWgsl", sb.from); return src; }
    t.replace(p, std::strlen(sb.from), sb.to);
  }
  return t;
}

// [DIRECT-NOLOAD 探针 2026-09-05] 内层载入换成由 k 合成的值(非逐字节,只量纯 FMA 循环的地板)。认 8x4/4x4、pipeb/nopb、tex/texa。
std::string DirectNoLoadWgsl(const std::string& src) {
  // 载入提到 k 循环外(k→0 的那一次),循环内零载入;绑定 7/8 仍被引用,Dawn 布局不变。
  std::string t = src;
  struct Sub { const char* from; const char* var; const char* hoist; };
  const Sub subs[] = {
    {"      let al = At[k * rowPad4 + rq];\n", "al", "    let al_c = At[rq];\n"},
    {"      let ah = At[k * rowPad4 + rq + 1u];\n", "ah", "    let ah_c = At[rq + 1u];\n"},
    {"      let bn = Bt[min(k + 1u, KD - 1u) * colPad4 + cq];\n", "bn", "    let bn_c = Bt[colPad4 + cq];\n"},
    {"      let b4 = Bt[k * colPad4 + cq];\n", "b4", "    let b4_c = Bt[cq];\n"},
    {"      let aln = At[min(k + 1u, KD - 1u) * rowPad4 + rq];\n", "aln", "    let aln_c = At[rowPad4 + rq];\n"},
    {"      let al = textureLoad(AtT, vec2<i32>(i32(rq), i32(k)), 0);\n", "al", "    let al_c = textureLoad(AtT, vec2<i32>(i32(rq), 0), 0);\n"},
    {"      let ah = textureLoad(AtT, vec2<i32>(i32(rq + 1u), i32(k)), 0);\n", "ah", "    let ah_c = textureLoad(AtT, vec2<i32>(i32(rq + 1u), 0), 0);\n"},
    {"      let bn = textureLoad(BtT, vec2<i32>(i32(cq), i32(min(k + 1u, KD - 1u))), 0);\n", "bn", "    let bn_c = textureLoad(BtT, vec2<i32>(i32(cq), 1), 0);\n"},
    {"      let b4 = textureLoad(BtT, vec2<i32>(i32(cq), i32(k)), 0);\n", "b4", "    let b4_c = textureLoad(BtT, vec2<i32>(i32(cq), 0), 0);\n"},
    {"      let aln = textureLoad(AtT, vec2<i32>(i32(rq), i32(min(k + 1u, KD - 1u))), 0);\n", "aln", "    let aln_c = textureLoad(AtT, vec2<i32>(i32(rq), 1), 0);\n"},
  };
  std::string hoisted;
  int hits = 0;
  for (const Sub& sb : subs) {
    const size_t p = t.find(sb.from);
    if (p == std::string::npos) continue;
    t.replace(p, std::strlen(sb.from), std::string("      let ") + sb.var + " = " + sb.var + "_c;\n");
    hoisted += sb.hoist; ++hits;
  }
  if (hits < 2) { AnchorAlarm("DirectNoLoadWgsl", "内层载入未命中"); return src; }
  const char* loop = "    for (var k = 0u; k < KD; k = k + 1u) {\n";
  const size_t q = t.find(loop);
  if (q == std::string::npos) { AnchorAlarm("DirectNoLoadWgsl", "k 循环头未命中"); return src; }
  t.insert(q, hoisted);
  return t;
}

// [DIRECT-FMA 2026-09-05] acc = acc + a * b → acc = fma(vec4(a), b, acc)。u8 积 ≤65025、和 ≤8.3M 全是精确整数,
// 融合与否结果逐字节同;Bifrost 标量发射,若编译器没融合就是双倍指令(Mate 10 探针:纯 FMA 循环只有 ~40% 峰值)。
std::string DirectFmaWgsl(const std::string& src) {
  std::string t = src;
  int hits = 0;
  const char* comps[] = {"x", "y", "z", "w"};
  const char* srcs[] = {"al", "ah", "a4"};
  for (int i = 0; i < 8; ++i) {
    for (const char* a : srcs) {
      for (const char* c : comps) {
        char from[96], to[96];
        std::snprintf(from, sizeof(from), "      acc%d = acc%d + %s.%s * b4;\n", i, i, a, c);
        std::snprintf(to, sizeof(to), "      acc%d = fma(vec4<f32>(%s.%s), b4, acc%d);\n", i, a, c, i);
        const size_t p = t.find(from);
        if (p != std::string::npos) { t.replace(p, std::strlen(from), to); ++hits; }
      }
    }
  }
  if (hits < 4) { AnchorAlarm("DirectFmaWgsl", "FMA 行未命中"); return src; }
  return t;
}
// [DIRECT-UNROLL 2026-09-05] 4x4+NOPB 的 k 循环手工展开 n 倍(KD=128 整除)。A16 曾对展开赔 43%(寄存器),
// 这里是给 Mali 的臂:每 16 次 FMA 配 5–6 条循环/地址指令,展开把这份税摊薄。只认 4x4+NOPB 文本。
std::string DirectUnrollWgsl(const std::string& src, int n) {
  std::string t = src;
  const std::string head = "    for (var k = 0u; k < KD; k = k + 1u) {\n";
  const size_t p = t.find(head);
  if (p == std::string::npos) { AnchorAlarm("DirectUnrollWgsl", "循环头未命中"); return src; }
  // 44 形态里 A 的变量名沿用 al(DirectTo44Wgsl 只删了 ah),不是 a4。
  const std::string tail = "      acc3 = acc3 + al.w * b4;\n    }\n";
  const std::string tailF = "      acc3 = fma(vec4<f32>(al.w), b4, acc3);\n    }\n";
  size_t q = t.find(tail, p); size_t tlen = tail.size();
  if (q == std::string::npos) { q = t.find(tailF, p); tlen = tailF.size(); }
  if (q == std::string::npos) { AnchorAlarm("DirectUnrollWgsl", "循环尾未命中(只认 4x4)"); return src; }
  std::string body = t.substr(p + head.size(), q + tlen - 6 - (p + head.size()));  // 去掉结尾 "    }\n"
  if (body.find("let ah") != std::string::npos || body.find("bn") != std::string::npos) {
    AnchorAlarm("DirectUnrollWgsl", "只认 4x4+NOPB 形态"); return src;
  }
  std::string out;
  char hdr[96];
  std::snprintf(hdr, sizeof(hdr), "    for (var k0 = 0u; k0 < KD; k0 = k0 + %du) {\n", n);
  out += hdr;
  for (int u = 0; u < n; ++u) {
    char kk[32]; std::snprintf(kk, sizeof(kk), "(k0 + %du)", u);
    std::string b = body;
    // 把 body 里的独立标识符 k 换成 (k0 + u);b 内没有其它以 k 命名的符号(KD 除外)。
    std::string r;
    for (size_t i = 0; i < b.size(); ++i) {
      if (b[i] == 'k' && (i == 0 || !(std::isalnum((unsigned char)b[i-1]) || b[i-1] == '_')) &&
          (i + 1 >= b.size() || !(std::isalnum((unsigned char)b[i+1]) || b[i+1] == '_'))) r += kk;
      else r += b[i];
    }
    out += "      {\n" + r + "      }\n";
  }
  out += "    }\n";
  t.replace(p, q + tlen - p, out);
  return t;
}

// [DIRECT-NOSYNC 探针 2026-09-05] 去掉 tile 边界的两个 workgroupBarrier 与 S 写入(扫描读到的是垃圾,非逐字节),
// 只量"barrier 尾巴 + 结果交换"的价。认 4x4 形态(S 写块 4 行)。
std::string DirectNoSyncWgsl(const std::string& src) {
  std::string t = src;
  const char* blk44 =
      "    workgroupBarrier();\n    S[(tr * 4u + 0u) * 16u + tc] = acc0;\n    S[(tr * 4u + 1u) * 16u + tc] = acc1;\n    S[(tr * 4u + 2u) * 16u + tc] = acc2;\n    S[(tr * 4u + 3u) * 16u + tc] = acc3;\n    workgroupBarrier();\n";
  const size_t p = t.find(blk44);
  if (p == std::string::npos) { AnchorAlarm("DirectNoSyncWgsl", "4x4 结果交换块未命中"); return src; }
  // 保留一处对 acc 的使用,免得编译器把整个循环删掉:只让 lid==0 写一个 vec4。
  t.replace(p, std::strlen(blk44), "    if (lid == 0u) { S[tc] = acc0 + acc1 + acc2 + acc3; }\n");
  return t;
}

// [DIRECT-44-W128 2026-09-05] 4x4 形态改 128 线程一组:tile 32 行 × 64 列(WGR=32),S 减半到 8 KiB。
// 动机:Bifrost 满占用率 384 线程/核要求 ≤32 寄存器,>32 就减半到 192 —— 256 线程的组比 192 还大,
// 编译器只能强行压寄存器(spill)或一核挂半个组;NOPB/SCANMEM 这些"少几个寄存器"的刀都赚正是这个症状。
// 组改 128 后 64 寄存器也不越界。ColP 的行组粒度变 32,merge 按 w 升序 = 行号升序,并列取最小行号的语义不变。
std::string DirectTo44W128Wgsl(const std::string& src) {
  std::string t = src;
  struct Sub { const char* from; const char* to; };
  const Sub subs[] = {
    {"const WGR : u32 = 64u;\n", "const WGR : u32 = 32u;\n"},
    {"var<workgroup> S : array<vec4<f32>, 1024>;\n", "var<workgroup> S : array<vec4<f32>, 512>;\n"},
    {"@compute @workgroup_size(256)\nfn main(", "@compute @workgroup_size(128)\nfn main("},
    {"  let rowPad4 = ((U.numA + 63u) / 64u) * 16u;\n", "  let rowPad4 = ((U.numA + 31u) / 32u) * 8u;\n"},
    {"    } else if (lid < 2u * WGR) {\n", "    } else if (lid < WGR + 64u) {\n"},
  };
  for (const Sub& sb : subs) {
    const size_t p = t.find(sb.from);
    if (p == std::string::npos) { AnchorAlarm("DirectTo44W128Wgsl", sb.from); return src; }
    t.replace(p, std::strlen(sb.from), sb.to);
  }
  if (t.find("let ah = ") != std::string::npos) { AnchorAlarm("DirectTo44W128Wgsl", "只认 4x4 形态"); return src; }
  return t;
}

// [DIRECT-PSCAN 2026-09-05] 并行扫描:tile 的行/列 best/second 搜索由全部线程分段做(行:4 线程/行各 16 列;
// 列:每线程 16 行),再按"前段 ⊕ 后段"的精确合并规则树形合并:
//   if (b2 > B) { S = max(B, s2); B = b2; I = i2; } else { S = max(S, b2); }
// 与 merge 核对行组的合并规则同一条(严格大于、并列取先出现者、second 含重复的 best),
// 分段按列/行升序合并 ⇒ 与串行扫描逐字节同。局部结果覆写在已读完的分数 S 上,不加线程组内存。
// 只认 4x4 形态:workgroup 128(WGR=32)或 256(WGR=64),即 NT = 4*WGR、NT/64 个列段。
std::string DirectPScanWgsl(const std::string& src) {
  std::string t = src;
  const bool w128 = t.find("const WGR : u32 = 32u;\n") != std::string::npos;
  const bool w256 = t.find("const WGR : u32 = 64u;\n") != std::string::npos &&
                    t.find("@compute @workgroup_size(256)\nfn main(") != std::string::npos;
  if (!w128 && !w256) { AnchorAlarm("DirectPScanWgsl", "只认 4x4 形态(128/WGR32 或 256/WGR64)"); return src; }
  const char* nt = w128 ? "const NT : u32 = 128u;\nconst CSEG : u32 = 2u;\n" : "const NT : u32 = 256u;\nconst CSEG : u32 = 4u;\n";
  {
    const std::string wgr = w128 ? "const WGR : u32 = 32u;\n" : "const WGR : u32 = 64u;\n";
    const size_t p = t.find(wgr);
    t.insert(p + wgr.size(), nt);
  }
  const std::string from_head = "    if (lid < WGR) {\n      for (var v = 0u; v < 16u; v = v + 1u) {\n";
  const std::string from_tail = "      if (gc < U.numB) { ColP[rb * U.numB + gc] = ColPart(cb, cs, ci); }\n    }\n";
  const size_t p = t.find(from_head);
  const size_t q = t.find(from_tail, p);
  if (p == std::string::npos || q == std::string::npos) { AnchorAlarm("DirectPScanWgsl", "扫描块未命中"); return src; }
  const std::string to =
    "    // [PSCAN] 行 partial:4 线程/行,各 16 列(4 个 vec4)\n"
    "    let prow = lid / 4u;\n"
    "    let psub = lid % 4u;\n"
    "    var pb = 0.0;\n    var ps = 0.0;\n    var pi = -1;\n"
    "    for (var v = 0u; v < 4u; v = v + 1u) {\n"
    "      let d = S[prow * 16u + psub * 4u + v];\n"
    "      let c0 = i32(col0 + (psub * 4u + v) * 4u);\n"
    "      if (d.x > pb) { ps = pb; pb = d.x; pi = c0; }\n      else if (d.x > ps) { ps = d.x; }\n"
    "      if (d.y > pb) { ps = pb; pb = d.y; pi = c0 + 1; }\n      else if (d.y > ps) { ps = d.y; }\n"
    "      if (d.z > pb) { ps = pb; pb = d.z; pi = c0 + 2; }\n      else if (d.z > ps) { ps = d.z; }\n"
    "      if (d.w > pb) { ps = pb; pb = d.w; pi = c0 + 3; }\n      else if (d.w > ps) { ps = d.w; }\n"
    "    }\n"
    "    // [PSCAN] 列 partial:线程负责列 lid%64、行段 lid/64(16 行)\n"
    "    let pcol = lid % 64u;\n"
    "    let pseg = lid / 64u;\n"
    "    let pq = pcol / 4u;\n"
    "    let pm = pcol % 4u;\n"
    "    var cb = 0.0;\n    var cs = 0.0;\n    var ci = -1;\n"
    "    for (var r = pseg * 16u; r < pseg * 16u + 16u; r = r + 1u) {\n"
    "      let d = S[r * 16u + pq][pm];\n"
    "      if (d > cb) { cs = cb; cb = d; ci = i32(row0 + r); }\n      else if (d > cs) { cs = d; }\n"
    "    }\n"
    "    workgroupBarrier();\n"
    "    S[lid] = vec4<f32>(pb, ps, bitcast<f32>(pi), 0.0);\n"
    "    S[NT + lid] = vec4<f32>(cb, cs, bitcast<f32>(ci), 0.0);\n"
    "    workgroupBarrier();\n"
    "    if (lid < WGR) {\n"
    "      for (var sg = 0u; sg < 4u; sg = sg + 1u) {\n"
    "        let pp = S[lid * 4u + sg];\n"
    "        let b2 = pp.x;\n        let s2 = pp.y;\n        let i2 = bitcast<i32>(pp.z);\n"
    "        if (b2 > rowBest) { rowSecond = max(rowBest, s2); rowBest = b2; rowBestI = i2; }\n"
    "        else { rowSecond = max(rowSecond, b2); }\n"
    "      }\n"
    "    } else if (lid < WGR + 64u) {\n"
    "      let c = lid - WGR;\n"
    "      var mb = 0.0;\n      var ms = 0.0;\n      var mi = -1;\n"
    "      for (var sg = 0u; sg < CSEG; sg = sg + 1u) {\n"
    "        let pp = S[NT + sg * 64u + c];\n"
    "        let b2 = pp.x;\n        let s2 = pp.y;\n        let i2 = bitcast<i32>(pp.z);\n"
    "        if (b2 > mb) { ms = max(mb, s2); mb = b2; mi = i2; }\n"
    "        else { ms = max(ms, b2); }\n"
    "      }\n"
    "      let gc = col0 + c;\n"
    "      if (gc < U.numB) { ColP[rb * U.numB + gc] = ColPart(mb, ms, mi); }\n"
    "    }\n";
  t.replace(p, q + from_tail.size() - p, to);
  // S 容量:W128 需要 NT + NT = 256 ≤ 512 ✓;256 线程需要 512 ≤ 1024 ✓(覆写在 WGR*16 个分数上)
  return t;
}

// [DIRECT-PACKED 2026-09-05] At/Bt 存 u8 打包(每个 u32 = 4 行在同一 k 的字节),载入字节量 ÷4,
// 用 unpack4xU8 在寄存器里展开成 f32(值逐位相同 ⇒ 逐字节同)。三端同一处方:A16 每条 vec4 载入
// 512 B 占 8 拍(梯子 gemm44ld 33%),Mali 每条载入指令占一个 FMA 槽 —— 都是"每次 FMA 搬的字节太多"。
// 认 4x4/8x4、pipeb/nopb;不与 TEX/TEXA 叠加(纹理已按"三端一起赚"规矩淘汰)。
constexpr char kWgslXposePacked[] = R"WGSL(
struct XParams { n4 : u32, p1 : u32, p2 : u32, p3 : u32, };
@group(0) @binding(0) var<storage, read> Src : array<u32>;
@group(0) @binding(3) var<uniform> X : XParams;
@group(0) @binding(7) var<storage, read_write> Dst : array<u32>;
@compute @workgroup_size(64)
fn xpose(@builtin(global_invocation_id) gid : vec3<u32>) {
  let n4 = X.n4;
  let i = gid.x;
  if (i >= n4 * 32u) { return; }
  let q = i % n4;
  let w = i / n4;
  let x0 = Src[(4u * q + 0u) * 32u + w];
  let x1 = Src[(4u * q + 1u) * 32u + w];
  let x2 = Src[(4u * q + 2u) * 32u + w];
  let x3 = Src[(4u * q + 3u) * 32u + w];
  let o = (w * 4u) * n4 + q;
  Dst[o + 0u * n4] = (x0 & 255u) | ((x1 & 255u) << 8u) | ((x2 & 255u) << 16u) | ((x3 & 255u) << 24u);
  Dst[o + 1u * n4] = ((x0 >> 8u) & 255u) | (((x1 >> 8u) & 255u) << 8u) | (((x2 >> 8u) & 255u) << 16u) | (((x3 >> 8u) & 255u) << 24u);
  Dst[o + 2u * n4] = ((x0 >> 16u) & 255u) | (((x1 >> 16u) & 255u) << 8u) | (((x2 >> 16u) & 255u) << 16u) | (((x3 >> 16u) & 255u) << 24u);
  Dst[o + 3u * n4] = (x0 >> 24u) | ((x1 >> 24u) << 8u) | ((x2 >> 24u) << 16u) | ((x3 >> 24u) << 24u);
}
)WGSL";
std::string DirectPackedWgsl(const std::string& src) {
  std::string t = src;
  struct Sub { const char* from; const char* to; };
  const Sub decl[] = {
    {"@group(0) @binding(7) var<storage, read> At : array<vec4<f32>>;\n", "@group(0) @binding(7) var<storage, read> At : array<u32>;\n"},
    {"@group(0) @binding(8) var<storage, read> Bt : array<vec4<f32>>;\n", "@group(0) @binding(8) var<storage, read> Bt : array<u32>;\n"},
  };
  for (const Sub& sb : decl) {
    const size_t p = t.find(sb.from);
    if (p == std::string::npos) { AnchorAlarm("DirectPackedWgsl", sb.from); return src; }
    t.replace(p, std::strlen(sb.from), sb.to);
  }
  const Sub loads[] = {
    {"At[k * rowPad4 + rq + 1u]", "vec4<f32>(unpack4xU8(At[k * rowPad4 + rq + 1u]))"},
    {"At[k * rowPad4 + rq]", "vec4<f32>(unpack4xU8(At[k * rowPad4 + rq]))"},
    {"At[min(k + 1u, KD - 1u) * rowPad4 + rq]", "vec4<f32>(unpack4xU8(At[min(k + 1u, KD - 1u) * rowPad4 + rq]))"},
    {"At[rq]", "vec4<f32>(unpack4xU8(At[rq]))"},
    {"Bt[min(k + 1u, KD - 1u) * colPad4 + cq]", "vec4<f32>(unpack4xU8(Bt[min(k + 1u, KD - 1u) * colPad4 + cq]))"},
    {"Bt[k * colPad4 + cq]", "vec4<f32>(unpack4xU8(Bt[k * colPad4 + cq]))"},
    {"Bt[cq]", "vec4<f32>(unpack4xU8(Bt[cq]))"},
  };
  int hits = 0;
  for (const Sub& sb : loads) {
    size_t p = 0;
    while ((p = t.find(sb.from, p)) != std::string::npos) {
      // 跳过已经包在 unpack4xU8( 里的
      if (p >= 11 && t.compare(p - 11, 11, "unpack4xU8(") == 0) { p += std::strlen(sb.from); continue; }
      t.replace(p, std::strlen(sb.from), sb.to); p += std::strlen(sb.to); ++hits;
    }
  }
  if (hits < 2) { AnchorAlarm("DirectPackedWgsl", "载入未命中"); return src; }
  return t;
}

// [DIRECT-F16 2026-09-05] At/Bt 存 vec4<f16>(u8 在 f16 精确),载入字节 ÷2,寄存器里 vec4<f32>(v) 一条转换后走
// 原 f32 FMA ⇒ 乘积/和全在 f32,逐字节同。动机:A16 梯子 gemm44ld 33%(每条 vec4 载入 ≈14 个 FMA 槽),
// PACKED(u8+unpack4xU8)因解包指令太多反赔 36% ⇒ 要"字节减半且几乎不加指令"。需要适配器有 ShaderF16。
constexpr char kWgslXposeF16[] = R"WGSL(
enable f16;
struct XParams { n4 : u32, p1 : u32, p2 : u32, p3 : u32, };
@group(0) @binding(0) var<storage, read> Src : array<u32>;
@group(0) @binding(3) var<uniform> X : XParams;
@group(0) @binding(7) var<storage, read_write> Dst : array<vec4<f16>>;
@compute @workgroup_size(64)
fn xpose(@builtin(global_invocation_id) gid : vec3<u32>) {
  let n4 = X.n4;
  let i = gid.x;
  if (i >= n4 * 32u) { return; }
  let q = i % n4;
  let w = i / n4;
  let x0 = Src[(4u * q + 0u) * 32u + w];
  let x1 = Src[(4u * q + 1u) * 32u + w];
  let x2 = Src[(4u * q + 2u) * 32u + w];
  let x3 = Src[(4u * q + 3u) * 32u + w];
  let o = (w * 4u) * n4 + q;
  Dst[o + 0u * n4] = vec4<f16>(f16(x0 & 255u), f16(x1 & 255u), f16(x2 & 255u), f16(x3 & 255u));
  Dst[o + 1u * n4] = vec4<f16>(f16((x0 >> 8u) & 255u), f16((x1 >> 8u) & 255u), f16((x2 >> 8u) & 255u), f16((x3 >> 8u) & 255u));
  Dst[o + 2u * n4] = vec4<f16>(f16((x0 >> 16u) & 255u), f16((x1 >> 16u) & 255u), f16((x2 >> 16u) & 255u), f16((x3 >> 16u) & 255u));
  Dst[o + 3u * n4] = vec4<f16>(f16(x0 >> 24u), f16(x1 >> 24u), f16(x2 >> 24u), f16(x3 >> 24u));
}
)WGSL";
std::string DirectF16Wgsl(const std::string& src) {
  std::string t = "enable f16;\n" + src;
  struct Sub { const char* from; const char* to; };
  const Sub decl[] = {
    {"@group(0) @binding(7) var<storage, read> At : array<vec4<f32>>;\n", "@group(0) @binding(7) var<storage, read> At : array<vec4<f16>>;\n"},
    {"@group(0) @binding(8) var<storage, read> Bt : array<vec4<f32>>;\n", "@group(0) @binding(8) var<storage, read> Bt : array<vec4<f16>>;\n"},
  };
  for (const Sub& sb : decl) {
    const size_t p = t.find(sb.from);
    if (p == std::string::npos) { AnchorAlarm("DirectF16Wgsl", sb.from); return src; }
    t.replace(p, std::strlen(sb.from), sb.to);
  }
  const char* loads[] = {"At[k * rowPad4 + rq + 1u]", "At[k * rowPad4 + rq]", "At[min(k + 1u, KD - 1u) * rowPad4 + rq]", "At[rq]",
                         "Bt[min(k + 1u, KD - 1u) * colPad4 + cq]", "Bt[k * colPad4 + cq]", "Bt[cq]"};
  int hits = 0;
  for (const char* ld : loads) {
    const std::string from = ld; const std::string to = "vec4<f32>(" + from + ")";
    size_t p = 0;
    while ((p = t.find(from, p)) != std::string::npos) {
      if (p >= 10 && t.compare(p - 10, 10, "vec4<f32>(") == 0) { p += from.size(); continue; }
      t.replace(p, from.size(), to); p += to.size(); ++hits;
    }
  }
  if (hits < 2) { AnchorAlarm("DirectF16Wgsl", "载入未命中"); return src; }
  return t;
}

// [DIRECT-TMAP 2026-09-05] 线程映射转置:tr = lid % NR, tc = lid / NR(原 tr = lid/16, tc = lid%16)。
// 相邻线程改为共享同一 B(b4 在 quad 内广播)、A 各不相同(al 连续)。动机:Mali 必须预取"每线程地址不同"
// 的那个操作数(现为 B:PIPEB 618 / NOPB 822 / PIPEA 842),而 A16 能接受预取 A(PIPEA 68.6–71.4)却不接受
// 预取 B(80.7)。转置后 Mali 要预取的变成 A ⇒ PIPEA 有望两端都不赔。扫描段只用 lid,不受影响;逐字节同。
std::string DirectTMapWgsl(const std::string& src) {
  std::string t = src;
  const bool w128 = t.find("@compute @workgroup_size(128)\nfn main(") != std::string::npos;
  const char* nr = w128 ? "8u" : "16u";  // 行组数:W128 是 8(4 行×8=32),256 线程是 16(×4=64)
  const std::string from = "  let tr = lid / 16u;\n  let tc = lid % 16u;\n";
  const size_t p = t.find(from);
  if (p == std::string::npos) { AnchorAlarm("DirectTMapWgsl", "tr/tc 映射未命中"); return src; }
  t.replace(p, from.size(), std::string("  let tr = lid % ") + nr + ";\n  let tc = lid / " + nr + ";\n");
  return t;
}

// [DIRECT-UNROLLH 2026-09-05] 载入提前的 n 倍展开:体首先发出 n 个 k 的 al/b4 载入,再按 k 升序做各自的 16 次 FMA。
// k+1 的载入在 k 的 FMA 期间在飞(Mali 编译器不重排,需要源码级软件流水),但不跨迭代持有寄存器(A16 对跨迭代
// 预取赔 17%)。累加顺序按 k 升序不变 ⇒ 逐字节同。只认 4x4+NOPB 文本(载入行 `let b4 = …` / `let al = …`)。
std::string DirectUnrollHWgsl(const std::string& src, int n) {
  std::string t = src;
  const std::string head = "    for (var k = 0u; k < KD; k = k + 1u) {\n";
  const size_t p = t.find(head);
  if (p == std::string::npos) { AnchorAlarm("DirectUnrollHWgsl", "循环头未命中"); return src; }
  const std::string tail = "      acc3 = acc3 + al.w * b4;\n    }\n";
  const size_t q = t.find(tail, p);
  if (q == std::string::npos) { AnchorAlarm("DirectUnrollHWgsl", "循环尾未命中(只认 4x4 未 fma 化)"); return src; }
  const std::string body = t.substr(p + head.size(), q + tail.size() - 6 - (p + head.size()));
  if (body.find("bn") != std::string::npos || body.find("aln") != std::string::npos || body.find("let ah") != std::string::npos) {
    AnchorAlarm("DirectUnrollHWgsl", "只认 4x4+NOPB(无预取)形态"); return src;
  }
  std::vector<std::string> loads, comps;
  size_t i = 0;
  while (i < body.size()) {
    size_t e = body.find('\n', i); if (e == std::string::npos) e = body.size();
    const std::string line = body.substr(i, e - i + 1);
    if (line.rfind("      let al = ", 0) == 0 || line.rfind("      let b4 = ", 0) == 0) loads.push_back(line); else comps.push_back(line);
    i = e + 1;
  }
  if (loads.size() != 2) { AnchorAlarm("DirectUnrollHWgsl", "载入行数不是 2"); return src; }
  auto subst_k = [](const std::string& b, const std::string& kk) {
    std::string r;
    for (size_t j = 0; j < b.size(); ++j) {
      if (b[j] == 'k' && (j == 0 || !(std::isalnum((unsigned char)b[j-1]) || b[j-1] == '_')) &&
          (j + 1 >= b.size() || !(std::isalnum((unsigned char)b[j+1]) || b[j+1] == '_'))) r += kk; else r += b[j];
    }
    return r;
  };
  auto rename = [](std::string l, const char* from, const std::string& to) {
    size_t pos = 0; while ((pos = l.find(from, pos)) != std::string::npos) { l.replace(pos, std::strlen(from), to); pos += to.size(); } return l;
  };
  std::string out;
  char hdr[96]; std::snprintf(hdr, sizeof(hdr), "    for (var k0 = 0u; k0 < KD; k0 = k0 + %du) {\n", n);
  out += hdr;
  for (int u = 0; u < n; ++u) {
    char kk[32]; std::snprintf(kk, sizeof(kk), "(k0 + %du)", u);
    for (const std::string& l : loads) {
      std::string x = subst_k(l, kk);
      x = rename(x, "let al = ", "let al_" + std::to_string(u) + " = ");
      x = rename(x, "let b4 = ", "let b4_" + std::to_string(u) + " = ");
      out += x;
    }
  }
  for (int u = 0; u < n; ++u) {
    for (const std::string& l : comps) {
      std::string x = rename(l, "al.", "al_" + std::to_string(u) + ".");
      x = rename(x, "b4;", "b4_" + std::to_string(u) + ";");
      out += x;
    }
  }
  out += "    }\n";
  t.replace(p, q + tail.size() - p, out);
  return t;
}

// [DIRECT-TAILB 2026-09-06] 零额外寄存器的 B 预取:FMAs(k) 之后再发 k+1 的 B 载入,装回已死的 b4。
// FMA 期间活寄存器 = acc + al + b4,与零预取相同(A16 对每个跨迭代活寄存器赔 ~17%);
// 载入在跑回循环头、取 A 的这段时间里在飞(Mali 需要源码级软件流水)。累加顺序不变 ⇒ 逐字节同。
// 只认 4x4+NOPB 文本(f32 或 f16 载入形态都认)。
std::string DirectTailBWgsl(const std::string& src) {
  std::string t = src;
  const char* heads[] = {
    "    for (var k = 0u; k < KD; k = k + 1u) {\n      let b4 = vec4<f32>(Bt[k * colPad4 + cq]);\n",
    "    for (var k = 0u; k < KD; k = k + 1u) {\n      let b4 = Bt[k * colPad4 + cq];\n",
  };
  const char* firsts[] = { "vec4<f32>(Bt[cq])", "Bt[cq]" };
  const char* nexts[]  = { "vec4<f32>(Bt[min(k + 1u, KD - 1u) * colPad4 + cq])", "Bt[min(k + 1u, KD - 1u) * colPad4 + cq]" };
  int which = -1; size_t p = std::string::npos;
  for (int i = 0; i < 2; ++i) { p = t.find(heads[i]); if (p != std::string::npos) { which = i; break; } }
  if (which < 0) { AnchorAlarm("DirectTailBWgsl", "只认 4x4+NOPB 的循环头"); return src; }
  t.replace(p, std::strlen(heads[which]),
            std::string("    var b4 = ") + firsts[which] + ";\n    for (var k = 0u; k < KD; k = k + 1u) {\n");
  const std::string tail = "      acc3 = acc3 + al.w * b4;\n    }\n";
  const size_t q = t.find(tail, p);
  if (q == std::string::npos) { AnchorAlarm("DirectTailBWgsl", "循环尾未命中"); return src; }
  t.replace(q, tail.size(), std::string("      acc3 = acc3 + al.w * b4;\n      b4 = ") + nexts[which] + ";\n    }\n");
  return t;
}

std::string BlkNoLoadWgsl(const std::string& src) {
  std::string t = src;
  // [ANCHOR 2026-09-05] 默认形态是 8x4+PIPEB(b4 预取成 bn),锚点必须先认这一形态;
  // 09-05 晚 Mac 活性检查发现本探针在默认形态上静默 no-op(生成代码与基线逐字节同)。
  const std::string fromPipeB =
      "        let al = S[k * 16u + tr * 2u];\n"
      "        let ah = S[k * 16u + tr * 2u + 1u];\n"
      "        let bn = S[512u + min(k + 1u, KC - 1u) * 16u + tc];\n";
  const size_t pb = t.find(fromPipeB);
  if (pb != std::string::npos) {
    t.replace(pb, fromPipeB.size(),
        "        let fk = f32(k);\n"
        "        let al = vec4<f32>(fk, fk + 1.0, fk + 2.0, fk + 3.0);\n"
        "        let ah = vec4<f32>(fk + 4.0, fk + 5.0, fk + 6.0, fk + 7.0);\n"
        "        let bn = vec4<f32>(fk * 0.5, fk, fk * 1.5, fk * 2.0);\n");
    return t;
  }
  const std::string from =
      "        let al = S[k * 16u + tr * 2u];\n"
      "        let ah = S[k * 16u + tr * 2u + 1u];\n"
      "        let b4 = S[512u + k * 16u + tc];\n";
  const size_t p = t.find(from);
  if (p != std::string::npos) {
    t.replace(p, from.size(),
        "        let fk = f32(k);\n"
        "        let al = vec4<f32>(fk, fk + 1.0, fk + 2.0, fk + 3.0);\n"
        "        let ah = vec4<f32>(fk + 4.0, fk + 5.0, fk + 6.0, fk + 7.0);\n"
        "        let b4 = vec4<f32>(fk * 0.5, fk, fk * 1.5, fk * 2.0);\n");
    return t;
  }
  // 4x4 基核的内层
  const std::string from44 =
      "        let a4 = S[k * 16u + tr];\n"
      "        let b4 = S[512u + k * 16u + tc];\n";
  const size_t q = t.find(from44);
  if (q == std::string::npos) { AnchorAlarm("BlkNoLoadWgsl", "内层载入未命中(4x4/8x4 都不是)"); return src; }
  t.replace(q, from44.size(),
      "        let fk = f32(k);\n"
      "        let a4 = vec4<f32>(fk, fk + 1.0, fk + 2.0, fk + 3.0);\n"
      "        let b4 = vec4<f32>(fk * 0.5, fk, fk * 1.5, fk * 2.0);\n");
  return t;
}

// 尺子(逐字节不变):BLK_XBAR 每个 k 段的计算之后多加 N 个 barrier,斜率 = 单个 barrier 的价。
std::string BlkXBarWgsl(const std::string& src, int n) {
  std::string t = src;
  // [ANCHOR 2026-09-05] 先认 PIPEB 形态的循环尾(多一行 b4 = bn),再认裸 8x4。
  std::string from =
      "        acc7 = acc7 + ah.w * b4;\n"
      "        b4 = bn;\n"
      "      }\n";
  size_t p = t.find(from);
  if (p == std::string::npos) {
    from = "        acc7 = acc7 + ah.w * b4;\n      }\n";
    p = t.find(from);
  }
  if (p == std::string::npos) { AnchorAlarm("BlkXBarWgsl", "8x4 内层尾未命中(PIPEB/裸 都不是)"); return src; }
  std::string add = from;
  for (int i = 0; i < n; ++i) add += "      workgroupBarrier();\n";
  t.replace(p, from.size(), add);
  return t;
}

// 刀(逐字节无损,第 6 刀复刻):BLK_GPF 把第 kc+1 段的**全局**载入提前到第 kc 段的
// 计算之前发出、落在寄存器里;下一段只做解包+写线程组。AGX 上全局载入**有** scoreboard,
// 能真正与 FMA 重叠 —— 与刚判死的 BLK_PIPE(线程组载入提前,无 scoreboard)是两回事。
// 实现:把暂存循环拆成「从寄存器写」+「预取下一段到寄存器」两半;寄存器多 4 个 u32/对。
std::string BlkGpfWgsl(const std::string& src) {
  std::string t = src;
  // 暂存体首尾锚点(8x4 与 8x8 共用同一形态,只是循环头不同)
  const char* heads[] = {
      "      for (var side = 0u; side < 2u; side = side + 1u) {\n        let w = lid / 16u;\n        let q = lid % 16u;\n",
      "      for (var pair = 0u; pair < 4u; pair = pair + 1u) {\n        let side = pair / 2u;\n        let t = lid + (pair % 2u) * 64u;\n        let w = t / 16u;\n        let q = t % 16u;\n"};
  size_t p = std::string::npos; int which = -1;
  for (int h = 0; h < 2; ++h) { p = t.find(heads[h]); if (p != std::string::npos) { which = h; break; } }
  if (which < 0) { AnchorAlarm("BlkGpfWgsl", "暂存头未命中"); return src; }
  const std::string tail = "        S[o + 3u * 16u] = vec4<f32>(f32(x0 >> 24u), f32(x1 >> 24u), f32(x2 >> 24u), f32(x3 >> 24u));\n      }\n";
  const size_t q = t.find(tail, p);
  if (q == std::string::npos) { AnchorAlarm("BlkGpfWgsl", "暂存尾未命中"); return src; }
  const int npair = which == 0 ? 2 : 4;
  // 新暂存:先从寄存器 px[pair] 写出;然后为 kc+1 预取。
  std::string body;
  body += "      // [GPF] 从上一步预取好的寄存器写线程组\n";
  for (int pr = 0; pr < npair; ++pr) {
    char b[1200];
    const char* sidx = which == 0 ? "%d" : "(%d / 2)";
    (void)sidx;
    const int side = which == 0 ? pr : pr / 2;
    const int tofs = which == 0 ? 0 : (pr % 2) * 64;
    std::snprintf(b, sizeof(b),
      "      {\n"
      "        let t = lid + %du;\n"
      "        let w = t / 16u;\n"
      "        let q = t %% 16u;\n"
      "        let o = %du + (w * 4u) * 16u + q;\n"
      "        S[o + 0u * 16u] = vec4<f32>(f32(px%d.x & 255u), f32(px%d.y & 255u), f32(px%d.z & 255u), f32(px%d.w & 255u));\n"
      "        S[o + 1u * 16u] = vec4<f32>(f32((px%d.x >> 8u) & 255u), f32((px%d.y >> 8u) & 255u), f32((px%d.z >> 8u) & 255u), f32((px%d.w >> 8u) & 255u));\n"
      "        S[o + 2u * 16u] = vec4<f32>(f32((px%d.x >> 16u) & 255u), f32((px%d.y >> 16u) & 255u), f32((px%d.z >> 16u) & 255u), f32((px%d.w >> 16u) & 255u));\n"
      "        S[o + 3u * 16u] = vec4<f32>(f32(px%d.x >> 24u), f32(px%d.y >> 24u), f32(px%d.z >> 24u), f32(px%d.w >> 24u));\n"
      "      }\n",
      tofs, side * 512, pr,pr,pr,pr, pr,pr,pr,pr, pr,pr,pr,pr, pr,pr,pr,pr);
    body += b;
  }
  t.replace(p, q + tail.size() - p, body);
  // 预取函数体:给定 kc,把 npair 对读进 px*
  std::string pre;
  for (int pr = 0; pr < npair; ++pr) {
    const int side = which == 0 ? pr : pr / 2;
    const int tofs = which == 0 ? 0 : (pr % 2) * 64;
    char b[900];
    std::snprintf(b, sizeof(b),
      "      {\n"
      "        let t = lid + %du;\n"
      "        let w = t / 16u;\n"
      "        let base = (t %% 16u) * 4u;\n"
      "        let g = %s + base;\n"
      "        px%d = vec4<u32>(\n"
      "          select(0u, %s[(g + 0u) * 32u + kcn * 8u + w], g + 0u < %s),\n"
      "          select(0u, %s[(g + 1u) * 32u + kcn * 8u + w], g + 1u < %s),\n"
      "          select(0u, %s[(g + 2u) * 32u + kcn * 8u + w], g + 2u < %s),\n"
      "          select(0u, %s[(g + 3u) * 32u + kcn * 8u + w], g + 3u < %s));\n"
      "      }\n",
      tofs, side == 0 ? "row0" : "col0", pr,
      side == 0 ? "A" : "B", side == 0 ? "U.numA" : "U.numB",
      side == 0 ? "A" : "B", side == 0 ? "U.numA" : "U.numB",
      side == 0 ? "A" : "B", side == 0 ? "U.numA" : "U.numB",
      side == 0 ? "A" : "B", side == 0 ? "U.numA" : "U.numB");
    pre += b;
  }
  // 段循环头:声明 px*,并在进入循环前预取 kc=0;循环内计算前预取 kc+1
  std::string decl;
  for (int pr = 0; pr < npair; ++pr) { char b[64]; std::snprintf(b, sizeof(b), "    var px%d = vec4<u32>(0u);\n", pr); decl += b; }
  const std::string loop_head = "    for (var kc = 0u; kc < 4u; kc = kc + 1u) {\n      workgroupBarrier();\n";
  const size_t lp = t.find(loop_head);
  if (lp == std::string::npos) { AnchorAlarm("BlkGpfWgsl", "段循环头未命中"); return src; }
  std::string pre0 = pre; { size_t z; while ((z = pre0.find("kcn")) != std::string::npos) pre0.replace(z, 3, "0u"); }
  t.replace(lp, loop_head.size(), decl + "    {\n" + pre0 + "    }\n" + loop_head);
  // 计算前(第二个 barrier 之后)预取 kc+1
  const std::string bar2 = "      workgroupBarrier();\n      for (var k = 0u; k < KC; k = k + 1u) {\n";
  const size_t bp = t.find(bar2, lp);
  if (bp == std::string::npos) { AnchorAlarm("BlkGpfWgsl", "第二 barrier 未命中"); return src; }
  std::string pre1 = pre; { size_t z; while ((z = pre1.find("kcn")) != std::string::npos) pre1.replace(z, 3, "kcx"); }
  t.replace(bp, bar2.size(),
            "      workgroupBarrier();\n"
            "      if (kc + 1u < 4u) {\n        let kcx = kc + 1u;\n" + pre1 + "      }\n"
            "      for (var k = 0u; k < KC; k = k + 1u) {\n");
  return t;
}

// 刀(逐字节无损):BLK_STG 暂存全局读改合并访问。现役映射 q=t%16、w=t/16 ⇒ 同一时刻
// 16 个线程读 16 个不同行组、同一个 word ⇒ 16 条 cache line。改成 w=t%8、q=t/8 ⇒
// 8 个连续线程读同 4 行的连续 8 个 word(每行 32B 连续)。数据与目的地不变。
std::string BlkStgWgsl(const std::string& src) {
  std::string t = src;
  const std::string from = "        let w = lid / 16u;\n        let q = lid % 16u;\n";
  const size_t p = t.find(from);
  if (p == std::string::npos) { AnchorAlarm("BlkStgWgsl", "8x4 暂存映射未命中"); return src; }
  t.replace(p, from.size(), "        let w = lid % 8u;\n        let q = lid / 8u;\n");
  return t;
}

// 刀(逐字节无损,第 3 刀复刻):BLK_RSCAN 寄存器内 partial 扫描。
// 每线程先在寄存器里把自己 8x4 块归约成 8 个行向 partial(各在 4 列上 top-2,列升序严格 >)
// 与 4 个列向 partial(各在 8 行上 top-2,行升序严格 >);行 partial 存 S[row*16+tc](恰好
// 1024 个 vec4 = 16 KiB),64 线程各折叠 16 个(tc 升序 = 列升序);再存 4 个列 partial 到
// S[col*8+tr],64 线程各折叠 8 个(tr 升序 = 行升序)。
// 折叠规则逐字复刻 MMA 核蝶形:高下标集合只在严格 > 时替换 best,second = max(...)。
// 层次 top-2 归并与逐元素扫描等价(v2 对 v1 过闸的同一论证)⇒ 逐字节不变。
std::string BlkRScanWgsl(const std::string& src) {
  std::string t = src;
  const std::string head = "    workgroupBarrier();\n    S[(tr * 8u + 0u) * 16u + tc] = acc0;\n";
  const size_t p = t.find(head);
  if (p == std::string::npos) { AnchorAlarm("BlkRScanWgsl", "acc 存储头未命中"); return src; }
  const std::string tail = "      if (gc < U.numB) { ColP[rb * U.numB + gc] = ColPart(cb, cs, ci); }\n    }\n";
  const size_t q = t.find(tail, p);
  if (q == std::string::npos) { AnchorAlarm("BlkRScanWgsl", "列扫描尾未命中"); return src; }
  std::string body;
  body +=
    "    workgroupBarrier();\n"
    "    // ── 行向 partial(本线程 8 行 × 4 列)──\n";
  for (int i = 0; i < 8; ++i) {
    char b[700];
    std::snprintf(b, sizeof(b),
      "    {\n"
      "      let d = acc%d;\n"
      "      var pb = 0.0; var ps = 0.0; var pi = -1;\n"
      "      let cb0 = i32(col0 + tc * 4u);\n"
      "      if (d.x > pb) { ps = pb; pb = d.x; pi = cb0; } else if (d.x > ps) { ps = d.x; }\n"
      "      if (d.y > pb) { ps = pb; pb = d.y; pi = cb0 + 1; } else if (d.y > ps) { ps = d.y; }\n"
      "      if (d.z > pb) { ps = pb; pb = d.z; pi = cb0 + 2; } else if (d.z > ps) { ps = d.z; }\n"
      "      if (d.w > pb) { ps = pb; pb = d.w; pi = cb0 + 3; } else if (d.w > ps) { ps = d.w; }\n"
      "      S[(tr * 8u + %du) * 16u + tc] = vec4<f32>(pb, ps, bitcast<f32>(pi), 0.0);\n"
      "    }\n", i, i);
    body += b;
  }
  body +=
    "    workgroupBarrier();\n"
    "    if (lid < WGR) {\n"
    "      for (var v = 0u; v < 16u; v = v + 1u) {\n"
    "        let d = S[lid * 16u + v];\n"
    "        let ob = d.x; let os = d.y; let oi = bitcast<i32>(d.z);\n"
    "        if (ob > rowBest) { rowSecond = max(os, rowBest); rowBest = ob; rowBestI = oi; }\n"
    "        else { rowSecond = max(rowSecond, ob); }\n"
    "      }\n"
    "    }\n"
    "    workgroupBarrier();\n"
    "    // ── 列向 partial(本线程 4 列 × 8 行)──\n";
  for (int j = 0; j < 4; ++j) {
    const char* comp = "xyzw";
    std::string b =
      "    {\n"
      "      var pb = 0.0; var ps = 0.0; var pi = -1;\n"
      "      let rb0 = i32(row0 + tr * 8u);\n";
    for (int i = 0; i < 8; ++i) {
      char l[200];
      std::snprintf(l, sizeof(l),
        "      if (acc%d.%c > pb) { ps = pb; pb = acc%d.%c; pi = rb0 + %d; } else if (acc%d.%c > ps) { ps = acc%d.%c; }\n",
        i, comp[j], i, comp[j], i, i, comp[j], i, comp[j]);
      b += l;
    }
    char st[160];
    std::snprintf(st, sizeof(st), "      S[(tc * 4u + %du) * 8u + tr] = vec4<f32>(pb, ps, bitcast<f32>(pi), 0.0);\n    }\n", j);
    b += st;
    body += b;
  }
  body +=
    "    workgroupBarrier();\n"
    "    if (lid >= WGR && lid < 2u * WGR) {\n"
    "      let c = lid - WGR;\n"
    "      var cb = 0.0; var cs = 0.0; var ci = -1;\n"
    "      for (var r8 = 0u; r8 < 8u; r8 = r8 + 1u) {\n"
    "        let d = S[c * 8u + r8];\n"
    "        let ob = d.x; let os = d.y; let oi = bitcast<i32>(d.z);\n"
    "        if (ob > cb) { cs = max(os, cb); cb = ob; ci = oi; }\n"
    "        else { cs = max(cs, ob); }\n"
    "      }\n"
    "      let gc = col0 + c;\n"
    "      if (gc < U.numB) { ColP[rb * U.numB + gc] = ColPart(cb, cs, ci); }\n"
    "    }\n";
  t.replace(p, q + tail.size() - p, body);
  return t;
}

// 刀(逐字节无损):BLK_PIPEB 只把 B 那一个 vec4 提前一拍(A 的两个不动)。
// 依据:PIPE 在 Adreno −13% 但在 A16 +12% —— A16 赔的是 3 个活 vec4;只提前 B 把活寄存器
// 压到 1 个,试探两边都赚的形态。
std::string BlkPipeBWgsl(const std::string& src) {
  std::string t = src;
  const std::string from =
      "      for (var k = 0u; k < KC; k = k + 1u) {\n"
      "        let al = S[k * 16u + tr * 2u];\n"
      "        let ah = S[k * 16u + tr * 2u + 1u];\n"
      "        let b4 = S[512u + k * 16u + tc];\n";
  const size_t p = t.find(from);
  if (p == std::string::npos) { AnchorAlarm("BlkPipeBWgsl", "8x4 循环头未命中"); return src; }
  t.replace(p, from.size(),
      "      var b4 = S[512u + tc];\n"
      "      for (var k = 0u; k < KC; k = k + 1u) {\n"
      "        let al = S[k * 16u + tr * 2u];\n"
      "        let ah = S[k * 16u + tr * 2u + 1u];\n"
      "        let bn = S[512u + min(k + 1u, KC - 1u) * 16u + tc];\n");
  const std::string tail = "        acc7 = acc7 + ah.w * b4;\n      }\n";
  const size_t q = t.find(tail, p);
  if (q == std::string::npos) { AnchorAlarm("BlkPipeBWgsl", "8x4 循环尾未命中"); return src; }
  t.replace(q, tail.size(), "        acc7 = acc7 + ah.w * b4;\n        b4 = bn;\n      }\n");
  return t;
}

std::string BlkUnrollWgsl(const std::string& src) {
  std::string t = src;
  const std::string from =
      "      for (var k = 0u; k < KC; k = k + 1u) {\n"
      "        let a4 = S[k * 16u + tr];\n"
      "        let b4 = S[512u + k * 16u + tc];\n"
      "        acc0 = acc0 + a4.x * b4;\n"
      "        acc1 = acc1 + a4.y * b4;\n"
      "        acc2 = acc2 + a4.z * b4;\n"
      "        acc3 = acc3 + a4.w * b4;\n"
      "      }\n";
  const size_t p = t.find(from);
  if (p == std::string::npos) { AnchorAlarm("BlkUnrollWgsl", "k 循环未命中"); return src; }
  std::string to;
  for (int k = 0; k < 32; ++k) {
    char buf[512];
    std::snprintf(buf, sizeof(buf),
        "      {\n"
        "        let a4 = S[%du + tr];\n"
        "        let b4 = S[%du + tc];\n"
        "        acc0 = acc0 + a4.x * b4;\n"
        "        acc1 = acc1 + a4.y * b4;\n"
        "        acc2 = acc2 + a4.z * b4;\n"
        "        acc3 = acc3 + a4.w * b4;\n"
        "      }\n", k * 16, 512 + k * 16);
    to += buf;
  }
  t.replace(p, from.size(), to);
  return t;
}

// [PREFETCH-SHADOW 2026-09-04] 软件流水:把下一块 B 的 device load **提前**发出、
// 解包写回**推后**,让扫描+归并跑在 load 的延迟阴影里。
// 机制(用无污染源的探针量出来的,这是本战役最关键的一次测量):
//   同一二进制、同一着色器、只改一个 uniform(额外一遍扫描写影子变量 + 运行期 select
//   折回,输出逐字节不变)⇒ **一遍扫描的边际成本:我们 0.98ms,原生 1.02-1.28ms**。
//   **两边扫描一样贵** —— 此前十刀全部瞄准"我们的扫描更慢",那个缺陷根本不存在。
//   再对账:原生总计 4.71,而它的 MMA-only 4.28 + 一遍扫描 1.02 = 5.30 > 总计
//   ⇒ **原生有约 0.6ms 的扫描是藏起来的**,藏在预取的 device load 延迟阴影里
//   (它的预取是 8 次迭代的长延迟 load,GEMM 之后扫描就在这些 load 的影子里跑)。
//   而 packed 上传把我们的预取压到 2 次迭代 —— 省了 0.65ms 上传 + 0.3ms GPU(净赚),
//   **但同时把阴影削没了**。这也解释了当时那个反常:packed 之后串行归并突然比蝶形贵
//   0.85ms,因为它原本就藏在预取后面。
// 做法:不需要第二个 Bsh 缓冲。GEMM 之后的 barrier 已保证所有 SG 读完 Bsh ⇒
//   同一个 Bsh 可以就地覆盖。每线程只多 2 个 u32 寄存器(packed 下 1024 u32 / 512 线程)。
//   共享内存不变、barrier 数不变(仍 3 次)。
// env OFFICIAL_AETHER_MATCH_DAWN_NOPREFETCH=1 回到原结构做单变量 A/B。
std::string PrefetchWgsl(const std::string& src) {
  std::string t = src;
  // packed 形态下的预取块(PackedWgsl 的产物),整块搬走
  const std::string stage =
      "    for (var e = lid; e < BT * 32u; e = e + 512u) {\n"
      "      let brow = col0 + e / 32u;\n"
      "      let pu = select(0u, B[brow * 32u + (e % 32u)], brow < U.numB);\n"
      "      let po = (e / 32u) * 128u + (e % 32u) * 4u;\n"
      "      Bsh[po] = f16(pu & 255u);\n"
      "      Bsh[po + 1u] = f16((pu >> 8u) & 255u);\n"
      "      Bsh[po + 2u] = f16((pu >> 16u) & 255u);\n"
      "      Bsh[po + 3u] = f16(pu >> 24u);\n"
      "    }\n"
      "    workgroupBarrier();\n";
  const size_t sp = t.find(stage);
  if (sp == std::string::npos) {
    // 🔴 今天被这个静默出口坑过一次:撤诊断探针时留下的 `let ntm = nt;` 让锚点失配,
    // 变换悄悄退化成 no-op,于是"晚 vs 早"的 A/B 实际测成了"有预取 vs 无预取",
    // 差点报出一个不存在的 −0.213ms。锚点失配一律出声。
    std::fprintf(stderr,
                 "[pwofficial_gpu_match_dawn] PrefetchWgsl 锚点失配(stage),"
                 "变换未生效 —— 内核结构可能已改,请核对锚点\n");
    { AnchorAlarm("PrefetchWgsl", "静默退化为 no-op"); return src; }
  }
  // 1) 循环内的预取块删掉
  t.erase(sp, stage.size());
  // 2) 循环外(loop 之前)先把第 0 块预取好
  // [ANCHOR-FIX 2026-09-05] COLCHUNK 把 `var col0 = 0u;` 改成了 `= U.colBase;`
  // 并在其后加了 colEnd —— 锚点随之更新。第 0 块的预取地址也不再恒为 0,
  // 而是 U.colBase(按行分块时它就是 0,逐字节等价)。
  const std::string loop_head =
      "  var col0 = U.colBase;\n"
      "  let colEnd = min(U.colBase + U.colSpan, U.numB);\n"
      "  loop {\n";
  const size_t lp = t.find(loop_head);
  if (lp == std::string::npos) {
    std::fprintf(stderr, "[pwofficial_gpu_match_dawn] PrefetchWgsl 锚点失配(loop_head),变换未生效\n");
    { AnchorAlarm("PrefetchWgsl", "静默退化为 no-op"); return src; }
  }
  std::string pre0 = stage;
  { const size_t q = pre0.find("col0 + e / 32u"); pre0.replace(q, 14, "U.colBase + e / 32u"); }
  t.insert(lp, pre0);
  // 3) GEMM 后的 barrier 之后:发出下一块的 load 到寄存器
  // [LIVE-RANGE 2026-09-04] 预取的发出点:默认挪到 cp barrier 之后(紧挨归并),
  // 把 pv0/pv1 的活跃区间从「跨扫描+归并」缩短到「只跨归并」。
  // 起因:加法定价测出**预取的 2 个寄存器让 GEMM 边际从 4.200 涨到 4.733(+0.53ms)** ——
  // 这一刀是交易不是白赚。发得更早(agent 试过)更慢,与此自洽;发得更晚没人试过。
  // 发出点三选一都试过:提前到循环顶(+0.10ms)、现役(GEMM barrier 之后)、
  // 推后到 cp barrier 之后(隔离台架 +0.025ms)⇒ **这一维已穷尽,保持现役**。
  const bool late = getenv("OFFICIAL_AETHER_MATCH_DAWN_PFLATE") != nullptr;
  const std::string after_gemm =
      late ? std::string("    cpIdx[sg * 32u + lane] = ci;\n    workgroupBarrier();\n")
           : std::string(
      "    subgroupMatrixStore(&accSh, (sg * 8u) * 32u + 3u * 8u, acc3, false, 32u);\n"
      "    workgroupBarrier();\n");
  const size_t ag = t.find(after_gemm);
  if (ag == std::string::npos) {
    std::fprintf(stderr, "[pwofficial_gpu_match_dawn] PrefetchWgsl 锚点失配(after_gemm),变换未生效\n");
    { AnchorAlarm("PrefetchWgsl", "静默退化为 no-op"); return src; }
  }
  t.insert(ag + after_gemm.size(),
      "    // 提前发出下一块的 device load(只进寄存器,不碰 Bsh)\n"
      "    let nextT = col0 + BT;\n"
      "    let pe0 = lid;\n"
      "    let pe1 = lid + 512u;\n"
      "    let pr0 = nextT + pe0 / 32u;\n"
      "    let pr1 = nextT + pe1 / 32u;\n"
      "    // 🔴 WGSL 的 select **两个操作数都会求值** ⇒ 条件为假时 B[...] 照样读。\n"
      "    // 最后一块 nextT == numB,行号最多超出 15 行 ⇒ 读到 B 尾后约 2 KiB。\n"
      "    // disable_robustness 开着,在 Metal 上无害(值被外层 select 丢弃),但这是 UB,\n"
      "    // **Vulkan 后端可能触发校验层或崩溃** —— 三端一套下是硬伤。先把下标钳到界内,\n"
      "    // 界内地址逐字节不变(只影响最后一块的越界行,那些行本来就被丢弃)。\n"
      "    let sr0 = select(0u, pr0, pr0 < U.numB);\n"
      "    let sr1 = select(0u, pr1, pr1 < U.numB);\n"
      "    let pv0 = select(0u, B[sr0 * 32u + (pe0 % 32u)], pr0 < U.numB);\n"
      "    let pv1 = select(0u, B[sr1 * 32u + (pe1 % 32u)], pr1 < U.numB);\n");
  // 4) 归并之后、循环末尾之前:解包写回 Bsh,再一次 barrier
  const std::string tail = "    col0 = col0 + BT;\n";
  const size_t tp = t.rfind(tail);
  if (tp == std::string::npos) { AnchorAlarm("PrefetchWgsl", "静默退化为 no-op"); return src; }
  t.replace(tp, tail.size(),
      "    // 用得最晚:此时 load 已在飞行中被扫描+归并掩藏\n"
      "    let po0 = (pe0 / 32u) * 128u + (pe0 % 32u) * 4u;\n"
      "    Bsh[po0] = f16(pv0 & 255u);\n"
      "    Bsh[po0 + 1u] = f16((pv0 >> 8u) & 255u);\n"
      "    Bsh[po0 + 2u] = f16((pv0 >> 16u) & 255u);\n"
      "    Bsh[po0 + 3u] = f16(pv0 >> 24u);\n"
      "    let po1 = (pe1 / 32u) * 128u + (pe1 % 32u) * 4u;\n"
      "    Bsh[po1] = f16(pv1 & 255u);\n"
      "    Bsh[po1 + 1u] = f16((pv1 >> 8u) & 255u);\n"
      "    Bsh[po1 + 2u] = f16((pv1 >> 16u) & 255u);\n"
      "    Bsh[po1 + 3u] = f16(pv1 >> 24u);\n"
      "    workgroupBarrier();\n"
      "    col0 = nextT;\n");
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
  if (!ok) { AnchorAlarm("ColpTransposeWgsl", "静默退化为 no-op"); return src; }
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
  if (c.p_main && (c.backend == Backend::kTiled || c.p_merge)) return true;
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
    if (c.packed && shape &&
        getenv("OFFICIAL_AETHER_MATCH_DAWN_NOPREFETCH") == nullptr) {
      mixed_src = PrefetchWgsl(mixed_src);
    }
    if (c.mixed && getenv("OFFICIAL_AETHER_MATCH_DAWN_NOSCAN") != nullptr) {
      mixed_src = NoScanWgsl(mixed_src);
    }
    if (c.mixed && getenv("OFFICIAL_AETHER_MATCH_DAWN_HALFLOAD") != nullptr) {
      mixed_src = HalfLoadWgsl(mixed_src);
    }
    if (c.mixed && getenv("OFFICIAL_AETHER_MATCH_DAWN_NOAPRO") != nullptr) {
      mixed_src = NoAProWgsl(mixed_src);
    }
    if (c.mixed && getenv("OFFICIAL_AETHER_MATCH_DAWN_BSTORE") != nullptr) {
      mixed_src = BStoreWgsl(mixed_src);
    }
    if (c.mixed && getenv("OFFICIAL_AETHER_MATCH_DAWN_MERGE1") != nullptr) {
      mixed_src = Merge1Wgsl(mixed_src);
    }
    if (c.mixed && getenv("OFFICIAL_AETHER_MATCH_DAWN_BLOAD") != nullptr) {
      mixed_src = BLoadHoistWgsl(mixed_src);
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
  if (c.backend == Backend::kBlocked) {
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT") != nullptr) {
      // [DIRECT 2026-09-05] 见 kWgslBlocked84Direct 注释。纯净形态,不叠任何探针变换。
      std::string dsrc = kWgslBlocked84Direct;
      const bool dbg = getenv("OFFICIAL_AETHER_MATCH_DAWN_WGSL_DUMP") != nullptr;
      if (dbg) std::fprintf(stderr, "[direct-chain] base len=%zu\n", dsrc.size());
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_44") != nullptr) {
        dsrc = DirectTo44Wgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] after 44 len=%zu\n", dsrc.size());
        if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_W128") != nullptr) {
          const std::string x = DirectTo44W128Wgsl(dsrc);
          if (x != dsrc) gBlockedRows = 32;
          if (dbg) std::fprintf(stderr, "[direct-chain] W128 in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
          dsrc = x;
        }
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_PSCAN") != nullptr) {
        const std::string x = DirectPScanWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] PSCAN in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_TMAP") != nullptr) {
        const std::string x = DirectTMapWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] TMAP in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_SCANMEM") != nullptr) {
        const std::string x = DirectScanMemWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] SCANMEM in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_NOPB") != nullptr) {
        const std::string x = DirectNoPipeBWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] NOPB in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_PIPEA") != nullptr) {
        const std::string x = DirectPipeAWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] PIPEA in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_G") != nullptr) {
        const std::string g = DirectToGlobalScratchWgsl(dsrc);
        c.direct_g = (g != dsrc);  // 变换未命中就不绑 Scr,避免"核没变、绑定多了"的管线失败
        if (dbg) std::fprintf(stderr, "[direct-chain] G in=%zu out=%zu applied=%d\n", dsrc.size(), g.size(), (int)c.direct_g);
        dsrc = g;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_F16") != nullptr) {
        if (!c.feat_f16) { if (dbg) std::fprintf(stderr, "[direct-chain] F16 skipped: adapter lacks ShaderF16\n"); }
        else {
          const std::string x = DirectF16Wgsl(dsrc);
          c.direct_f16 = (x != dsrc);
          if (dbg) std::fprintf(stderr, "[direct-chain] F16 in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)c.direct_f16);
          dsrc = x;
        }
      }
      if (!c.direct_f16 && getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_PACKED") != nullptr) {
        const std::string x = DirectPackedWgsl(dsrc);
        c.direct_packed = (x != dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] PACKED in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)c.direct_packed);
        dsrc = x;
      }
      if (!c.direct_packed && getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_TEXA") != nullptr) {
        const std::string x = DirectToTexAWgsl(dsrc);
        c.direct_texa = (x != dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] TEXA in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)c.direct_texa);
        dsrc = x;
      }
      if (!c.direct_packed && getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_TEX") != nullptr) {
        const std::string x = DirectToTexWgsl(dsrc);
        c.direct_tex = (x != dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] TEX in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)c.direct_tex);
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_TAILB") != nullptr) {
        const std::string x = DirectTailBWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] TAILB in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_FMA") != nullptr) {
        const std::string x = DirectFmaWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] FMA in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (const char* uh = getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_UNROLLH")) {
        const std::string x = DirectUnrollHWgsl(dsrc, std::max(2, atoi(uh)));
        if (dbg) std::fprintf(stderr, "[direct-chain] UNROLLH%s in=%zu out=%zu applied=%d\n", uh, dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (const char* un = getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_UNROLL")) {
        const std::string x = DirectUnrollWgsl(dsrc, std::max(2, atoi(un)));
        if (dbg) std::fprintf(stderr, "[direct-chain] UNROLL%s in=%zu out=%zu applied=%d\n", un, dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_NOLOAD") != nullptr) {  // 探针
        const std::string x = DirectNoLoadWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] NOLOAD(probe) in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_NOSYNC") != nullptr) {  // 探针
        const std::string x = DirectNoSyncWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] NOSYNC(probe) in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_DIRECT_NOSCAN") != nullptr) {  // 探针:复用 LDS 核的扫描锚点(S 文本相同)
        const std::string x = BlkNoScanWgsl(dsrc);
        if (dbg) std::fprintf(stderr, "[direct-chain] NOSCAN(probe) in=%zu out=%zu applied=%d\n", dsrc.size(), x.size(), (int)(x != dsrc));
        dsrc = x;
      }
      if (getenv("OFFICIAL_AETHER_MATCH_DAWN_WGSL_DUMP") != nullptr) std::fprintf(stderr, "===WGSL_BEGIN===\n%s\n===WGSL_END===\n", dsrc.c_str());
      wgpu::ShaderModule m = CompileWgsl(c, dsrc.c_str(), "blocked direct");
      if (!m) return false;
      wgpu::ShaderModule mx = CompileWgsl(c, c.direct_f16 ? kWgslXposeF16 : (c.direct_packed ? kWgslXposePacked : kWgslXpose), "xpose");
      if (!mx) return false;
      c.p_main = MakePipeline(c, m, "main");
      c.p_merge = MakePipeline(c, m, "merge");
      c.p_xpose = MakePipeline(c, mx, "xpose");
      c.direct = c.p_main && c.p_merge && c.p_xpose;
      return c.direct;
    }
    // [UNIVERSAL-DEFAULT 2026-09-05] 通用核默认 = 8x4/128 线程 + PIPEB(只提前 B 的一个 vec4)。
    // 两台真机同向:A16 −5.2%(两轮交替)、Adreno 660 −5.9%(5 轮 min);三平台逐字节相同。
    // 这是唯一一把两边都赚的预取刀:PIPE(提前 3 个 vec4)与 GPF 在 A16 赔 +12%/+9%、
    // 在 Adreno 赚 −13%/−11% —— 反相关;PIPEB 把活寄存器压到 1 个,两边都正。
    // env:BLK_44=1 回 4x4/256;BLK_88=1 选 8x8;BLK_NOPIPEB=1 关 B 预取(单变量 A/B)。
    std::string blk = getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_88") != nullptr
                          ? std::string(kWgslBlocked88)
                      : getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_44") != nullptr
                          ? std::string(kWgslBlockedPlain) : std::string(kWgslBlocked84);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_GPF") != nullptr) blk = BlkGpfWgsl(blk);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_STG") != nullptr) blk = BlkStgWgsl(blk);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_RSCAN") != nullptr) blk = BlkRScanWgsl(blk);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_PIPE") != nullptr) blk = BlkPipeWgsl(blk);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_NOPIPEB") == nullptr &&
        getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_PIPE") == nullptr &&
        getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_88") == nullptr &&
        getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_44") == nullptr) {
      blk = BlkPipeBWgsl(blk);  // 默认开(见上)
    }
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_FMA") != nullptr) blk = BlkFmaWgsl(blk);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_NOLOAD") != nullptr) blk = BlkNoLoadWgsl(blk);
    if (const char* nb = getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_XBAR")) blk = BlkXBarWgsl(blk, atoi(nb));
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_UNROLL") != nullptr) blk = BlkUnrollWgsl(blk);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_NOSCAN") != nullptr) blk = BlkNoScanWgsl(blk);
    if (getenv("OFFICIAL_AETHER_MATCH_DAWN_BLK_NOSTAGE") != nullptr) blk = BlkNoStageWgsl(blk);
    wgpu::ShaderModule m = CompileWgsl(c, blk.c_str(), "blocked plain");
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
  if (c.backend == Backend::kBlocked) return (uint64_t)npad * kD;  // packed u8 + 零补位
  if (c.backend != Backend::kMma) return (uint64_t)n * kD;
  if (c.packed) return (uint64_t)npad * kD;  // u8;npad*128 恒为 4 的倍数
  return (uint64_t)npad * kD * (c.mixed ? sizeof(uint16_t) : sizeof(float));
}

// Uploads n descriptor rows at byte offset off (MMA: u8→f32 expansion into a
// zero-filled npad-row table — the per-call u8→half conversion of the Metal
// TU, exact; tiled: raw u8 rows, the kernel guards rows itself).
void UploadDesc(Ctx& c, wgpu::Buffer buf, uint64_t off, const uint8_t* d,
                uint32_t n, uint32_t npad, std::vector<float>& scratch) {
  if ((c.backend == Backend::kMma && c.packed) || c.backend == Backend::kBlocked) {
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
  // [COLCHUNK 2026-09-05] 只有平路径的 mma 核认识 colBase/colSpan/RowP。
  // guided 核用的是另一套 GParams(布局不同、没有这两个字段),
  // 若按 stages.size()==1 来判会把列参数写进它的 uniform ⇒ 污染。显式标记。
  bool col_chunkable = false;
  uint32_t tile_cols = 32;  // 列分块 span 的对齐单位 = 核的 BT
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
  // [COLCHUNK 2026-09-05] 按列分块:每个 dispatch 发全部工作组、只跑一段列。
  if (kColChunk && stages.size() == 1 && stages[0].col_chunkable) {
    Stage& s = stages[0];
    uint32_t c0 = 0;
    while (c0 < s.nDb) {
      const double target = ThermalHot() ? chunkTargetMs : ChunkTargetCoolMs();
      const double unit = *ema;  // ms / (group × 1024 列)
      uint32_t span = 1024;      // 首探:1024 列
      if (unit > 0.0) {
        const double perCol = unit * (double)s.total_groups / 1024.0;
        const double ideal = target / (perCol > 1e-9 ? perCol : 1e-9);
        span = ideal < 32.0 ? 32u : (uint32_t)std::min(ideal, 1e9);
      }
      span = ((span + s.tile_cols - 1u) / s.tile_cols) * s.tile_cols;  // 必须是核的 BT 的整数倍
      if (span > s.nDb - c0) span = s.nDb - c0;
      c.queue.WriteBuffer(s.uni, s.uniOff + kColBaseOffset,
                          reinterpret_cast<const uint8_t*>(&c0), 4);
      c.queue.WriteBuffer(s.uni, s.uniOff + kColSpanOffset,
                          reinterpret_cast<const uint8_t*>(&span), 4);
      wgpu::CommandEncoder enc = c.device.CreateCommandEncoder();
      wgpu::ComputePassEncoder pass = BeginPassTs(c, enc);
      s.encode(pass, 0u, s.total_groups);
      pass.End();
      wgpu::CommandBuffer cb = enc.Finish();
      double gpuMs = 0.0;
      const int rc = SubmitAndWait(c, cb, &gpuMs);
      if (rc != 0) return rc;
      if (gpuMs > 0.0 && gpuMs < 10000.0) aether_match_gpu_ms += gpuMs;
      ++aether_match_chunks;
      if (gpuMs > 0.0 && gpuMs < 10000.0) {
        const double u =
            gpuMs / ((double)s.total_groups * ((double)span / 1024.0));
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
      c0 += span;
    }
    // 收尾后把 colBase/colSpan 复位,免得污染同一 uni 槽的后续调用。
    const uint32_t zero = 0u;
    c.queue.WriteBuffer(s.uni, s.uniOff + kColBaseOffset,
                        reinterpret_cast<const uint8_t*>(&zero), 4);
    c.queue.WriteBuffer(s.uni, s.uniOff + kColSpanOffset,
                        reinterpret_cast<const uint8_t*>(&s.nDb), 4);
  } else
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
  const uint32_t nApad = (uint32_t)RoundUp(nAu, MainRows(c.backend));
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
  wgpu::Buffer uni = PoolGet(c, c.uni, 4 * kSlot, kUsageUni);  // 槽 1/2 给 [DIRECT] 的 XParams
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
  if (c.backend == Backend::kMma || c.backend == Backend::kBlocked) {
    const uint32_t numWg = nApad / MainRows(c.backend);
    const uint64_t colBytes = (uint64_t)nBu * numWg * 12;
    wgpu::Buffer colp = PoolGet(c, c.colp, colBytes, kUsageColp);
    if (!colp) return 6;
    // [COLCHUNK 2026-09-05] colSpan 默认 = nBu ⇒ 与按行分块时行为逐字节相同。
    const uint64_t rowBytes = (uint64_t)nApad * 12;
    wgpu::Buffer rowp = PoolGet(c, c.rowp, rowBytes, kUsageColp);
    if (!rowp) return 6;
    const Params p{nAu, nBu, maxRatio, maxDistance, numWg, 0u, 0u, nBu};
    c.queue.WriteBuffer(uni, 0, reinterpret_cast<const uint8_t*>(&p), sizeof(p));
    std::vector<wgpu::BindGroupEntry> mainEntries = {
        BE(0, aBuf, 0, aBytes), BE(1, bBuf, 0, bBytes),
        BE(2, outAB, 0, outABBytes), BE(3, uni, 0, sizeof(Params)),
        BE(4, colp, 0, colBytes), BE(6, rowp, 0, rowBytes)};
    wgpu::BindGroup bgXA, bgXB;
    if (c.direct) {
      // [DIRECT] 主核不再读 A/B(绑定 0/1);Dawn 自动布局只收录实际用到的绑定,多给会报
      // "binding index 0 not present in the bind group layout"(首次 Mac 复验就撞上)。
      mainEntries.erase(mainEntries.begin(), mainEntries.begin() + 2);
      // [DIRECT] At/Bt = f32 [k][row/4]:每行 128 k × 4 B = 512 B;按补位行数分配。
      const uint64_t rowB = c.direct_f16 ? 256ull : (c.direct_packed ? 128ull : 512ull);  // [F16] 2 B / [PACKED] 1 B 每 k
      const uint64_t atBytes = rowB * nApad, btBytes = rowB * nBpad;
      wgpu::Buffer at = PoolGet(c, c.at, atBytes,
                                c.direct_texa ? (kUsageColp | wgpu::BufferUsage::CopySrc) : kUsageColp);
      wgpu::Buffer bt = PoolGet(c, c.bt, btBytes,
                                c.direct_tex ? (kUsageColp | wgpu::BufferUsage::CopySrc) : kUsageColp);
      if (!at || !bt) return 6;
      const uint32_t xa[4] = {nApad / 4u, 0u, 0u, 0u};
      const uint32_t xb[4] = {nBpad / 4u, 0u, 0u, 0u};
      c.queue.WriteBuffer(uni, kSlot, reinterpret_cast<const uint8_t*>(xa), 16);
      c.queue.WriteBuffer(uni, 2 * kSlot, reinterpret_cast<const uint8_t*>(xb), 16);
      if (c.direct_texa) {
        wgpu::TextureView tv = EnsureBtTexture(c, c.atTex, c.atTexW, nApad / 4u);
        if (!tv) return 6;
        wgpu::BindGroupEntry te{};
        te.binding = 7;
        te.textureView = tv;
        mainEntries.push_back(te);
      } else {
        mainEntries.push_back(BE(7, at, 0, atBytes));
      }
      if (c.direct_tex) {
        wgpu::TextureView tv = EnsureBtTexture(c, c.btTex, c.btTexW, nBpad / 4u);
        if (!tv) return 6;
        wgpu::BindGroupEntry te{};
        te.binding = 8;
        te.textureView = tv;
        mainEntries.push_back(te);
      } else {
        mainEntries.push_back(BE(8, bt, 0, btBytes));
      }
      if (c.direct_g) {
        const uint64_t scrBytes = 16384ull * numWg;  // 每 workgroup 64x64 f32
        wgpu::Buffer scr = PoolGet(c, c.scr, scrBytes, kUsageColp);
        if (!scr) return 6;
        mainEntries.push_back(BE(9, scr, 0, scrBytes));
      }
      bgXA = MakeBG(c, c.p_xpose, {BE(0, aBuf, 0, aBytes), BE(3, uni, kSlot, 16),
                                   BE(7, at, 0, atBytes)});
      bgXB = MakeBG(c, c.p_xpose, {BE(0, bBuf, 0, bBytes), BE(3, uni, 2 * kSlot, 16),
                                   BE(7, bt, 0, btBytes)});
      if (!bgXA || !bgXB) return 6;
    }
    bgMain = MakeBG(c, c.p_main, mainEntries);
    bgMerge = MakeBG(c, c.p_merge,
                     {BE(3, uni, 0, sizeof(Params)), BE(4, colp, 0, colBytes),
                      BE(5, outBA, 0, outBABytes)});
    if (!bgMain || !bgMerge) return 6;
    if (c.direct) {
      // [DIRECT] 预转置一次;队列有序,后续分块 submit 天然在其后。
      wgpu::CommandEncoder enc = c.device.CreateCommandEncoder();
      wgpu::ComputePassEncoder pass = enc.BeginComputePass();
      pass.SetPipeline(c.p_xpose);
      pass.SetBindGroup(0, bgXA);
      pass.DispatchWorkgroups((nApad / 4u * 32u + 63u) / 64u);
      pass.SetBindGroup(0, bgXB);
      pass.DispatchWorkgroups((nBpad / 4u * 32u + 63u) / 64u);
      pass.End();
      if (c.direct_tex) EncodeBtToTexture(enc, c.bt.buf, c.btTex, nBpad / 4u);
      if (c.direct_texa) EncodeBtToTexture(enc, c.at.buf, c.atTex, nApad / 4u);
      wgpu::CommandBuffer cb = enc.Finish();
      const int rcx = SubmitAndWait(c, cb, nullptr);
      if (rcx != 0) return rcx;
    }
    Stage s;
    s.col_chunkable = true;  // 只有这一处的核认识 colBase/colSpan/RowP
    s.tile_cols = MainTileCols(c.backend);
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
  wgpu::Buffer uni = PoolGet(c, c.uni, 4 * kSlot, kUsageUni);  // 槽 1/2 给 [DIRECT] 的 XParams
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
  const bool mma = c.backend == Backend::kMma || c.backend == Backend::kBlocked;
  const uint32_t nAu = (uint32_t)nA;
  const uint32_t nApad = (uint32_t)RoundUp(nAu, MainRows(c.backend));
  const uint32_t numWg = nApad / MainRows(c.backend);
  const uint64_t aBytes = DescBytes(c, nAu, nApad);
  // [COLCHUNK 2026-09-05] 行向 top-2 的持久缓冲(binding 6),probe_batch 也要有。
  const uint64_t rowPbBytes = (uint64_t)nApad * 12;
  const uint64_t outABBytes = (uint64_t)nAu * 4;
  const uint64_t outABSlot = RoundUp(outABBytes, kSlot);
  const uint32_t uniPerCand = mma ? 1u : 2u;

  struct Cand {
    uint32_t nB, nBpad;
    uint64_t bOff, bBytes, outBAOff, outBABytes, colOff, colBytes, uniOff,
        stgOff;
    uint64_t btOff = 0, btBytes = 0;  // [DIRECT]
    wgpu::BindGroup bgMain, bgMerge, bgBA;
    wgpu::BindGroup bgX;  // [DIRECT] 该候选 B 的预转置
    double units;
  };
  std::vector<Cand> cands((size_t)n_cands);
  uint64_t bTotal = 0, outBATotal = 0, colTotal = 0, stgTotal = 0, btTotal = 0;
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
    cd.btBytes = (c.direct_f16 ? 256ull : (c.direct_packed ? 128ull : 512ull)) * cd.nBpad;
    cd.btOff = btTotal;
    btTotal += RoundUp(cd.btBytes, kSlot);
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
  wgpu::Buffer rowpPb = PoolGet(c, c.pbRowp, rowPbBytes, kUsageColp);
  if (!rowpPb) return 6;
  // [DIRECT] 批量路径同样要绑定 7/8 并先做预转置(ABI 门会抓漏绑定)。
  const uint64_t atPbBytes = (c.direct_f16 ? 256ull : (c.direct_packed ? 128ull : 512ull)) * nApad;
  wgpu::Buffer atPb, btPb, xuni;
  wgpu::BindGroup bgXA;
  if (c.direct) {
    atPb = PoolGet(c, c.pbAt, atPbBytes,
                   c.direct_texa ? (kUsageColp | wgpu::BufferUsage::CopySrc) : kUsageColp);
    btPb = PoolGet(c, c.pbBt, btTotal,
                   c.direct_tex ? (kUsageColp | wgpu::BufferUsage::CopySrc) : kUsageColp);
    if (c.direct_tex) { c.pbTex.resize((size_t)n_cands); c.pbTexW.resize((size_t)n_cands, 0u); }
    xuni = PoolGet(c, c.pbXUni, (uint64_t)(n_cands + 1) * kSlot, kUsageUni);
    if (!atPb || !btPb || !xuni) return 6;
    const uint32_t xa[4] = {nApad / 4u, 0u, 0u, 0u};
    c.queue.WriteBuffer(xuni, 0, reinterpret_cast<const uint8_t*>(xa), 16);
    bgXA = MakeBG(c, c.p_xpose, {BE(0, aBuf, 0, aBytes), BE(3, xuni, 0, 16),
                                 BE(7, atPb, 0, atPbBytes)});
    if (!bgXA) return 6;
  }
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
      // [COLCHUNK 2026-09-05] 主核多了 binding 6(RowP),这条 probe_batch 路径的
      // 绑定组也必须跟上 —— 否则 Dawn 报 "Number of entries (5) did not match
      // the expected number of entries (6)"。ABI 门当场抓到了这一处遗漏,
      // 而 probe-gate 正是采集期在跑的路径。colSpan 同样默认 = cd.nB。
      const Params p{nAu, cd.nB, maxRatio, maxDistance, numWg, 0u, 0u, cd.nB};
      c.queue.WriteBuffer(uni, cd.uniOff, reinterpret_cast<const uint8_t*>(&p),
                          sizeof(p));
      std::vector<wgpu::BindGroupEntry> me = {
          BE(0, aBuf, 0, aBytes), BE(1, bBuf, cd.bOff, cd.bBytes),
          BE(2, outAB, (uint64_t)k * outABSlot, outABBytes),
          BE(3, uni, cd.uniOff, sizeof(Params)), BE(4, colp, cd.colOff, cd.colBytes),
          BE(6, rowpPb, 0, rowPbBytes)};
      if (c.direct) {
        me.erase(me.begin(), me.begin() + 2);  // 主核不读 A/B(见 MatchPairsImpl)
        const uint32_t xb[4] = {cd.nBpad / 4u, 0u, 0u, 0u};
        c.queue.WriteBuffer(xuni, (uint64_t)(k + 1) * kSlot,
                            reinterpret_cast<const uint8_t*>(xb), 16);
        if (c.direct_texa) {
          wgpu::TextureView tv = EnsureBtTexture(c, c.pbAtTex, c.pbAtTexW, nApad / 4u);
          if (!tv) return 6;
          wgpu::BindGroupEntry ta{};
          ta.binding = 7;
          ta.textureView = tv;
          me.push_back(ta);
        } else {
          me.push_back(BE(7, atPb, 0, atPbBytes));
        }
        if (c.direct_tex) {
          wgpu::TextureView tv = EnsureBtTexture(c, c.pbTex[(size_t)k], c.pbTexW[(size_t)k], cd.nBpad / 4u);
          if (!tv) return 6;
          wgpu::BindGroupEntry te{};
          te.binding = 8;
          te.textureView = tv;
          me.push_back(te);
        } else {
          me.push_back(BE(8, btPb, cd.btOff, cd.btBytes));
        }
        if (c.direct_g) {
          const uint64_t scrBytes = 16384ull * numWg;
          wgpu::Buffer scr = PoolGet(c, c.pbScr, scrBytes, kUsageColp);
          if (!scr) return 6;
          me.push_back(BE(9, scr, 0, scrBytes));
        }
        cd.bgX = MakeBG(c, c.p_xpose,
                        {BE(0, bBuf, cd.bOff, cd.bBytes),
                         BE(3, xuni, (uint64_t)(k + 1) * kSlot, 16),
                         BE(7, btPb, cd.btOff, cd.btBytes)});
        if (!cd.bgX) return 6;
      }
      cd.bgMain = MakeBG(c, c.p_main, me);
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
    if (c.direct && c0 == 0) {
      pass.SetPipeline(c.p_xpose);
      pass.SetBindGroup(0, bgXA);
      pass.DispatchWorkgroups((nApad / 4u * 32u + 63u) / 64u);
    }
    if (c.direct && (c.direct_tex || c.direct_texa)) {
      // 纹理拷贝不能在 pass 内:先把本组所有候选的 xposeB 发完,结束 pass,拷纹理,再开 pass 跑主核。
      for (int k = c0; k < c1; ++k) {
        const Cand& cd = cands[(size_t)k];
        pass.SetPipeline(c.p_xpose);
        pass.SetBindGroup(0, cd.bgX);
        pass.DispatchWorkgroups((cd.nBpad / 4u * 32u + 63u) / 64u);
      }
      pass.End();
      if (c.direct_texa && c0 == 0) EncodeBtToTexture(enc, atPb, c.pbAtTex, nApad / 4u);
      for (int k = c0; k < c1 && c.direct_tex; ++k) {
        const Cand& cd = cands[(size_t)k];
        wgpu::TexelCopyBufferInfo src{};
        src.buffer = btPb;
        src.layout.offset = cd.btOff;
        src.layout.bytesPerRow = cd.nBpad * 4u;
        src.layout.rowsPerImage = 128u;
        wgpu::TexelCopyTextureInfo dst{};
        dst.texture = c.pbTex[(size_t)k];
        wgpu::Extent3D ext{cd.nBpad / 4u, 128u, 1u};
        enc.CopyBufferToTexture(&src, &dst, &ext);
      }
      pass = enc.BeginComputePass();
    }
    for (int k = c0; k < c1; ++k) {
      const Cand& cd = cands[(size_t)k];
      if (mma) {
        if (c.direct && !(c.direct_tex || c.direct_texa)) {
          pass.SetPipeline(c.p_xpose);
          pass.SetBindGroup(0, cd.bgX);
          pass.DispatchWorkgroups((cd.nBpad / 4u * 32u + 63u) / 64u);
        }
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

// ── [ALU-PEAK 探针 2026-09-05] 纯算术、零访存:16 条独立 FMA 链,量"此刻这台 GPU 的 FMA 峰值"。
// 用途:Mate 10 的 GPU 频率节点不 root 读不到;这个数就是当前热态下的真实天花板,是跨端通用的尺子。
// 只有探针台架调用;不进产品路径。
extern "C" int pwdawn_probe_alu_shape(const char* shape, uint32_t workgroups, uint32_t iters, double* out_ms, double* out_gfma);
extern "C" int pwdawn_probe_alu_peak(uint32_t workgroups, uint32_t iters, double* out_ms, double* out_gfma) {
  return pwdawn_probe_alu_shape("chain16", workgroups, iters, out_ms, out_gfma);
}
// [ALU-LADDER 2026-09-05] 同一探针的"梯子":逐级加回 GEMM 内层的构件,看 GFMA/s 在哪一级掉下去。
//   chain16   : 16 条独立 FMA 链,全向量 fma(a,b,c)                —— 纯峰值
//   gemm44    : 我们的 4x4 内层(4 个 vec4 acc,al.{x..w} 广播 × b4),al/b4 由 k 合成,无访存
//   gemm44ld  : 同上但 al/b4 从一块 L1 常驻的小缓冲读(索引 k&63)   —— 加回载入指令
//   gemm84    : 8 个 vec4 acc(我们的 8x4 内层),无访存
// 每级的 FMA 数按各自形态精确计入。仅探针台架调用。
extern "C" int pwdawn_probe_alu_shape(const char* shape, uint32_t workgroups, uint32_t iters, double* out_ms, double* out_gfma) {
  Ctx* cp = EnsureDawn();
  if (!cp) return 2;
  Ctx& c = *cp;
  const std::string sh = shape ? shape : "chain16";
  std::string body; double fmaPerIter = 32.0;
  if (sh == "gemm44" || sh == "gemm44ld") {
    body = sh == "gemm44"
      ? "    let fk = f32(i);\n    let al = vec4<f32>(fk, fk + 1.0, fk + 2.0, fk + 3.0) * 0.001;\n    let b4 = vec4<f32>(fk * 0.5, fk, fk * 1.5, fk * 2.0) * 0.001;\n"
      : "    let al = Src[(i & 63u) * 2u + (lid & 1u)];\n    let b4 = Src[128u + (i & 63u) * 4u + (lid & 3u)];\n";
    body += "    a0 = a0 + al.x * b4;\n    a1 = a1 + al.y * b4;\n    a2 = a2 + al.z * b4;\n    a3 = a3 + al.w * b4;\n";
    fmaPerIter = 16.0;
  } else if (sh == "gemm84") {
    body = "    let fk = f32(i);\n    let al = vec4<f32>(fk, fk + 1.0, fk + 2.0, fk + 3.0) * 0.001;\n    let ah = al + 4.0;\n    let b4 = vec4<f32>(fk * 0.5, fk, fk * 1.5, fk * 2.0) * 0.001;\n"
           "    a0 = a0 + al.x * b4;\n    a1 = a1 + al.y * b4;\n    a2 = a2 + al.z * b4;\n    a3 = a3 + al.w * b4;\n"
           "    a4 = a4 + ah.x * b4;\n    a5 = a5 + ah.y * b4;\n    a6 = a6 + ah.z * b4;\n    a7 = a7 + ah.w * b4;\n";
    fmaPerIter = 32.0;
  } else {
    body = "    a0 = fma(a0, b, cc); a1 = fma(a1, b, cc); a2 = fma(a2, b, cc); a3 = fma(a3, b, cc);\n"
           "    a0 = fma(a0, b, cc); a1 = fma(a1, b, cc); a2 = fma(a2, b, cc); a3 = fma(a3, b, cc);\n";
    fmaPerIter = 32.0;
  }
  const bool eight = sh == "gemm84";
  std::string src =
    "struct P { iters : u32, p1 : u32, p2 : u32, p3 : u32, };\n"
    "@group(0) @binding(0) var<uniform> U : P;\n"
    "@group(0) @binding(1) var<storage, read_write> Out : array<f32>;\n"
    "@group(0) @binding(2) var<storage, read> Src : array<vec4<f32>>;\n"
    "@compute @workgroup_size(256)\n"
    "fn main(@builtin(global_invocation_id) gid : vec3<u32>, @builtin(local_invocation_index) lid : u32) {\n"
    "  var a0 = vec4<f32>(f32(lid) * 0.001, 1.0, 2.0, 3.0);\n  var a1 = a0 + 1.0;\n  var a2 = a0 + 2.0;\n  var a3 = a0 + 3.0;\n";
  if (eight) src += "  var a4 = a0 + 4.0;\n  var a5 = a0 + 5.0;\n  var a6 = a0 + 6.0;\n  var a7 = a0 + 7.0;\n";
  src += "  let b = vec4<f32>(0.999, 1.001, 0.998, 1.002);\n  let cc = vec4<f32>(0.0000001);\n"
         "  for (var i = 0u; i < U.iters; i = i + 1u) {\n" + body + "  }\n"
         "  var sum = a0 + a1 + a2 + a3;\n";
  if (eight) src += "  sum = sum + a4 + a5 + a6 + a7;\n";
  src += "  Out[gid.x] = sum.x + sum.y + sum.z + sum.w + Src[lid & 3u].x * 0.0;\n}\n";
  wgpu::ShaderModule m = CompileWgsl(c, src.c_str(), "alu ladder");
  if (!m) return 3;
  wgpu::ComputePipeline pipe = MakePipeline(c, m, "main");
  if (!pipe) return 3;
  wgpu::BufferDescriptor ud{}; ud.usage = kUsageUni; ud.size = 256;
  wgpu::Buffer uni = c.device.CreateBuffer(&ud);
  wgpu::BufferDescriptor od{}; od.usage = wgpu::BufferUsage::Storage; od.size = (uint64_t)workgroups * 256u * 4u;
  wgpu::Buffer outb = c.device.CreateBuffer(&od);
  wgpu::BufferDescriptor sd{}; sd.usage = wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst; sd.size = 512u * 16u;
  wgpu::Buffer srcb = c.device.CreateBuffer(&sd);
  if (!uni || !outb || !srcb) return 6;
  {
    std::vector<float> init(512 * 4);
    for (size_t k = 0; k < init.size(); ++k) init[k] = 0.001f * (float)(k % 97);
    c.queue.WriteBuffer(srcb, 0, reinterpret_cast<const uint8_t*>(init.data()), init.size() * 4);
  }
  const uint32_t pv[4] = {iters, 0u, 0u, 0u};
  c.queue.WriteBuffer(uni, 0, reinterpret_cast<const uint8_t*>(pv), 16);
  wgpu::BindGroup bg = MakeBG(c, pipe, {BE(0, uni, 0, 16), BE(1, outb, 0, od.size), BE(2, srcb, 0, sd.size)});
  if (!bg) return 6;
  double best = 1e30;
  for (int rep = 0; rep < 3; ++rep) {
    wgpu::CommandEncoder enc = c.device.CreateCommandEncoder();
    wgpu::ComputePassEncoder pass = enc.BeginComputePass();
    pass.SetPipeline(pipe);
    pass.SetBindGroup(0, bg);
    pass.DispatchWorkgroups(workgroups);
    pass.End();
    wgpu::CommandBuffer cb = enc.Finish();
    const double t0 = NowMs();
    const int rc = SubmitAndWait(c, cb, nullptr);
    const double dt = NowMs() - t0;
    if (rc != 0) return rc;
    if (dt < best) best = dt;
  }
  const double fmas = (double)workgroups * 256.0 * (double)iters * fmaPerIter;
  if (out_ms) *out_ms = best;
  if (out_gfma) *out_gfma = fmas / (best * 1e-3) / 1e9;
  return 0;
}
