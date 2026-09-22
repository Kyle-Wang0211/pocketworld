// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <cstdlib>
#include "vulkan_runtime.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <type_traits>
#include <utility>
#include <vector>

#include "../cost_ops/sampler_contract.h"
#include "../rng/rng_contract.h"
#include "../sweep/sweep_contract.h"

#if !defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)
#include <vulkan/vulkan.h>
#endif

namespace pocketworld::official_dense::vulkan::runtime {
namespace {

constexpr std::uint32_t kSpirvMagic = 0x07230203U;

constexpr std::array<std::uint32_t, 64> kSha256Round = {{
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU,
    0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U,
    0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U,
    0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U,
    0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
    0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
    0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U,
    0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U, 0x1e376c08U,
    0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU,
    0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
}};

constexpr std::uint32_t RotR(const std::uint32_t x,
                             const std::uint32_t n) noexcept {
  return (x >> n) | (x << (32U - n));
}

std::array<char, 65> Sha256Hex(const void *const input,
                              const std::size_t size) {
  const auto *bytes = static_cast<const std::uint8_t *>(input);
  const std::size_t padded = ((size + 9U + 63U) / 64U) * 64U;
  std::vector<std::uint8_t> message(padded, 0U);
  std::copy(bytes, bytes + size, message.begin());
  message[size] = 0x80U;
  const std::uint64_t bits = static_cast<std::uint64_t>(size) * 8U;
  for (std::size_t i = 0; i < 8; ++i)
    message[padded - 1U - i] = static_cast<std::uint8_t>(bits >> (8U * i));
  std::array<std::uint32_t, 8> h = {{
      0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
      0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
  }};
  for (std::size_t block = 0; block < padded; block += 64U) {
    std::array<std::uint32_t, 64> w{};
    for (std::size_t i = 0; i < 16; ++i) {
      const std::size_t p = block + i * 4U;
      w[i] = static_cast<std::uint32_t>(message[p]) << 24U |
             static_cast<std::uint32_t>(message[p + 1U]) << 16U |
             static_cast<std::uint32_t>(message[p + 2U]) << 8U |
             static_cast<std::uint32_t>(message[p + 3U]);
    }
    for (std::size_t i = 16; i < 64; ++i) {
      const std::uint32_t s0 =
          RotR(w[i - 15U], 7U) ^ RotR(w[i - 15U], 18U) ^ (w[i - 15U] >> 3U);
      const std::uint32_t s1 =
          RotR(w[i - 2U], 17U) ^ RotR(w[i - 2U], 19U) ^ (w[i - 2U] >> 10U);
      w[i] = w[i - 16U] + s0 + w[i - 7U] + s1;
    }
    std::uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4],
                  f = h[5], g = h[6], hh = h[7];
    for (std::size_t i = 0; i < 64; ++i) {
      const std::uint32_t s1 = RotR(e, 6U) ^ RotR(e, 11U) ^ RotR(e, 25U);
      const std::uint32_t ch = (e & f) ^ (~e & g);
      const std::uint32_t t1 = hh + s1 + ch + kSha256Round[i] + w[i];
      const std::uint32_t s0 = RotR(a, 2U) ^ RotR(a, 13U) ^ RotR(a, 22U);
      const std::uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
      const std::uint32_t t2 = s0 + maj;
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }
  constexpr char hex[] = "0123456789abcdef";
  std::array<char, 65> output{};
  for (std::size_t i = 0; i < h.size(); ++i) {
    for (std::size_t nibble = 0; nibble < 8; ++nibble) {
      const std::uint32_t shift = static_cast<std::uint32_t>((7U - nibble) * 4U);
      output[i * 8U + nibble] = hex[(h[i] >> shift) & 0xFU];
    }
  }
  return output;
}

// 🔴 [2026-08-30] 这是**第三处**独立的 shader 哈希锁,与另外两处并列:
//   ① vulkan_shader_bundle/frozen_manifest.json —— 冻结脚本的预期值
//   ② build gate 生成的 generated/shaders/manifest.json —— 编译产物记录
//   ③ 本表 —— 运行时 ValidShaderBundle() 的准绳,fail-closed
// 三者必须同步更新,漏掉本表 ⇒ 运行时报
// "shader, resource, dimension, or image contract is invalid" 并拒绝执行。
// 更新入口统一走 ~/Developer/dense-bench-20260830/bench.sh(它三处一起改),
// 不要手改单处。
constexpr std::array<ShaderManifestEntry, kShaderCount> kShaderManifest = {{
    {PipelineKind::kReferenceFilter, "ref_filter/filter_u8.comp",
     "1c4509178d96df841d64b0c0263b2ebee6915a40f46448be5ba3336aa4d317c7",
     "76fc218d29b687c8aeec4bf5e16321343b93fd01f8e0c58c0774f8f03606108b"},
    {PipelineKind::kOpenMvsPcgInitialize, "rng/init_openmvs_pcg.comp",
     "5eb75c051603b345022f34023be5162e0c49c025b4c477d21e860094f0eaa03a",
     "302ebac4f548cf82d8a5bf9a802ffd075ea7815d2063a217ce43d6a7d5f30bd5"},
    {PipelineKind::kNormalInitialize,
     "normal_ops/init_normal_openmvs_pcg.comp",
     "9618000ea831ff3bfa320ee1d7229a11995eccb3111fb8cae3ef1889cc727d2c",
     "0c22b933e6b97e535d313ed4915adcba27ef9de6dd6232a974a7feacf55c79e2"},
    {PipelineKind::kInitialCost, "initial_cost/compute_initial_cost.comp",
     "46b10170e6458567f35e765f4ff0fa1360dd450e2713e7d7e85e20627a73c031",
     "dbc5ae3c6eef1b4eea88142dac320ccf408cf8987ff873d8e151262320e5923b"},
    {PipelineKind::kFullSweep, "sweep/sweep_full_openmvs_pcg.comp",
     "08dfb3bbdb01815b268c9df499a8e7a1550b5f5750a790d127d549d39710fccd",
     "08c91449b3db423d12e2f93cb47554196b8c8f096d137ad922797d0d0ba2ccfb"},
    {PipelineKind::kRotateF32, "mat_ops/rotate_f32.comp",
     "c43fcf5352d3d19b62941552c71ca2b859dd88b295acc5dd10d1d5321e536875",
     "79d470e058b178fee1fc562e27c9f92a3d720f2423d28064979077fae5fea693"},
    {PipelineKind::kTransposeF32, "mat_ops/transpose_f32.comp",
     "2a077c8a0181f1d8f28b3de6402e9245448d37523167c1686a981113af419dd7",
     "5dfae3d47e84f9d99a1d9ea8855cd5b8b524911b2f37d75a6162ae8966f0c64f"},
    {PipelineKind::kFlipHorizontalF32, "mat_ops/flip_horizontal_f32.comp",
     "536cd7273d9c322d005600549d0e6e0f0138e8cff03681ffc14d1d193d629550",
     "64e37d36d8ea3df31f230c25dfcaa9d25449071a4be7b97e9f37114f689c06b8"},
    {PipelineKind::kRotateNormalF32, "normal_ops/rotate_normal_f32.comp",
     "79a8f655932415a14f0dbf52e1b35839b23a0a85f09f34b9b75e1e0848e1b5bd",
     "9cd47fc696e92f1564309ad7dba395f5b2b126258736c2c47c8a8d1d463401a4"},
    {PipelineKind::kOpenMvsPcgDepthInitialize,
     "depth_ops/init_depth_openmvs_pcg.comp",
     "6b1016d9dfe2d669d73a8746efe0e83f94886e55febea2fe58f6591c018f5182",
     "b546f066db24189b6e3ab1afb0d4a8230add1d74a0d4df210f6b8b75799add86"},
    {PipelineKind::kRotateU32, "mat_ops/rotate_u32.comp",
     "aed3b6a644898a3255828b58e5a7d0a1a16aad6fa2324dd6396a2623fc003d16",
     "c9cd296fbfd321fdd3cb67fcb007624fd9692451a1ce93d3e023ccca994a472a"},
}};

#if defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)
// Test binaries are deliberately distinct per pipeline. These are trusted
// compile-time identities for the fake backend only; no caller-provided digest
// participates in acceptance.
constexpr std::array<const char *, kShaderCount> kTestingSpirvSha256 = {{
    "98065727a1ab8303a0aa274573c4eec46a0204fb1ba3f0193d549131308a340a",
    "9f61793541d3852e36c6056728b7b007d892989644911551488c1ed40b9154be",
    "4febb2e86d2c6756914810a820a95efbf0ff173621ecb856aa3f096ac03453b2",
    "10071813afca34413639b7174d3754886e7ea97ae10a4472ce3b2eb959853f5a",
    "d8abcd23d66a4b7e4624a2f9490f7b0e62f73950454db694eb50a19ff5c364d7",
    "d86be861de0bf8530325ad1aa0e82bf88756a963c10cc3069f6f1b2f3b4674d6",
    "e81c55506479a0b796da86537d1db84af6d8ad02866b5f5f2d312fc6038e54e7",
    "2d1006ee684f97673f7b289926235851a73f165abe920ab0a54d45d2296b8a9a",
    "71bf93a148ebf348d37e6ed17532c36caf1103c6b774dd17d7ded81c23d1eefd",
    "953b9d6c9bf73a2c7b72119ae07645ff95c562bbf63b77ce7970782995f14e83",
    "60bf00ff6716d1c29188279923e54fd609b10d64295c2b92f4ba2e389af6d054",
}};
#endif

struct Write {
  std::uint32_t shader_binding = 0;
  bool combined_image_sampler = false;
  BoundResource resource;
};

class Backend {
public:
  virtual ~Backend() = default;
  virtual bool CreatePipeline(PipelineKind kind,
                              const ShaderBinary &binary) noexcept = 0;
  virtual bool Begin() noexcept = 0;
  virtual bool AllocateAndBindDescriptorSet(PipelineKind kind,
                                            const Write *writes,
                                            std::size_t count) noexcept = 0;
  virtual bool BindAndDispatch(PipelineKind kind,
                               std::uint32_t specialization_mask,
                               const void *push_constants,
                               std::size_t push_constant_size, std::uint32_t x,
                               std::uint32_t y, std::uint32_t z) noexcept = 0;
  virtual bool BindAndDispatchPartitioned(
      PipelineKind kind, std::uint32_t specialization_mask,
      const void *push_constants, std::size_t push_constant_size,
      std::uint32_t x, std::uint32_t y, std::uint32_t z) noexcept = 0;
  virtual bool PipelineBarrier() noexcept = 0;
  virtual bool CopyBuffer(std::uint64_t source, std::uint64_t source_offset,
                          std::uint64_t destination,
                          std::uint64_t destination_offset,
                          std::uint64_t byte_count) noexcept = 0;
  virtual bool TransitionSampledImage(std::uint64_t image,
                                      bool to_transfer_destination) noexcept = 0;
  virtual bool ClearSampledImageFloat(std::uint64_t image,
                                      float value) noexcept = 0;
  virtual bool CopyBufferToImage(std::uint64_t source,
                                 std::uint64_t source_offset,
                                 std::uint64_t destination_image,
                                 std::uint32_t destination_layer,
                                 std::uint32_t width,
                                 std::uint32_t height,
                                 std::uint32_t bytes_per_texel) noexcept = 0;
  virtual bool FillBuffer(std::uint64_t buffer, std::uint64_t offset,
                          std::uint64_t byte_count,
                          std::uint32_t value) noexcept = 0;
  virtual bool CopyBufferRotatedU32(std::uint64_t source,
                                    std::uint64_t source_offset,
                                    std::uint64_t destination,
                                    std::uint64_t destination_offset,
                                    std::uint32_t width, std::uint32_t height,
                                    std::uint32_t layers) noexcept = 0;
  virtual bool SubmitWaitAndContinue() noexcept = 0;
  virtual bool EndSubmitAndWait() noexcept = 0;
};

template <typename ResetCommandBuffer, typename BeginCommandBuffer>
bool ResetThenBeginCommandBuffer(ResetCommandBuffer &&reset,
                                 BeginCommandBuffer &&begin) noexcept {
  if (!reset())
    return false;
  return begin();
}

struct Certifications {
  bool pcg = false;
  bool texture = false;
  bool full_sweep = false;
};

constexpr std::uint32_t DivideRoundUp(const std::uint32_t value,
                                      const std::uint32_t divisor) noexcept {
  return value / divisor + static_cast<std::uint32_t>(value % divisor != 0U);
}

[[maybe_unused]] constexpr std::uint32_t
PackSweepRowRange(const std::uint32_t begin, const std::uint32_t end,
                  const bool backward) noexcept {
  return begin | (end << 16U) | (backward ? 0x80000000U : 0U);
}

bool ValidShaderBundle(const ShaderBundle &bundle) noexcept {
  constexpr std::size_t kMaximumShaderWords = 4U * 1024U * 1024U;
  for (std::size_t index = 0; index < kShaderCount; ++index) {
    const ShaderBinary &binary = bundle.binaries[index];
    const char *expected_spirv_sha256 = kShaderManifest[index].spirv_sha256;
#if defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)
    expected_spirv_sha256 = kTestingSpirvSha256[index];
#endif
    if (binary.kind != kShaderManifest[index].kind || binary.words == nullptr ||
        binary.word_count < 5 || binary.words[0] != kSpirvMagic ||
        binary.word_count > kMaximumShaderWords ||
        binary.source_sha256 == nullptr || expected_spirv_sha256 == nullptr ||
        std::strcmp(binary.source_sha256,
                    kShaderManifest[index].source_sha256) != 0 ||
        Sha256Hex(binary.words, binary.word_count * sizeof(std::uint32_t)) !=
            [expected_spirv_sha256]() {
              std::array<char, 65> expected{};
              std::copy(expected_spirv_sha256,
                        expected_spirv_sha256 + 64U,
                        expected.begin());
              return expected;
            }()) {
      return false;
    }
  }
  return true;
}

bool ValidResource(const BoundResource &resource) noexcept {
  return resource.buffer != 0 && resource.range != 0 &&
         resource.offset <=
             std::numeric_limits<std::uint64_t>::max() - resource.range &&
         resource.array_layers != 0 && resource.element_size == 4 &&
         resource.range % resource.array_layers == 0;
}

bool BufferRangesOverlap(const BoundResource &left,
                         const BoundResource &right) noexcept {
  if (left.buffer == 0 || right.buffer == 0 || left.buffer != right.buffer)
    return false;
  return left.offset < right.offset + right.range &&
         right.offset < left.offset + left.range;
}

bool ValidSampler(const BoundResource &resource,
                  const std::uint32_t binding) noexcept {
  if (resource.image_view == 0 || resource.sampler == 0 ||
      resource.sampler_metadata.address_u !=
          SamplerAddressMode::kClampToBorder ||
      resource.sampler_metadata.address_v !=
          SamplerAddressMode::kClampToBorder ||
      resource.sampler_metadata.border_color !=
          SamplerBorderColor::kFloatTransparentBlack ||
      !resource.sampler_metadata.normalized_coordinates) {
    return false;
  }
  if (binding == 12) {
    return resource.sampler_metadata.format == SamplerFormat::kR32Sfloat &&
           resource.sampler_metadata.min_filter == SamplerFilter::kNearest &&
           resource.sampler_metadata.mag_filter == SamplerFilter::kNearest;
  }
  return binding == 14 &&
         resource.sampler_metadata.format == SamplerFormat::kR8Unorm &&
         resource.sampler_metadata.min_filter == SamplerFilter::kLinear &&
         resource.sampler_metadata.mag_filter == SamplerFilter::kLinear;
}

bool SameSamplerMetadata(const SamplerMetadata &left,
                         const SamplerMetadata &right) noexcept {
  return left.format == right.format && left.min_filter == right.min_filter &&
         left.mag_filter == right.mag_filter &&
         left.address_u == right.address_u &&
         left.address_v == right.address_v &&
         left.border_color == right.border_color &&
         left.normalized_coordinates == right.normalized_coordinates;
}

bool CheckedProduct(const std::size_t left, const std::size_t right,
                    std::size_t *const product) noexcept {
  if (product == nullptr ||
      (left != 0 && right > std::numeric_limits<std::size_t>::max() / left)) {
    return false;
  }
  *product = left * right;
  return true;
}

bool CheckedProductU64(const std::uint64_t left, const std::uint64_t right,
                       std::uint64_t *const product) noexcept {
  if (product == nullptr ||
      (left != 0U &&
       right > std::numeric_limits<std::uint64_t>::max() / left)) {
    return false;
  }
  *product = left * right;
  return true;
}

bool SourcePlaneByteCounts(const PatchPC &patch,
                           std::uint64_t *const gray_buffer_bytes,
                           std::uint64_t *const gray_image_bytes,
                           std::uint64_t *const depth_plane_bytes) noexcept {
  std::uint64_t pixels = 0;
  std::uint64_t layered_pixels = 0;
  if (!CheckedProductU64(patch.source_width, patch.source_height, &pixels) ||
      !CheckedProductU64(pixels, patch.num_sources, &layered_pixels) ||
      !CheckedProductU64(layered_pixels, sizeof(std::uint32_t),
                         gray_buffer_bytes) ||
      !CheckedProductU64(pixels, sizeof(float), depth_plane_bytes)) {
    return false;
  }
  *gray_image_bytes = layered_pixels;
  return true;
}

const ModeResources &ResourcesFor(const ImageResources &image,
                                  const Mode mode) noexcept {
  return mode == Mode::kPhotometric ? image.photometric : image.geometric;
}

bool ValidModeResources(const ModeResources &resources) noexcept {
  for (std::size_t binding = 0; binding < kBindingCount; ++binding) {
    for (std::uint32_t rotation = 0; rotation < 4; ++rotation) {
      const BoundResource &resource = resources.bindings[binding][rotation];
      if (binding != 12 && !ValidResource(resource))
        return false;
      if ((binding == 12 || binding == 14) &&
          !ValidSampler(resource, static_cast<std::uint32_t>(binding))) {
        return false;
      }
      const bool should_be_uint = binding == 5 || binding == 6 ||
                                  binding == 8 || binding == 9 || binding == 14;
      if (binding != 12 && (resource.scalar_type ==
                            ResourceScalarType::kUint32) != should_be_uint) {
        return false;
      }
    }
  }
  const BoundResource &depth_zero = resources.bindings[12][0];
  const BoundResource &gray_zero = resources.bindings[14][0];
  for (std::uint32_t rotation = 0; rotation < 4; ++rotation) {
    const BoundResource &depth = resources.bindings[12][rotation];
    const BoundResource &gray = resources.bindings[14][rotation];
    if (depth.image != depth_zero.image ||
        depth.image_view != depth_zero.image_view ||
        depth.sampler != depth_zero.sampler ||
        depth.array_layers != depth_zero.array_layers ||
        depth.range != depth_zero.range ||
        depth.content_identity != depth_zero.content_identity ||
        !SameSamplerMetadata(depth.sampler_metadata,
                             depth_zero.sampler_metadata) ||
        gray.buffer != gray_zero.buffer || gray.offset != gray_zero.offset ||
        gray.image != gray_zero.image ||
        gray.image_view != gray_zero.image_view ||
        gray.sampler != gray_zero.sampler ||
        gray.array_layers != gray_zero.array_layers ||
        gray.range != gray_zero.range ||
        gray.content_identity != gray_zero.content_identity ||
        !SameSamplerMetadata(gray.sampler_metadata,
                             gray_zero.sampler_metadata) ||
        depth.image == gray.image) {
      return false;
    }
  }
  // [ROT-2 2026-08-30] 这里原本要求 4 个 rotation 的 buffer **两两不同**。
  // 那比真正需要的不变量强:官方 PatchMatchCuda::Rotate()
  // (patch_match_cuda.cu:1810) 每次只 new **一个**临时目标,rotate 后 swap,
  // 旧的随 unique_ptr 立刻析构 ⇒ 官方自己的活跃集也只有 {当前, 目标} 两份。
  //
  // 枚举证据(rot_liveness.cc,对 kPhotometricOnly 273 步 / kFull 552 步全量):
  // 出现过的 (rotation_before → rotation_after) 组合只有
  //   (0→0)(0→1)(1→1)(1→2)(2→2)(2→3)(3→0)(3→3)
  // 非相邻步骤数 = 0。即任何一步引用的 rotation 只可能是 {r} 或 {r, r+1}。
  //
  // 因此 rotation 0/2 与 1/3 各自复用一块物理缓冲是安全的
  // (奇偶同尺寸:偶数轮 W×H,奇数轮 H×W,见 resource_arena_plan.cc:234)。
  // 校验相应收紧为**相邻两轮必须不同**——这仍然 fail-closed,
  // 且恰好挡住真正的错误(把 rotate 的源和目标别名到同一块)。
  constexpr std::array<std::uint32_t, 10> kRotatedBindings = {
      0U, 1U, 2U, 3U, 4U, 5U, 6U, 9U, 10U, 11U};
  for (const std::uint32_t binding : kRotatedBindings) {
    for (std::uint32_t rotation = 0; rotation < 4; ++rotation) {
      const std::uint32_t next = (rotation + 1U) & 3U;
      if (resources.bindings[binding][rotation].buffer ==
          resources.bindings[binding][next].buffer) {
        return false;
      }
    }
  }
  if (!ValidResource(resources.reference_upload_staging) ||
      !ValidResource(resources.source_gray_upload_staging) ||
      !ValidResource(resources.source_gray_image_upload_staging) ||
      !ValidResource(resources.depth_readback) ||
      !ValidResource(resources.normal_readback) ||
      !ValidResource(resources.mask_readback) ||
      resources.reference_transfer_byte_count == 0 ||
      resources.source_gray_transfer_byte_count == 0 ||
      resources.source_gray_image_transfer_byte_count == 0 ||
      resources.reference_transfer_byte_count > resources.bindings[8][0].range ||
      resources.reference_transfer_byte_count >
          resources.reference_upload_staging.range ||
      resources.source_gray_transfer_byte_count >
          resources.source_gray_upload_staging.range ||
      resources.source_gray_image_transfer_byte_count >
          resources.source_gray_image_upload_staging.range ||
      resources.source_gray_transfer_byte_count >
          resources.bindings[14][0].range ||
      resources.source_gray_upload_staging.content_identity == 0 ||
      resources.source_gray_upload_staging.content_identity !=
          resources.source_gray_image_upload_staging.content_identity ||
      resources.source_gray_upload_staging.content_identity !=
          resources.bindings[14][0].content_identity ||
      resources.depth_readback.range < resources.bindings[0][0].range ||
      resources.normal_readback.range < resources.bindings[1][0].range ||
      resources.mask_readback.range < resources.bindings[5][0].range) {
    return false;
  }
  for (std::uint32_t rotation = 0; rotation < 4; ++rotation) {
    // [ROT-2] 同上:两两不同 → 相邻不同。同一轮内 3 与 4 必须仍是两块
    // (它们在同一次 dispatch 里同时被读写),这条一个字都没放松。
    const std::uint32_t next = (rotation + 1U) & 3U;
    if (resources.bindings[3][rotation].buffer ==
            resources.bindings[3][next].buffer ||
        resources.bindings[4][rotation].buffer ==
            resources.bindings[4][next].buffer) {
      return false;
    }
    if (resources.bindings[3][rotation].buffer ==
        resources.bindings[4][rotation].buffer) {
      return false;
    }
    constexpr std::array<std::uint32_t, 14> kBufferBindings = {
        0U, 1U, 2U, 3U, 4U, 5U, 6U, 7U, 8U, 9U, 10U, 11U, 13U, 14U};
    for (std::size_t index = 0; index < kBufferBindings.size(); ++index) {
      for (std::size_t other = index + 1U; other < kBufferBindings.size();
           ++other) {
        if (BufferRangesOverlap(
                resources.bindings[kBufferBindings[index]][rotation],
                resources.bindings[kBufferBindings[other]][rotation]))
          return false;
      }
    }
  }
  return true;
}

bool ValidRequest(const RecordRequest &request) noexcept {
  if (request.plan == nullptr || !request.plan->Validate() ||
      request.images == nullptr || request.image_count == 0 ||
      request.image_count != request.plan->image_count ||
      !ValidShaderBundle(request.shaders) || request.window_radius != 5 ||
      request.window_step != 1) {
    return false;
  }
  const bool needs_photometric =
      request.plan->phase == PlanPhase::kFull ||
      request.plan->phase == PlanPhase::kPhotometricOnly;
  const bool needs_geometric = request.plan->phase == PlanPhase::kFull ||
                               request.plan->phase == PlanPhase::kGeometricOnly;
  for (std::size_t image = 0; image < request.image_count; ++image) {
    const ImageResources &resources = request.images[image];
    if ((needs_photometric && !ValidModeResources(resources.photometric)) ||
        (needs_geometric && !ValidModeResources(resources.geometric)) ||
        (needs_photometric && needs_geometric &&
         (resources.photometric.bindings[0][0].buffer ==
            resources.geometric.bindings[0][0].buffer ||
          resources.photometric.bindings[1][0].buffer ==
            resources.geometric.bindings[1][0].buffer ||
          resources.photometric.bindings[0][0].range >
            resources.geometric.bindings[0][0].range ||
          resources.photometric.bindings[1][0].range >
            resources.geometric.bindings[1][0].range ||
          resources.photometric.bindings[12][0].image ==
            resources.photometric.bindings[14][0].image ||
          resources.geometric.bindings[12][0].image ==
              resources.geometric.bindings[14][0].image))) {
      return false;
    }
    const PatchPC &base = resources.calibration[0].patch;
    // [BATCH-REF] base(PatchPC)描述的是**一个** reference:
    // width/height/num_sources 是 shader 用的 stride,一个字都不能乘 N。
    // 而 arena 里每个缓冲、纹理层、逐层拷贝清单都是 N 份首尾相接。
    const std::uint64_t batch =
        request.batch_count == 0U ? 1U : request.batch_count;
    const std::uint64_t batched_source_layers =
        static_cast<std::uint64_t>(base.num_sources) * batch;
    if (base.width == 0 || base.height == 0 || base.num_sources == 0 ||
        base.source_width == 0 || base.source_height == 0 ||
        base.workspace_max_dim < std::max(base.width, base.height) ||
        (needs_geometric &&
         (resources.consistency_graph.source_image_indices == nullptr ||
          // [BATCH-REF] 一致性图的源清单是**每 reference** 的(它是 stride);
          // 逐层拷贝清单则是 N 份首尾相接,层号 = ref*num_sources + source。
          resources.consistency_graph.source_image_count !=
              batched_source_layers ||
          resources.source_depth_layers == nullptr ||
          resources.source_depth_layer_count != batched_source_layers))) {
      return false;
    }

    std::uint64_t expected_gray_buffer_bytes = 0;
    std::uint64_t expected_gray_image_bytes = 0;
    std::uint64_t expected_depth_plane_bytes = 0;
    if (!SourcePlaneByteCounts(base, &expected_gray_buffer_bytes,
                               &expected_gray_image_bytes,
                               &expected_depth_plane_bytes)) {
      return false;
    }
    // [BATCH-REF] 期望字节数按 N 放大。
    if (!CheckedProductU64(expected_gray_buffer_bytes, batch,
                           &expected_gray_buffer_bytes) ||
        !CheckedProductU64(expected_gray_image_bytes, batch,
                           &expected_gray_image_bytes) ||
        !CheckedProductU64(expected_depth_plane_bytes, batch,
                           &expected_depth_plane_bytes)) {
      return false;
    }
    const ModeResources &geometric_resources = resources.geometric;
    const BoundResource &external_depth_staging =
        geometric_resources.source_depth_upload_staging;
    const bool has_external_source_depth =
        needs_geometric && ValidResource(external_depth_staging);
    const bool split_geometric =
        request.plan->phase == PlanPhase::kGeometricOnly;
    const BoundResource &reference_depth_staging =
        geometric_resources.reference_depth_upload_staging;
    const BoundResource &reference_normal_staging =
        geometric_resources.reference_normal_upload_staging;
    std::uint64_t expected_layered_depth_bytes = 0;
    std::uint64_t expected_reference_normal_bytes = 0;
    if (!CheckedProductU64(expected_depth_plane_bytes, base.num_sources,
                           &expected_layered_depth_bytes) ||
        !CheckedProductU64(expected_depth_plane_bytes, 3U,
                           &expected_reference_normal_bytes) ||
        (split_geometric &&
         (!has_external_source_depth ||
          !ValidResource(reference_depth_staging) ||
          !ValidResource(reference_normal_staging) ||
          reference_depth_staging.scalar_type !=
              ResourceScalarType::kFloat32 ||
          reference_normal_staging.scalar_type !=
              ResourceScalarType::kFloat32 ||
          reference_depth_staging.content_identity == 0U ||
          reference_normal_staging.content_identity == 0U ||
          reference_depth_staging.content_identity !=
              geometric_resources.bindings[0][0].content_identity ||
          reference_normal_staging.content_identity !=
              geometric_resources.bindings[1][0].content_identity ||
          reference_depth_staging.range < expected_depth_plane_bytes ||
          reference_normal_staging.range < expected_reference_normal_bytes ||
          geometric_resources.reference_depth_transfer_byte_count !=
              expected_depth_plane_bytes ||
          geometric_resources.reference_normal_transfer_byte_count !=
              expected_reference_normal_bytes)) ||
        (has_external_source_depth &&
         (external_depth_staging.scalar_type != ResourceScalarType::kFloat32 ||
          external_depth_staging.content_identity == 0U ||
          external_depth_staging.content_identity !=
              geometric_resources.bindings[12][0].content_identity ||
          external_depth_staging.range < expected_layered_depth_bytes ||
          geometric_resources.source_depth_transfer_byte_count !=
              expected_layered_depth_bytes))) {
      return false;
    }
    for (const Mode mode : {Mode::kPhotometric, Mode::kGeometric}) {
      if ((mode == Mode::kPhotometric && !needs_photometric) ||
          (mode == Mode::kGeometric && !needs_geometric)) {
        continue;
      }
      const ModeResources &mode_resources = ResourcesFor(resources, mode);
      const BoundResource &source_gray = mode_resources.bindings[14][0];
      const BoundResource &source_depth = mode_resources.bindings[12][0];
      if (mode_resources.source_gray_transfer_byte_count !=
              expected_gray_buffer_bytes ||
          mode_resources.source_gray_image_transfer_byte_count !=
              expected_gray_image_bytes ||
          mode_resources.source_gray_upload_staging.range <
              expected_gray_buffer_bytes ||
          mode_resources.source_gray_image_upload_staging.range <
              expected_gray_image_bytes ||
          source_gray.range < expected_gray_buffer_bytes ||
          source_gray.array_layers != batched_source_layers ||
          source_depth.range < expected_layered_depth_bytes ||
          source_depth.array_layers != batched_source_layers) {
        return false;
      }
    }

    std::size_t pixel_count = 0;
    std::size_t mask_word_count = 0;
    std::size_t max_graph_value_count = 0;
    const ConsistencyGraphReadback &graph = resources.consistency_graph_readback;
    // [BATCH-REF] 一致性掩码与图的值都是每 reference 一份 ⇒ 按 N 放大。
    if (!CheckedProduct(base.width, base.height, &pixel_count) ||
        !CheckedProduct(pixel_count, base.num_sources, &mask_word_count) ||
        !CheckedProduct(mask_word_count, static_cast<std::size_t>(batch),
                        &mask_word_count) ||
        !CheckedProduct(pixel_count,
                        static_cast<std::size_t>(base.num_sources) + 3U,
                        &max_graph_value_count) ||
        !CheckedProduct(max_graph_value_count, static_cast<std::size_t>(batch),
                        &max_graph_value_count) ||
        (needs_geometric &&
         (!graph.host_coherent || graph.mapped_mask_words == nullptr ||
          graph.mapped_mask_word_count != mask_word_count ||
          graph.values == nullptr || graph.value_count == nullptr ||
          graph.value_capacity < max_graph_value_count))) {
      return false;
    }
    for (std::uint32_t rotation = 0; rotation < 4; ++rotation) {
      const RotationCalibration &calibration = resources.calibration[rotation];
      const bool swapped = (rotation & 1U) != 0;
      if (!ValidResource(calibration.active_pose_table) ||
          !ValidResource(calibration.pose_upload_staging) ||
          calibration.active_pose_table.content_identity == 0 ||
          calibration.active_pose_table.content_identity !=
              calibration.pose_upload_staging.content_identity ||
          calibration.patch.width != (swapped ? base.height : base.width) ||
          calibration.patch.height != (swapped ? base.width : base.height) ||
          calibration.patch.num_sources != base.num_sources ||
          calibration.patch.workspace_max_dim != base.workspace_max_dim ||
          calibration.patch.source_width != base.source_width ||
          calibration.patch.source_height != base.source_height ||
          calibration.patch.rotation_0_to_3 != rotation ||
          calibration.active_pose_table.range <
              static_cast<std::uint64_t>(
                  kPoseFloatsPerReference(base.num_sources)) *
                  sizeof(float) * batch ||
          calibration.pose_upload_staging.range <
              static_cast<std::uint64_t>(
                  kPoseFloatsPerReference(base.num_sources)) *
                  sizeof(float) * batch) {
        return false;
      }
      for (const Mode mode : {Mode::kPhotometric, Mode::kGeometric}) {
        if ((mode == Mode::kPhotometric && !needs_photometric) ||
            (mode == Mode::kGeometric && !needs_geometric)) {
          continue;
        }
        const ModeResources &mode_resources = ResourcesFor(resources, mode);
        for (const std::uint32_t binding :
             {0U, 1U, 2U, 3U, 4U, 5U, 6U, 9U, 10U, 11U}) {
          const BoundResource &bound =
              mode_resources.bindings[binding][rotation];
          std::uint64_t minimum = 0;
          if (!CheckedProductU64(calibration.patch.width,
                                 calibration.patch.height, &minimum) ||
              !CheckedProductU64(minimum, bound.array_layers, &minimum) ||
              !CheckedProductU64(minimum, sizeof(std::uint32_t), &minimum) ||
              bound.range < minimum) {
            return false;
          }
          // [BATCH-REF] binding 6 是 xorwow RNG 状态,每像素 6 个 uint32。
          // 批处理后是 N 份首尾相接 ⇒ 层数 6*N。
          if (binding == 6U &&
              (bound.array_layers != 6U * batch || bound.range != minimum)) {
            return false;
          }
        }
        const BoundResource &workspace = mode_resources.bindings[7][rotation];
        std::uint64_t minimum_workspace = 0;
        if (!CheckedProductU64(base.workspace_max_dim, base.num_sources,
                               &minimum_workspace) ||
            !CheckedProductU64(minimum_workspace, 2U, &minimum_workspace) ||
            !CheckedProductU64(minimum_workspace, sizeof(float),
                               &minimum_workspace) ||
            !CheckedProductU64(minimum_workspace, batch,
                               &minimum_workspace) ||
            workspace.range < minimum_workspace ||
            // [BATCH-REF] 每个「每 reference 一层」的量都变成 N 份。
            mode_resources.bindings[1][rotation].array_layers !=
                kNormalPlaneCount * batch ||
            mode_resources.bindings[2][rotation].array_layers !=
                batched_source_layers ||
            mode_resources.bindings[3][rotation].array_layers !=
                batched_source_layers ||
            mode_resources.bindings[4][rotation].array_layers !=
                batched_source_layers ||
            mode_resources.bindings[5][rotation].array_layers !=
                batched_source_layers ||
            mode_resources.bindings[12][rotation].array_layers !=
                batched_source_layers ||
            mode_resources.bindings[14][rotation].array_layers !=
                batched_source_layers ||
            mode_resources.bindings[12][rotation].image == 0 ||
            mode_resources.bindings[14][rotation].image == 0) {
          return false;
        }
      }
    }
    for (std::size_t layer = 0U;
         needs_geometric && layer < resources.source_depth_layer_count;
         ++layer) {
      const SourceDepthLayerCopy &copy = resources.source_depth_layers[layer];
      if (copy.destination_layer != layer ||
          copy.destination_layer >= batched_source_layers ||
          copy.width == 0U || copy.height == 0U ||
          copy.width > base.source_width ||
          copy.height > base.source_height) {
        return false;
      }
      if (has_external_source_depth) continue;
      if (copy.source_image_slot >= request.image_count) return false;
      const ImageResources &source_image =
          request.images[copy.source_image_slot];
      const PatchPC &source_patch = source_image.calibration[0].patch;
      const BoundResource &source_depth =
          source_image.photometric.bindings[0][0];
      std::uint64_t source_copy_bytes = 0;
      if (source_patch.width != copy.width || source_patch.height != copy.height ||
          source_depth.scalar_type != ResourceScalarType::kFloat32 ||
          source_depth.array_layers != 1U ||
          !CheckedProductU64(copy.width, copy.height, &source_copy_bytes) ||
          !CheckedProductU64(source_copy_bytes, sizeof(float),
                             &source_copy_bytes) ||
          source_depth.range < source_copy_bytes) {
        return false;
      }
    }
    for (std::uint32_t rotation = 0; rotation < 4; ++rotation) {
      for (std::uint32_t other = rotation + 1U; other < 4; ++other) {
        if (resources.calibration[rotation].active_pose_table.buffer ==
            resources.calibration[other].active_pose_table.buffer) {
          return false;
        }
      }
    }
  }
  return true;
}

RuntimeStatus CertificationStatus(const Certifications &certifications,
                                  const char **detail) noexcept {
  if (!certifications.pcg) {
    *detail = "OpenMVS-PCG adaptation is not production-certified";
    return RuntimeStatus::kPcgAdaptationNotCertified;
  }
  if (!certifications.texture) {
    *detail = "CUDA/Vulkan texture sampling parity is not certified";
    return RuntimeStatus::kTextureParityNotCertified;
  }
  if (!certifications.full_sweep) {
    *detail = "full SweepFromTopToBottom is not certified for runtime use";
    return RuntimeStatus::kFullSweepNotCertified;
  }
  *detail = "certified";
  return RuntimeStatus::kRecorded;
}

[[maybe_unused]] std::size_t
PushConstantSize(const PipelineKind kind) noexcept {
  switch (kind) {
  case PipelineKind::kReferenceFilter:
    return 24;
  case PipelineKind::kOpenMvsPcgInitialize:
    return sizeof(PatchPC);
  case PipelineKind::kOpenMvsPcgDepthInitialize:
    return sizeof(PatchPC);
  case PipelineKind::kRotateF32:
  case PipelineKind::kRotateU32:
  case PipelineKind::kTransposeF32:
  case PipelineKind::kFlipHorizontalF32:
    return 20;
  case PipelineKind::kNormalInitialize:
  case PipelineKind::kInitialCost:
  case PipelineKind::kFullSweep:
  case PipelineKind::kRotateNormalF32:
    return sizeof(PatchPC);
  }
  return 0;
}

// [BATCH-REF 2026-08-30] reference/batch:把「整块 N 份」的 buffer 切成
// 本 reference 的那一份。arena 里每个缓冲都恰好是单 reference 的 N 倍
// (batch_scale 实测 N=1..8 每 ref 恒为 2.04 GB),所以
//   offset += reference * (range / batch);  range /= batch;
// 就是精确的「第 reference 份」。
//
// 这样纯 buffer 的 kernel(kReferenceFilter / kOpenMvsPcg*Initialize /
// kNormalInitialize / kRotateNormalF32)可以**一行 shader 都不改**,
// 按 reference 逐次 dispatch 就正确 —— 每次看到的内存与单跑时完全一致。
// 绑了纹理数组的 kInitialCost / kFullSweep 走不了这条路(纹理层选不了偏移),
// 它们在 shader 里用 gl_WorkGroupID.y 当 reference 索引。
std::vector<Write> WritesFor(const PipelineKind kind,
                             const ImageResources &image, const Mode mode,
                             const std::uint32_t rotation,
                             const std::uint32_t rotated_binding = 0,
                             const std::uint32_t output_binding = 0,
                             const std::uint32_t layer = 0,
                             const std::uint32_t reference = UINT32_MAX,
                             const std::uint32_t batch = 1) {
  std::vector<Write> writes;
  const ModeResources &resources = ResourcesFor(image, mode);
  const auto slice = [reference, batch](BoundResource bound) -> BoundResource {
    if (reference == UINT32_MAX || batch <= 1U) return bound;
    const std::uint64_t per_reference = bound.range / batch;
    bound.offset += per_reference * reference;
    bound.range = per_reference;
    bound.array_layers =
        bound.array_layers >= batch ? bound.array_layers / batch : 1U;
    return bound;
  };
  const auto buffer = [&writes, &resources, rotation,
                       &slice](const std::uint32_t shader_binding,
                               const std::uint32_t logical_binding) {
    writes.push_back({shader_binding, false,
                      slice(resources.bindings[logical_binding][rotation])});
  };
  switch (kind) {
  case PipelineKind::kReferenceFilter:
    buffer(0, 8);
    buffer(1, 9);
    buffer(2, 10);
    buffer(3, 11);
    break;
  case PipelineKind::kOpenMvsPcgInitialize:
    buffer(6, 6);
    break;
  case PipelineKind::kOpenMvsPcgDepthInitialize:
    buffer(0, 0);
    buffer(6, 6);
    break;
  case PipelineKind::kNormalInitialize:
    buffer(1, 1);
    buffer(6, 6);
    break;
  case PipelineKind::kRotateNormalF32:
    buffer(1, 1);
    break;
  case PipelineKind::kInitialCost:
    for (const std::uint32_t binding : {0U, 1U, 2U, 9U, 10U, 11U}) {
      buffer(binding, binding);
    }
    writes.push_back(
        {13, false, slice(image.calibration[rotation].active_pose_table)});
    writes.push_back({14, true, resources.bindings[14][rotation]});
    break;
  case PipelineKind::kFullSweep:
    for (const std::uint32_t binding :
         {0U, 1U, 2U, 3U, 4U, 5U, 6U, 7U, 9U, 10U, 11U}) {
      buffer(binding, binding);
    }
    writes.push_back({12, true, resources.bindings[12][rotation]});
    writes.push_back(
        {13, false, image.calibration[rotation].active_pose_table});
    writes.push_back({14, true, resources.bindings[14][rotation]});
    break;
  case PipelineKind::kRotateF32:
  case PipelineKind::kRotateU32:
  case PipelineKind::kTransposeF32:
  case PipelineKind::kFlipHorizontalF32: {
    const std::uint32_t next_rotation = (rotation + 1U) & 3U;
    BoundResource source = resources.bindings[rotated_binding][rotation];
    BoundResource destination =
        resources.bindings[output_binding][next_rotation];
    // [LAYER-FUSE] layer == UINT32_MAX ⇒ 整块绑定,层号由 shader 的
    // gl_WorkGroupID.z 决定,一次 dispatch 覆盖所有层。
    if (layer != UINT32_MAX) {
      const std::uint64_t plane_bytes =
          source.range / std::max<std::uint32_t>(source.array_layers, 1U);
      source.offset += plane_bytes * layer;
      source.range = plane_bytes;
      destination.offset += plane_bytes * layer;
      destination.range = plane_bytes;
    }
    writes.push_back({0, false, source});
    writes.push_back({1, false, destination});
    break;
  }
  }
  return writes;
}

struct FilterPC {
  std::uint32_t width;
  std::uint32_t height;
  std::int32_t window_radius;
  std::int32_t window_step;
  float sigma_spatial;
  float sigma_color;
};
static_assert(sizeof(FilterPC) == 24);

struct MatPC {
  std::int32_t width;
  std::int32_t height;
  std::int32_t input_pitch_bytes;
  std::int32_t output_pitch_bytes;
  // [LAYER-FUSE] 每层元素数;transpose/flip 两个未被调用的 shader 只读前 16
  // 字节,pipeline layout 声明 20 字节而 shader 只用 16 是合法的。
  std::int32_t plane_elements;
};
static_assert(sizeof(MatPC) == 20);

std::uint32_t BindingFor(const RotatedResource resource) noexcept {
  switch (resource) {
  case RotatedResource::kRng:
    return 6;
  case RotatedResource::kDepth:
    return 0;
  case RotatedResource::kNormalVector:
  case RotatedResource::kNormalPlanes:
    return 1;
  case RotatedResource::kReferenceBytes:
    return 9;
  case RotatedResource::kReferenceWeightedSum:
    return 10;
  case RotatedResource::kReferenceWeightedSquaredSum:
    return 11;
  case RotatedResource::kSelectionToPrevious:
    return 4;
  case RotatedResource::kAllocateSelection:
    return 3;
  case RotatedResource::kCost:
    return 2;
  case RotatedResource::kNone:
    return UINT32_MAX;
  }
  return UINT32_MAX;
}

[[maybe_unused]] std::size_t
DescriptorBudget(const RecordRequest &request) noexcept {
  std::size_t budget = 0;
  for (const PlanStep &step : request.plan->steps) {
    std::size_t increment = 0;
    if (step.operation == Operation::kReferenceFilter ||
        step.operation == Operation::kInitialCost ||
        step.operation == Operation::kSweep ||
        (step.operation == Operation::kRotateResource &&
         step.resource == RotatedResource::kNormalVector)) {
      increment = 1;
    } else if (step.operation == Operation::kInitializeRng ||
               step.operation == Operation::kInitializeRandomNormal) {
      increment = 1;
    } else if (step.operation == Operation::kInitializeRandomDepth) {
      increment = 1;
    } else if (step.operation == Operation::kRotateResource &&
               step.resource != RotatedResource::kAllocateSelection) {
      const std::uint32_t binding = BindingFor(step.resource);
      if (binding == UINT32_MAX || step.image >= request.image_count)
        return 0;
      increment = ResourcesFor(request.images[step.image], step.mode)
                      .bindings[binding][step.rotation_before]
                      .array_layers;
    }
    if (increment > std::numeric_limits<std::size_t>::max() - budget)
      return 0;
    budget += increment;
  }
  return budget;
}

class Orchestrator {
public:
  Orchestrator(const RecordRequest &request, Backend *backend) noexcept
      : request_(request), backend_(backend) {}

