// pwofficial_gpu_match_dispatch.cc — thin owner of the public GPU matcher
// ABI (aether_gpu_match_* / aether_match_set_ab_phase) that forwards every
// call to ONE of two backend TUs:
//   * pwmetal_*  — the shipped Metal TU pwofficial_gpu_match.mm, compiled
//                  with -include pwofficial_gpu_match_metal_rename.h (Apple
//                  targets only; absent when PWOFFICIAL_MATCH_NO_METAL=1);
//   * pwdawn_*   — the cross-platform Dawn/WGSL TU pwofficial_gpu_match_dawn.cc
//                  (iOS → Metal, Android/HarmonyOS → Vulkan).
// Selection: env OFFICIAL_AETHER_MATCH_BACKEND, read ONCE per process.
//   unset / "dawn"  → Dawn (DEFAULT on every platform — one pipeline rule)
//   "metal"         → shipped Metal TU (parity oracle for on-device A/B only)
// On builds without the Metal TU the Dawn backend is the only implementation
// and the env is ignored. The choice is process-wide and cached like every
// other OFFICIAL_AETHER_* knob (the residency / cost-model state lives inside
// each backend, so switching mid-process is deliberately not supported).
//
// Flag setters (capture_active / preview_fps30 / ab_phase / thermal) are
// forwarded to BOTH backends so their scheduling state stays coherent
// regardless of which one executes the match.
//
// Observation globals aether_match_gpu_ms / _sleep_ms / _chunks and the
// Dart-dlsym'd aether_gpu_match_get_capture_active are NOT owned here: the
// Metal TU defines them on Apple (both backends write the same words); the
// Dawn TU defines them elsewhere.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {

// ── Dawn backend (always present) ────────────────────────────────────────
int pwdawn_gpu_match_gemm_pairs(const uint8_t* dA, int nA, const uint8_t* dB,
                                int nB, double max_ratio, uint32_t* out_pairs,
                                int max_pairs, int* out_num_matches);
int pwdawn_gpu_match_gemm_pairs_resident(
    uint64_t session_nonce, uint32_t frame_a, uint32_t generation_a,
    const uint8_t* dA, int nA, uint32_t frame_b, uint32_t generation_b,
    const uint8_t* dB, int nB, double max_ratio, uint32_t* out_pairs,
    int max_pairs, int* out_num_matches);
void pwdawn_gpu_match_descriptor_residency_invalidate(uint64_t session_nonce,
                                                      uint32_t frame_ordinal);
void pwdawn_gpu_match_descriptor_residency_clear_session(uint64_t session_nonce);
int pwdawn_gpu_match_descriptor_residency_stats(
    uint64_t session_nonce, uint64_t* hits, uint64_t* misses,
    uint64_t* evictions, uint64_t* stale_replacements, uint64_t* upload_bytes,
    uint64_t* resident_bytes, uint64_t* resident_entries,
    uint64_t* allocation_failures, uint64_t* device_resets);
int pwdawn_gpu_match_probe_batch(const uint8_t* dA, int nA,
                                 const uint8_t* const* dBs, const int* nBs,
                                 int n_cands, double max_ratio, int* out_counts);
int pwdawn_gpu_match_gemm_pairs_guided(
    const uint8_t* dA, int nA, const float* xyA, const uint8_t* dB, int nB,
    const float* xyB, double max_ratio, const float* matrixAB,
    const float* matrixBA, int guide_mode, float max_residual,
    uint32_t* out_pairs, int max_pairs, int* out_num_matches);
int pwdawn_gpu_match_last_error(char* buf, int cap);
void pwdawn_match_set_ab_phase(int phase);
void pwdawn_gpu_match_set_capture_active(int active);
void pwdawn_gpu_match_set_preview_fps30(int on);
void pwdawn_gpu_match_set_thermal_state(int state);
int pwdawn_gpu_match_backend_info(char* buf, int cap);

#if !defined(PWOFFICIAL_MATCH_NO_METAL)
// ── Metal backend (renamed exports of pwofficial_gpu_match.mm) ───────────
int pwmetal_gpu_match_gemm_pairs(const uint8_t* dA, int nA, const uint8_t* dB,
                                 int nB, double max_ratio, uint32_t* out_pairs,
                                 int max_pairs, int* out_num_matches);
int pwmetal_gpu_match_gemm_pairs_resident(
    uint64_t session_nonce, uint32_t frame_a, uint32_t generation_a,
    const uint8_t* dA, int nA, uint32_t frame_b, uint32_t generation_b,
    const uint8_t* dB, int nB, double max_ratio, uint32_t* out_pairs,
    int max_pairs, int* out_num_matches);
void pwmetal_gpu_match_descriptor_residency_invalidate(uint64_t session_nonce,
                                                       uint32_t frame_ordinal);
