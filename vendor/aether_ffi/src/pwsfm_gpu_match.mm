// pwsfm_gpu_match.mm — pocketworld-vendored tiled-GEMM Metal descriptor
// matcher, adapted from the research harness's GpuMatch.m (iosapp/Sources,
// bench-proven on iPhone 14 Pro: 11568×11568 @ 0.7 ratio, mutual cross-check
// in 119 ms). Two deltas vs the harness original:
//
//   1. Kernel loads via newLibraryWithSource (embedded MSL below, compiled
//      once and cached) instead of newDefaultLibrary — the harness relied on
//      its app target compiling MatchKernelGEMM.metal into the main bundle's
//      default.metallib, which a CocoaPods static-lib target does not do.
//   2. Exports a PAIRS variant (aether_gpu_match_gemm_pairs) that emits the
//      mutually cross-checked [idxA, idxB] list — the streaming SfM
//      add_frame persists these via WriteMatches/WriteTwoViewGeometry.
//      Mutual B→A verification is kept EXACTLY (one-directional matching
//      feeds many-to-one false matches → block drift; hard constraint).
//
// aether_sfm_add_frame (libglomap_core.a) references this symbol WEAKLY and
// falls back to the CPU matcher when it is absent or errors — so host
// benches and any target without this TU keep working unchanged.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <atomic>
#include <mutex>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ── [RC7-FILELOG 2026-07-11] Last command-buffer error stash ─────────────
// The Metal error object (domain/code/description, e.g.
// IOGPUCommandQueueErrorDomain "GPU hang under thermal pressure") is only
// visible HERE, but the pair id + capture context live in the caller
// (aether_sfm_c.cc NoteGpuMatchFailure, which writes the timestamped
// sfm_match_fail.jsonl next to the capture db). Bridge: stash the latest
// error text; the caller pulls it via aether_gpu_match_last_error (declared
// WEAK there, so host builds without this TU keep working).
static std::mutex gLastErrLock;
static char gLastErr[192] = {0};

static void stashLastError(NSError* error) {
  NSString* text =
      error ? [NSString stringWithFormat:@"%@ code=%ld %@", error.domain,
                                         (long)error.code,
                                         error.localizedDescription ?: @""]
            : @"(nil error)";
  std::lock_guard<std::mutex> lk(gLastErrLock);
  strlcpy(gLastErr, text.UTF8String ?: "(utf8 failed)", sizeof(gLastErr));
}

// Copies the last stashed command-buffer error into buf (NUL-terminated).
// Returns the number of bytes copied excluding the NUL (0 = nothing stashed).
extern "C" int aether_gpu_match_last_error(char* buf, int cap) {
  if (!buf || cap <= 0) return 0;
  std::lock_guard<std::mutex> lk(gLastErrLock);
  const size_t n = strlcpy(buf, gLastErr, (size_t)cap);
  return (int)(n < (size_t)cap ? n : (size_t)cap - 1);
}

// ── pw_match_gemm v6 kernel — COLMAP-faithful angular matcher ───────────
// Bit-parity with FindBestMatchesOneWayBruteForce (colmap/feature/sift.cc:770):
// best/second are selected by MAXIMUM dot product (the GEMM output), and the
// ratio + absolute thresholds are applied in the acos(dot/512^2) ANGULAR
// domain — NOT squared-L2. This closes the audited divergences vs the
// COLMAP-native reference that produced cloud_k12_mutual.ply:
//   1. metric domain: angular acos, not squared-L2;
//   2. absolute max_distance gate (default 0.7) — was missing entirely;
//   3. single-candidate rows: second_dot stays 0 → second_dist = acos(0) =
//      pi/2, exactly as COLMAP (its second_best_dot_product init is 0).
// Descriptors are SIFT-normalized to L2 norm 512, so dot/512^2 = cosine and
// kInvSqNorm = 1/kSqSiftDescriptorNorm = 1/262144. No per-descriptor norms
// are needed (COLMAP uses the idealized 512^2 normalization constant).
static const char* kGemmKernelSrc = R"MSL(
#include <metal_stdlib>
#include <metal_simdgroup_matrix>
using namespace metal;

