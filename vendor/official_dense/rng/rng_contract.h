// Copyright (c) 2026, PocketWorld contributors.
//
// SPDX-License-Identifier: BSD-3-Clause
//
// Exact host-side contract for the not-yet-implemented Vulkan translation of
// COLMAP 4.1.1 GpuMatPRNG. This contract must not be treated as an RNG
// implementation. The backend remains unavailable until official CUDA
// sequences have been captured on the 5090 and bit-for-bit parity is proven.

#ifndef POCKETWORLD_OFFICIAL_DENSE_RNG_CONTRACT_H_
#define POCKETWORLD_OFFICIAL_DENSE_RNG_CONTRACT_H_

#include <cstddef>
#include <cstdint>

namespace pocketworld::official_dense::vulkan::rng {

inline constexpr char kUpstreamCommit[] =
    "a0d785fba74b2664f31edc4a29026a8b27c00f67";
inline constexpr char kGpuMatPrngSha256[] =
    "aac48adcc68e558b3634141d327a352895ea90d351c254bce3e7d289f5ffe15f";

// GpuMat<T>::kBlockDimX/Y in the frozen COLMAP source. These are also the
// InitRandomStateKernel launch dimensions.
inline constexpr std::uint32_t kInitBlockSizeX = 32;
inline constexpr std::uint32_t kInitBlockSizeY = 16;
inline constexpr std::uint32_t kInitBlockSizeZ = 1;

inline constexpr std::uint64_t kSubsequence = 0;
inline constexpr std::uint64_t kOffset = 0;

// Mirrors the CUDA id expression exactly. Padding invocations in the final
// workgroup retain their IDs but do not initialize a state outside width/height.
constexpr std::uint64_t LinearThreadId(const std::uint64_t block_x,
                                       const std::uint64_t block_y,
                                       const std::uint64_t thread_x,
                                       const std::uint64_t thread_y,
                                       const std::uint64_t grid_size_x) noexcept {
  const std::uint64_t unique_block_index =
      block_y * grid_size_x + block_x;
  return unique_block_index * kInitBlockSizeY * kInitBlockSizeX +
         thread_y * kInitBlockSizeX + thread_x;
}

// Frozen COLMAP calls curand_init(id, 0, 0, state). Despite the nearby
// upstream comment, id is therefore the seed and not the sequence number.
constexpr std::uint64_t SeedForInvocation(
    const std::uint64_t linear_thread_id) noexcept {
  return linear_thread_id;
}

// Transport layout for captured opaque curandState words. Each state word is
// one complete width*height plane, matching the repository's slice-major
// [slice][row][col] convention.
constexpr std::size_t StateWordIndex(const std::size_t state_word,
                                     const std::size_t row,
                                     const std::size_t col,
                                     const std::size_t width,
                                     const std::size_t height) noexcept {
  return state_word * width * height + row * width + col;
}

// curand_uniform(curandState*) returns an IEEE-754 float in (0, 1]. These
// booleans make the asymmetric endpoints part of the compiled host contract.
inline constexpr bool kCurandUniformLowerExclusive = true;
inline constexpr bool kCurandUniformUpperInclusive = true;

// Consumers must take values from a single per-state stream in program order.
// No buffering, vectorization, rejection-loop flattening, or stage-local
// reseeding is allowed to change the number or order of Next() calls.
class UniformDrawStream {
 public:
  virtual ~UniformDrawStream() = default;
  virtual float Next() = 0;
};

enum class ConsumptionStage : std::uint32_t {
  kFillDepthSlices = 0,
  kInitNormalMarsagliaPairs = 1,
  kSweepPerturbDepth = 2,
  kSweepPerturbNormalAngles = 3,
  kSweepSourceImageSamples = 4,
};

enum class BackendStatus : std::uint32_t {
  kUnavailableUntilCudaXorwowParity = 0,
};

inline constexpr BackendStatus kBackendStatus =
    BackendStatus::kUnavailableUntilCudaXorwowParity;

// Fail closed. This must not become true merely because a golden manifest is
// structurally valid; an exact XORWOW implementation plus bitwise CUDA parity
// evidence is required in a later, separately reviewed change.
constexpr bool CanDispatchRngBackend() noexcept {
  return false;
}

}  // namespace pocketworld::official_dense::vulkan::rng

#endif  // POCKETWORLD_OFFICIAL_DENSE_RNG_CONTRACT_H_