  bool Run(RecordResult *result) noexcept {
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
    const auto run_started = std::chrono::steady_clock::now();
    const auto elapsed_ms = [&run_started]() noexcept {
      return std::chrono::duration_cast<std::chrono::milliseconds>(
                 std::chrono::steady_clock::now() - run_started)
          .count();
    };
#endif
    for (const ShaderBinary &shader : request_.shaders.binaries) {
      if (!backend_->CreatePipeline(shader.kind, shader))
        return false;
    }
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
    std::fprintf(stderr,
                 "{\"runtime_stage\":\"pipelines_ready\","
                 "\"elapsed_ms\":%lld}\n",
                 static_cast<long long>(elapsed_ms()));
    std::fflush(stderr);
#endif
    if (!backend_->Begin())
      return false;
    for (const PlanStep &step : request_.plan->steps) {
      if (!RecordStep(step, result))
        return false;
      ++result->recorded_plan_steps;
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
      if ((result->recorded_plan_steps % 64U) == 0U) {
        std::fprintf(stderr,
                     "{\"runtime_stage\":\"recording\",\"steps\":%zu,"
                     "\"dispatches\":%zu,\"iteration\":%u,\"sweep\":%u,"
                     "\"elapsed_ms\":%lld}\n",
                     result->recorded_plan_steps, result->dispatch_count,
                     step.iteration, step.sweep,
                     static_cast<long long>(elapsed_ms()));
        std::fflush(stderr);
      }
#endif
    }
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
    std::fprintf(stderr,
                 "{\"runtime_stage\":\"before_queue_submit\",\"steps\":%zu,"
                 "\"dispatches\":%zu,\"elapsed_ms\":%lld}\n",
                 result->recorded_plan_steps, result->dispatch_count,
                 static_cast<long long>(elapsed_ms()));
    std::fflush(stderr);
#endif
    if (!backend_->EndSubmitAndWait())
      return false;
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
    std::fprintf(stderr,
                 "{\"runtime_stage\":\"final_submit_complete\","
                 "\"elapsed_ms\":%lld}\n",
                 static_cast<long long>(elapsed_ms()));
    std::fflush(stderr);
#endif
    ++result->queue_submit_count;
    return FinalizeConsistencyGraphs(result);
  }

private:
  bool FinalizeConsistencyGraphs(RecordResult *result) const noexcept {
    if (request_.plan->phase == PlanPhase::kPhotometricOnly) {
      // PatchMatchController writes no consistency graph during its first,
      // photometric-only pass. It is created only by the later geometric pass.
      return true;
    }
    for (std::size_t image_index = 0; image_index < request_.image_count;
         ++image_index) {
      const ImageResources &image = request_.images[image_index];
      const PatchPC &base = image.calibration[0].patch;
      const ConsistencyGraphReadback &readback =
          image.consistency_graph_readback;
      // [BATCH-REF 2026-08-31] 一致性图逐 reference 各序列化一份:
      //   掩码    : mapped_mask_words + r * (W*H*num_sources)
      //   源索引  : source_image_indices + r * num_sources(N 个 ref 的源不同)
      //   输出    : values + r * (value_capacity / batch),各占独立一片,
      //             互不追加,导出时按 r 取片即可。
      //   计数    : value_count[r]
      // batch == 1 时与原来逐字等价。
      const std::uint32_t batch =
          request_.batch_count == 0U ? 1U : request_.batch_count;
      const std::size_t mask_plane =
          static_cast<std::size_t>(base.width) * base.height * base.num_sources;
      const std::size_t per_reference_capacity =
          readback.value_capacity / batch;
      for (std::uint32_t reference = 0U; reference < batch; ++reference) {
        const ConsistencyGraphInput input = {
            readback.mapped_mask_words + mask_plane * reference,
            base.width,
            base.height,
            base.num_sources,
            image.consistency_graph.source_image_indices +
                static_cast<std::size_t>(base.num_sources) * reference,
            base.num_sources,
        };
        const std::size_t required = RequiredConsistencyGraphValueCount(input);
        if (required > per_reference_capacity ||
            !SerializeConsistencyGraph(
                input, readback.values + per_reference_capacity * reference,
                required) ||
            required > std::numeric_limits<std::size_t>::max() -
                           result->consistency_graph_value_count) {
          return false;
        }
        readback.value_count[reference] = required;
        result->consistency_graph_value_count += required;
      }
    }
    return true;
  }

