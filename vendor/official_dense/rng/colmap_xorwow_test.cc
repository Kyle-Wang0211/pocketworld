#include "colmap_xorwow_reference.h"

#include <cstdint>
#include <cstdlib>

namespace xorwow =
    pocketworld::official_dense::vulkan::rng::colmap_xorwow;

constexpr bool Equal(const xorwow::State& left,
                     const xorwow::State& right) noexcept {
  return left.v0 == right.v0 && left.v1 == right.v1 &&
         left.v2 == right.v2 && left.v3 == right.v3 &&
         left.v4 == right.v4 && left.d == right.d;
}

int main() {
  xorwow::State seed_zero = xorwow::Initialize(0U);
  const std::uint32_t first = xorwow::Next(&seed_zero);
  if (first != 3179217846U) return EXIT_FAILURE;

  const xorwow::State expected_after_first = {
      0x455f2458U, 0xf8a42704U, 0xdcd8f87cU,
      0x511db0d6U, 0x92bd2e1cU, 0x2ac1d59aU};
  if (!Equal(seed_zero, expected_after_first)) return EXIT_FAILURE;

  xorwow::State seed_one = xorwow::Initialize(1U);
  if (xorwow::Next(&seed_one) != 2898200796U) return EXIT_FAILURE;

  xorwow::State seed_512 = xorwow::Initialize(512U);
  if (xorwow::Next(&seed_512) != 1627530550U) return EXIT_FAILURE;

  const float minimum = xorwow::UniformFromOutput(0U);
  const float maximum = xorwow::UniformFromOutput(0xffffffffU);
  if (!(minimum > 0.0F) || maximum != 1.0F) return EXIT_FAILURE;
  return EXIT_SUCCESS;
}
