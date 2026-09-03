// pwofficial_gpu_match_metal_rename.h — backend-private names for the
// shipped Metal matcher TU (pwofficial_gpu_match.mm).
//
// Force-included (`clang++ -include <this file>`) ONLY when compiling
// pwofficial_gpu_match.mm. It renames that TU's exported C entry points to
// pwmetal_* so the public aether_gpu_match_* ABI can be owned by the thin
// dispatch layer (pwofficial_gpu_match_dispatch.cc) that selects Metal or
// Dawn at runtime. The .mm SOURCE stays byte-identical (single-variable
// discipline: the Metal TU's logic is not touched; only its symbol names
// change, at the build-script level).
//
// Deliberately NOT renamed (shared words, defined once by the Metal TU on
// iOS, accumulated by both backends):
//   aether_match_gpu_ms / aether_match_sleep_ms / aether_match_chunks
//   aether_gpu_match_get_capture_active  (dlsym'd by the Dart worker; both
//                                         backends' flags are set together)
#ifndef PWOFFICIAL_GPU_MATCH_METAL_RENAME_H
#define PWOFFICIAL_GPU_MATCH_METAL_RENAME_H

#define aether_gpu_match_gemm_pairs pwmetal_gpu_match_gemm_pairs
#define aether_gpu_match_gemm_pairs_resident pwmetal_gpu_match_gemm_pairs_resident
#define aether_gpu_match_descriptor_residency_invalidate \
  pwmetal_gpu_match_descriptor_residency_invalidate
#define aether_gpu_match_descriptor_residency_clear_session \
  pwmetal_gpu_match_descriptor_residency_clear_session
#define aether_gpu_match_descriptor_residency_stats \
  pwmetal_gpu_match_descriptor_residency_stats
#define aether_gpu_match_probe_batch pwmetal_gpu_match_probe_batch
#define aether_gpu_match_gemm_pairs_guided pwmetal_gpu_match_gemm_pairs_guided
#define aether_gpu_match_last_error pwmetal_gpu_match_last_error
#define aether_match_set_ab_phase pwmetal_match_set_ab_phase
#define aether_gpu_match_set_capture_active pwmetal_gpu_match_set_capture_active
#define aether_gpu_match_set_preview_fps30 pwmetal_gpu_match_set_preview_fps30

#endif  // PWOFFICIAL_GPU_MATCH_METAL_RENAME_H
