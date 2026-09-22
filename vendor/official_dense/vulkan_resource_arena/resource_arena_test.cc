// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "resource_arena.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace arena =
    pocketworld::official_dense::vulkan::resource_arena;
namespace runtime = pocketworld::official_dense::vulkan::runtime;
using pocketworld::official_dense::vulkan::BufferAllocationSpec;
using pocketworld::official_dense::vulkan::ImageSamplerKind;
using pocketworld::official_dense::vulkan::SampledImageFormat;
using pocketworld::official_dense::vulkan::SampledImageSpec;
using pocketworld::official_dense::vulkan::PatchPC;
using pocketworld::official_dense::vulkan::kPoseFloatCount;

namespace {

int Require(const bool condition, const int code) {
  if (!condition) std::fprintf(stderr, "resource_arena_test failure %d\n", code);
  return condition ? 0 : code;
}

struct Memory {
  explicit Memory(const std::size_t size, std::size_t *const releases)
      : bytes(size), releases(releases) {}
  ~Memory() { ++*releases; }
  std::vector<std::uint8_t> bytes;
  std::size_t *releases;
};

struct ImageLifetime {
  explicit ImageLifetime(std::size_t *const releases) : releases(releases) {}
  ~ImageLifetime() { ++*releases; }
  std::size_t *releases;
};

class FakeProvider final : public arena::ResourceAllocationProvider {
 public:
  std::size_t fail_buffer_call = 0U;
  std::size_t fail_image_call = 0U;
  std::size_t collide_buffer_call = 0U;
  std::size_t collide_image_call = 0U;
  std::size_t collide_sampler_call = 0U;
  std::size_t buffer_calls = 0U;
  std::size_t image_calls = 0U;
  std::size_t buffer_releases = 0U;
  std::size_t image_releases = 0U;
  std::vector<BufferAllocationSpec> buffer_specs;
  std::vector<SampledImageSpec> image_specs;
  std::map<std::uint64_t, std::weak_ptr<Memory>> memories;

  bool CreateBufferAllocation(const BufferAllocationSpec &spec,
                              arena::ProviderBufferAllocation *const out,
                              std::string *) noexcept override {
    ++buffer_calls;
    if (buffer_calls == fail_buffer_call) return false;
    try {
      buffer_specs.push_back(spec);
      auto memory = std::make_shared<Memory>(
          static_cast<std::size_t>(spec.byte_count), &buffer_releases);
      const std::uint64_t handle = buffer_calls == collide_buffer_call
                                       ? 1001U
                                       : 1000U + buffer_calls;
      memories.emplace(handle, memory);
      out->buffer_handle = handle;
      out->byte_count = spec.byte_count;
      out->mapped_pointer =
          spec.memory_class == pocketworld::official_dense::vulkan::
                                   BufferMemoryClass::kDeviceLocal
              ? nullptr
              : memory->bytes.data();
      out->host_coherent = out->mapped_pointer != nullptr;
      out->lifetime = std::move(memory);
      return true;
    } catch (...) {
      return false;
    }
  }

  bool CreateSampledImageAllocation(
      const SampledImageSpec &spec,
      arena::ProviderSampledImageAllocation *const out,
      std::string *) noexcept override {
    ++image_calls;
    if (image_calls == fail_image_call) return false;
    try {
      image_specs.push_back(spec);
      const std::uint64_t base = 100000U + image_calls * 10U;
      const std::uint64_t first_base = 100010U;
      out->image_handle = image_calls == collide_image_call
                              ? first_base + 1U
                              : base + 1U;
      out->image_view_handle = image_calls == collide_image_call
                                   ? first_base + 2U
                                   : base + 2U;
      out->sampler_handle = image_calls == collide_sampler_call
                                ? first_base + 3U
                                : base + 3U;
      out->spec = spec;
      out->lifetime = std::make_shared<ImageLifetime>(&image_releases);
      return true;
    } catch (...) {
      return false;
    }
  }