  PatchPC PatchFor(const ImageResources &image, const PlanStep &step,
                   const std::uint32_t reference = 0U) const noexcept {
    const RotationCalibration &calibration =
        image.calibration[step.rotation_before];
    // [BATCH-REF] 有逐 reference 的 patch 就用它,否则退回单份(N=1 等价)。
    PatchPC patch =
        (calibration.reference_patches != nullptr &&
         reference < calibration.reference_patch_count)
            ? calibration.reference_patches[reference]
            : calibration.patch;
    patch.reserved = OfficialNccNormalizationBits(patch.ncc_sigma);
    if (step.operation == Operation::kSweep) {
      patch.perturbation = step.perturbation;
      patch.prev_sel_prob_weight = step.prev_sel_prob_weight;
    }
    return patch;
  }

  bool Barrier(RecordResult *result) noexcept {
    if (!backend_->PipelineBarrier())
      return false;
    ++result->barrier_count;
    return true;
  }

  bool HostSynchronize(RecordResult *result) noexcept {
    // COLMAP's CUDA_SYNC_AND_CHECK is cudaStreamSynchronize(nullptr), not only
    // an in-command-buffer dependency. End and wait for this Vulkan batch,
    // then continue recording the next official stage in the same resources.
    if (!Barrier(result) || !backend_->SubmitWaitAndContinue())
      return false;
    ++result->queue_submit_count;
    return true;
  }

