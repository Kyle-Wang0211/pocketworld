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

#include <stdint.h>

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
                          threadgroup half*   Bsh         [[threadgroup(0)]],
                          threadgroup float*  acc         [[threadgroup(1)]],
                          uint tgid  [[threadgroup_position_in_grid]],
                          uint lid   [[thread_index_in_threadgroup]],
                          uint sgid  [[simdgroup_index_in_threadgroup]]) {
  const uint row0 = tgid * kMB;
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
    const float bd = acos(min(bestT[lid]   * kInvSqNorm, 1.0f));
    const float sd = acos(min(secondT[lid] * kInvSqNorm, 1.0f));
    const bool keep = (bd <= maxDistance) && (bd < maxRatio * sd);
    out[row0 + lid] = keep ? bi : -1;
  }
}
)MSL";

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

// GEMM matcher with mutual cross-check, emitting index pairs.
// out_pairs: caller-allocated, 2*max_pairs uint32 entries filled as
// [idxA, idxB]; cross-checked matches are unique per idxA so
// max_pairs = min(nA, nB) can never truncate. Returns 0 on success;
// non-zero → caller falls back to the CPU matcher.
extern "C" int aether_gpu_match_gemm_pairs(const uint8_t* dA, int nA,
                                           const uint8_t* dB, int nB,
                                           double max_ratio,
                                           uint32_t* out_pairs, int max_pairs,
                                           int* out_num_matches) {
  @autoreleasepool {
    if (out_num_matches) *out_num_matches = 0;
    if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
    if (out_pairs != nullptr && max_pairs <= 0) return 1;
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
    // COLMAP thresholds passed straight through (angular domain in-kernel):
    // max_ratio from the caller (default 0.7), max_distance = COLMAP's
    // SiftMatchingOptions default 0.7. The angular kernel needs no
    // per-descriptor norms — it uses the idealized 512^2 normalization.
    float maxRatio = (float)max_ratio;
    if (maxRatio <= 0.0f) maxRatio = 0.7f;
    float maxDistance = 0.7f;  // colmap::SiftMatchingOptions::max_distance default
    const NSUInteger bshLen = 16 * 128 * sizeof(__fp16);
    const NSUInteger accLen = 128 * 16 * sizeof(float);
    id<MTLCommandBuffer> cmd = [gQueue commandBuffer];
    void (^enc2)(id<MTLBuffer>, id<MTLBuffer>, id<MTLBuffer>, uint32_t,
                 uint32_t) =
        ^(id<MTLBuffer> Q, id<MTLBuffer> Db, id<MTLBuffer> O, uint32_t nQ,
          uint32_t nDb) {
          id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
          [enc setComputePipelineState:gGemm];
          [enc setBuffer:Q offset:0 atIndex:0];
          [enc setBuffer:Db offset:0 atIndex:1];
          [enc setBuffer:O offset:0 atIndex:2];
          [enc setBytes:&nQ length:4 atIndex:3];
          [enc setBytes:&nDb length:4 atIndex:4];
          [enc setBytes:&maxRatio length:4 atIndex:5];
          [enc setBytes:&maxDistance length:4 atIndex:6];
          [enc setThreadgroupMemoryLength:bshLen atIndex:0];
          [enc setThreadgroupMemoryLength:accLen atIndex:1];
          NSUInteger groups = (nQ + 127) / 128;
          [enc dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
              threadsPerThreadgroup:MTLSizeMake(512, 1, 1)];
          [enc endEncoding];
        };
    enc2(aBuf, bBuf, outAB, (uint32_t)nA, (uint32_t)nB);  // A→B
    enc2(bBuf, aBuf, outBA, (uint32_t)nB, (uint32_t)nA);  // B→A
    [cmd commit];
    [cmd waitUntilCompleted];
    if (cmd.status == MTLCommandBufferStatusError) return 7;

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