void pwmetal_gpu_match_descriptor_residency_clear_session(uint64_t session_nonce);
int pwmetal_gpu_match_descriptor_residency_stats(
    uint64_t session_nonce, uint64_t* hits, uint64_t* misses,
    uint64_t* evictions, uint64_t* stale_replacements, uint64_t* upload_bytes,
    uint64_t* resident_bytes, uint64_t* resident_entries,
    uint64_t* allocation_failures, uint64_t* device_resets);
int pwmetal_gpu_match_probe_batch(const uint8_t* dA, int nA,
                                  const uint8_t* const* dBs, const int* nBs,
                                  int n_cands, double max_ratio, int* out_counts);
int pwmetal_gpu_match_gemm_pairs_guided(
    const uint8_t* dA, int nA, const float* xyA, const uint8_t* dB, int nB,
    const float* xyB, double max_ratio, const float* matrixAB,
    const float* matrixBA, int guide_mode, float max_residual,
    uint32_t* out_pairs, int max_pairs, int* out_num_matches);
int pwmetal_gpu_match_last_error(char* buf, int cap);
void pwmetal_match_set_ab_phase(int phase);
void pwmetal_gpu_match_set_capture_active(int active);
void pwmetal_gpu_match_set_preview_fps30(int on);
#endif

}  // extern "C"

namespace {

bool UseDawn() {
#if defined(PWOFFICIAL_MATCH_NO_METAL)
  return true;
#else
  // [ONE-PIPELINE 2026-09-03] User rule: all three platforms run the SAME
  // matcher implementation (Dawn/WGSL). Dawn is the default everywhere; the
  // shipped Metal TU stays linked ONLY as the byte-exact parity oracle for
  // on-device A/B (env OFFICIAL_AETHER_MATCH_BACKEND=metal). Never make Metal
  // the default again for speed — close the speed gap in the Dawn kernel.
  static const bool v = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_MATCH_BACKEND");
    const bool dawn = !(e != nullptr && std::strcmp(e, "metal") == 0);
    // Device fingerprint (installed != live): one pull-able line per process,
    // <HOME>/Documents/matcher_backend.jsonl. Observation only; never throws.
    if (const char* home = std::getenv("HOME")) {
      std::string path = std::string(home) + "/Documents/matcher_backend.jsonl";
      if (FILE* f = std::fopen(path.c_str(), "a")) {
        std::fprintf(f, "{\"backend\":\"%s\",\"env\":\"%s\"}\n",
                     dawn ? "dawn" : "metal", e ? e : "");
        std::fclose(f);
      }
    }
    return dawn;
  }();
  return v;
#endif
}

}  // namespace

// Which backend this process dispatches to ("metal" | "dawn"). For device
// verification that the env switch actually took effect (installed ≠ live).
extern "C" const char* aether_gpu_match_backend_name(void) {
  return UseDawn() ? "dawn" : "metal";
}

extern "C" int aether_gpu_match_gemm_pairs(const uint8_t* dA, int nA,
                                           const uint8_t* dB, int nB,
                                           double max_ratio,
                                           uint32_t* out_pairs, int max_pairs,
                                           int* out_num_matches) {
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  if (!UseDawn()) {
    return pwmetal_gpu_match_gemm_pairs(dA, nA, dB, nB, max_ratio, out_pairs,
                                        max_pairs, out_num_matches);
  }
#endif
  return pwdawn_gpu_match_gemm_pairs(dA, nA, dB, nB, max_ratio, out_pairs,
                                     max_pairs, out_num_matches);
}

extern "C" int aether_gpu_match_gemm_pairs_resident(
    uint64_t session_nonce, uint32_t frame_a, uint32_t generation_a,
    const uint8_t* dA, int nA, uint32_t frame_b, uint32_t generation_b,
    const uint8_t* dB, int nB, double max_ratio, uint32_t* out_pairs,
    int max_pairs, int* out_num_matches) {
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  if (!UseDawn()) {
    return pwmetal_gpu_match_gemm_pairs_resident(
        session_nonce, frame_a, generation_a, dA, nA, frame_b, generation_b,
        dB, nB, max_ratio, out_pairs, max_pairs, out_num_matches);
  }
#endif
  return pwdawn_gpu_match_gemm_pairs_resident(
      session_nonce, frame_a, generation_a, dA, nA, frame_b, generation_b, dB,
      nB, max_ratio, out_pairs, max_pairs, out_num_matches);
}

extern "C" void aether_gpu_match_descriptor_residency_invalidate(
    uint64_t session_nonce, uint32_t frame_ordinal) {
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  if (!UseDawn()) {
    pwmetal_gpu_match_descriptor_residency_invalidate(session_nonce,
                                                      frame_ordinal);
    return;
  }
#endif
  pwdawn_gpu_match_descriptor_residency_invalidate(session_nonce, frame_ordinal);
}

