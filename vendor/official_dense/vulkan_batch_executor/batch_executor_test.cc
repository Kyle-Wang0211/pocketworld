// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "batch_executor.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace vulkan = pocketworld::official_dense::vulkan;
namespace arena = vulkan::resource_arena;
namespace executor = vulkan::batch_executor;
namespace runtime = vulkan::runtime;

namespace {

int Require(const bool value, const int code) {
  if (!value) std::fprintf(stderr, "batch_executor_test failure %d\n", code);
  return value ? 0 : code;
}

struct Bytes {
  explicit Bytes(const std::size_t size) : values(size) {}
  std::vector<std::uint8_t> values;
};

class Provider final : public arena::ResourceAllocationProvider {
 public:
  bool CreateBufferAllocation(
      const vulkan::BufferAllocationSpec &spec,
      arena::ProviderBufferAllocation *const out,
      std::string *) noexcept override {
    try {
      auto bytes = std::make_shared<Bytes>(
          static_cast<std::size_t>(spec.byte_count));
      const std::uint64_t handle = 1000U + ++buffer_count;
      mapped.emplace(handle, bytes);
      out->buffer_handle = handle;
      out->byte_count = spec.byte_count;
      out->mapped_pointer =
          spec.memory_class == vulkan::BufferMemoryClass::kDeviceLocal
              ? nullptr
              : bytes->values.data();
      out->host_coherent = out->mapped_pointer != nullptr;
      out->lifetime = std::move(bytes);
      return true;
    } catch (...) {
      return false;
    }
  }

  bool CreateSampledImageAllocation(
      const vulkan::SampledImageSpec &spec,
      arena::ProviderSampledImageAllocation *const out,
      std::string *) noexcept override {
    try {
      const std::uint64_t base = 100000U + ++image_count * 10U;
      out->image_handle = base + 1U;
      out->image_view_handle = base + 2U;
      out->sampler_handle = base + 3U;
      out->spec = spec;
      out->lifetime = std::make_shared<int>(1);
      return true;
    } catch (...) {
      return false;
    }
  }

  bool SetWord(const std::uint64_t handle, const std::size_t index,
               const std::uint32_t value) {
    const auto found = mapped.find(handle);
    if (found == mapped.end()) return false;
    const std::shared_ptr<Bytes> bytes = found->second.lock();
    if (!bytes || (index + 1U) * sizeof(value) > bytes->values.size()) {
      return false;
    }
    auto *const words =
        reinterpret_cast<std::uint32_t *>(bytes->values.data());
    words[index] = value;
    return true;
  }