constant uint kD  = 128u;
constant uint kKT = 16u;
constant uint kSG = 16u;
constant uint kMB = kSG * 8u;
constant uint kBN = 16u;
constant uint kNT = kBN / 8u;
constant uint kTGT = kSG * 32u;
constant float kInvSqNorm = 1.0f / 262144.0f;  // 1 / kSqSiftDescriptorNorm (512^2)

kernel void pw_match_gemm(device const half*  A          [[buffer(0)]],
                          device const half*  B          [[buffer(1)]],
                          device int*         out         [[buffer(2)]],
                          constant uint&      numA        [[buffer(3)]],
                          constant uint&      numB        [[buffer(4)]],
                          constant float&     maxRatio    [[buffer(5)]],
                          constant float&     maxDistance [[buffer(6)]],
                          device const float2* pointsA     [[buffer(7)]],
                          device const float2* pointsB     [[buffer(8)]],
                          device const float*  guideMatrix [[buffer(9)]],
                          constant uint&       guideMode   [[buffer(10)]],
                          constant float&      maxResidual [[buffer(11)]],
                          constant uint&       rowBase     [[buffer(12)]],
                          threadgroup half*   Bsh         [[threadgroup(0)]],
                          threadgroup float*  acc         [[threadgroup(1)]],
                          uint tgid  [[threadgroup_position_in_grid]],
                          uint lid   [[thread_index_in_threadgroup]],
                          uint sgid  [[simdgroup_index_in_threadgroup]]) {
  // rowBase: first row-block of this chunk. Chunked dispatch splits one
  // logical (numA x numB) pass into several small command buffers so a
  // single dispatch never occupies the GPU long enough to starve the
  // ARKit camera/render pipeline (rc=7 pathology). Row blocks are
  // independent — per-row results are identical for any chunking.
  const uint row0 = (rowBase + tgid) * kMB;
  if (row0 >= numA) { return; }
  const uint rows = min(kMB, numA - row0);

  const uint aRow0 = row0 + sgid * 8u;
  simdgroup_matrix<half, 8, 8> aFrag[kKT];
  for (uint k = 0; k < kKT; ++k) {
    simdgroup_load(aFrag[k], A + aRow0 * kD + k * 8u, kD, ulong2(0, 0));
  }

  // Track the two LARGEST dot products per row (COLMAP: best = max dot,
  // init 0 so only positive dots become candidates; index -1 if none).
  threadgroup float bestT[kMB];
  threadgroup float secondT[kMB];
  threadgroup int   biT[kMB];
  for (uint r = lid; r < kMB; r += kTGT) { bestT[r] = 0.0f; secondT[r] = 0.0f; biT[r] = -1; }
  threadgroup_barrier(mem_flags::mem_threadgroup);

  for (uint col0 = 0; col0 < numB; col0 += kBN) {
    const uint cols = min(kBN, numB - col0);

    for (uint e = lid; e < kBN * kD; e += kTGT) {
      uint r = e / kD, d = e % kD;
      Bsh[e] = (r < cols) ? B[(col0 + r) * kD + d] : half(0);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint nt = 0; nt < kNT; ++nt) {
      simdgroup_matrix<float, 8, 8> c = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
      for (uint k = 0; k < kKT; ++k) {
        simdgroup_matrix<half, 8, 8> bF;
        simdgroup_load(bF, Bsh + (nt * 8u) * kD + k * 8u, kD, ulong2(0, 0),
                       true);
        simdgroup_multiply_accumulate(c, aFrag[k], bF, c);
      }
      simdgroup_store(c, acc + (sgid * 8u) * kBN + nt * 8u, kBN, ulong2(0, 0));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    {
      const uint row = lid / 4u;
      const uint cg  = lid % 4u;
      const uint per = kBN / 4u;
      float pb = 0.0f, ps = 0.0f; int pbi = -1;  // best/second DOT (max)
      if (row < rows) {
        for (uint t = 0; t < per; ++t) {
          const uint c = cg * per + t;
          if (col0 + c >= numB) break;
          bool geometryOK = true;
          if (guideMode == 1u) {
            const float2 q = pointsA[row0 + row];
            const float2 d = pointsB[col0 + c];
            const float3 p1 = float3(q, 1.0f);
            const float3 p2 = float3(d, 1.0f);
            const float3 line2 = float3(
                guideMatrix[0] * p1.x + guideMatrix[1] * p1.y + guideMatrix[2],
                guideMatrix[3] * p1.x + guideMatrix[4] * p1.y + guideMatrix[5],
                guideMatrix[6] * p1.x + guideMatrix[7] * p1.y + guideMatrix[8]);
            const float3 line1 = float3(
                guideMatrix[0] * p2.x + guideMatrix[3] * p2.y + guideMatrix[6],
                guideMatrix[1] * p2.x + guideMatrix[4] * p2.y + guideMatrix[7],
                guideMatrix[2] * p2.x + guideMatrix[5] * p2.y + guideMatrix[8]);
            const float nom = dot(p2, line2);
            const float denom = dot(line2.xy, line2.xy) +
                                dot(line1.xy, line1.xy);
            geometryOK = denom > 1e-12f &&
                         nom * nom <= maxResidual * denom;
          } else if (guideMode == 2u) {
            const float2 q = pointsA[row0 + row];
            const float2 d = pointsB[col0 + c];
            const float hx = guideMatrix[0] * q.x + guideMatrix[1] * q.y +
                             guideMatrix[2];
            const float hy = guideMatrix[3] * q.x + guideMatrix[4] * q.y +
                             guideMatrix[5];
            const float hz = guideMatrix[6] * q.x + guideMatrix[7] * q.y +
                             guideMatrix[8];
            if (abs(hz) <= 1e-8f) {
              geometryOK = false;
            } else {
              const float2 delta = float2(hx / hz, hy / hz) - d;
              geometryOK = dot(delta, delta) <= maxResidual;
            }
          }
          if (!geometryOK) continue;
          const float dot = acc[row * kBN + c];
          if (dot > pb) { ps = pb; pb = dot; pbi = (int)(col0 + c); }
          else if (dot > ps) { ps = dot; }
        }
      }
      for (ushort off = 1; off <= 2; off <<= 1) {
        const float ob = simd_shuffle_xor(pb, off);
        const float os = simd_shuffle_xor(ps, off);
        const int   oi = simd_shuffle_xor(pbi, off);
        if (ob > pb) { ps = max(os, pb); pb = ob; pbi = oi; }
        else         { ps = max(ps, ob); }
      }
      if (cg == 0u && row < rows) {
        float bb = bestT[row], ss = secondT[row]; int bi = biT[row];
        if (pb > bb) { ss = max(bb, ps); bb = pb; bi = pbi; }
        else         { ss = max(ss, pb); }
        bestT[row] = bb; secondT[row] = ss; biT[row] = bi;
      }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
  }

  if (lid < kMB && lid < rows) {
    const int bi = biT[lid];
    if (bi < 0) { out[row0 + lid] = -1; return; }
    // COLMAP FindBestMatchesOneWayBruteForce (sift.cc:801-816):
    //   best_dist = acos(min(best_dot/512^2, 1));  reject if best_dist > max_distance
    //   second_dist = acos(min(second_dot/512^2, 1));
    //   reject if best_dist >= max_ratio * second_dist  (>= keeps best==second out)
    float bd;
    float sd;
    if (guideMode == 0u) {
      bd = acos(min(bestT[lid] * kInvSqNorm, 1.0f));
      sd = acos(min(secondT[lid] * kInvSqNorm, 1.0f));
    } else {
      // COLMAP's guided CPU path applies the thresholds in normalized L2.
      // With fixed-norm 512 SIFT descriptors, L2^2 / 512^2 = 2 - 2*cos.
      // A filtered candidate has COLMAP's sentinel distance 512, so it also
      // serves as the second-best baseline when only one candidate lies in the
      // geometry band.
      const float secondDot = max(secondT[lid], 131072.0f);
      bd = sqrt(max(0.0f, 2.0f - 2.0f * bestT[lid] * kInvSqNorm));
      sd = sqrt(max(0.0f, 2.0f - 2.0f * secondDot * kInvSqNorm));
    }
    const bool keep = (bd <= maxDistance) && (bd < maxRatio * sd);
    out[row0 + lid] = keep ? bi : -1;
  }
}
)MSL";

// ── [KNIFE-C 2026-07-26, signed] Chunked dispatch + thermal duty-cycle ───
// cap45 pathology: under thermal-serious a monolithic 8192² dispatch
// (~25ms cool, ~160ms+ downclocked) monopolizes the GPU and ARKit loses
// Metal command buffers (rc=7) → camera freeze. Apple's documented remedy
// for long compute coexisting with rendering is splitting work into small
// chunks and interleaving (developer.apple.com/forums/thread/87964);
// MTLCommandQueue has no priority/QoS API. So: split each direction's
// row range into chunks sized to ~OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS
// of GPU time (default 6ms, 0 = legacy monolithic dispatch), keep exactly
// one command buffer in flight, and under thermal serious/critical insert
// a gap between chunks (duty-cycle) so the camera pipeline always has GPU
// headroom. Row blocks are independent in the kernel, so the match set is
// bit-identical for any chunking (host-verified by parity diff).
static double ChunkTargetMs(void) {
  static double v = -1.0;
  if (v < 0.0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS");
    v = e ? atof(e) : 6.0;
    if (v < 0.0) v = 0.0;
  }
  return v;
}
// Cool-state (nominal/fair) chunk target. Contention only bites under
// thermal serious/critical, and each chunk costs a CPU↔GPU sync round-trip
// (host-measured ~19% at 6ms chunks), so when cool we use bigger chunks and
// only tighten to ChunkTargetMs() when the device heats up.
static double ChunkTargetCoolMs(void) {
  static double v = -1.0;
  if (v < 0.0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_CHUNK_TARGET_COOL_MS");
    v = e ? atof(e) : 16.0;
    if (v < 0.0) v = 0.0;
  }
  const double hot = ChunkTargetMs();
  return v > hot ? v : hot;
}
static bool ThermalHot(void) {
  if (@available(iOS 11.0, macOS 10.10.3, *)) {
    const NSProcessInfoThermalState st =
        NSProcessInfo.processInfo.thermalState;
    return st == NSProcessInfoThermalStateSerious ||
           st == NSProcessInfoThermalStateCritical;
  }
  return false;
}
// Extra idle gap between chunks as % of the last chunk's GPU time.
// serious default 100 (≈50% duty), critical default 300 (≈25% duty).
static double ThermalGapPct(void) {
  if (@available(iOS 11.0, macOS 10.10.3, *)) {
    const NSProcessInfoThermalState st =
        NSProcessInfo.processInfo.thermalState;
    if (st == NSProcessInfoThermalStateSerious) {
      static double v = -1.0;
      if (v < 0.0) {
        const char* e = getenv("OFFICIAL_AETHER_MATCH_GAP_SERIOUS_PCT");
        v = e ? atof(e) : 100.0;
        if (v < 0.0) v = 0.0;
      }
      return v;
    }
    if (st == NSProcessInfoThermalStateCritical) {
      static double v = -1.0;
      if (v < 0.0) {
        const char* e = getenv("OFFICIAL_AETHER_MATCH_GAP_CRITICAL_PCT");
        v = e ? atof(e) : 300.0;
        if (v < 0.0) v = 0.0;
      }
      return v;
    }
  }
  return 0.0;
}
// EMA of measured GPU ms per (row threadgroup × 1024 database columns) —
// the chunk sizer's cost model. Self-calibrates across thermal states.
static std::atomic<double> gMsPerTgKCol{0.0};

// Lazily-built shared Metal context.
static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQueue;
static id<MTLComputePipelineState> gGemm;

static BOOL ensureMetal(void) {
  if (gGemm) return YES;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gDev = MTLCreateSystemDefaultDevice();
    if (!gDev) return;
    gQueue = [gDev newCommandQueue];
    NSError* e = nil;
    id<MTLLibrary> lib = [gDev
        newLibraryWithSource:[NSString stringWithUTF8String:kGemmKernelSrc]
                     options:nil
                       error:&e];
    if (!lib) {
      NSLog(@"[pwsfm_gpu_match] kernel compile failed: %@", e);
      return;
    }
    id<MTLFunction> f = [lib newFunctionWithName:@"pw_match_gemm"];
    if (f) gGemm = [gDev newComputePipelineStateWithFunction:f error:&e];
    if (!gGemm) NSLog(@"[pwsfm_gpu_match] pipeline failed: %@", e);
  });
  return gGemm != nil;
}