  const std::vector<std::uint8_t> &Bytes(const std::uint64_t handle) const {
    return memories.at(handle).lock()->bytes;
  }
};

runtime::CameraCalibrationInput Camera(const float cx) {
  runtime::CameraCalibrationInput camera;
  camera.K = {100.0F, 0.0F, cx, 0.0F, 101.0F, 1.0F, 0.0F, 0.0F, 1.0F};
  camera.R = {1.0F, 0.0F, 0.0F, 0.0F, 1.0F, 0.0F, 0.0F, 0.0F, 1.0F};
  camera.T = {cx * 0.01F, 0.0F, 0.0F};
  return camera;
}

PatchPC Patch(const std::uint32_t width, const std::uint32_t height) {
  PatchPC patch{};
  patch.width = width;
  patch.height = height;
  patch.num_sources = 2U;
  patch.workspace_max_dim = width > height ? width : height;
  patch.source_width = 3U;
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

struct Prepared {
  arena::ResourceArenaImageInput input;
  std::vector<std::uint32_t> reference;
  std::vector<std::uint32_t> gray_u32;
  std::vector<std::uint8_t> gray_u8;
  std::array<runtime::CameraCalibrationInput, 2> cameras;
  std::array<arena::SourceResourceRef, 2> sources;
};

std::array<Prepared, 2> Inputs() {
  std::array<Prepared, 2> prepared;
  constexpr std::array<std::uint32_t, 2> widths = {2U, 3U};
  for (std::size_t image = 0U; image < prepared.size(); ++image) {
    Prepared &p = prepared[image];
    const std::uint32_t width = widths[image];
    p.reference.resize(static_cast<std::size_t>(width) * 2U);
    for (std::size_t i = 0U; i < p.reference.size(); ++i) {
      p.reference[i] = static_cast<std::uint32_t>(100U * image + i + 1U);
    }
    p.gray_u32.resize(12U);
    p.gray_u8.resize(12U);
    for (std::size_t i = 0U; i < 12U; ++i) {
      p.gray_u32[i] = static_cast<std::uint32_t>(1000U * image + i);
      p.gray_u8[i] = static_cast<std::uint8_t>(20U * image + i);
    }
    p.cameras = {Camera(static_cast<float>(image)),
                 Camera(static_cast<float>(image + 1U))};
    p.sources = {{{0U, 70, 2U, 2U}, {1U, 71, 3U, 2U}}};
    p.input.image_index = static_cast<std::int32_t>(70U + image);
    p.input.resources = {width, 2U, 3U, 2U, 2U, width};
    p.input.calibration =
        {Patch(width, 2U), Camera(static_cast<float>(image + 2U)),
         p.cameras.data(), p.cameras.size()};
    p.input.reference_u32 = p.reference.data();
    p.input.reference_u32_count = p.reference.size();
    p.input.source_gray_u32 = p.gray_u32.data();
    p.input.source_gray_u32_count = p.gray_u32.size();
    p.input.source_gray_u8 = p.gray_u8.data();
    p.input.source_gray_u8_count = p.gray_u8.size();
    p.input.reference_content_identity = 10U + image;
    p.input.source_depth_content_identity = 20U + image;
    p.input.source_gray_content_identity = 30U + image;
    p.input.pose_content_identities = {40U + image, 50U + image,
                                       60U + image, 70U + image};
    p.input.sources = p.sources.data();
    p.input.source_count = p.sources.size();
  }
  return prepared;
}

bool SameBytes(const std::vector<std::uint8_t> &actual, const void *expected,
               const std::size_t size) {
  return actual.size() == size && std::memcmp(actual.data(), expected, size) == 0;
}

}  // namespace

int main() {
  auto prepared = Inputs();
  // Repair views into inline arrays after the aggregate return/move.
  for (Prepared &item : prepared) {
    item.input.calibration.sources = item.cameras.data();
    item.input.sources = item.sources.data();
  }
  std::array<arena::ResourceArenaImageInput, 2> inputs = {
      prepared[0].input, prepared[1].input};
  FakeProvider provider;
  arena::ResourceArenaBatch batch;
  std::string detail;
  const bool built = arena::BuildResourceArenaBatch(
      inputs.data(), inputs.size(), &provider, &batch, &detail);
  if (!built) {
    std::fprintf(stderr, "detail: %s calls=%zu specs=%zu\n", detail.c_str(),
                 provider.buffer_calls, provider.buffer_specs.size());
  }
  if (int e = Require(built, 1)) return e;
  if (int e = Require(batch.image_count() == 2U && batch.images() != nullptr &&
                          provider.buffer_calls == 202U &&
                          provider.image_calls == 4U,
                      2)) return e;

  const runtime::ImageResources *const images = batch.images();
  for (std::size_t image = 0U; image < 2U; ++image) {
    const auto &photo = images[image].photometric;
    const auto &geo = images[image].geometric;
    if (int e = Require(
            photo.bindings[8][0].buffer == geo.bindings[8][3].buffer &&
                photo.bindings[12][0].image == geo.bindings[12][3].image &&
                photo.bindings[14][0].buffer == geo.bindings[14][3].buffer &&
                photo.bindings[14][0].image == geo.bindings[14][3].image &&
                photo.bindings[12][0].image != photo.bindings[14][0].image &&
                photo.bindings[7][0].buffer == photo.bindings[7][3].buffer &&
                photo.bindings[7][0].buffer != geo.bindings[7][0].buffer &&
                photo.bindings[0][0].buffer != photo.bindings[0][1].buffer &&
                photo.bindings[0][0].buffer != geo.bindings[0][0].buffer &&
                photo.bindings[14][0].range == 48U &&
                photo.bindings[14][0].array_layers == 2U &&
                photo.bindings[14][0].scalar_type ==
                    runtime::ResourceScalarType::kUint32 &&
                photo.bindings[12][0].sampler_metadata.min_filter ==
                    runtime::SamplerFilter::kNearest &&
                photo.bindings[14][0].sampler_metadata.min_filter ==
                    runtime::SamplerFilter::kLinear,
            3)) return e;
    if (int e = Require(
            photo.source_gray_image_upload_staging.range == 12U &&
                photo.source_gray_image_upload_staging.element_size == 4U &&
                photo.source_gray_image_upload_staging.scalar_type ==
                    runtime::ResourceScalarType::kUint32,
            16)) return e;
    if (int e = Require(
            images[image].consistency_graph.source_image_count == 2U &&
                images[image].consistency_graph.source_image_indices[0] == 70 &&
                images[image].consistency_graph.source_image_indices[1] == 71 &&
                images[image].source_depth_layer_count == 2U &&
                images[image].source_depth_layers[0].source_image_slot == 0U &&
                images[image].source_depth_layers[1].source_image_slot == 1U &&
                images[image].source_depth_layers[1].destination_layer == 1U &&
                images[image].source_depth_layers[1].width == 3U &&
                images[image].consistency_graph_readback.mapped_mask_words ==
                    reinterpret_cast<const std::uint32_t *>(
                        provider.memories
                            .at(geo.mask_readback.buffer)
                            .lock()
                            ->bytes.data()) &&
                images[image].consistency_graph_readback.value_capacity ==
                    static_cast<std::size_t>(prepared[image].input.resources.width) *
                        2U * 5U,
            4)) return e;

    if (int e = Require(
            SameBytes(provider.Bytes(photo.reference_upload_staging.buffer),
                      prepared[image].reference.data(),
                      prepared[image].reference.size() * sizeof(std::uint32_t)) &&
                SameBytes(provider.Bytes(photo.source_gray_upload_staging.buffer),
                          prepared[image].gray_u32.data(), 48U) &&
                SameBytes(
                    provider.Bytes(photo.source_gray_image_upload_staging.buffer),
                    prepared[image].gray_u8.data(), 12U),
            5)) return e;

    std::array<PatchPC, 4> expected_patches{};
    std::array<float, 4U * 2U * kPoseFloatCount> expected_poses{};
    if (int e = Require(runtime::BuildRotationCalibrationHost(
                            prepared[image].input.calibration,
                            &expected_patches, expected_poses.data(),
                            expected_poses.size()),
                        6)) return e;
    for (std::size_t rotation = 0U; rotation < 4U; ++rotation) {
      const auto &calibration = images[image].calibration[rotation];
      if (int e = Require(
              calibration.patch.rotation_0_to_3 == rotation &&
                  calibration.active_pose_table.content_identity ==
                      prepared[image].input.pose_content_identities[rotation] &&
                  calibration.active_pose_table.content_identity ==
                      calibration.pose_upload_staging.content_identity &&
                  SameBytes(
                      provider.Bytes(calibration.pose_upload_staging.buffer),
                      expected_poses.data() + rotation * 2U * kPoseFloatCount,
                      2U * kPoseFloatCount * sizeof(float)),
              7)) return e;
    }
  }

  const runtime::ImageResources *const stable = batch.images();
  arena::ResourceArenaBatch moved(std::move(batch));
  if (int e = Require(batch.empty() && moved.images() == stable &&
                          moved.images()[1].source_depth_layers[1].width == 3U,
                      8)) return e;

  // COLMAP's geometric pass reloads previously written photometric source
  // depths. The phone implementation must preserve that exact layered input
  // without keeping every source PatchMatch arena resident on the GPU.
  std::vector<float> streamed_depth(12U);
  for (std::size_t i = 0U; i < streamed_depth.size(); ++i) {
    streamed_depth[i] = 0.25F + static_cast<float>(i);
  }
  std::vector<float> streamed_reference_depth(4U);
  std::vector<float> streamed_reference_normal(12U);
  for (std::size_t i = 0U; i < streamed_reference_depth.size(); ++i) {
    streamed_reference_depth[i] = 1.25F + static_cast<float>(i);
  }
  for (std::size_t i = 0U; i < streamed_reference_normal.size(); ++i) {
    streamed_reference_normal[i] = -0.75F + static_cast<float>(i) * 0.125F;
  }
  arena::ResourceArenaImageInput streamed_input = prepared[0].input;
  streamed_input.resources.phase =
      pocketworld::official_dense::vulkan::PlanPhase::kGeometricOnly;
  streamed_input.resources.streamed_source_depth = true;
  streamed_input.resources.streamed_reference_state = true;
  streamed_input.source_depth_f32 = streamed_depth.data();
  streamed_input.source_depth_f32_count = streamed_depth.size();
  streamed_input.reference_depth_f32 = streamed_reference_depth.data();
  streamed_input.reference_depth_f32_count = streamed_reference_depth.size();
  streamed_input.reference_normal_f32 = streamed_reference_normal.data();
  streamed_input.reference_normal_f32_count = streamed_reference_normal.size();
  streamed_input.reference_depth_content_identity = 801U;
  streamed_input.reference_normal_content_identity = 802U;
  std::array<arena::SourceResourceRef, 2> streamed_sources =
      prepared[0].sources;
  for (arena::SourceResourceRef &source : streamed_sources) {
    source.image_slot = UINT32_MAX;
  }
  streamed_input.sources = streamed_sources.data();
  FakeProvider streamed_provider;
  arena::ResourceArenaBatch streamed_batch;
  if (int e = Require(
          arena::BuildResourceArenaBatch(&streamed_input, 1U,
                                         &streamed_provider,
                                         &streamed_batch, &detail) &&
              streamed_batch.image_count() == 1U &&
              streamed_batch.images()[0]
                      .geometric.source_depth_upload_staging.range == 48U &&
              streamed_batch.images()[0]
                      .geometric.reference_depth_upload_staging.range == 16U &&
              streamed_batch.images()[0]
                      .geometric.reference_normal_upload_staging.range == 48U &&
              streamed_batch.images()[0]
                      .geometric.source_depth_transfer_byte_count == 48U &&
              streamed_batch.images()[0]
                      .geometric.reference_depth_transfer_byte_count == 16U &&
              streamed_batch.images()[0]
                      .geometric.reference_normal_transfer_byte_count == 48U &&
              streamed_batch.images()[0]
                      .geometric.source_depth_upload_staging.content_identity ==
                  streamed_input.source_depth_content_identity &&
              streamed_batch.images()[0]
                      .geometric.reference_depth_upload_staging.content_identity ==
                  streamed_input.reference_depth_content_identity &&
              streamed_batch.images()[0]
                      .geometric.reference_normal_upload_staging.content_identity ==
                  streamed_input.reference_normal_content_identity &&
              streamed_batch.images()[0].source_depth_layers[0]
                      .source_image_slot == UINT32_MAX &&
              SameBytes(
                  streamed_provider.Bytes(
                      streamed_batch.images()[0]
                          .geometric.source_depth_upload_staging.buffer),
                  streamed_depth.data(), 48U) &&
              SameBytes(
                  streamed_provider.Bytes(
                      streamed_batch.images()[0]
                          .geometric.reference_depth_upload_staging.buffer),
                  streamed_reference_depth.data(), 16U) &&
              SameBytes(
                  streamed_provider.Bytes(
                      streamed_batch.images()[0]
                          .geometric.reference_normal_upload_staging.buffer),
                  streamed_reference_normal.data(), 48U),
          22)) {
    return e;
  }

  // Validation failures must happen before any provider call and preserve old.
  auto invalid = inputs;
  invalid[0].source_gray_content_identity = 0U;
  const runtime::ImageResources *const old_images = moved.images();
  const std::size_t old_buffer_calls = provider.buffer_calls;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(invalid.data(), invalid.size(),
                                          &provider, &moved, &detail) &&
              provider.buffer_calls == old_buffer_calls &&
              moved.images() == old_images,
          9)) return e;

  const auto fails_preallocation =
      [&](const std::array<arena::ResourceArenaImageInput, 2> &bad) {
        const std::size_t before_buffers = provider.buffer_calls;
        const std::size_t before_images = provider.image_calls;
        return !arena::BuildResourceArenaBatch(
                   bad.data(), bad.size(), &provider, &moved, &detail) &&
               provider.buffer_calls == before_buffers &&
               provider.image_calls == before_images &&
               moved.images() == old_images;
      };
  auto invalid_size = inputs;
  --invalid_size[0].reference_u32_count;
  if (int e = Require(fails_preallocation(invalid_size), 10)) return e;
  auto invalid_topology = inputs;
  std::array<arena::SourceResourceRef, 2> bad_sources = prepared[0].sources;
  bad_sources[0].image_slot = 7U;
  invalid_topology[0].sources = bad_sources.data();
  if (int e = Require(fails_preallocation(invalid_topology), 11)) return e;
  auto invalid_overflow = inputs;
  invalid_overflow[0].resources.workspace_max_dim =
      std::numeric_limits<std::uint64_t>::max();
  if (int e = Require(fails_preallocation(invalid_overflow), 12)) return e;
  auto invalid_calibration = inputs;
  std::array<runtime::CameraCalibrationInput, 2> bad_cameras =
      prepared[0].cameras;
  bad_cameras[0].K[0] = 0.0F;
  invalid_calibration[0].calibration.sources = bad_cameras.data();
  if (int e = Require(fails_preallocation(invalid_calibration), 13)) return e;
  auto duplicate_image_index = inputs;
  duplicate_image_index[1].image_index = duplicate_image_index[0].image_index;
  if (int e = Require(fails_preallocation(duplicate_image_index), 19)) return e;
  auto mismatched_source_identity = inputs;
  std::array<arena::SourceResourceRef, 2> mismatched_sources =
      prepared[0].sources;
  mismatched_sources[1].image_index = 999;
  mismatched_source_identity[0].sources = mismatched_sources.data();
  if (int e = Require(fails_preallocation(mismatched_source_identity), 20)) {
    return e;
  }
  auto invalid_streamed_count = streamed_input;
  --invalid_streamed_count.source_depth_f32_count;
  const std::size_t streamed_before = streamed_provider.buffer_calls;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(&invalid_streamed_count, 1U,
                                          &streamed_provider,
                                          &streamed_batch, &detail) &&
              streamed_provider.buffer_calls == streamed_before,
          23)) {
    return e;
  }
  auto invalid_reference_depth_count = streamed_input;
  --invalid_reference_depth_count.reference_depth_f32_count;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(&invalid_reference_depth_count, 1U,
                                          &streamed_provider,
                                          &streamed_batch, &detail) &&
              streamed_provider.buffer_calls == streamed_before,
          25)) {
    return e;
  }
  auto missing_reference_normal = streamed_input;
  missing_reference_normal.reference_normal_f32 = nullptr;
  missing_reference_normal.reference_normal_f32_count = 0U;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(&missing_reference_normal, 1U,
                                          &streamed_provider,
                                          &streamed_batch, &detail) &&
              streamed_provider.buffer_calls == streamed_before,
          26)) {
    return e;
  }
  auto invalid_photo_stream = streamed_input;
  invalid_photo_stream.resources.phase =
      pocketworld::official_dense::vulkan::PlanPhase::kPhotometricOnly;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(&invalid_photo_stream, 1U,
                                          &streamed_provider,
                                          &streamed_batch, &detail) &&
              streamed_provider.buffer_calls == streamed_before,
          24)) {
    return e;
  }

  // Nth buffer failure unwinds only its completed candidate and preserves old.
  FakeProvider fail_buffer;
  fail_buffer.fail_buffer_call = 5U;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(inputs.data(), inputs.size(),
                                          &fail_buffer, &moved, &detail) &&
              fail_buffer.buffer_calls == 5U &&
              fail_buffer.buffer_releases == 4U &&
              moved.images() == old_images,
          14)) return e;

  // Image failure occurs after all buffers; every candidate allocation unwinds.
  FakeProvider fail_image;
  fail_image.fail_image_call = 2U;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(inputs.data(), inputs.size(),
                                          &fail_image, &moved, &detail) &&
              fail_image.buffer_calls == 202U &&
              fail_image.image_calls == 2U &&
              fail_image.buffer_releases == 202U &&
              fail_image.image_releases == 1U &&
              moved.images() == old_images,
          15)) return e;

  // The first alias of image 1 must not reuse the first buffer of image 0.
  FakeProvider collide_buffer;
  collide_buffer.collide_buffer_call = 102U;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(inputs.data(), inputs.size(),
                                          &collide_buffer, &moved, &detail) &&
              collide_buffer.buffer_calls == 102U &&
              collide_buffer.buffer_releases == 102U &&
              collide_buffer.image_calls == 0U && moved.images() == old_images,
          17)) return e;

  // b12 and b14 are distinct sampled-image aliases and cannot share image/view.
  FakeProvider collide_image;
  collide_image.collide_image_call = 2U;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(inputs.data(), inputs.size(),
                                          &collide_image, &moved, &detail) &&
              collide_image.buffer_calls == 202U &&
              collide_image.image_calls == 2U &&
              collide_image.buffer_releases == 202U &&
              collide_image.image_releases == 2U &&
              moved.images() == old_images,
          18)) return e;

  // A sampler object cannot mean nearest-depth and linear-gray concurrently.
  FakeProvider collide_sampler;
  collide_sampler.collide_sampler_call = 2U;
  if (int e = Require(
          !arena::BuildResourceArenaBatch(inputs.data(), inputs.size(),
                                          &collide_sampler, &moved, &detail) &&
              collide_sampler.buffer_calls == 202U &&
              collide_sampler.image_calls == 2U &&
              collide_sampler.buffer_releases == 202U &&
              collide_sampler.image_releases == 2U &&
              moved.images() == old_images,
          21)) return e;
  return 0;
}
