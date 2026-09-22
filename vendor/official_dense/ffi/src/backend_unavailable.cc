#include "backend_contract.h"

namespace pocketworld::official_dense::ffi {

BackendReadiness QueryBackendReadiness() { return {}; }

BackendRunResult RunBackend(const BackendRunRequest& /*request*/) {
  return {PW_OFFICIAL_DENSE_UNAVAILABLE,
          "official COLMAP 4.1.1 Vulkan dense backend is unavailable"};
}

void CancelBackend() noexcept {}

}  // namespace pocketworld::official_dense::ffi