  std::size_t buffer_count = 0U;
  std::size_t image_count = 0U;
  std::map<std::uint64_t, std::weak_ptr<Bytes>> mapped;
};

class Backend final : public runtime::FakeDispatchBackend {
 public:
  bool CreatePipeline(const runtime::PipelineKind,
                      const runtime::ShaderBinary &) noexcept override {
    ++pipelines;
    return true;
  }
  bool Begin() noexcept override {
    ++begins;
    return true;
  }
  bool AllocateAndBindDescriptorSet(
      const runtime::PipelineKind, const runtime::DescriptorWrite *const writes,
      const std::size_t count) noexcept override {
    if (writes == nullptr || count == 0U) return false;
    ++descriptor_sets;
    return true;
  }
  bool BindAndDispatch(const runtime::PipelineKind, const std::uint32_t,
                       const void *const push_constants,
                       const std::size_t push_constant_size,
                       const std::uint32_t x, const std::uint32_t y,
                       const std::uint32_t z) noexcept override {
    if (push_constants == nullptr || push_constant_size == 0U || x == 0U ||
        y == 0U || z == 0U) {
      return false;
    }
    ++dispatches;
    return true;
  }
  bool BindAndDispatchPartitioned(
      const runtime::PipelineKind kind, const std::uint32_t mask,
      const void *const push_constants,
      const std::size_t push_constant_size, const std::uint32_t x,
      const std::uint32_t y, const std::uint32_t z) noexcept override {
    return BindAndDispatch(kind, mask, push_constants, push_constant_size,
                           x, y, z);
  }
  bool PipelineBarrier() noexcept override {
    ++barriers;
    return true;
  }
  bool CopyBuffer(const std::uint64_t source, const std::uint64_t,
                  const std::uint64_t destination, const std::uint64_t,
                  const std::uint64_t byte_count) noexcept override {
    if (source == 0U || destination == 0U || byte_count == 0U) return false;
    ++buffer_copies;
    return true;
  }
  bool TransitionSampledImage(
      const std::uint64_t image,
      const bool) noexcept override {
    if (image == 0U) return false;
    ++image_transitions;
    return true;
  }
  bool ClearSampledImageFloat(const std::uint64_t image,
                              const float) noexcept override {
    if (image == 0U) return false;
    ++image_clears;
    return true;
  }
  bool CopyBufferToImage(const std::uint64_t source, const std::uint64_t,
                         const std::uint64_t destination_image,
                         const std::uint32_t, const std::uint32_t width,
                         const std::uint32_t height,
                         const std::uint32_t bytes_per_texel) noexcept override {
    if (source == 0U || destination_image == 0U || width == 0U || height == 0U ||
        bytes_per_texel == 0U) {
      return false;
    }
    ++image_copies;
    return true;
  }
  bool FillBuffer(const std::uint64_t buffer, const std::uint64_t,
                  const std::uint64_t byte_count,
                  const std::uint32_t) noexcept override {
    if (buffer == 0U || byte_count == 0U) return false;
    ++fills;
    return true;
  }
  bool CopyBufferRotatedU32(
      const std::uint64_t source, const std::uint64_t,
      const std::uint64_t destination, const std::uint64_t,
      const std::uint32_t width, const std::uint32_t height,
      const std::uint32_t layers) noexcept override {
    if (source == 0U || destination == 0U || source == destination ||
        width == 0U || height == 0U || layers == 0U) {
      return false;
    }
    ++rotated_copies;
    return true;
  }
  bool SubmitWaitAndContinue() noexcept override {
    ++submits;
    ++begins;
    return true;
  }
  bool EndSubmitAndWait() noexcept override {
    ++submits;
    return true;
  }

  std::size_t pipelines = 0U;
  std::size_t begins = 0U;
  std::size_t descriptor_sets = 0U;
  std::size_t dispatches = 0U;
  std::size_t barriers = 0U;
  std::size_t buffer_copies = 0U;
  std::size_t image_transitions = 0U;
  std::size_t image_clears = 0U;
  std::size_t image_copies = 0U;
  std::size_t fills = 0U;
  std::size_t rotated_copies = 0U;
  std::size_t submits = 0U;
};

runtime::CameraCalibrationInput Camera(const float x) {
  runtime::CameraCalibrationInput out;
  out.K = {100.0F, 0.0F, 1.0F, 0.0F, 101.0F, 1.0F, 0.0F, 0.0F, 1.0F};
  out.R = {1.0F, 0.0F, 0.0F, 0.0F, 1.0F, 0.0F, 0.0F, 0.0F, 1.0F};
  out.T = {x, 0.0F, 0.0F};
  return out;
}

vulkan::PatchPC Patch() {
  vulkan::PatchPC patch{};
  patch.width = 2U;
  patch.height = 2U;
  patch.num_sources = 2U;
  patch.workspace_max_dim = 2U;
  patch.source_width = 2U;
  patch.source_height = 2U;
  patch.perturbation = 0.5F;
  patch.depth_min = 0.1F;
  patch.depth_max = 8.0F;
  patch.num_samples = 15;
  patch.sigma_spatial = 5.0F;
  patch.sigma_color = 0.2F;
  patch.ncc_sigma = 0.6F;
  patch.prev_sel_prob_weight = 0.9F;
  return patch;
}

constexpr std::array<std::array<std::uint32_t, 5>, runtime::kShaderCount>
    kSpirv = {{
        {{0x07230203U, 0x10000U, 0U, 1U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 2U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 3U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 4U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 5U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 6U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 7U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 8U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 9U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 10U, 0U}},
        {{0x07230203U, 0x10000U, 0U, 11U, 0U}},
    }};

runtime::ShaderBundle Shaders() {
  runtime::ShaderBundle bundle;
  for (std::size_t index = 0U; index < runtime::kShaderCount; ++index) {
    bundle.binaries[index] = {
        static_cast<runtime::PipelineKind>(index), kSpirv[index].data(),
        kSpirv[index].size(),
        runtime::CanonicalShaderManifest()[index].source_sha256};
  }
  return bundle;
}

}  // namespace