  bool Dispatch(const PipelineKind kind, const ImageResources &image,
                const Mode mode, const std::uint32_t rotation, const void *pc,
                const std::size_t pc_size, const std::uint32_t x,
                const std::uint32_t y, const std::uint32_t z,
                const std::uint32_t specialization, RecordResult *result,
                const PatchPC *const per_reference_patches = nullptr,
                const std::size_t per_reference_count = 0U) noexcept {
    const std::uint32_t batch =
        request_.batch_count == 0U ? 1U : request_.batch_count;
    // kFullSweep / kInitialCost 在 shader 里用 gl_WorkGroupID.y 当 reference
    // 索引(它们绑了纹理数组,切不了子区间),一次 dispatch 覆盖全部 N。
    // 其余 kernel 全是纯 buffer,按 reference 逐次 dispatch + 切子区间,
    // 零 shader 改动。
    const bool batched_in_shader =
        kind == PipelineKind::kFullSweep || kind == PipelineKind::kInitialCost;
    const std::uint32_t passes = batched_in_shader ? 1U : batch;
    for (std::uint32_t reference = 0U; reference < passes; ++reference) {
      // [BATCH-REF] 逐 reference dispatch 时,push constant 也要换成这个
      // reference 自己的(depth_min/max 与内参逐帧不同)。
      const PatchPC *const per_reference =
          (per_reference_patches != nullptr && !batched_in_shader &&
           reference < per_reference_count)
              ? &per_reference_patches[reference]
              : nullptr;
      const void *const active_pc =
          per_reference != nullptr ? static_cast<const void *>(per_reference)
                                   : pc;
      const std::vector<Write> writes =
          WritesFor(kind, image, mode, rotation, 0U, 0U, 0U,
                    batched_in_shader ? UINT32_MAX : reference, batch);
      if (!backend_->AllocateAndBindDescriptorSet(kind, writes.data(),
                                                  writes.size())) {
        return false;
      }
      if (!backend_->BindAndDispatch(kind, specialization, active_pc, pc_size,
                                     x, y, z)) {
        return false;
      }
      ++result->dispatch_count;
    }
    return true;
  }

  bool RotateFloat(const PlanStep &step, const ImageResources &image,
                   const std::uint32_t input_binding,
                   const std::uint32_t output_binding,
                   RecordResult *result) noexcept {
    const ModeResources &resources = ResourcesFor(image, step.mode);
    const BoundResource &source =
        resources.bindings[input_binding][step.rotation_before];
    const std::uint32_t next = (step.rotation_before + 1U) & 3U;
    const BoundResource &destination = resources.bindings[output_binding][next];
    const PatchPC patch = PatchFor(image, step);
    if (source.array_layers != destination.array_layers ||
        source.scalar_type != ResourceScalarType::kFloat32 ||
        destination.scalar_type != ResourceScalarType::kFloat32 ||
        source.range != destination.range ||
        patch.width > static_cast<std::uint32_t>(
                          std::numeric_limits<std::int32_t>::max()) ||
        patch.height > static_cast<std::uint32_t>(
                           std::numeric_limits<std::int32_t>::max())) {
      return false;
    }
    // [LAYER-FUSE 2026-08-30] 原来是逐层一个 dispatch + 逐层一次
    // AllocateAndBindDescriptorSet(10 个源 ⇒ 单步 10 次)。实测每个 rotate
    // dispatch 约 30 ms,其中只有 ~6 ms 是转置本身,其余是 MoltenVK 的
    // descriptor 绑定开销(argument buffers 关掉后 rotate 从 20.4s 掉到 4.2s)。
    // 各层互相独立、同一组值的同一个置换、不做算术 ⇒ 合并成一次 dispatch、
    // 用 gl_WorkGroupID.z 当层号,按构造逐字节相同。
    const std::uint32_t layers = std::max<std::uint32_t>(source.array_layers, 1U);
    const std::uint64_t plane_bytes = source.range / layers;
    const MatPC mat = {static_cast<std::int32_t>(patch.width),
                       static_cast<std::int32_t>(patch.height),
                       static_cast<std::int32_t>(patch.width * 4U),
                       static_cast<std::int32_t>(patch.height * 4U),
                       static_cast<std::int32_t>(plane_bytes / 4U)};
    {
      const std::vector<Write> writes =
          WritesFor(PipelineKind::kRotateF32, image, step.mode,
                    step.rotation_before, input_binding, output_binding,
                    UINT32_MAX);
      if (!backend_->AllocateAndBindDescriptorSet(
              PipelineKind::kRotateF32, writes.data(), writes.size()) ||
          !backend_->BindAndDispatch(PipelineKind::kRotateF32, 0, &mat,
                                     sizeof(mat),
                                     DivideRoundUp(patch.width, 32),
                                     DivideRoundUp(patch.height, 32), layers)) {
        return false;
      }
      ++result->dispatch_count;
    }
    // GpuMat<T>::Rotate ends with CUDA_SYNC_AND_CHECK. A Vulkan execution
    // barrier is required here before the rotated allocation becomes the next
    // active map.
    return Barrier(result);
  }

  bool RotateU32(const PlanStep &step, const ImageResources &image,
                 const std::uint32_t input_binding,
                 const std::uint32_t output_binding,
                 RecordResult *result) noexcept {
    const ModeResources &resources = ResourcesFor(image, step.mode);
    const std::uint32_t next = (step.rotation_before + 1U) & 3U;
    const BoundResource &source =
        resources.bindings[input_binding][step.rotation_before];
    const BoundResource &destination = resources.bindings[output_binding][next];
    const PatchPC patch = PatchFor(image, step);
    if (source.scalar_type != ResourceScalarType::kUint32 ||
        destination.scalar_type != ResourceScalarType::kUint32 ||
        source.array_layers != destination.array_layers ||
        source.range != destination.range) {
      return false;
    }
    // [LAYER-FUSE 2026-08-30] 原来是逐层一个 dispatch + 逐层一次
    // AllocateAndBindDescriptorSet(10 个源 ⇒ 单步 10 次)。实测每个 rotate
    // dispatch 约 30 ms,其中只有 ~6 ms 是转置本身,其余是 MoltenVK 的
    // descriptor 绑定开销(argument buffers 关掉后 rotate 从 20.4s 掉到 4.2s)。
    // 各层互相独立、同一组值的同一个置换、不做算术 ⇒ 合并成一次 dispatch、
    // 用 gl_WorkGroupID.z 当层号,按构造逐字节相同。
    const std::uint32_t layers = std::max<std::uint32_t>(source.array_layers, 1U);
    const std::uint64_t plane_bytes = source.range / layers;
    const MatPC mat = {static_cast<std::int32_t>(patch.width),
                       static_cast<std::int32_t>(patch.height),
                       static_cast<std::int32_t>(patch.width * sizeof(std::uint32_t)),
                       static_cast<std::int32_t>(patch.height * sizeof(std::uint32_t)),
                       static_cast<std::int32_t>(plane_bytes / sizeof(std::uint32_t))};
    {
      const std::vector<Write> writes =
          WritesFor(PipelineKind::kRotateU32, image, step.mode,
                    step.rotation_before, input_binding, output_binding,
                    UINT32_MAX);
      if (!backend_->AllocateAndBindDescriptorSet(
              PipelineKind::kRotateU32, writes.data(), writes.size()) ||
          !backend_->BindAndDispatch(PipelineKind::kRotateU32, 0, &mat,
                                     sizeof(mat),
                                     DivideRoundUp(patch.width, 32),
                                     DivideRoundUp(patch.height, 32), layers)) {
        return false;
      }
      ++result->dispatch_count;
    }
    return true;
  }

