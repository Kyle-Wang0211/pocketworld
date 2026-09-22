#include "rng_contract.h"
#include "openmvs_pcg_reference.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace rng = pocketworld::official_dense::vulkan::rng;
namespace openmvs_pcg =
    pocketworld::official_dense::vulkan::rng::openmvs_pcg;

static_assert(rng::kInitBlockSizeX == 32);
static_assert(rng::kInitBlockSizeY == 16);
static_assert(rng::kInitBlockSizeZ == 1);
static_assert(rng::kSubsequence == 0);
static_assert(rng::kOffset == 0);
static_assert(!rng::CanDispatchRngBackend());
static_assert(
    rng::kBackendStatus ==
    rng::BackendStatus::kUnavailableUntilCudaXorwowParity);

static_assert(openmvs_pcg::SeedForPixel(0, 0) == 1234u);
static_assert(openmvs_pcg::NextState(1234u) == 2254131583u);
static_assert(openmvs_pcg::OutputFromState(2254131583u) == 1819980427u);
static_assert(openmvs_pcg::UniformBits(1819980427u) == 8041099u);

// Independently precomputed uint32 vectors. These cover distinct coordinates,
// wraparound in the pixel seed, and continued advancement of one stream.
static_assert(openmvs_pcg::SeedForPixel(1, 0) == 3207u);
static_assert(openmvs_pcg::NextState(3207u) == 187688824u);
static_assert(openmvs_pcg::OutputFromState(187688824u) == 808217463u);
static_assert(openmvs_pcg::UniformBits(808217463u) == 2911095u);

static_assert(openmvs_pcg::SeedForPixel(0, 1) == 10511u);
static_assert(openmvs_pcg::NextState(10511u) == 3189197728u);
static_assert(openmvs_pcg::OutputFromState(3189197728u) == 3525136406u);
static_assert(openmvs_pcg::UniformBits(3525136406u) == 1921046u);

static_assert(openmvs_pcg::SeedForPixel(37, 19) == 250498u);
static_assert(openmvs_pcg::NextState(250498u) == 3691548399u);
static_assert(openmvs_pcg::OutputFromState(3691548399u) == 1518259290u);
static_assert(openmvs_pcg::UniformBits(1518259290u) == 8309850u);

static_assert(openmvs_pcg::SeedForPixel(0xffffffffu, 0xffffffffu) ==
              4294957280u);
static_assert(openmvs_pcg::NextState(4294957280u) == 3385508197u);
static_assert(openmvs_pcg::OutputFromState(3385508197u) == 3381184881u);
static_assert(openmvs_pcg::UniformBits(3381184881u) == 8964465u);

static_assert(openmvs_pcg::NextState(187688824u) == 2084420317u);
static_assert(openmvs_pcg::OutputFromState(2084420317u) == 1970291471u);
static_assert(openmvs_pcg::UniformBits(1970291471u) == 7357199u);

std::uint32_t FloatBits(const float value) {
  static_assert(sizeof(float) == sizeof(std::uint32_t));
  std::uint32_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  return bits;
}

int main() {
  constexpr std::uint64_t kGridSizeX = 3;
  constexpr std::uint64_t kBlockX = 2;
  constexpr std::uint64_t kBlockY = 1;
  constexpr std::uint64_t kThreadX = 31;
  constexpr std::uint64_t kThreadY = 15;
  constexpr std::uint64_t kExpectedId =
      ((kBlockY * kGridSizeX + kBlockX) * 16 * 32) + 15 * 32 + 31;
  constexpr std::uint64_t kId = rng::LinearThreadId(
      kBlockX, kBlockY, kThreadX, kThreadY, kGridSizeX);
  static_assert(kId == kExpectedId);
  static_assert(rng::SeedForInvocation(kId) == kExpectedId);

  constexpr std::size_t kWidth = 7;
  constexpr std::size_t kHeight = 5;
  static_assert(rng::StateWordIndex(0, 0, 0, kWidth, kHeight) == 0);
  static_assert(rng::StateWordIndex(1, 0, 0, kWidth, kHeight) == 35);
  static_assert(rng::StateWordIndex(2, 4, 6, kWidth, kHeight) == 104);

  std::uint32_t state = openmvs_pcg::SeedForPixel(0, 0);
  const std::uint32_t raw = openmvs_pcg::Next(&state);
  if (state != 2254131583u || raw != 1819980427u ||
      FloatBits(openmvs_pcg::UniformFromOutput(raw)) != 0x3ef56516u) {
    return EXIT_FAILURE;
  }

  if (!(openmvs_pcg::UniformFromOutput(0u) == 0.0f) ||
      !(openmvs_pcg::UniformFromOutput(0xffffffffu) < 1.0f)) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