// Shared GEMM implementation. guideMode=0 is the original matcher;
// guideMode=1 constrains candidates by E/F and guideMode=2 by H. The reverse
// pass receives matrixBA (E/F transpose or H inverse), preserving the same
// mutual cross-check as the unconstrained path.
static int matchPairsImpl(const uint8_t* dA, int nA, const float* xyA,
                          const uint8_t* dB, int nB, const float* xyB,
                          double max_ratio, const float* matrixAB,
                          const float* matrixBA, uint32_t guideMode,
                          float maxResidual, uint32_t* out_pairs,
                          int max_pairs, int* out_num_matches) {
  @autoreleasepool {
    if (out_num_matches) *out_num_matches = 0;
    if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
    if (out_pairs != nullptr && max_pairs <= 0) return 1;
    if (guideMode > 2u) return 1;
    if (guideMode != 0u &&
        (!xyA || !xyB || !matrixAB || !matrixBA || maxResidual <= 0.0f)) {
      return 1;
    }
    if (!ensureMetal()) return 2;
    const int D = 128;
    // Host-padded query buffers: multiple of kMB(128) rows, zero-filled,
    // so the kernel's device-side simdgroup_load never reads OOB.
    NSUInteger nApad = (((NSUInteger)nA + 127) / 128) * 128;
    NSUInteger nBpad = (((NSUInteger)nB + 127) / 128) * 128;
    id<MTLBuffer> aBuf = [gDev newBufferWithLength:nApad * D * sizeof(__fp16)
                                           options:MTLResourceStorageModeShared];
    id<MTLBuffer> bBuf = [gDev newBufferWithLength:nBpad * D * sizeof(__fp16)
                                           options:MTLResourceStorageModeShared];
    if (!aBuf || !bBuf) return 5;
    __fp16* af = (__fp16*)aBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nA * D; ++i) af[i] = (__fp16)dA[i];
    for (NSUInteger i = (NSUInteger)nA * D; i < nApad * D; ++i) af[i] = 0;
    __fp16* bf = (__fp16*)bBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nB * D; ++i) bf[i] = (__fp16)dB[i];
    for (NSUInteger i = (NSUInteger)nB * D; i < nBpad * D; ++i) bf[i] = 0;
    id<MTLBuffer> outAB = [gDev newBufferWithLength:(NSUInteger)nA * sizeof(int)
                                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> outBA = [gDev newBufferWithLength:(NSUInteger)nB * sizeof(int)
                                            options:MTLResourceStorageModeShared];
    if (!outAB || !outBA) return 6;
    static const float kDummyPoints[2] = {0.0f, 0.0f};
    static const float kDummyMatrix[9] = {1.0f, 0.0f, 0.0f,
                                          0.0f, 1.0f, 0.0f,
                                          0.0f, 0.0f, 1.0f};
    const float* pointsA = guideMode == 0u ? kDummyPoints : xyA;
    const float* pointsB = guideMode == 0u ? kDummyPoints : xyB;
    const float* matrixAtoB = guideMode == 0u ? kDummyMatrix : matrixAB;
    const float* matrixBtoA = guideMode == 0u ? kDummyMatrix : matrixBA;
    const NSUInteger pointsALength =
        guideMode == 0u ? sizeof(kDummyPoints)
                        : (NSUInteger)nA * 2 * sizeof(float);
    const NSUInteger pointsBLength =
        guideMode == 0u ? sizeof(kDummyPoints)
                        : (NSUInteger)nB * 2 * sizeof(float);
    id<MTLBuffer> pointsABuf =
        [gDev newBufferWithBytes:pointsA
                          length:pointsALength
                         options:MTLResourceStorageModeShared];
    id<MTLBuffer> pointsBBuf =
        [gDev newBufferWithBytes:pointsB
                          length:pointsBLength
                         options:MTLResourceStorageModeShared];
    id<MTLBuffer> matrixABBuf =
        [gDev newBufferWithBytes:matrixAtoB
                          length:9 * sizeof(float)
                         options:MTLResourceStorageModeShared];
    id<MTLBuffer> matrixBABuf =
        [gDev newBufferWithBytes:matrixBtoA
                          length:9 * sizeof(float)
                         options:MTLResourceStorageModeShared];
    if (!pointsABuf || !pointsBBuf || !matrixABBuf || !matrixBABuf) return 6;
    // COLMAP thresholds passed straight through (angular domain in-kernel):
    // max_ratio from the caller (default 0.7), max_distance = COLMAP's
    // SiftMatchingOptions default 0.7. The angular kernel needs no
    // per-descriptor norms — it uses the idealized 512^2 normalization.
    float maxRatio = (float)max_ratio;
    if (maxRatio <= 0.0f) maxRatio = 0.7f;
    float maxDistance = 0.7f;  // colmap::SiftMatchingOptions::max_distance default
    const NSUInteger bshLen = 16 * 128 * sizeof(__fp16);
    const NSUInteger accLen = 128 * 16 * sizeof(float);
    // Encodes one row-chunk of one direction (rowBase..rowBase+groups blocks).
    auto encChunk = [&](id<MTLCommandBuffer> cmd, id<MTLBuffer> Q,
                        id<MTLBuffer> Db, id<MTLBuffer> O, id<MTLBuffer> Qxy,
                        id<MTLBuffer> Dbxy, id<MTLBuffer> M, uint32_t nQ,
                        uint32_t nDb, uint32_t rowBase, NSUInteger groups) {
      id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
      [enc setComputePipelineState:gGemm];
      [enc setBuffer:Q offset:0 atIndex:0];
      [enc setBuffer:Db offset:0 atIndex:1];
      [enc setBuffer:O offset:0 atIndex:2];
      [enc setBytes:&nQ length:4 atIndex:3];
      [enc setBytes:&nDb length:4 atIndex:4];
      [enc setBytes:&maxRatio length:4 atIndex:5];
      [enc setBytes:&maxDistance length:4 atIndex:6];
      [enc setBuffer:Qxy offset:0 atIndex:7];
      [enc setBuffer:Dbxy offset:0 atIndex:8];
      [enc setBuffer:M offset:0 atIndex:9];
      [enc setBytes:&guideMode length:4 atIndex:10];
      [enc setBytes:&maxResidual length:4 atIndex:11];
      [enc setBytes:&rowBase length:4 atIndex:12];
      [enc setThreadgroupMemoryLength:bshLen atIndex:0];
      [enc setThreadgroupMemoryLength:accLen atIndex:1];
      [enc dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(512, 1, 1)];
      [enc endEncoding];
    };
    // [MATCH-FAIL TELEMETRY 2026-07-11] rc=7 is the ONLY "GPU command
    // failed" code — distinct from rc=0 with *out_num_matches==0 (a
    // legitimate zero-match pair) — so callers can bucket failures by rc.
    // Log the underlying Metal error rate-limited (a thermal collapse fails
    // hundreds of pairs back-to-back; capture 43 lost a 66-frame block this
    // way) so device logs show WHY (e.g. IOGPUCommandQueueErrorDomain /
    // GPU hang under thermal pressure).
    // [RC7-FILELOG 2026-07-11] Also stash the Metal error for the caller's
    // timestamped sfm_match_fail.jsonl line (NSLog is lost on detached/拔线
    // runs; the jsonl in the app container is recovered by devicectl copy).
    auto noteCmdError = [](id<MTLCommandBuffer> cmd) {
      static std::atomic<long> gCmdErrCount{0};
      const long k = ++gCmdErrCount;
      if (k <= 5 || (k % 100) == 0) {
        NSLog(@"[pwsfm_gpu_match] command buffer error #%ld (rc=7): %@", k,
              cmd.error);
      }
      stashLastError(cmd.error);
    };
    const double chunkTargetMs = ChunkTargetMs();
    if (chunkTargetMs <= 0.0) {
      // Legacy monolithic path (kill switch): both directions in a single
      // command buffer — the exact pre-KNIFE-C scheduling.
      id<MTLCommandBuffer> cmd = [gQueue commandBuffer];
      encChunk(cmd, aBuf, bBuf, outAB, pointsABuf, pointsBBuf, matrixABBuf,
               (uint32_t)nA, (uint32_t)nB, 0u,
               ((NSUInteger)nA + 127) / 128);  // A→B
      encChunk(cmd, bBuf, aBuf, outBA, pointsBBuf, pointsABuf, matrixBABuf,
               (uint32_t)nB, (uint32_t)nA, 0u,
               ((NSUInteger)nB + 127) / 128);  // B→A
      [cmd commit];
      [cmd waitUntilCompleted];
      if (cmd.status == MTLCommandBufferStatusError) {
        noteCmdError(cmd);
        return 7;
      }
    } else {
      // [KNIFE-C] Chunked path: one small command buffer at a time, sized
      // from the measured cost model to ~chunkTargetMs of GPU time, with a
      // thermal duty-cycle gap between chunks. Numerically identical output
      // for any chunking (row blocks are independent in the kernel).
      auto runDirection = [&](id<MTLBuffer> Q, id<MTLBuffer> Db,
                              id<MTLBuffer> O, id<MTLBuffer> Qxy,
                              id<MTLBuffer> Dbxy, id<MTLBuffer> M, uint32_t nQ,
                              uint32_t nDb) -> int {
        const NSUInteger totalGroups = ((NSUInteger)nQ + 127) / 128;
        NSUInteger tg0 = 0;
        while (tg0 < totalGroups) {
          // Re-evaluated per chunk so a thermal transition mid-pair
          // immediately tightens/relaxes the chunk size.
          const double target =
              ThermalHot() ? chunkTargetMs : ChunkTargetCoolMs();
          const double unit = gMsPerTgKCol.load();
          NSUInteger want = 8;  // first probe: 1024 rows (~few ms cool)
          if (unit > 0.0) {
            const double perTg = unit * ((double)nDb / 1024.0);
            const double ideal = target / (perTg > 1e-6 ? perTg : 1e-6);
            want = ideal < 1.0 ? 1 : (NSUInteger)ideal;
          }
          const NSUInteger groups =
              want < totalGroups - tg0 ? want : totalGroups - tg0;
          id<MTLCommandBuffer> cmd = [gQueue commandBuffer];
          encChunk(cmd, Q, Db, O, Qxy, Dbxy, M, nQ, nDb, (uint32_t)tg0,
                   groups);
          [cmd commit];
          [cmd waitUntilCompleted];
          if (cmd.status == MTLCommandBufferStatusError) {
            noteCmdError(cmd);
            return 7;
          }
          const double gpuMs = (cmd.GPUEndTime - cmd.GPUStartTime) * 1000.0;
          if (gpuMs > 0.0 && gpuMs < 10000.0) {
            const double u = gpuMs / ((double)groups * ((double)nDb / 1024.0));
            const double prev = gMsPerTgKCol.load();
            gMsPerTgKCol.store(prev <= 0.0 ? u : prev * 0.7 + u * 0.3);
          }
          const double gapPct = ThermalGapPct();
          if (gapPct > 0.0 && gpuMs > 0.0) {
            // Cap the idle gap so a pathologically slow chunk (deep
            // downclock) cannot stall the matcher for seconds.
            double gapMs = gpuMs * gapPct / 100.0;
            if (gapMs > 250.0) gapMs = 250.0;
            usleep((useconds_t)(gapMs * 1000.0));
          }
          tg0 += groups;
        }
        return 0;
      };
      int rc = runDirection(aBuf, bBuf, outAB, pointsABuf, pointsBBuf,
                            matrixABBuf, (uint32_t)nA, (uint32_t)nB);  // A→B
      if (rc == 0) {
        rc = runDirection(bBuf, aBuf, outBA, pointsBBuf, pointsABuf,
                          matrixBABuf, (uint32_t)nB, (uint32_t)nA);  // B→A
      }
      if (rc != 0) return rc;
    }

    // Mutual cross-check, emitting pairs.
    const int* mAB = (const int*)outAB.contents;
    const int* mBA = (const int*)outBA.contents;
    int n_out = 0;
    for (int i = 0; i < nA; ++i) {
      int j = mAB[i];
      if (j >= 0 && j < nB && mBA[j] == i) {
        if (out_pairs != nullptr) {
          if (n_out >= max_pairs) break;  // unreachable per contract
          out_pairs[2 * n_out] = (uint32_t)i;
          out_pairs[2 * n_out + 1] = (uint32_t)j;
        }
        ++n_out;
      }
    }
    if (out_num_matches) *out_num_matches = n_out;
    return 0;
  }
}