  bool Rotate(const PlanStep &step, const ImageResources &image,
              RecordResult *result) noexcept {
    const ModeResources &resources = ResourcesFor(image, step.mode);
    const PatchPC patch = PatchFor(image, step);
    if (step.resource == RotatedResource::kNormalVector) {
      if (!Dispatch(PipelineKind::kRotateNormalF32, image, step.mode,
                    step.rotation_before, &patch, sizeof(patch),
                    DivideRoundUp(patch.width, 16),
                    DivideRoundUp(patch.height, 8), 1, 0, result)) {
        return false;
      }
      return Barrier(result);
    }
    if (step.resource == RotatedResource::kAllocateSelection) {
      const std::uint32_t next = (step.rotation_before + 1U) & 3U;
      return resources.bindings[3][next].buffer !=
                 resources.bindings[3][step.rotation_before].buffer &&
             resources.bindings[3][next].buffer !=
                 resources.bindings[4][next].buffer;
    }
    if (step.resource == RotatedResource::kRng) {
      return RotateU32(step, image, 6, 6, result) && Barrier(result);
    }
    if (step.resource == RotatedResource::kReferenceBytes) {
      return RotateU32(step, image, 9, 9, result) && Barrier(result);
    }
    if (step.resource == RotatedResource::kSelectionToPrevious) {
      return RotateFloat(step, image, 3, 4, result);
    }
    const std::uint32_t binding = BindingFor(step.resource);
    return binding != UINT32_MAX &&
           RotateFloat(step, image, binding, binding, result);
  }

  bool InitializeRng(const PlanStep &step, const ImageResources &image,
                     const PatchPC &patch, RecordResult *result) noexcept {
    return Dispatch(PipelineKind::kOpenMvsPcgInitialize, image, step.mode, 0,
                    &patch, sizeof(patch), DivideRoundUp(patch.width, 32),
                    DivideRoundUp(patch.height, 16), 1, 0, result,
                    image.calibration[0].reference_patches,
                    image.calibration[0].reference_patch_count) &&
           Barrier(result);
  }

  bool InitializeRandomDepth(const PlanStep &step, const ImageResources &image,
                             const PatchPC &patch,
                             RecordResult *result) noexcept {
    return Dispatch(PipelineKind::kOpenMvsPcgDepthInitialize, image, step.mode,
                    0, &patch, sizeof(patch),
                    DivideRoundUp(patch.width, 32),
                    DivideRoundUp(patch.height, 16), 1, 0, result,
                    image.calibration[0].reference_patches,
                    image.calibration[0].reference_patch_count) &&
           Barrier(result);
  }

  bool Readback(const PlanStep &step, const ImageResources &image,
                const std::uint32_t binding,
                const BoundResource &destination) noexcept {
    const ModeResources &resources = ResourcesFor(image, step.mode);
    const BoundResource &source = resources.bindings[binding][0];
    return backend_->CopyBuffer(source.buffer, source.offset,
                                destination.buffer, destination.offset,
                                source.range);
  }

  bool RecordStep(const PlanStep &step, RecordResult *result) noexcept {
    if (step.operation == Operation::kWaitPhotometricAll) {
      return HostSynchronize(result);
    }
    if (step.image >= request_.image_count)
      return false;
    const ImageResources &image = request_.images[step.image];
    const ModeResources &resources = ResourcesFor(image, step.mode);
    const PatchPC patch = PatchFor(image, step);
    switch (step.operation) {
    case Operation::kUploadReferenceImage:
      return backend_->CopyBuffer(resources.reference_upload_staging.buffer,
                                  resources.reference_upload_staging.offset,
                                  resources.bindings[8][0].buffer,
                                  resources.bindings[8][0].offset,
                                  resources.reference_transfer_byte_count) &&
             Barrier(result);
    case Operation::kUploadSourceImages: {
      const BoundResource &source_image = resources.bindings[14][0];
      if (!backend_->CopyBuffer(resources.source_gray_upload_staging.buffer,
                                  resources.source_gray_upload_staging.offset,
                                  source_image.buffer, source_image.offset,
                                  resources.source_gray_transfer_byte_count) ||
          !backend_->TransitionSampledImage(source_image.image, true))
        return false;
      const std::uint64_t plane = static_cast<std::uint64_t>(patch.source_width) *
                                  patch.source_height;
      // [BATCH-REF] 纹理数组现在是 N*num_sources 层,staging 里也是 N 份,
      // 层号 = reference*num_sources + source(与 shader 的 SourceLayer 一致)。
      const std::uint32_t batched_layers =
          patch.num_sources *
          (request_.batch_count == 0U ? 1U : request_.batch_count);
      for (std::uint32_t layer = 0; layer < batched_layers; ++layer) {
        if (!backend_->CopyBufferToImage(
                resources.source_gray_image_upload_staging.buffer,
                resources.source_gray_image_upload_staging.offset +
                    plane * layer,
                source_image.image, layer, patch.source_width,
                patch.source_height, 1U))
          return false;
      }
      return backend_->TransitionSampledImage(source_image.image, false) &&
             Barrier(result);
    }
    case Operation::kBarrier:
      return HostSynchronize(result);
    case Operation::kReferenceFilter: {
      const FilterPC filter = {patch.width, patch.height,
                               request_.window_radius, request_.window_step,
                               patch.sigma_spatial, patch.sigma_color};
      return Dispatch(PipelineKind::kReferenceFilter, image, step.mode,
                      step.rotation_before, &filter, sizeof(filter),
                      DivideRoundUp(patch.width, 16),
                      DivideRoundUp(patch.height, 8), 1, 0, result);
    }
    case Operation::kUploadSourceDepthMaps: {
      const BoundResource &destination = resources.bindings[12][0];
      if (!backend_->TransitionSampledImage(destination.image, true) ||
          !backend_->ClearSampledImageFloat(destination.image, 0.0F) ||
          !Barrier(result))
        return false;
      for (std::size_t layer = 0; layer < image.source_depth_layer_count;
           ++layer) {
        const SourceDepthLayerCopy &copy = image.source_depth_layers[layer];
        const bool has_external_source_depth =
            ValidResource(resources.source_depth_upload_staging);
        const BoundResource &source = has_external_source_depth
            ? resources.source_depth_upload_staging
            : request_.images[copy.source_image_slot]
                  .photometric.bindings[0][0];
        const std::uint64_t source_offset = has_external_source_depth
            ? source.offset + static_cast<std::uint64_t>(layer) *
                                  copy.width * copy.height * sizeof(float)
            : source.offset;
        if (!backend_->CopyBufferToImage(
                source.buffer, source_offset, destination.image,
                copy.destination_layer, copy.width, copy.height,
                sizeof(float))) {
          return false;
        }
      }
      return backend_->TransitionSampledImage(destination.image, false) &&
             Barrier(result);
    }
    case Operation::kUploadTransformsAndCalibrations: {
      // [BATCH-REF] staging 与 active table 都是 N 份首尾相接,整块拷。
      const std::uint64_t bytes =
          static_cast<std::uint64_t>(
              kPoseFloatsPerReference(patch.num_sources)) *
          sizeof(float) *
          (request_.batch_count == 0U ? 1U : request_.batch_count);
      for (const RotationCalibration &calibration : image.calibration) {
        if (!backend_->CopyBuffer(calibration.pose_upload_staging.buffer,
                                  calibration.pose_upload_staging.offset,
                                  calibration.active_pose_table.buffer,
                                  calibration.active_pose_table.offset,
                                  bytes)) {
          return false;
        }
      }
      return Barrier(result);
    }
    case Operation::kInitializeRng:
      return InitializeRng(step, image, patch, result);
    case Operation::kInitializeRandomDepth:
      return InitializeRandomDepth(step, image, patch, result);
    case Operation::kInitializeRandomNormal:
      return Dispatch(PipelineKind::kNormalInitialize, image, step.mode,
                      step.rotation_before, &patch, sizeof(patch),
                      DivideRoundUp(patch.width, 32),
                      DivideRoundUp(patch.height, 16), 1, 0, result,
                      image.calibration[step.rotation_before].reference_patches,
                      image.calibration[step.rotation_before]
                          .reference_patch_count) &&
             Barrier(result);
    case Operation::kCopyPhotometricDepth:
      return backend_->CopyBuffer(
                                  request_.plan->phase ==
                                          PlanPhase::kGeometricOnly
                                      ? image.geometric
                                            .reference_depth_upload_staging
                                            .buffer
                                      : image.photometric.bindings[0][0].buffer,
                                  request_.plan->phase ==
                                          PlanPhase::kGeometricOnly
                                      ? image.geometric
                                            .reference_depth_upload_staging
                                            .offset
                                      : image.photometric.bindings[0][0].offset,
                                  image.geometric.bindings[0][0].buffer,
                                  image.geometric.bindings[0][0].offset,
                                  request_.plan->phase ==
                                          PlanPhase::kGeometricOnly
                                      ? image.geometric
                                            .reference_depth_transfer_byte_count
                                      : image.photometric.bindings[0][0].range) &&
             Barrier(result);
    case Operation::kCopyPhotometricNormal:
      return backend_->CopyBuffer(
                                  request_.plan->phase ==
                                          PlanPhase::kGeometricOnly
                                      ? image.geometric
                                            .reference_normal_upload_staging
                                            .buffer
                                      : image.photometric.bindings[1][0].buffer,
                                  request_.plan->phase ==
                                          PlanPhase::kGeometricOnly
                                      ? image.geometric
                                            .reference_normal_upload_staging
                                            .offset
                                      : image.photometric.bindings[1][0].offset,
                                  image.geometric.bindings[1][0].buffer,
                                  image.geometric.bindings[1][0].offset,
                                  request_.plan->phase ==
                                          PlanPhase::kGeometricOnly
                                      ? image.geometric
                                            .reference_normal_transfer_byte_count
                                      : image.photometric.bindings[1][0].range) &&
             Barrier(result);
    case Operation::kInitializeSelectionAndWorkspace:
      return backend_->FillBuffer(resources.bindings[4][0].buffer,
                                  resources.bindings[4][0].offset,
                                  resources.bindings[4][0].range,
                                  0x3f000000U) &&
             Barrier(result);
    case Operation::kInitialCost:
      // [BATCH-REF] 与 sweep 同样在 shader 里用 gl_WorkGroupID.y 当 reference。
      return Dispatch(PipelineKind::kInitialCost, image, step.mode,
                      step.rotation_before, &patch, sizeof(patch),
                      DivideRoundUp(patch.width, 32),
                      request_.batch_count == 0U ? 1U : request_.batch_count,
                      1, 0, result);
    case Operation::kSweep: {
      const std::uint32_t specialization = step.sweep_flags;
      // [BATCH-REF 2026-08-30] y 维 = 批内 reference 数,shader 里
      // RefIndex() = gl_WorkGroupID.y。
      return Dispatch(PipelineKind::kFullSweep, image, step.mode,
                      step.rotation_before, &patch, sizeof(patch),
                      DivideRoundUp(patch.width, 32),
                      request_.batch_count == 0U ? 1U : request_.batch_count, 1,
                      specialization, result);
    }
    case Operation::kRotateResource:
      return Rotate(step, image, result);
    case Operation::kAllocateConsistencyMask:
      return ValidResource(resources.bindings[5][step.rotation_before]);
    case Operation::kClearConsistencyMask: {
      const BoundResource &mask = resources.bindings[5][step.rotation_before];
      return backend_->FillBuffer(mask.buffer, mask.offset, mask.range, 0U) &&
             Barrier(result);
    }
    case Operation::kSelectCalibrationAndPose:
      return step.calibration_rotation == step.rotation_before &&
             ValidResource(image.calibration[step.calibration_rotation]
                               .active_pose_table);
    case Operation::kRotateFinalMask: {
      PlanStep mask_rotation = step;
      mask_rotation.rotation_before = 3;
      mask_rotation.rotation_after = 0;
      return RotateU32(mask_rotation, image, 5, 5, result) && Barrier(result);
    }
    case Operation::kReadbackDepth:
      return Readback(step, image, 0, resources.depth_readback);
    case Operation::kReadbackNormal:
      return Readback(step, image, 1, resources.normal_readback);
    case Operation::kReadbackMask:
      return step.mode == Mode::kGeometric &&
             Readback(step, image, 5, resources.mask_readback);
    case Operation::kWaitPhotometricAll:
      return false;
    }
    return false;
  }

  const RecordRequest &request_;
  Backend *backend_;
};

RecordResult RecordImpl(const RecordRequest &request,
                        const Certifications &certifications,
                        Backend *backend) noexcept {
  RecordResult result;
  if (request.plan == nullptr || !request.plan->Validate()) {
    result.status = RuntimeStatus::kInvalidPlan;
    result.detail = "dispatch plan is not the canonical COLMAP sequence";
    return result;
  }
  const char *gate_detail = nullptr;
  result.status = CertificationStatus(certifications, &gate_detail);
  result.detail = gate_detail;
  if (result.status != RuntimeStatus::kRecorded)
    return result;
  if (!ValidRequest(request)) {
    result.status = RuntimeStatus::kInvalidRequest;
    result.detail = "shader, resource, dimension, or image contract is invalid";
    return result;
  }
  if (backend == nullptr) {
    result.status = RuntimeStatus::kVulkanFunctionUnavailable;
    result.detail = "Vulkan backend is unavailable";
    return result;
  }
  Orchestrator orchestrator(request, backend);
  if (!orchestrator.Run(&result)) {
    result.status = RuntimeStatus::kVulkanError;
    result.detail = "Vulkan pipeline creation or command recording failed";
    return result;
  }
  result.status = RuntimeStatus::kRecorded;
  result.detail = "canonical command buffer recorded, submitted, and waited";
  return result;
}

#if !defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)

template <typename T> T FromOpaque(const std::uint64_t value) noexcept {
  if constexpr (std::is_pointer_v<T>) {
    return reinterpret_cast<T>(static_cast<std::uintptr_t>(value));
  } else {
    return static_cast<T>(value);
  }
}

struct DescriptorSpec {
  std::uint32_t binding;
  VkDescriptorType type;
};

std::vector<DescriptorSpec> DescriptorSpecs(const PipelineKind kind) {
  std::vector<DescriptorSpec> specs;
  const auto storage = [&specs](const std::uint32_t binding) {
    specs.push_back({binding, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER});
  };
  switch (kind) {
  case PipelineKind::kReferenceFilter:
    for (const std::uint32_t binding : {0U, 1U, 2U, 3U})
      storage(binding);
    break;
  case PipelineKind::kOpenMvsPcgInitialize:
    storage(6);
    break;
  case PipelineKind::kOpenMvsPcgDepthInitialize:
    storage(0);
    storage(6);
    break;
  case PipelineKind::kNormalInitialize:
    storage(1);
    storage(6);
    break;
  case PipelineKind::kRotateNormalF32:
    storage(1);
    break;
  case PipelineKind::kInitialCost:
    for (const std::uint32_t binding : {0U, 1U, 2U, 9U, 10U, 11U, 13U}) {
      storage(binding);
    }
    specs.push_back({14, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER});
    break;
  case PipelineKind::kFullSweep:
    for (const std::uint32_t binding :
         {0U, 1U, 2U, 3U, 4U, 5U, 6U, 7U, 9U, 10U, 11U, 13U}) {
      storage(binding);
    }
    specs.push_back({12, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER});
    specs.push_back({14, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER});
    break;
  case PipelineKind::kRotateF32:
  case PipelineKind::kRotateU32:
  case PipelineKind::kTransposeF32:
  case PipelineKind::kFlipHorizontalF32:
    storage(0);
    storage(1);
    break;
  }
  return specs;
}

class NativeBackend final : public Backend {
public:
  NativeBackend() = default;
  ~NativeBackend() override { Reset(); }

