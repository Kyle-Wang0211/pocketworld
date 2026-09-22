// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "patch_match_sequence_probe.h"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "moltenvk_loader.h"
#include "../vulkan_batch_executor/batch_executor.h"
#include "../vulkan_host/dispatch_plan.h"
#include "../vulkan_resource_arena/resource_arena.h"
#include "../vulkan_shader_bundle/shader_bundle.h"

namespace pocketworld::official_dense::vulkan {
namespace {

namespace arena = resource_arena;
namespace executor = batch_executor;
namespace shader = shader_bundle;

constexpr std::uint32_t kWidth = 32U;
constexpr std::uint32_t kHeight = 8U;
constexpr std::size_t kPixelCount =
    static_cast<std::size_t>(kWidth) * kHeight;
constexpr std::size_t kImageCount = 3U;
constexpr std::size_t kSourceCount = 2U;
constexpr float kDegreesToRadians = 0.01745329251994329577F;

struct PreparedImage {
  arena::ResourceArenaImageInput input;
  std::vector<std::uint32_t> reference;
  std::vector<std::uint32_t> source_gray_u32;
  std::vector<std::uint8_t> source_gray_u8;
  std::array<runtime::CameraCalibrationInput, kSourceCount> source_cameras;
  std::array<arena::SourceResourceRef, kSourceCount> sources;
};

runtime::CameraCalibrationInput Camera(const std::size_t index) noexcept {
  runtime::CameraCalibrationInput camera;
  camera.K = {100.0F, 0.0F, static_cast<float>(kWidth) * 0.5F,
              0.0F, 101.0F, static_cast<float>(kHeight) * 0.5F,
              0.0F, 0.0F, 1.0F};
  camera.R = {1.0F, 0.0F, 0.0F,
              0.0F, 1.0F, 0.0F,
              0.0F, 0.0F, 1.0F};
  camera.T = {static_cast<float>(index) * 0.05F, 0.0F, 0.0F};
  return camera;
}

PatchPC Patch() noexcept {
  PatchPC patch{};
  patch.width = kWidth;
  patch.height = kHeight;
  patch.num_sources = static_cast<std::uint32_t>(kSourceCount);
  patch.workspace_max_dim = kWidth;
  patch.source_width = kWidth;
  patch.source_height = kHeight;
  patch.perturbation = 0.5F;
  patch.depth_min = 0.1F;
  patch.depth_max = 8.0F;
  patch.num_samples = 15;
  patch.sigma_spatial = 5.0F;
  patch.sigma_color = 0.2F;
  patch.ncc_sigma = 0.6F;
  patch.min_triangulation_angle_rad = 1.0F * kDegreesToRadians;
  patch.incident_angle_sigma = 0.9F;
  patch.prev_sel_prob_weight = 0.9F;
  patch.geom_consistency_regularizer = 0.3F;
  patch.geom_consistency_max_cost = 3.0F;
  patch.filter_min_ncc = 0.1F;
  patch.filter_min_triangulation_angle_rad = 3.0F * kDegreesToRadians;
  patch.filter_min_num_consistent = 2;
  patch.filter_geom_consistency_max_cost = 1.0F;
  return patch;
}

void PrepareInputs(std::array<PreparedImage, kImageCount>* const prepared,
                   std::array<arena::ResourceArenaImageInput, kImageCount>*
                       inputs) {
  for (std::size_t image = 0U; image < kImageCount; ++image) {
    PreparedImage& item = (*prepared)[image];
    item.reference.resize(kPixelCount);
    for (std::size_t pixel = 0U; pixel < kPixelCount; ++pixel) {
      const std::uint32_t row = static_cast<std::uint32_t>(pixel / kWidth);
      const std::uint32_t column = static_cast<std::uint32_t>(pixel % kWidth);
      item.reference[pixel] =
          (column * 7U + row * 13U + static_cast<std::uint32_t>(image) * 29U) &
          0xffU;
    }
  }

  for (std::size_t image = 0U; image < kImageCount; ++image) {
    PreparedImage& item = (*prepared)[image];
    item.source_gray_u32.resize(kSourceCount * kPixelCount);
    item.source_gray_u8.resize(kSourceCount * kPixelCount);
    for (std::size_t source = 0U; source < kSourceCount; ++source) {
      const std::size_t source_slot = (image + source + 1U) % kImageCount;
      item.source_cameras[source] = Camera(source_slot);
      item.sources[source] = {
          static_cast<std::uint32_t>(source_slot),
          static_cast<std::int32_t>(70U + source_slot), kWidth, kHeight};
      for (std::size_t pixel = 0U; pixel < kPixelCount; ++pixel) {
        const std::uint32_t value =
            (*prepared)[source_slot].reference[pixel] & 0xffU;
        const std::size_t offset = source * kPixelCount + pixel;
        item.source_gray_u32[offset] = value;
        item.source_gray_u8[offset] = static_cast<std::uint8_t>(value);
      }
    }

    item.input.image_index = static_cast<std::int32_t>(70U + image);
    item.input.resources = {kWidth, kHeight, kWidth, kHeight, kSourceCount,
                            kWidth};
    item.input.calibration = {Patch(), Camera(image),
                              item.source_cameras.data(), kSourceCount};
    item.input.reference_u32 = item.reference.data();
    item.input.reference_u32_count = item.reference.size();
    item.input.source_gray_u32 = item.source_gray_u32.data();
    item.input.source_gray_u32_count = item.source_gray_u32.size();
    item.input.source_gray_u8 = item.source_gray_u8.data();
    item.input.source_gray_u8_count = item.source_gray_u8.size();
    item.input.reference_content_identity = 100U + image;
    item.input.source_depth_content_identity = 200U + image;
    item.input.source_gray_content_identity = 300U + image;
    item.input.pose_content_identities = {
        400U + image * 4U, 401U + image * 4U,
        402U + image * 4U, 403U + image * 4U};
    item.input.sources = item.sources.data();
    item.input.source_count = item.sources.size();
    (*inputs)[image] = item.input;
  }
}

void SetResult(PatchMatchSequenceProbeResult* const out, const bool ok,
               const char* const stage, const runtime::RuntimeStatus status,
               const runtime::RecordResult* const record,
               const char* const detail) noexcept {
  const auto& manifest = shader::FrozenShaderManifest();
  std::snprintf(
      out->json.data(), out->json.size(),
      "{\"ok\":%s,\"stage\":\"%s\",\"runtime_status\":%u,"
      "\"images\":%zu,\"width\":%u,\"height\":%u,"
      "\"diagnostic_certification_override\":true,"
      "\"production_gate_preserved\":true,"
      "\"recorded_plan_steps\":%zu,\"dispatch_count\":%zu,"
      "\"barrier_count\":%zu,\"graph_values\":%zu,"
      "\"first_shader_sha256\":\"%s\",\"detail\":\"%s\"}",
      ok ? "true" : "false", stage, static_cast<unsigned int>(status),
      kImageCount, kWidth, kHeight,
      record == nullptr ? 0U : record->recorded_plan_steps,
      record == nullptr ? 0U : record->dispatch_count,
      record == nullptr ? 0U : record->barrier_count,
      record == nullptr ? 0U : record->consistency_graph_value_count,
      manifest[0].spirv_sha256, detail == nullptr ? "" : detail);
  out->ok = ok;
}

}  // namespace

PatchMatchSequenceProbeResult RunMoltenVkPatchMatchSequenceProbe() noexcept {
  PatchMatchSequenceProbeResult output;
  try {
    const ExternalLoader loader = MoltenVkExternalLoader();
    const CreateOptions options{loader};
    const CapabilityReport probed = VulkanHost::Probe(options);
    if (!probed.ready()) {
      SetResult(&output, false, "host_probe",
                runtime::RuntimeStatus::kVulkanFunctionUnavailable, nullptr,
                probed.detail.c_str());
      return output;
    }

    CapabilityReport created;
    std::unique_ptr<VulkanHost> host = VulkanHost::Create(options, &created);
    if (host == nullptr || !created.ready()) {
      SetResult(&output, false, "host_create",
                runtime::RuntimeStatus::kVulkanFunctionUnavailable, nullptr,
                created.detail.c_str());
      return output;
    }

    std::array<PreparedImage, kImageCount> prepared;
    std::array<arena::ResourceArenaImageInput, kImageCount> inputs;
    PrepareInputs(&prepared, &inputs);
    arena::VulkanHostResourceAllocationProvider provider(host.get());
    arena::ResourceArenaBatch batch;
    std::string arena_detail;
    if (!arena::BuildResourceArenaBatch(inputs.data(), inputs.size(), &provider,
                                        &batch, &arena_detail)) {
      SetResult(&output, false, "arena_build",
                runtime::RuntimeStatus::kInvalidRequest, nullptr,
                arena_detail.c_str());
      return output;
    }

    const NativeHandles native = host->native_handles();
    executor::BatchExecuteRequest request;
    request.arena = &batch;
    request.native = {native.instance, native.device, native.command_buffer,
                      native.queue, loader.get_instance_proc_addr};
    request.shaders = shader::CanonicalShaderBundle();

    const runtime::RecordResult production =
        executor::ExecuteResourceArenaBatch(request);
    if (production.status !=
            runtime::RuntimeStatus::kPcgAdaptationNotCertified ||
        production.recorded_plan_steps != 0U) {
      SetResult(&output, false, "production_gate_changed", production.status,
                &production, production.detail);
      return output;
    }

    const runtime::RecordResult record =
        executor::ExecuteResourceArenaBatchForDiagnostic(request);
    const DispatchPlan expected = CreateDispatchPlan(kImageCount);
    const bool complete = record.recorded() && expected.Validate() &&
                          record.recorded_plan_steps == expected.steps.size() &&
                          record.dispatch_count != 0U &&
                          record.barrier_count != 0U;
    SetResult(&output, complete,
              complete ? "full_patch_match_sequence_complete"
                       : "full_patch_match_sequence_failed",
              record.status, &record, record.detail);
    return output;
  } catch (...) {
    SetResult(&output, false, "exception",
              runtime::RuntimeStatus::kInvalidRequest, nullptr,
              "diagnostic probe threw");
    return output;
  }
}

}  // namespace pocketworld::official_dense::vulkan
