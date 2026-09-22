#include "sweep_contract.h"

#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <initializer_list>

namespace sweep = pocketworld::official_dense::vulkan::sweep;

static_assert(sweep::kLocalSizeX == 32);
static_assert(sweep::kLocalSizeY == 1);
static_assert(sweep::kLocalSizeZ == 1);
static_assert(sweep::kCandidatesPerPixel == 5);
static_assert(sweep::kRngReadRow == 0);
static_assert(sweep::kRngWriteRow == 0);
static_assert(sweep::kGeomConsistencySpecializationId == 2);
static_assert(sweep::kFilterPhotoSpecializationId == 3);
static_assert(sweep::kFilterGeomSpecializationId == 4);
static_assert(sweep::kFinalGeometricMask == 7);
static_assert(!sweep::kFinalMaskRequiresAdditionalSweep);
static_assert(sweep::kNccNormFactorPatchPcByteOffset == 28);
static_assert(sweep::kCurrentDepthCurrentNormal == 0);
static_assert(sweep::kPreviousDepthPreviousNormal == 1);
static_assert(sweep::kRandomDepthRandomNormal == 2);
static_assert(sweep::kCurrentDepthRandomNormal == 3);
static_assert(sweep::kRandomDepthCurrentNormal == 4);
static_assert(
    sweep::kBackendStatus ==
    sweep::BackendStatus::kUnavailableUntilCudaXorwowAndTextureParity);
static_assert(!sweep::CanDispatchSweepBackend());
static_assert(sweep::kDefaultNumSamples == 15);
static_assert(sweep::PcgDrawsPerRow(1, 15) == 19);
static_assert(sweep::PcgDrawsPerRow(2, 15) == 22);
static_assert(sweep::PcgDrawsPerRow(3, 15) == 25);
static_assert(sweep::PcgDrawsPerRow(4, 15) == 28);
static_assert(sweep::PcgDrawsPerRow(4, 0) == 13);

namespace {

bool Near(const float actual, const float expected) {
  return std::abs(actual - expected) <= 1e-7f;
}

}  // namespace

int main() {
  const float kNccNormFactor = sweep::ComputeNccCostNormFactor(0.6f);
  if (!Near(kNccNormFactor, 1.3309495f)) {
    return EXIT_FAILURE;
  }
  const std::uint32_t encoded =
      sweep::EncodeNccNormFactorForPatchPcReservedBits(kNccNormFactor);
  if (sweep::DecodeNccNormFactorFromPatchPcReservedBits(encoded) !=
          kNccNormFactor) {
    return EXIT_FAILURE;
  }

  const float tied_costs[5] = {3.0f, 1.0f, 2.0f, 1.0f, 1.0f};
  if (sweep::FindMinCostLastTie(tied_costs) != 4) {
    return EXIT_FAILURE;
  }

  float probabilities[4] = {1.0f, 1.0f, 2.0f, 4.0f};
  sweep::TransformPDFToCDF(probabilities, 4);
  if (!Near(probabilities[0], 0.125f) ||
      !Near(probabilities[1], 0.25f) ||
      !Near(probabilities[2], 0.5f) ||
      !Near(probabilities[3], 1.0f)) {
    return EXIT_FAILURE;
  }
  if (sweep::StrictCDFSelection(probabilities, 4, 0.25f) != 2 ||
      sweep::StrictCDFSelection(probabilities, 4, 1.0f) != -1) {
    return EXIT_FAILURE;
  }
  if (sweep::SelectionDrawFromPcgUniform(0.0f) !=
      -sweep::kBinary32Epsilon) {
    return EXIT_FAILURE;
  }

  constexpr std::uint32_t kInitialState = 0x12345678u;
  if (sweep::AdvancePcgStateForRow(kInitialState, 1, 15) != 0x8c9a45f3u ||
      sweep::AdvancePcgStateForRow(kInitialState, 2, 15) != 0xfb98aec2u ||
      sweep::AdvancePcgStateForRow(kInitialState, 3, 15) != 0x5d43c945u ||
      sweep::AdvancePcgStateForRow(kInitialState, 4, 15) != 0xc27149ecu) {
    return EXIT_FAILURE;
  }
  if (sweep::AdvancePcgStateForRows(kInitialState, 4, 1, 15) !=
      0x4058fd7cu) {
    return EXIT_FAILURE;
  }
  for (const bool geometric : {false, true}) {
    for (const bool filter_photo : {false, true}) {
      for (const bool filter_geometric : {false, true}) {
        if (sweep::AdvancePcgStateForRowWithModes(
                kInitialState,
                4,
                15,
                geometric,
                filter_photo,
                filter_geometric) != 0xc27149ecu) {
          return EXIT_FAILURE;
        }
      }
    }
  }

  float zero_probabilities[2] = {0.0f, 0.0f};
  sweep::TransformPDFToCDF(zero_probabilities, 2);
  if (!std::isnan(zero_probabilities[0]) ||
      !std::isnan(zero_probabilities[1])) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