  RuntimeStatus Initialize(const NativeContext &context,
                           const std::size_t descriptor_budget,
                           const char **detail) noexcept {
#if defined(__ANDROID__)
    PFN_vkGetInstanceProcAddr get_instance_proc_addr =
        context.get_instance_proc_addr == nullptr
            ? &vkGetInstanceProcAddr
            : reinterpret_cast<PFN_vkGetInstanceProcAddr>(
                  context.get_instance_proc_addr);
#elif defined(__APPLE__) || defined(PW_OFFICIAL_DENSE_HARMONY)
    if (context.get_instance_proc_addr == nullptr) {
      *detail = "Apple and Harmony require injected vkGetInstanceProcAddr";
      return RuntimeStatus::kExternalLoaderRequired;
    }
    PFN_vkGetInstanceProcAddr get_instance_proc_addr =
        reinterpret_cast<PFN_vkGetInstanceProcAddr>(
            context.get_instance_proc_addr);
#else
    if (context.get_instance_proc_addr == nullptr) {
      *detail = "non-Android builds require injected vkGetInstanceProcAddr";
      return RuntimeStatus::kExternalLoaderRequired;
    }
    PFN_vkGetInstanceProcAddr get_instance_proc_addr =
        reinterpret_cast<PFN_vkGetInstanceProcAddr>(
            context.get_instance_proc_addr);
#endif
    instance_ = FromOpaque<VkInstance>(context.instance);
    device_ = FromOpaque<VkDevice>(context.device);
    command_buffer_ = FromOpaque<VkCommandBuffer>(context.command_buffer);
    queue_ = FromOpaque<VkQueue>(context.queue);
    if (instance_ == VK_NULL_HANDLE || device_ == VK_NULL_HANDLE ||
        command_buffer_ == VK_NULL_HANDLE || queue_ == VK_NULL_HANDLE ||
        get_instance_proc_addr == nullptr) {
      *detail = "native Vulkan handles are invalid";
      return RuntimeStatus::kInvalidRequest;
    }
    const auto get_device_proc_addr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
        get_instance_proc_addr(instance_, "vkGetDeviceProcAddr"));
    if (get_device_proc_addr == nullptr) {
      *detail = "vkGetDeviceProcAddr is unavailable";
      return RuntimeStatus::kVulkanFunctionUnavailable;
    }
#define PW_LOAD_DEVICE(name)                                                   \
  name##_ = reinterpret_cast<PFN_##name>(get_device_proc_addr(device_, #name))
    PW_LOAD_DEVICE(vkCreateDescriptorSetLayout);
    PW_LOAD_DEVICE(vkDestroyDescriptorSetLayout);
    PW_LOAD_DEVICE(vkCreatePipelineLayout);
    PW_LOAD_DEVICE(vkDestroyPipelineLayout);
    PW_LOAD_DEVICE(vkCreateShaderModule);
    PW_LOAD_DEVICE(vkDestroyShaderModule);
    PW_LOAD_DEVICE(vkCreateComputePipelines);
    PW_LOAD_DEVICE(vkDestroyPipeline);
    PW_LOAD_DEVICE(vkCreateDescriptorPool);
    PW_LOAD_DEVICE(vkDestroyDescriptorPool);
    PW_LOAD_DEVICE(vkAllocateDescriptorSets);
    PW_LOAD_DEVICE(vkUpdateDescriptorSets);
    PW_LOAD_DEVICE(vkResetCommandBuffer);
    PW_LOAD_DEVICE(vkBeginCommandBuffer);
    PW_LOAD_DEVICE(vkEndCommandBuffer);
    PW_LOAD_DEVICE(vkCmdBindPipeline);
    PW_LOAD_DEVICE(vkCmdBindDescriptorSets);
    PW_LOAD_DEVICE(vkCmdPushConstants);
    PW_LOAD_DEVICE(vkCmdDispatch);
    PW_LOAD_DEVICE(vkCmdDispatchBase);
    PW_LOAD_DEVICE(vkCmdPipelineBarrier);
    PW_LOAD_DEVICE(vkCmdCopyBuffer);
    PW_LOAD_DEVICE(vkCmdCopyBufferToImage);
    PW_LOAD_DEVICE(vkCmdClearColorImage);
    PW_LOAD_DEVICE(vkCmdFillBuffer);
    PW_LOAD_DEVICE(vkQueueSubmit);
    PW_LOAD_DEVICE(vkQueueWaitIdle);
#undef PW_LOAD_DEVICE
    if (!FunctionsReady()) {
      *detail = "one or more Vulkan 1.0 command entry points are unavailable";
      return RuntimeStatus::kVulkanFunctionUnavailable;
    }
    if (descriptor_budget == 0 ||
        descriptor_budget > std::numeric_limits<std::uint32_t>::max() / 15U) {
      *detail = "descriptor budget is invalid";
      return RuntimeStatus::kInvalidRequest;
    }
    const std::uint32_t budget = static_cast<std::uint32_t>(descriptor_budget);
    const std::array<VkDescriptorPoolSize, 2> sizes = {{
        {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, budget * 15U},
        {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, budget * 2U},
    }};
    VkDescriptorPoolCreateInfo pool_info{};
    pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.maxSets = budget;
    pool_info.poolSizeCount = static_cast<std::uint32_t>(sizes.size());
    pool_info.pPoolSizes = sizes.data();
    if (vkCreateDescriptorPool_(device_, &pool_info, nullptr,
                                &descriptor_pool_) != VK_SUCCESS) {
      *detail = "vkCreateDescriptorPool failed";
      return RuntimeStatus::kVulkanError;
    }
    *detail = "ready";
    return RuntimeStatus::kRecorded;
  }

  bool CreatePipeline(const PipelineKind kind,
                      const ShaderBinary &binary) noexcept override {
    PipelineState &state = pipelines_[static_cast<std::size_t>(kind)];
    const std::vector<DescriptorSpec> specs = DescriptorSpecs(kind);
    std::vector<VkDescriptorSetLayoutBinding> bindings;
    bindings.reserve(specs.size());
    for (const DescriptorSpec &spec : specs) {
      VkDescriptorSetLayoutBinding binding{};
      binding.binding = spec.binding;
      binding.descriptorType = spec.type;
      binding.descriptorCount = 1;
      binding.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
      bindings.push_back(binding);
    }
    VkDescriptorSetLayoutCreateInfo set_info{};
    set_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    set_info.bindingCount = static_cast<std::uint32_t>(bindings.size());
    set_info.pBindings = bindings.data();
    if (vkCreateDescriptorSetLayout_(device_, &set_info, nullptr,
                                     &state.set_layout) != VK_SUCCESS) {
      return false;
    }

    VkPushConstantRange push_range{};
    push_range.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    push_range.size = static_cast<std::uint32_t>(PushConstantSize(kind));
    VkPipelineLayoutCreateInfo layout_info{};
    layout_info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout_info.setLayoutCount = 1;
    layout_info.pSetLayouts = &state.set_layout;
    layout_info.pushConstantRangeCount = 1;
    layout_info.pPushConstantRanges = &push_range;
    if (vkCreatePipelineLayout_(device_, &layout_info, nullptr,
                                &state.pipeline_layout) != VK_SUCCESS) {
      return false;
    }

    VkShaderModuleCreateInfo shader_info{};
    shader_info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    shader_info.codeSize = binary.word_count * sizeof(std::uint32_t);
    shader_info.pCode = binary.words;
    VkShaderModule module = VK_NULL_HANDLE;
    if (vkCreateShaderModule_(device_, &shader_info, nullptr, &module) !=
        VK_SUCCESS) {
      return false;
    }
    const auto destroy_module = [this, module]() {
      vkDestroyShaderModule_(device_, module, nullptr);
    };

    const std::array<std::uint32_t, 3> masks =
        kind == PipelineKind::kFullSweep
            ? std::array<std::uint32_t, 3>{0U, 1U, 7U}
            : std::array<std::uint32_t, 3>{0U, UINT32_MAX, UINT32_MAX};
    for (const std::uint32_t mask : masks) {
      if (mask == UINT32_MAX)
        continue;
      const std::array<VkBool32, 3> values = {{
          static_cast<VkBool32>((mask & 1U) != 0),
          static_cast<VkBool32>((mask & 2U) != 0),
          static_cast<VkBool32>((mask & 4U) != 0),
      }};
      const std::array<VkSpecializationMapEntry, 3> entries = {{
          {2, 0, sizeof(VkBool32)},
          {3, sizeof(VkBool32), sizeof(VkBool32)},
          {4, 2 * sizeof(VkBool32), sizeof(VkBool32)},
      }};
      VkSpecializationInfo specialization{};
      if (kind == PipelineKind::kFullSweep) {
        specialization.mapEntryCount =
            static_cast<std::uint32_t>(entries.size());
        specialization.pMapEntries = entries.data();
        specialization.dataSize = sizeof(values);
        specialization.pData = values.data();
      }
      VkPipelineShaderStageCreateInfo stage{};
      stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
      stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
      stage.module = module;
      stage.pName = "main";
      stage.pSpecializationInfo =
          kind == PipelineKind::kFullSweep ? &specialization : nullptr;
      VkComputePipelineCreateInfo pipeline_info{};
      pipeline_info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
      pipeline_info.flags =
          kind == PipelineKind::kInitialCost ||
                  kind == PipelineKind::kFullSweep
              ? VK_PIPELINE_CREATE_DISPATCH_BASE_BIT
              : 0U;
      pipeline_info.stage = stage;
      pipeline_info.layout = state.pipeline_layout;
      if (vkCreateComputePipelines_(device_, VK_NULL_HANDLE, 1, &pipeline_info,
                                    nullptr,
                                    &state.variants[mask]) != VK_SUCCESS) {
        destroy_module();
        return false;
      }
    }
    destroy_module();
    return true;
  }

  bool Begin() noexcept override {
    return ResetThenBeginCommandBuffer(
        [this]() noexcept {
          return vkResetCommandBuffer_(command_buffer_, 0) == VK_SUCCESS;
        },
        [this]() noexcept {
          VkCommandBufferBeginInfo info{};
          info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
          info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
          return vkBeginCommandBuffer_(command_buffer_, &info) == VK_SUCCESS;
        });
  }

  bool AllocateAndBindDescriptorSet(const PipelineKind kind,
                                    const Write *writes,
                                    const std::size_t count) noexcept override {
    PipelineState &state = pipelines_[static_cast<std::size_t>(kind)];
    VkDescriptorSetAllocateInfo allocate{};
    allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocate.descriptorPool = descriptor_pool_;
    allocate.descriptorSetCount = 1;
    allocate.pSetLayouts = &state.set_layout;
    VkDescriptorSet set = VK_NULL_HANDLE;
    if (vkAllocateDescriptorSets_(device_, &allocate, &set) != VK_SUCCESS) {
      return false;
    }
    std::vector<VkDescriptorBufferInfo> buffer_infos(count);
    std::vector<VkDescriptorImageInfo> image_infos(count);
    std::vector<VkWriteDescriptorSet> vk_writes(count);
    for (std::size_t index = 0; index < count; ++index) {
      VkWriteDescriptorSet &write = vk_writes[index];
      write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
      write.dstSet = set;
      write.dstBinding = writes[index].shader_binding;
      write.descriptorCount = 1;
      if (writes[index].combined_image_sampler) {
        VkDescriptorImageInfo &image = image_infos[index];
        image.sampler = FromOpaque<VkSampler>(writes[index].resource.sampler);
        image.imageView =
            FromOpaque<VkImageView>(writes[index].resource.image_view);
        image.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &image;
      } else {
        VkDescriptorBufferInfo &buffer = buffer_infos[index];
        buffer.buffer = FromOpaque<VkBuffer>(writes[index].resource.buffer);
        buffer.offset = writes[index].resource.offset;
        buffer.range = writes[index].resource.range;
        write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo = &buffer;
      }
    }
    vkUpdateDescriptorSets_(device_, static_cast<std::uint32_t>(count),
                            vk_writes.data(), 0, nullptr);
    vkCmdBindDescriptorSets_(command_buffer_, VK_PIPELINE_BIND_POINT_COMPUTE,
                             state.pipeline_layout, 0, 1, &set, 0, nullptr);
    state.active_descriptor_set = set;
    return true;
  }

  bool BindAndDispatch(const PipelineKind kind,
                       const std::uint32_t specialization_mask,
                       const void *push_constants,
                       const std::size_t push_constant_size,
                       const std::uint32_t x, const std::uint32_t y,
                       const std::uint32_t z) noexcept override {
    PipelineState &state = pipelines_[static_cast<std::size_t>(kind)];
    if (specialization_mask >= state.variants.size() ||
        state.variants[specialization_mask] == VK_NULL_HANDLE ||
        push_constant_size != PushConstantSize(kind)) {
      return false;
    }
    vkCmdBindPipeline_(command_buffer_, VK_PIPELINE_BIND_POINT_COMPUTE,
                       state.variants[specialization_mask]);
    vkCmdBindDescriptorSets_(
        command_buffer_, VK_PIPELINE_BIND_POINT_COMPUTE,
        state.pipeline_layout, 0, 1, &state.active_descriptor_set, 0, nullptr);
    vkCmdPushConstants_(
        command_buffer_, state.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0,
        static_cast<std::uint32_t>(push_constant_size), push_constants);
    vkCmdDispatch_(command_buffer_, x, y, z);
    return true;
  }

