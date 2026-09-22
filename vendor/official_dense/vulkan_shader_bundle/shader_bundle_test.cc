#include "shader_bundle.h"

#include <cstdint>
#include <cstring>

#include "../vulkan_host/dispatch_plan.h"

int main() {
  namespace bundle =
      pocketworld::official_dense::vulkan::shader_bundle;
  namespace runtime = pocketworld::official_dense::vulkan::runtime;
  namespace vulkan = pocketworld::official_dense::vulkan;

  constexpr std::uint32_t kSpirvMagic = 0x07230203U;
  const auto &identities = bundle::FrozenShaderManifest();
  const auto &canonical = bundle::CanonicalShaderBundle();
  const auto &runtime_manifest = runtime::CanonicalShaderManifest();
  for (std::size_t index = 0; index < runtime::kShaderCount; ++index) {
    const auto &identity = identities[index];
    const auto &binary = canonical.binaries[index];
    const auto &expected = runtime_manifest[index];
    if (identity.kind != expected.kind || binary.kind != expected.kind ||
        std::strcmp(identity.source_path, expected.source_path) != 0 ||
        std::strcmp(identity.source_sha256, expected.source_sha256) != 0 ||
        std::strcmp(identity.spirv_sha256, expected.spirv_sha256) != 0 ||
        std::strcmp(binary.source_sha256, identity.source_sha256) != 0 ||
        binary.words == nullptr || binary.word_count != identity.word_count ||
        binary.word_count < 5U || binary.words[0] != kSpirvMagic) {
      return static_cast<int>(index + 1U);
    }
  }

  const auto plan = vulkan::CreateDispatchPlan(1U);
  runtime::RecordRequest request;
  request.plan = &plan;
  request.shaders = canonical;
  const runtime::RecordResult result = runtime::Record(request);
  if (result.status != runtime::RuntimeStatus::kPcgAdaptationNotCertified ||
      result.recorded()) {
    return 20;
  }
  return 0;
}