int main() {
  std::array<std::uint32_t, 4> reference = {1U, 2U, 3U, 4U};
  std::array<std::uint32_t, 8> gray_u32 = {1U, 2U, 3U, 4U,
                                           5U, 6U, 7U, 8U};
  std::array<std::uint8_t, 8> gray_u8 = {1U, 2U, 3U, 4U,
                                         5U, 6U, 7U, 8U};
  std::array<runtime::CameraCalibrationInput, 2> cameras = {
      Camera(0.1F), Camera(0.2F)};
  std::array<arena::SourceResourceRef, 2> sources = {
      {{0U, 70, 2U, 2U}, {0U, 70, 2U, 2U}}};

  arena::ResourceArenaImageInput input;
  input.image_index = 70;
  input.resources = {2U, 2U, 2U, 2U, 2U, 2U};
  input.calibration =
      {Patch(), Camera(0.0F), cameras.data(), cameras.size()};
  input.reference_u32 = reference.data();
  input.reference_u32_count = reference.size();
  input.source_gray_u32 = gray_u32.data();
  input.source_gray_u32_count = gray_u32.size();
  input.source_gray_u8 = gray_u8.data();
  input.source_gray_u8_count = gray_u8.size();
  input.reference_content_identity = 10U;
  input.source_depth_content_identity = 20U;
  input.source_gray_content_identity = 30U;
  input.pose_content_identities = {40U, 50U, 60U, 70U};
  input.sources = sources.data();
  input.source_count = sources.size();

  Provider provider;
  arena::ResourceArenaBatch batch;
  std::string detail;
  if (int error = Require(arena::BuildResourceArenaBatch(
                              &input, 1U, &provider, &batch, &detail),
                          1)) {
    return error;
  }
  const runtime::ImageResources *const images = batch.images();
  if (int error = Require(images != nullptr && batch.image_count() == 1U, 2)) {
    return error;
  }
  const std::uint64_t mask_handle = images[0].geometric.mask_readback.buffer;
  if (int error = Require(provider.SetWord(mask_handle, 0U, 1U) &&
                              provider.SetWord(mask_handle, 4U, 1U),
                          3)) {
    return error;
  }

  executor::BatchExecuteRequest request;
  request.arena = &batch;
  request.shaders = Shaders();
  const runtime::RecordResult production =
      executor::ExecuteResourceArenaBatch(request);
  if (int error = Require(
          production.status == runtime::RuntimeStatus::kPcgAdaptationNotCertified &&
              production.recorded_plan_steps == 0U,
          4)) {
    return error;
  }

  runtime::TestCertifications gates;
  gates.pcg = true;
  gates.texture = true;
  gates.full_sweep = true;
  Backend backend;
  const runtime::RecordResult result =
      executor::ExecuteResourceArenaBatchForTesting(request, gates, &backend);
  if (int error = Require(result.recorded() &&
                              result.recorded_plan_steps == 552U &&
                              result.consistency_graph_value_count == 5U,
                          5)) {
    return error;
  }
  if (int error = Require(
          backend.pipelines == runtime::kShaderCount &&
              backend.begins == backend.submits && backend.submits > 1U &&
              backend.dispatches > 0U &&
              backend.descriptor_sets > 0U && backend.barriers > 0U &&
              backend.buffer_copies > 0U && backend.image_transitions > 0U &&
              backend.image_clears > 0U && backend.image_copies > 0U &&
              backend.fills > 0U && backend.rotated_copies == 0U,
          6)) {
    return error;
  }
  const runtime::ConsistencyGraphReadback &graph =
      images[0].consistency_graph_readback;
  if (int error = Require(
          *graph.value_count == 5U && graph.values[0] == 0 &&
              graph.values[1] == 0 && graph.values[2] == 2 &&
              graph.values[3] == 70 && graph.values[4] == 70,
          7)) {
    return error;
  }
  return 0;
}