  bool BindAndDispatchPartitioned(
      const PipelineKind kind, const std::uint32_t specialization_mask,
      const void *push_constants, const std::size_t push_constant_size,
      const std::uint32_t x, const std::uint32_t y,
      const std::uint32_t z) noexcept override {
    PipelineState &state = pipelines_[static_cast<std::size_t>(kind)];
    const bool is_initial_cost = kind == PipelineKind::kInitialCost;
    const bool is_full_sweep = kind == PipelineKind::kFullSweep;
    if ((!is_initial_cost && !is_full_sweep) ||
        x == 0U || y == 0U || z == 0U ||
        specialization_mask >= state.variants.size() ||
        state.variants[specialization_mask] == VK_NULL_HANDLE ||
        state.active_descriptor_set == VK_NULL_HANDLE ||
        push_constants == nullptr ||
        push_constant_size != PushConstantSize(kind)) {
      return false;
    }
    const PatchPC &full_patch = *static_cast<const PatchPC *>(push_constants);
    const std::uint64_t physical_partition_count =
        PhysicalPartitionCount(kind, full_patch.height, x);
    if (physical_partition_count < 2U || full_patch.height > 32767U)
      return false;
    if (is_initial_cost) {
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
      std::fprintf(stderr,
                   "{\"runtime_stage\":\"before_initial_cost_partitions\","
                   "\"groups_x\":%u,\"height\":%u,\"row_tile\":%u}\n",
                   x, full_patch.height, kSweepRowTileHeight);
      std::fflush(stderr);
#endif
    }
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
    if (is_full_sweep) {
      std::fprintf(stderr,
                   "{\"runtime_stage\":\"before_pre_sweep_submit\","
                   "\"groups_x\":%u,\"height\":%u,\"row_tile\":%u,"
                   "\"dispatches_per_submit\":%llu}\n",
                   x, full_patch.height, kSweepRowTileHeight,
                   static_cast<unsigned long long>(
                       kPartitionDispatchesPerSubmit));
      std::fflush(stderr);
    }
#endif
    // Isolate all commands that precede the first full sweep. This keeps the
    // official operation order and resources unchanged while ensuring that an
    // iOS GPU timeout can be attributed to either pre-sweep work or one bounded
    // recurrence batch. Initial cost does not require this extra boundary.
    if (is_full_sweep && !SubmitWaitAndContinue())
      return false;
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
    if (is_full_sweep) {
      std::fprintf(stderr,
                   "{\"runtime_stage\":\"after_pre_sweep_submit\"}\n");
      std::fflush(stderr);
    }
#endif
    for (std::uint64_t index = 0U; index < physical_partition_count; ++index) {
      const PartitionDispatch partition =
          PartitionDispatchAt(kind, full_patch.height, x, index);
      if (!partition.valid)
        return false;
      PatchPC tiled_patch = full_patch;
      // rotation_0_to_3 is consumed only by host resource selection. These
      // kernels never use it for geometry, so its 32 bits carry the two 16-bit
      // execution bounds without expanding the frozen 128-byte ABI.
      tiled_patch.rotation_0_to_3 = PackSweepRowRange(
          partition.row_begin, partition.row_end, partition.backward);
      vkCmdBindPipeline_(command_buffer_, VK_PIPELINE_BIND_POINT_COMPUTE,
                         state.variants[specialization_mask]);
      vkCmdBindDescriptorSets_(command_buffer_, VK_PIPELINE_BIND_POINT_COMPUTE,
                               state.pipeline_layout, 0, 1,
                               &state.active_descriptor_set, 0, nullptr);
      vkCmdPushConstants_(command_buffer_, state.pipeline_layout,
                          VK_SHADER_STAGE_COMPUTE_BIT, 0,
                          static_cast<std::uint32_t>(push_constant_size),
                          &tiled_patch);
      vkCmdDispatchBase_(command_buffer_, partition.base_group_x, 0U, 0U, 1U,
                         y, z);
      if (partition.boundary_after == PartitionBoundary::kSubmitWait) {
        if (!SubmitWaitAndContinue())
          return false;
      } else if (partition.boundary_after == PartitionBoundary::kBarrier &&
                 !PipelineBarrier()) {
        return false;
      }
    }
    return true;
  }

  bool PipelineBarrier() noexcept override {
    VkMemoryBarrier barrier{};
    barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    barrier.srcAccessMask =
        VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask =
        VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT |
        VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT;
    vkCmdPipelineBarrier_(
        command_buffer_,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 1, &barrier, 0, nullptr, 0, nullptr);
    return true;
  }

  bool CopyBuffer(const std::uint64_t source, const std::uint64_t source_offset,
                  const std::uint64_t destination,
                  const std::uint64_t destination_offset,
                  const std::uint64_t byte_count) noexcept override {
    if (source == 0 || destination == 0 || byte_count == 0)
      return false;
    const VkBufferCopy region = {source_offset, destination_offset, byte_count};
    vkCmdCopyBuffer_(command_buffer_, FromOpaque<VkBuffer>(source),
                     FromOpaque<VkBuffer>(destination), 1, &region);
    return true;
  }

  bool TransitionSampledImage(const std::uint64_t image,
                              const bool to_transfer_destination) noexcept override {
    if (image == 0)
      return false;
    VkImageMemoryBarrier barrier{};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = to_transfer_destination
                            ? VK_IMAGE_LAYOUT_UNDEFINED
                            : VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = to_transfer_destination
                            ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
                            : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask = to_transfer_destination ? 0U
                                                     : VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = to_transfer_destination ? VK_ACCESS_TRANSFER_WRITE_BIT
                                                     : VK_ACCESS_SHADER_READ_BIT;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = FromOpaque<VkImage>(image);
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = VK_REMAINING_ARRAY_LAYERS;
    vkCmdPipelineBarrier_(
        command_buffer_,
        to_transfer_destination ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
                                : VK_PIPELINE_STAGE_TRANSFER_BIT,
        to_transfer_destination ? VK_PIPELINE_STAGE_TRANSFER_BIT
                                : VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0, 0, nullptr, 0, nullptr, 1, &barrier);
    return true;
  }

  bool ClearSampledImageFloat(const std::uint64_t image,
                              const float value) noexcept override {
    if (image == 0 || !std::isfinite(value))
      return false;
    VkClearColorValue clear{};
    clear.float32[0] = value;
    clear.float32[1] = value;
    clear.float32[2] = value;
    clear.float32[3] = value;
    VkImageSubresourceRange range{};
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.baseMipLevel = 0;
    range.levelCount = 1;
    range.baseArrayLayer = 0;
    range.layerCount = VK_REMAINING_ARRAY_LAYERS;
    vkCmdClearColorImage_(command_buffer_, FromOpaque<VkImage>(image),
                          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1,
                          &range);
    return true;
  }

