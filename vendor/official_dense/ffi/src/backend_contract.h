#pragma once

#include <atomic>
#include <string>

#include "pwofficial_dense_c.h"

namespace pocketworld::official_dense::ffi {

inline constexpr char kColmapUpstreamCommit[] =
    "a0d785fba74b2664f31edc4a29026a8b27c00f67";
inline constexpr char kColmapSourceManifestSha256[] =
    "6f10ea037800b375467b7b0511cc35aef248ca2becd834e260056dddb653be28";

struct BackendReadiness {
  bool source_hash_ready = false;
  std::string upstream_commit;
  std::string source_manifest_sha256;
  bool vulkan_loader_caps_ready = false;
  bool xorwow_ready = false;
  bool texture_parity_ready = false;
  bool shader_dispatch_ready = false;
  bool fusion_ready = false;

  bool SourceIdentityReady() const noexcept {
    return source_hash_ready && upstream_commit == kColmapUpstreamCommit &&
           source_manifest_sha256 == kColmapSourceManifestSha256;
  }

  bool AllReady() const noexcept {
    return SourceIdentityReady() && vulkan_loader_caps_ready && xorwow_ready &&
           texture_parity_ready && shader_dispatch_ready && fusion_ready;
  }
};

struct BackendRunRequest {
  const char* workspace_path = nullptr;
  const char* output_ply = nullptr;
  const pwofficial_dense_options_t* options = nullptr;
  const std::atomic<bool>* cancel_requested = nullptr;
};

struct BackendRunResult {
  pwofficial_dense_result_t code = PW_OFFICIAL_DENSE_INTERNAL_ERROR;
  std::string message;
};

// The production backend must implement these three functions. Until that
// backend replaces backend_unavailable.cc, the public ABI stays fail-closed.
BackendReadiness QueryBackendReadiness();
BackendRunResult RunBackend(const BackendRunRequest& request);
void CancelBackend() noexcept;

}  // namespace pocketworld::official_dense::ffi