extern "C" void aether_gpu_match_descriptor_residency_clear_session(
    uint64_t session_nonce) {
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  if (!UseDawn()) {
    pwmetal_gpu_match_descriptor_residency_clear_session(session_nonce);
    return;
  }
#endif
  pwdawn_gpu_match_descriptor_residency_clear_session(session_nonce);
}

extern "C" int aether_gpu_match_descriptor_residency_stats(
    uint64_t session_nonce, uint64_t* hits, uint64_t* misses,
    uint64_t* evictions, uint64_t* stale_replacements, uint64_t* upload_bytes,
    uint64_t* resident_bytes, uint64_t* resident_entries,
    uint64_t* allocation_failures, uint64_t* device_resets) {
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  if (!UseDawn()) {
    return pwmetal_gpu_match_descriptor_residency_stats(
        session_nonce, hits, misses, evictions, stale_replacements,
        upload_bytes, resident_bytes, resident_entries, allocation_failures,
        device_resets);
  }
#endif
  return pwdawn_gpu_match_descriptor_residency_stats(
      session_nonce, hits, misses, evictions, stale_replacements, upload_bytes,
      resident_bytes, resident_entries, allocation_failures, device_resets);
}

extern "C" int aether_gpu_match_probe_batch(const uint8_t* dA, int nA,
                                            const uint8_t* const* dBs,
                                            const int* nBs, int n_cands,
                                            double max_ratio,
                                            int* out_counts) {
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  if (!UseDawn()) {
    return pwmetal_gpu_match_probe_batch(dA, nA, dBs, nBs, n_cands, max_ratio,
                                         out_counts);
  }
#endif
  return pwdawn_gpu_match_probe_batch(dA, nA, dBs, nBs, n_cands, max_ratio,
                                      out_counts);
}

extern "C" int aether_gpu_match_gemm_pairs_guided(
    const uint8_t* dA, int nA, const float* xyA, const uint8_t* dB, int nB,
    const float* xyB, double max_ratio, const float* matrixAB,
    const float* matrixBA, int guide_mode, float max_residual,
    uint32_t* out_pairs, int max_pairs, int* out_num_matches) {
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  if (!UseDawn()) {
    return pwmetal_gpu_match_gemm_pairs_guided(
        dA, nA, xyA, dB, nB, xyB, max_ratio, matrixAB, matrixBA, guide_mode,
        max_residual, out_pairs, max_pairs, out_num_matches);
  }
#endif
  return pwdawn_gpu_match_gemm_pairs_guided(
      dA, nA, xyA, dB, nB, xyB, max_ratio, matrixAB, matrixBA, guide_mode,
      max_residual, out_pairs, max_pairs, out_num_matches);
}

extern "C" int aether_gpu_match_last_error(char* buf, int cap) {
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  if (!UseDawn()) return pwmetal_gpu_match_last_error(buf, cap);
#endif
  return pwdawn_gpu_match_last_error(buf, cap);
}

// Flag setters: both backends, always (cheap atomics; keeps scheduling
// state coherent whichever backend executes).
extern "C" void aether_match_set_ab_phase(int phase) {
  pwdawn_match_set_ab_phase(phase);
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  pwmetal_match_set_ab_phase(phase);
#endif
}

extern "C" void aether_gpu_match_set_capture_active(int active) {
  pwdawn_gpu_match_set_capture_active(active);
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  pwmetal_gpu_match_set_capture_active(active);
#endif
}

extern "C" void aether_gpu_match_set_preview_fps30(int on) {
  pwdawn_gpu_match_set_preview_fps30(on);
#if !defined(PWOFFICIAL_MATCH_NO_METAL)
  pwmetal_gpu_match_set_preview_fps30(on);
#endif
}

// Portable thermal feed (0 nominal · 1 fair · 2 serious · 3 critical). On
// Apple the Dawn TU also reads NSProcessInfo through the weak platform hook;
// the Metal TU reads NSProcessInfo itself, so only Dawn consumes this.
extern "C" void aether_gpu_match_set_thermal_state(int state) {
  pwdawn_gpu_match_set_thermal_state(state);
}

extern "C" int aether_gpu_match_backend_info(char* buf, int cap) {
  if (!buf || cap <= 0) return 0;
  if (!UseDawn()) {
    const int n = std::snprintf(buf, (size_t)cap, "backend=metal(pwofficial_gpu_match.mm)");
    return n < 0 ? 0 : (n < cap ? n : cap - 1);
  }
  return pwdawn_gpu_match_backend_info(buf, cap);
}