  bool CopyBufferToImage(const std::uint64_t source,
                         const std::uint64_t source_offset,
                         const std::uint64_t destination_image,
                         const std::uint32_t destination_layer,
                         const std::uint32_t width,
                         const std::uint32_t height,
                         const std::uint32_t bytes_per_texel) noexcept override {
    if (source == 0 || destination_image == 0 || width == 0 || height == 0 ||
        (bytes_per_texel != 1U && bytes_per_texel != 4U))
      return false;
    VkBufferImageCopy region{};
    region.bufferOffset = source_offset;
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = 0;
    region.imageSubresource.baseArrayLayer = destination_layer;
    region.imageSubresource.layerCount = 1;
    region.imageExtent = {width, height, 1U};
    vkCmdCopyBufferToImage_(command_buffer_, FromOpaque<VkBuffer>(source),
                            FromOpaque<VkImage>(destination_image),
                            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    return true;
  }

  bool FillBuffer(const std::uint64_t buffer, const std::uint64_t offset,
                  const std::uint64_t byte_count,
                  const std::uint32_t value) noexcept override {
    if (buffer == 0 || byte_count == 0 || byte_count % 4U != 0)
      return false;
    vkCmdFillBuffer_(command_buffer_, FromOpaque<VkBuffer>(buffer), offset,
                     byte_count, value);
    return true;
  }

  bool CopyBufferRotatedU32(const std::uint64_t source,
                            const std::uint64_t source_offset,
                            const std::uint64_t destination,
                            const std::uint64_t destination_offset,
                            const std::uint32_t width,
                            const std::uint32_t height,
                            const std::uint32_t layers) noexcept override {
    const std::uint64_t plane_elements =
        static_cast<std::uint64_t>(width) * height;
    const std::uint64_t total_elements = plane_elements * layers;
    if (source == 0 || destination == 0 || source == destination ||
        width == 0 || height == 0 || layers == 0 ||
        total_elements > std::numeric_limits<std::uint32_t>::max() ||
        total_elements > std::numeric_limits<std::size_t>::max()) {
      return false;
    }
    std::vector<VkBufferCopy> regions;
    regions.reserve(static_cast<std::size_t>(total_elements));
    for (std::uint32_t layer = 0; layer < layers; ++layer) {
      for (std::uint32_t row = 0; row < height; ++row) {
        for (std::uint32_t col = 0; col < width; ++col) {
          const std::uint64_t input =
              static_cast<std::uint64_t>(layer) * plane_elements +
              static_cast<std::uint64_t>(row) * width + col;
          const std::uint64_t output =
              static_cast<std::uint64_t>(layer) * plane_elements +
              static_cast<std::uint64_t>(width - 1U - col) * height + row;
          regions.push_back({source_offset + input * 4U,
                             destination_offset + output * 4U, 4U});
        }
      }
    }
    vkCmdCopyBuffer_(command_buffer_, FromOpaque<VkBuffer>(source),
                     FromOpaque<VkBuffer>(destination),
                     static_cast<std::uint32_t>(regions.size()),
                     regions.data());
    return true;
  }

  bool EndSubmitAndWait() noexcept override {
    if (vkEndCommandBuffer_(command_buffer_) != VK_SUCCESS)
      return false;
    VkSubmitInfo submit{};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command_buffer_;
    return vkQueueSubmit_(queue_, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS &&
           vkQueueWaitIdle_(queue_) == VK_SUCCESS;
  }

  bool SubmitWaitAndContinue() noexcept override {
    return EndSubmitAndWait() && Begin();
  }

private:
  struct PipelineState {
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkDescriptorSet active_descriptor_set = VK_NULL_HANDLE;
    std::array<VkPipeline, 8> variants{};
  };

  bool FunctionsReady() const noexcept {
    return vkCreateDescriptorSetLayout_ && vkDestroyDescriptorSetLayout_ &&
           vkCreatePipelineLayout_ && vkDestroyPipelineLayout_ &&
           vkCreateShaderModule_ && vkDestroyShaderModule_ &&
           vkCreateComputePipelines_ && vkDestroyPipeline_ &&
           vkCreateDescriptorPool_ && vkDestroyDescriptorPool_ &&
           vkAllocateDescriptorSets_ && vkUpdateDescriptorSets_ &&
           vkResetCommandBuffer_ && vkBeginCommandBuffer_ &&
           vkEndCommandBuffer_ && vkCmdBindPipeline_ &&
           vkCmdBindDescriptorSets_ && vkCmdPushConstants_ && vkCmdDispatch_ &&
           vkCmdDispatchBase_ &&
           vkCmdPipelineBarrier_ && vkCmdCopyBuffer_ &&
           vkCmdCopyBufferToImage_ && vkCmdClearColorImage_ &&
           vkCmdFillBuffer_ &&
           vkQueueSubmit_ && vkQueueWaitIdle_;
  }

  void Reset() noexcept {
    if (device_ == VK_NULL_HANDLE)
      return;
    if (vkDestroyPipeline_ && vkDestroyPipelineLayout_ &&
        vkDestroyDescriptorSetLayout_) {
      for (PipelineState &state : pipelines_) {
        for (VkPipeline &pipeline : state.variants) {
          if (pipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline_(device_, pipeline, nullptr);
            pipeline = VK_NULL_HANDLE;
          }
        }
        if (state.pipeline_layout != VK_NULL_HANDLE) {
          vkDestroyPipelineLayout_(device_, state.pipeline_layout, nullptr);
          state.pipeline_layout = VK_NULL_HANDLE;
        }
        if (state.set_layout != VK_NULL_HANDLE) {
          vkDestroyDescriptorSetLayout_(device_, state.set_layout, nullptr);
          state.set_layout = VK_NULL_HANDLE;
        }
      }
    }
    if (descriptor_pool_ != VK_NULL_HANDLE && vkDestroyDescriptorPool_) {
      vkDestroyDescriptorPool_(device_, descriptor_pool_, nullptr);
      descriptor_pool_ = VK_NULL_HANDLE;
    }
  }

  VkInstance instance_ = VK_NULL_HANDLE;
  VkDevice device_ = VK_NULL_HANDLE;
  VkCommandBuffer command_buffer_ = VK_NULL_HANDLE;
  VkQueue queue_ = VK_NULL_HANDLE;
  VkDescriptorPool descriptor_pool_ = VK_NULL_HANDLE;
  std::array<PipelineState, kShaderCount> pipelines_{};

#define PW_DEVICE_MEMBER(name) PFN_##name name##_ = nullptr
  PW_DEVICE_MEMBER(vkCreateDescriptorSetLayout);
  PW_DEVICE_MEMBER(vkDestroyDescriptorSetLayout);
  PW_DEVICE_MEMBER(vkCreatePipelineLayout);
  PW_DEVICE_MEMBER(vkDestroyPipelineLayout);
  PW_DEVICE_MEMBER(vkCreateShaderModule);
  PW_DEVICE_MEMBER(vkDestroyShaderModule);
  PW_DEVICE_MEMBER(vkCreateComputePipelines);
  PW_DEVICE_MEMBER(vkDestroyPipeline);
  PW_DEVICE_MEMBER(vkCreateDescriptorPool);
  PW_DEVICE_MEMBER(vkDestroyDescriptorPool);
  PW_DEVICE_MEMBER(vkAllocateDescriptorSets);
  PW_DEVICE_MEMBER(vkUpdateDescriptorSets);
  PW_DEVICE_MEMBER(vkResetCommandBuffer);
  PW_DEVICE_MEMBER(vkBeginCommandBuffer);
  PW_DEVICE_MEMBER(vkEndCommandBuffer);
  PW_DEVICE_MEMBER(vkCmdBindPipeline);
  PW_DEVICE_MEMBER(vkCmdBindDescriptorSets);
  PW_DEVICE_MEMBER(vkCmdPushConstants);
  PW_DEVICE_MEMBER(vkCmdDispatch);
  PW_DEVICE_MEMBER(vkCmdDispatchBase);
  PW_DEVICE_MEMBER(vkCmdPipelineBarrier);
  PW_DEVICE_MEMBER(vkCmdCopyBuffer);
  PW_DEVICE_MEMBER(vkCmdCopyBufferToImage);
  PW_DEVICE_MEMBER(vkCmdClearColorImage);
  PW_DEVICE_MEMBER(vkCmdFillBuffer);
  PW_DEVICE_MEMBER(vkQueueSubmit);
  PW_DEVICE_MEMBER(vkQueueWaitIdle);
#undef PW_DEVICE_MEMBER
};

#endif // !PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING

} // namespace

const std::array<ShaderManifestEntry, kShaderCount> &
CanonicalShaderManifest() noexcept {
  return kShaderManifest;
}

bool BuildRotationCalibrationHost(
    const CalibrationBuildInput &input, std::array<PatchPC, 4> *const patches,
    float *const pose_values, const std::size_t pose_value_capacity) noexcept {
  if (patches == nullptr || pose_values == nullptr || input.sources == nullptr ||
      input.source_count == 0 || input.source_count != input.base_patch.num_sources ||
      input.base_patch.width == 0 || input.base_patch.height == 0 ||
      pose_value_capacity !=
          4U * kPoseFloatsPerReference(input.source_count))
    return false;
  std::array<std::array<float, 4>, 4> K{};
  for (auto &value : K)
    value = {input.reference.K[0], input.reference.K[2],
             input.reference.K[4], input.reference.K[5]};
  std::swap(K[1][0], K[1][2]);
  std::swap(K[1][1], K[1][3]);
  K[1][3] = static_cast<float>(input.base_patch.width - 1U) - K[1][3];
  K[2][1] = static_cast<float>(input.base_patch.width - 1U) - K[2][1];
  K[2][3] = static_cast<float>(input.base_patch.height - 1U) - K[2][3];
  std::swap(K[3][0], K[3][2]);
  std::swap(K[3][1], K[3][3]);
  K[3][1] = static_cast<float>(input.base_patch.height - 1U) - K[3][1];

  auto rotated_R = input.reference.R;
  auto rotated_T = input.reference.T;
  for (std::size_t rotation = 0; rotation < 4; ++rotation) {
    PatchPC patch = input.base_patch;
    if ((rotation & 1U) != 0U)
      std::swap(patch.width, patch.height);
    patch.rotation_0_to_3 = static_cast<std::uint32_t>(rotation);
    patch.ref_K_fx = K[rotation][0]; patch.ref_K_cx = K[rotation][1];
    patch.ref_K_fy = K[rotation][2]; patch.ref_K_cy = K[rotation][3];
    if (patch.ref_K_fx == 0.0F || patch.ref_K_fy == 0.0F)
      return false;
    patch.ref_inv_fx = 1.0F / patch.ref_K_fx;
    patch.ref_inv_neg_cx_fx = -patch.ref_K_cx / patch.ref_K_fx;
    patch.ref_inv_fy = 1.0F / patch.ref_K_fy;
    patch.ref_inv_neg_cy_fy = -patch.ref_K_cy / patch.ref_K_fy;
    (*patches)[rotation] = patch;

    // [BATCH-REF] 把这一轮的 ref_k / ref_inv_k 也写进本 reference 位姿区的
    // 尾部。sweep 批处理时从这里按 RefIndex() 读,不再走 push constant。
    // 值与 (*patches)[rotation] 里的完全相同,单 reference 时两条路等价
    // ⇒ N=1 必须逐字节不变。
    float *const tail = pose_values +
        rotation * kPoseFloatsPerReference(input.source_count) +
        input.source_count * kPoseFloatCount;
    tail[0] = patch.ref_K_fx;
    tail[1] = patch.ref_K_cx;
    tail[2] = patch.ref_K_fy;
    tail[3] = patch.ref_K_cy;
    tail[4] = patch.ref_inv_fx;
    tail[5] = patch.ref_inv_neg_cx_fx;
    tail[6] = patch.ref_inv_fy;
    tail[7] = patch.ref_inv_neg_cy_fy;

    for (std::size_t source_index = 0; source_index < input.source_count;
         ++source_index) {
      const CameraCalibrationInput &source = input.sources[source_index];
      float *const out =
          pose_values + rotation * kPoseFloatsPerReference(input.source_count) +
          source_index * kPoseFloatCount;
      out[0] = source.K[0]; out[1] = source.K[2];
      out[2] = source.K[4]; out[3] = source.K[5];
      float rel_R[9]{};
      float rel_T[3]{};
      for (std::size_t row = 0; row < 3; ++row) {
        for (std::size_t col = 0; col < 3; ++col) {
          for (std::size_t k = 0; k < 3; ++k)
            rel_R[row * 3U + col] +=
                source.R[row * 3U + k] * rotated_R[col * 3U + k];
          out[kPoseRotationOffset + row * 3U + col] =
              rel_R[row * 3U + col];
        }
        rel_T[row] = source.T[row];
        for (std::size_t k = 0; k < 3; ++k)
          rel_T[row] -= rel_R[row * 3U + k] * rotated_T[k];
        out[kPoseTranslationOffset + row] = rel_T[row];
      }
      for (std::size_t row = 0; row < 3; ++row) {
        float center = 0.0F;
        for (std::size_t k = 0; k < 3; ++k)
          center -= rel_R[k * 3U + row] * rel_T[k];
        out[kPoseProjectionCenterOffset + row] = center;
      }
      const float fx = source.K[0], cx = source.K[2];
      const float fy = source.K[4], cy = source.K[5];
      if (fx == 0.0F || fy == 0.0F)
        return false;
      const float inv_K[9] = {1.0F / fx, 0.0F, -cx / fx,
                              0.0F, 1.0F / fy, -cy / fy,
                              0.0F, 0.0F, 1.0F};
      for (std::size_t row = 0; row < 3; ++row) {
        for (std::size_t col = 0; col < 3; ++col) {
          float projected = 0.0F, inverse = 0.0F;
          for (std::size_t k = 0; k < 3; ++k) {
            projected += source.K[row * 3U + k] * rel_R[k * 3U + col];
            inverse += rel_R[k * 3U + row] * inv_K[k * 3U + col];
          }
          out[kPoseProjectionMatrixOffset + row * 4U + col] = projected;
          out[kPoseInverseProjectionMatrixOffset + row * 4U + col] = inverse;
        }
        float projected_t = 0.0F;
        for (std::size_t k = 0; k < 3; ++k)
          projected_t += source.K[row * 3U + k] * rel_T[k];
        out[kPoseProjectionMatrixOffset + row * 4U + 3U] = projected_t;
        out[kPoseInverseProjectionMatrixOffset + row * 4U + 3U] =
            out[kPoseProjectionCenterOffset + row];
      }
    }
    const auto previous_R = rotated_R;
    const auto previous_T = rotated_T;
    for (std::size_t col = 0; col < 3; ++col) {
      rotated_R[col] = previous_R[3U + col];
      rotated_R[3U + col] = -previous_R[col];
      rotated_R[6U + col] = previous_R[6U + col];
    }
    rotated_T = {previous_T[1], -previous_T[0], previous_T[2]};
  }
  return true;
}

std::uint32_t OfficialNccNormalizationBits(const float ncc_sigma) noexcept {
  if (!(ncc_sigma > 0.0F) || !std::isfinite(ncc_sigma))
    return 0;
  return sweep::EncodeNccNormFactorForPatchPcReservedBits(
      sweep::ComputeNccCostNormFactor(ncc_sigma));
}

bool ValidConsistencyGraphInput(const ConsistencyGraphInput &input) noexcept {
  return input.mask_words != nullptr && input.width != 0 && input.height != 0 &&
         input.depth != 0 && input.source_image_indices != nullptr &&
         input.source_image_count == input.depth &&
         input.width <= static_cast<std::uint32_t>(
                            std::numeric_limits<std::int32_t>::max()) &&
         input.height <= static_cast<std::uint32_t>(
                             std::numeric_limits<std::int32_t>::max()) &&
         input.depth <= static_cast<std::uint32_t>(
                            std::numeric_limits<std::int32_t>::max());
}

std::size_t RequiredConsistencyGraphValueCount(
    const ConsistencyGraphInput &input) noexcept {
  if (!ValidConsistencyGraphInput(input))
    return 0;
  std::size_t count = 0;
  const std::size_t plane =
      static_cast<std::size_t>(input.width) * input.height;
  for (std::uint32_t row = 0; row < input.height; ++row) {
    for (std::uint32_t col = 0; col < input.width; ++col) {
      std::size_t consistent = 0;
      for (std::uint32_t source = 0; source < input.depth; ++source) {
        if (input.mask_words[static_cast<std::size_t>(source) * plane +
                             static_cast<std::size_t>(row) * input.width +
                             col] != 0) {
          ++consistent;
        }
      }
      if (consistent != 0) {
        if (consistent > std::numeric_limits<std::size_t>::max() - count - 3U)
          return 0;
        count += 3U + consistent;
      }
    }
  }
  return count;
}

bool SerializeConsistencyGraph(const ConsistencyGraphInput &input,
                               std::int32_t *output,
                               const std::size_t output_count) noexcept {
  const std::size_t required = RequiredConsistencyGraphValueCount(input);
  if (!ValidConsistencyGraphInput(input) || output_count != required)
    return false;
  if (required == 0)
    return true;
  if (output == nullptr)
    return false;
  const std::size_t plane =
      static_cast<std::size_t>(input.width) * input.height;
  std::size_t cursor = 0;
  for (std::uint32_t row = 0; row < input.height; ++row) {
    for (std::uint32_t col = 0; col < input.width; ++col) {
      const std::size_t count_position = cursor + 2U;
      std::size_t consistent = 0;
      for (std::uint32_t source = 0; source < input.depth; ++source) {
        if (input.mask_words[static_cast<std::size_t>(source) * plane +
                             static_cast<std::size_t>(row) * input.width +
                             col] != 0) {
          if (consistent == 0) {
            output[cursor++] = static_cast<std::int32_t>(col);
            output[cursor++] = static_cast<std::int32_t>(row);
            ++cursor;
          }
          output[cursor++] = input.source_image_indices[source];
          ++consistent;
        }
      }
      if (consistent != 0) {
        output[count_position] = static_cast<std::int32_t>(consistent);
      }
    }
  }
  return cursor == required;
}

RecordResult Record(const RecordRequest &request) noexcept {
  const Certifications certifications = {
      rng::CanDispatchRngBackend(),
      cost_ops::TextureFixtureAllowsParity(),
      sweep::CanDispatchSweepBackend(),
  };

  // The current frozen contracts are all fail-closed, so no Vulkan loader or
  // handle is touched. Once separately reviewed contracts become certified,
  // this exact branch initializes the Android/system or injected loader.
  const char *gate_detail = nullptr;
  if (CertificationStatus(certifications, &gate_detail) !=
      RuntimeStatus::kRecorded) {
    return RecordImpl(request, certifications, nullptr);
  }

#if defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)
  return RecordImpl(request, certifications, nullptr);
#else
  if (request.plan == nullptr || !request.plan->Validate() ||
      !ValidRequest(request)) {
    return RecordImpl(request, certifications, nullptr);
  }
  NativeBackend backend;
  RecordResult result;
  const std::size_t descriptor_budget = DescriptorBudget(request);
  result.status =
      backend.Initialize(request.native, descriptor_budget, &result.detail);
  if (result.status != RuntimeStatus::kRecorded)
    return result;
  return RecordImpl(request, certifications, &backend);
#endif
}

#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC) && \
    !defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)

RecordResult RecordNativeForDiagnostic(const RecordRequest &request) noexcept {
  const Certifications diagnostic_certification_override = {true, true, true};
  if (request.plan == nullptr || !request.plan->Validate() ||
      !ValidRequest(request)) {
    return RecordImpl(request, diagnostic_certification_override, nullptr);
  }
  NativeBackend backend;
  RecordResult result;
  result.status = backend.Initialize(request.native, DescriptorBudget(request),
                                     &result.detail);
  if (result.status != RuntimeStatus::kRecorded) return result;
  return RecordImpl(request, diagnostic_certification_override, &backend);
}

#endif

#if defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)

using NativeCommandStepForTesting = bool (*)(void *) noexcept;

bool ResetThenBeginCommandBufferForTesting(
    void *const context, const NativeCommandStepForTesting reset,
    const NativeCommandStepForTesting begin) noexcept {
  if (context == nullptr || reset == nullptr || begin == nullptr)
    return false;
  return ResetThenBeginCommandBuffer(
      [context, reset]() noexcept { return reset(context); },
      [context, begin]() noexcept { return begin(context); });
}

namespace {
class FakeBackendAdapter final : public Backend {
public:
  explicit FakeBackendAdapter(FakeDispatchBackend *backend) noexcept
      : backend_(backend) {}

  bool CreatePipeline(const PipelineKind kind,
                      const ShaderBinary &binary) noexcept override {
    return backend_->CreatePipeline(kind, binary);
  }
  bool Begin() noexcept override { return backend_->Begin(); }
  bool AllocateAndBindDescriptorSet(const PipelineKind kind,
                                    const Write *writes,
                                    const std::size_t count) noexcept override {
    std::vector<DescriptorWrite> converted;
    converted.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
      converted.push_back({writes[index].shader_binding,
                           writes[index].combined_image_sampler,
                           writes[index].resource});
    }
    return backend_->AllocateAndBindDescriptorSet(kind, converted.data(),
                                                  converted.size());
  }
  bool BindAndDispatch(const PipelineKind kind,
                       const std::uint32_t specialization_mask,
                       const void *push_constants,
                       const std::size_t push_constant_size,
                       const std::uint32_t x, const std::uint32_t y,
                       const std::uint32_t z) noexcept override {
    return backend_->BindAndDispatch(kind, specialization_mask, push_constants,
                                     push_constant_size, x, y, z);
  }
  bool BindAndDispatchPartitioned(
      const PipelineKind kind, const std::uint32_t specialization_mask,
      const void *push_constants, const std::size_t push_constant_size,
      const std::uint32_t x, const std::uint32_t y,
      const std::uint32_t z) noexcept override {
    return backend_->BindAndDispatchPartitioned(
        kind, specialization_mask, push_constants, push_constant_size, x, y,
        z);
  }
  bool PipelineBarrier() noexcept override {
    return backend_->PipelineBarrier();
  }
  bool CopyBuffer(const std::uint64_t source, const std::uint64_t source_offset,
                  const std::uint64_t destination,
                  const std::uint64_t destination_offset,
                  const std::uint64_t byte_count) noexcept override {
    return backend_->CopyBuffer(source, source_offset, destination,
                                destination_offset, byte_count);
  }
  bool TransitionSampledImage(const std::uint64_t image,
                              const bool to_transfer_destination) noexcept override {
    return backend_->TransitionSampledImage(image, to_transfer_destination);
  }
  bool ClearSampledImageFloat(const std::uint64_t image,
                              const float value) noexcept override {
    return backend_->ClearSampledImageFloat(image, value);
  }
  bool CopyBufferToImage(const std::uint64_t source,
                         const std::uint64_t source_offset,
                         const std::uint64_t destination_image,
                         const std::uint32_t destination_layer,
                         const std::uint32_t width,
                         const std::uint32_t height,
                         const std::uint32_t bytes_per_texel) noexcept override {
    return backend_->CopyBufferToImage(
        source, source_offset, destination_image, destination_layer, width,
        height, bytes_per_texel);
  }
  bool FillBuffer(const std::uint64_t buffer, const std::uint64_t offset,
                  const std::uint64_t byte_count,
                  const std::uint32_t value) noexcept override {
    return backend_->FillBuffer(buffer, offset, byte_count, value);
  }
  bool CopyBufferRotatedU32(const std::uint64_t source,
                            const std::uint64_t source_offset,
                            const std::uint64_t destination,
                            const std::uint64_t destination_offset,
                            const std::uint32_t width,
                            const std::uint32_t height,
                            const std::uint32_t layers) noexcept override {
    return backend_->CopyBufferRotatedU32(source, source_offset, destination,
                                          destination_offset, width, height,
                                          layers);
  }
  bool SubmitWaitAndContinue() noexcept override {
    return backend_->SubmitWaitAndContinue();
  }
  bool EndSubmitAndWait() noexcept override {
    return backend_->EndSubmitAndWait();
  }

private:
  FakeDispatchBackend *backend_;
};
} // namespace

RecordResult RecordForTesting(const RecordRequest &request,
                              const TestCertifications &certifications,
                              FakeDispatchBackend *backend) noexcept {
  const Certifications internal = {
      certifications.pcg, certifications.texture, certifications.full_sweep};
  if (backend == nullptr)
    return RecordImpl(request, internal, nullptr);
  FakeBackendAdapter adapter(backend);
  return RecordImpl(request, internal, &adapter);
}

#endif

} // namespace pocketworld::official_dense::vulkan::runtime