// GEMM matcher with mutual cross-check, emitting index pairs.
// out_pairs is caller-allocated as 2*max_pairs uint32 entries. Cross-checked
// matches are unique per idxA, so max_pairs=min(nA,nB) cannot truncate.
extern "C" int aether_gpu_match_gemm_pairs(const uint8_t* dA, int nA,
                                           const uint8_t* dB, int nB,
                                           double max_ratio,
                                           uint32_t* out_pairs, int max_pairs,
                                           int* out_num_matches) {
  return matchPairsImpl(dA, nA, nullptr, dB, nB, nullptr, max_ratio, nullptr,
                        nullptr, 0u, 0.0f, out_pairs, max_pairs,
                        out_num_matches);
}

// COLMAP-style geometry-guided matcher. xy arrays contain two floats per
// keypoint. matrixAB/matrixBA are row-major 3x3 matrices; guide_mode 1 means
// epipolar E/F and 2 means homography H. A non-zero return is fail-closed by
// native finalize and never triggers CPU matching on the device.
extern "C" int aether_gpu_match_gemm_pairs_guided(
    const uint8_t* dA, int nA, const float* xyA, const uint8_t* dB, int nB,
    const float* xyB, double max_ratio, const float* matrixAB,
    const float* matrixBA, int guide_mode, float max_residual,
    uint32_t* out_pairs, int max_pairs, int* out_num_matches) {
  return matchPairsImpl(dA, nA, xyA, dB, nB, xyB, max_ratio, matrixAB,
                        matrixBA, (uint32_t)guide_mode, max_residual,
                        out_pairs, max_pairs, out_num_matches);
}
