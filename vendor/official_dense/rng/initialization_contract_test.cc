#include "openmvs_pcg_initialization_reference.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace pcg = pocketworld::official_dense::vulkan::rng::openmvs_pcg;

std::uint32_t FloatBits(const float value) noexcept {
  std::uint32_t bits = 0;
  static_assert(sizeof(bits) == sizeof(value));
  std::memcpy(&bits, &value, sizeof(bits));
  return bits;
}

struct Expected {
  std::uint32_t x;
  std::uint32_t y;
  std::uint32_t final_state;
  std::uint32_t draw_count;
  std::uint32_t rejected_pairs;
  std::uint32_t depth_bits;
  std::uint32_t states[5];
  std::uint32_t raw_outputs[5];
  std::uint32_t uniform_float_bits[5];
};

int main() {
  constexpr Expected kVectors[] = {
      {0u,
       0u,
       4105086997u,
       3u,
       0u,
       0x407db9edu,
       {2254131583u, 1815540432u, 4105086997u, 0u, 0u},
       {1819980427u, 2623117565u, 3416109486u, 0u, 0u},
       {0x3ef56516u, 0x3eb331fau, 0x3f1db1aeu, 0u, 0u}},
      {1u,
       0u,
       3286377542u,
       3u,
       0u,
       0x3fcc206du,
       {187688824u, 2084420317u, 3286377542u, 0u, 0u},
       {808217463u, 1970291471u, 1195860761u, 0u, 0u},
       {0x3e31addcu, 0x3ee0861eu, 0x3e8ec632u, 0u, 0u}},
      {3u,
       0u,
       1724174326u,
       5u,
       1u,
       0x40f9767au,
       {349770602u, 2622180087u, 1648958632u, 1579787725u, 1724174326u},
       {1308180606u, 753894422u, 2832340020u, 911045022u, 886877742u},
       {0x3f79407eu, 0x3f6f8416u, 0x3f521434u, 0x3e9ae33cu, 0x3f5cae2eu}},
      {0xffffffffu,
       0xffffffffu,
       2384231627u,
       3u,
       0u,
       0x408c8325u,
       {3385508197u, 1076951662u, 2384231627u, 0u, 0u},
       {3381184881u, 3711147008u, 3365303310u, 0u, 0u},
       {0x3f08c971u, 0x3e4e7000u, 0x3f16740eu, 0u, 0u}},
  };

  for (const Expected& expected : kVectors) {
    const pcg::InitializationResult observed = pcg::InitializePixel(
        expected.x,
        expected.y,
        0.25f,
        8.0f,
        1.0f,
        0.0f,
        1.0f,
        0.0f);
    if (observed.state != expected.final_state ||
        observed.draw_count != expected.draw_count ||
        observed.rejected_pairs != expected.rejected_pairs ||
        FloatBits(observed.depth) != expected.depth_bits) {
      return EXIT_FAILURE;
    }
    std::uint32_t sequence_state = pcg::SeedForPixel(expected.x, expected.y);
    for (std::uint32_t draw = 0; draw < expected.draw_count; ++draw) {
      const std::uint32_t raw = pcg::Next(&sequence_state);
      if (sequence_state != expected.states[draw] ||
          raw != expected.raw_outputs[draw] ||
          FloatBits(pcg::UniformFromOutput(raw)) !=
              expected.uniform_float_bits[draw]) {
        return EXIT_FAILURE;
      }
    }
  }

  // Pixel (3,0) is the fixed rejection sentinel: the depth draw is followed
  // by one rejected Marsaglia pair and then one accepted pair.
  std::uint32_t state = pcg::SeedForPixel(3u, 0u);
  constexpr std::uint32_t kStates[] = {
      349770602u,
      2622180087u,
      1648958632u,
      1579787725u,
      1724174326u,
  };
  for (const std::uint32_t expected_state : kStates) {
    static_cast<void>(pcg::Next(&state));
    if (state != expected_state) {
      return EXIT_FAILURE;
    }
  }
  return EXIT_SUCCESS;
}
