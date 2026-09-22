// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "resource_arena.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <map>
#include <new>
#include <set>
#include <utility>
#include <vector>

namespace pocketworld::official_dense::vulkan::resource_arena {
namespace {

using runtime::BoundResource;
using runtime::ImageResources;
using runtime::ModeResources;

bool SamePlan(const AllocationPlan &a, const AllocationPlan &b) noexcept {
  return a.exact_bytes == b.exact_bytes && a.array_layers == b.array_layers &&
         a.scalar_type == b.scalar_type && a.memory_class == b.memory_class &&
         a.usage == b.usage && a.alias_group == b.alias_group;
}

bool FitsU32(const std::uint64_t value) noexcept {
  return value <= std::numeric_limits<std::uint32_t>::max();
}

bool CheckedProduct(const std::uint64_t a, const std::uint64_t b,
                    std::uint64_t *out) noexcept {
  if (out == nullptr ||
      (a != 0U && b > std::numeric_limits<std::uint64_t>::max() / a)) {
    return false;
  }
  *out = a * b;
  return true;
}

bool SetDetail(std::string *detail, const char *message) noexcept {
  if (detail != nullptr) {
    try {
      *detail = message;
    } catch (...) {
    }
  }
  return false;
}

std::uint32_t ElementSize(const ScalarType type) noexcept {
  switch (type) {
    case ScalarType::kFloat32:
    case ScalarType::kUint32:
    case ScalarType::kInt32:
      return 4U;
    case ScalarType::kUint8:
      // BoundResource has no byte scalar variant and its runtime ABI requires
      // element_size == 4 even for byte-exact transfer-only staging buffers.
      return 4U;
  }
  return 0U;
}

runtime::ResourceScalarType RuntimeScalar(const ScalarType type) noexcept {
  return type == ScalarType::kFloat32
             ? runtime::ResourceScalarType::kFloat32
             : runtime::ResourceScalarType::kUint32;
}

bool BufferSpecFor(const AllocationPlan &plan,
                   BufferAllocationSpec *out) noexcept {
  if (out == nullptr || !plan.present() ||
      plan.memory_class == MemoryClass::kHostValues ||
      (plan.usage & kUsageSampled) != 0U ||
      (plan.usage & kUsageHostValues) != 0U) {
    return false;
  }
  BufferAllocationSpec candidate;
  candidate.byte_count = plan.exact_bytes;
  if ((plan.usage & kUsageStorage) != 0U) {
    candidate.usage_flags |= kBufferUsageStorage;
  }
  if ((plan.usage & kUsageTransferSource) != 0U) {
    candidate.usage_flags |= kBufferUsageTransferSrc;
  }
  if ((plan.usage & kUsageTransferDestination) != 0U) {
    candidate.usage_flags |= kBufferUsageTransferDst;
  }
  switch (plan.memory_class) {
    case MemoryClass::kDeviceLocal:
      candidate.memory_class = BufferMemoryClass::kDeviceLocal;
      break;
    case MemoryClass::kHostUpload:
      candidate.memory_class = BufferMemoryClass::kHostUpload;
      break;
    case MemoryClass::kHostReadback:
      candidate.memory_class = BufferMemoryClass::kHostReadback;
      break;
    case MemoryClass::kHostValues:
      return false;
  }
  if (candidate.usage_flags == 0U) return false;
  *out = candidate;
  return true;
}

bool ImageSpecFor(const ResourceArenaPlan &owner,
                  const AllocationPlan &plan,
                  SampledImageSpec *out) noexcept {
  if (out == nullptr || !plan.present() || !FitsU32(owner.input.source_width) ||
      !FitsU32(owner.input.source_height) || !FitsU32(plan.array_layers) ||
      plan.memory_class != MemoryClass::kDeviceLocal ||
      (plan.usage & kUsageSampled) == 0U ||
      (plan.usage & kUsageTransferDestination) == 0U) {
    return false;
  }
  SampledImageSpec candidate;
  candidate.width = static_cast<std::uint32_t>(owner.input.source_width);
  candidate.height = static_cast<std::uint32_t>(owner.input.source_height);
  candidate.array_layers = static_cast<std::uint32_t>(plan.array_layers);
  if (plan.scalar_type == ScalarType::kFloat32) {
    candidate.format = SampledImageFormat::kR32Sfloat;
    candidate.sampler = ImageSamplerKind::kDepthNearest;
  } else if (plan.scalar_type == ScalarType::kUint8) {
    candidate.format = SampledImageFormat::kR8Unorm;
    candidate.sampler = ImageSamplerKind::kGrayLinear;
  } else {
    return false;
  }
  *out = candidate;
  return true;
}

runtime::SamplerMetadata MetadataFor(const SampledImageSpec &spec) noexcept {
  runtime::SamplerMetadata metadata;
  metadata.format = spec.format == SampledImageFormat::kR32Sfloat
                        ? runtime::SamplerFormat::kR32Sfloat
                        : runtime::SamplerFormat::kR8Unorm;
  metadata.min_filter = spec.sampler == ImageSamplerKind::kDepthNearest
                            ? runtime::SamplerFilter::kNearest
                            : runtime::SamplerFilter::kLinear;
  metadata.mag_filter = metadata.min_filter;
  metadata.address_u = runtime::SamplerAddressMode::kClampToBorder;
  metadata.address_v = runtime::SamplerAddressMode::kClampToBorder;
  metadata.border_color = runtime::SamplerBorderColor::kFloatTransparentBlack;
  metadata.normalized_coordinates = true;
  return metadata;
}

struct PlannedImage {
  ResourceArenaPlan plan;
  std::array<PatchPC, kRotationCount> patches{};
  // [BATCH-REF] 逐 (rotation, reference) 的 patch,布局 [rotation][reference]。
  std::array<std::vector<PatchPC>, kRotationCount> reference_patches{};
  std::vector<float> pose_values;
};

struct OwnedImage {
  ImageResources resources;
  // [BATCH-REF 2026-08-30] 逐 (rotation, reference) 的 PatchPC。
  // ImageResources::calibration[rotation].reference_patches 指向这里,
  // 所以生命周期必须与 OwnedImage 一致(它被 unique_ptr 持有,地址稳定)。
  std::array<std::vector<PatchPC>, kRotationCount> reference_patches;
  PlanPhase phase = PlanPhase::kFull;
  std::vector<std::int32_t> source_indices;
  std::vector<runtime::SourceDepthLayerCopy> source_depth_layers;
  std::vector<std::int32_t> graph_values;
  // [BATCH-REF] 每 reference 一个计数。
  std::vector<std::size_t> graph_value_counts;
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
  DiagnosticImageReadback diagnostic_readback{};
#endif
};

struct BufferEntry {
  AllocationPlan plan;
  ProviderBufferAllocation allocation;
};

struct ImageEntry {
  AllocationPlan plan;
  ProviderSampledImageAllocation allocation;
};

using AliasKey = std::pair<std::size_t, std::uint64_t>;

bool AddPlan(const std::size_t image, const AllocationPlan &plan,
             std::map<AliasKey, AllocationPlan> *plans,
             const bool image_kind) {
  if (!plan.present()) return true;
  if (image_kind != ((plan.usage & kUsageSampled) != 0U)) return false;
  const AliasKey key{image, plan.alias_group};
  const auto found = plans->find(key);
  if (found == plans->end()) {
    plans->emplace(key, plan);
    return true;
  }
  return SamePlan(found->second, plan);
}

bool CollectPlans(const std::size_t image, const ResourceArenaPlan &plan,
                  std::map<AliasKey, AllocationPlan> *buffers,
                  std::map<AliasKey, AllocationPlan> *images) {
  for (const ModePlan &mode : plan.modes) {
    for (const RotationPlan &rotation : mode.rotations) {
      for (const BindingPlan &binding : rotation.bindings) {
        if (!AddPlan(image, binding.buffer, buffers, false) ||
            !AddPlan(image, binding.sampled_image, images, true)) {
          return false;
        }
      }
    }
    for (const AllocationPlan *allocation :
         {&mode.reference_upload_staging,
          &mode.reference_depth_upload_staging,
          &mode.reference_normal_upload_staging,
          &mode.source_depth_upload_staging,
          &mode.source_gray_buffer_upload_staging,
          &mode.source_gray_image_upload_staging, &mode.depth_readback,
          &mode.normal_readback, &mode.mask_readback}) {
      if (!AddPlan(image, *allocation, buffers, false)) return false;
    }
  }
  for (const RotationPosePlan &pose : plan.poses) {
    if (!AddPlan(image, pose.active_pose_table, buffers, false) ||
        !AddPlan(image, pose.pose_upload_staging, buffers, false)) {
      return false;
    }
  }
  return true;
}

bool ValidInput(const ResourceArenaImageInput &input,
                const ResourceArenaImageInput *all_inputs,
                const std::size_t input_count,
                PlannedImage *planned) {
  if (planned == nullptr || input.image_index < 0 ||
      input.reference_u32 == nullptr ||
      input.source_gray_u32 == nullptr || input.source_gray_u8 == nullptr ||
      input.sources == nullptr || input.source_count == 0U ||
      input.source_count != input.resources.num_sources ||
      input.source_count != input.calibration.source_count ||
      input.calibration.sources == nullptr ||
      input.reference_content_identity == 0U ||
      input.source_depth_content_identity == 0U ||
      input.source_gray_content_identity == 0U ||
      std::any_of(input.pose_content_identities.begin(),
                  input.pose_content_identities.end(),
                  [](const std::uint64_t value) { return value == 0U; }) ||
      !FitsU32(input.resources.width) || !FitsU32(input.resources.height) ||
      !FitsU32(input.resources.source_width) ||
      !FitsU32(input.resources.source_height) ||
      !FitsU32(input.resources.num_sources) ||
      !FitsU32(input.resources.workspace_max_dim)) {
    return false;
  }
  const PatchPC &patch = input.calibration.base_patch;
  if (patch.width != input.resources.width ||
      patch.height != input.resources.height ||
      patch.source_width != input.resources.source_width ||
      patch.source_height != input.resources.source_height ||
      patch.num_sources != input.resources.num_sources ||
      patch.workspace_max_dim != input.resources.workspace_max_dim ||
      patch.rotation_0_to_3 != 0U) {
    return false;
  }
  const std::uint64_t batch =
      std::max<std::uint64_t>(input.resources.batch_count, 1U);
  if ((input.batch_calibrations != nullptr &&
       input.batch_calibration_count != batch) ||
      (input.batch_sources != nullptr &&
       input.batch_source_count != input.source_count * batch)) {
    return false;
  }
  std::uint64_t pixels = 0U;
  std::uint64_t source_pixels = 0U;
  std::uint64_t layered_source_pixels = 0U;
  if (!CheckedProduct(input.resources.width, input.resources.height, &pixels) ||
      !CheckedProduct(input.resources.source_width,
                      input.resources.source_height, &source_pixels) ||
      !CheckedProduct(source_pixels, input.resources.num_sources,
                      &layered_source_pixels) ||
      // [BATCH-REF] 输入数组是 N 份首尾相接;num_sources 仍是**每 reference**
      // 的源数(它是 shader 的 stride,不能乘 N)。
      pixels * batch != input.reference_u32_count ||
      layered_source_pixels * batch != input.source_gray_u32_count ||
      layered_source_pixels * batch != input.source_gray_u8_count ||
      ((input.source_depth_f32 == nullptr) !=
       (input.source_depth_f32_count == 0U)) ||
      ((input.reference_depth_f32 == nullptr) !=
       (input.reference_depth_f32_count == 0U)) ||
      ((input.reference_normal_f32 == nullptr) !=
       (input.reference_normal_f32_count == 0U)) ||
      ((input.reference_depth_f32 == nullptr) !=
       (input.reference_normal_f32 == nullptr)) ||
      input.resources.streamed_source_depth !=
          (input.source_depth_f32 != nullptr) ||
      input.resources.streamed_reference_state !=
          (input.reference_depth_f32 != nullptr) ||
      (input.resources.phase == PlanPhase::kPhotometricOnly &&
       (input.source_depth_f32 != nullptr ||
        input.reference_depth_f32 != nullptr)) ||
      (input.resources.phase == PlanPhase::kFull &&
       input.reference_depth_f32 != nullptr) ||
      (input.reference_depth_f32 != nullptr &&
       (input.reference_depth_content_identity == 0U ||
        input.reference_normal_content_identity == 0U ||
        pixels * batch != input.reference_depth_f32_count ||
        pixels > std::numeric_limits<std::size_t>::max() / 3U ||
        pixels * 3U * batch != input.reference_normal_f32_count)) ||
      (input.source_depth_f32 != nullptr &&
       layered_source_pixels * batch != input.source_depth_f32_count)) {
    return false;
  }
  const bool has_external_source_depth = input.source_depth_f32 != nullptr;
  for (std::size_t source = 0U; source < input.source_count; ++source) {
    const SourceResourceRef &ref = input.sources[source];
    if (ref.image_index < 0 ||
        ref.width == 0U || ref.height == 0U ||
        ref.width > input.resources.source_width ||
        ref.height > input.resources.source_height) {
      return false;
    }
    if (!has_external_source_depth &&
        (ref.image_slot >= input_count ||
         ref.image_index != all_inputs[ref.image_slot].image_index ||
         all_inputs[ref.image_slot].resources.width != ref.width ||
         all_inputs[ref.image_slot].resources.height != ref.height)) {
      return false;
    }
  }
  if (!BuildResourceArenaPlan(input.resources, &planned->plan)) return false;
  // [BATCH-REF] 位姿缓冲布局是 [rotation][reference][num_sources*43 + 8],
  // 因为 staging → device 的拷贝是按 rotation 分成 4 段、每段整块搬 N 份。
  const std::size_t per_reference = kPoseFloatsPerReference(input.source_count);
  const std::size_t batch_size = static_cast<std::size_t>(batch);
  planned->pose_values.assign(kRotationCount * batch_size * per_reference,
                              0.0F);
  for (std::size_t rotation = 0U; rotation < kRotationCount; ++rotation)
    planned->reference_patches[rotation].assign(batch_size, PatchPC{});

  std::vector<float> single(kRotationCount * per_reference, 0.0F);
  for (std::size_t reference = 0U; reference < batch_size; ++reference) {
    const runtime::CalibrationBuildInput &calibration =
        input.batch_calibrations != nullptr ? input.batch_calibrations[reference]
                                            : input.calibration;
    std::array<PatchPC, kRotationCount> patches{};
    if (!runtime::BuildRotationCalibrationHost(calibration, &patches,
                                               single.data(), single.size())) {
      return false;
    }
    for (std::size_t rotation = 0U; rotation < kRotationCount; ++rotation) {
      planned->reference_patches[rotation][reference] = patches[rotation];
      std::memcpy(planned->pose_values.data() +
                      (rotation * batch_size + reference) * per_reference,
                  single.data() + rotation * per_reference,
                  per_reference * sizeof(float));
    }
    // patches 对外仍暴露 reference 0 的那一份(单 reference 路径不变)。
    if (reference == 0U) planned->patches = patches;
  }
  return true;
}

BoundResource BindBuffer(const AllocationPlan &plan,
                         const ProviderBufferAllocation &allocation,
                         const std::uint64_t identity = 0U) noexcept {
  BoundResource out;
  out.buffer = allocation.buffer_handle;
  out.range = plan.exact_bytes;
  out.array_layers = static_cast<std::uint32_t>(plan.array_layers);
  out.element_size = ElementSize(plan.scalar_type);
  out.scalar_type = RuntimeScalar(plan.scalar_type);
  out.content_identity = identity;
  return out;
}

void BindImage(const AllocationPlan &plan,
               const ProviderSampledImageAllocation &allocation,
               const std::uint64_t identity,
               BoundResource *out) noexcept {
  out->image = allocation.image_handle;
  out->image_view = allocation.image_view_handle;
  out->sampler = allocation.sampler_handle;
  if (out->range == 0U) out->range = plan.exact_bytes;
  out->array_layers = static_cast<std::uint32_t>(plan.array_layers);
  if (out->buffer == 0U) {
    out->element_size = ElementSize(plan.scalar_type);
    out->scalar_type = RuntimeScalar(plan.scalar_type);
  }
  out->sampler_metadata = MetadataFor(allocation.spec);
  out->content_identity = identity;
}

}  // namespace

struct ResourceArenaBatch::Impl {
  std::vector<BufferEntry> buffers;
  std::vector<ImageEntry> sampled_images;
  std::vector<OwnedImage> owned_images;
  std::vector<ImageResources> image_views;
};

VulkanHostResourceAllocationProvider::VulkanHostResourceAllocationProvider(
    VulkanHost *const host) noexcept
    : host_(host) {}

bool VulkanHostResourceAllocationProvider::CreateBufferAllocation(
    const BufferAllocationSpec &spec, ProviderBufferAllocation *const out,
    std::string *const detail) noexcept {
  if (host_ == nullptr || out == nullptr) return SetDetail(detail, "invalid host");
  try {
    auto owned = std::make_shared<BufferAllocation>();
    if (!host_->CreateBufferAllocation(spec, owned.get(), detail)) return false;
    ProviderBufferAllocation candidate;
    candidate.buffer_handle = owned->opaque_buffer_handle();
    candidate.byte_count = owned->byte_count();
    candidate.mapped_pointer = owned->mapped_pointer();
    candidate.host_coherent = owned->host_coherent();
    candidate.lifetime = std::move(owned);
    *out = std::move(candidate);
    return true;
  } catch (...) {
    return SetDetail(detail, "buffer allocation ownership failed");
  }
}

bool VulkanHostResourceAllocationProvider::CreateSampledImageAllocation(
    const SampledImageSpec &spec,
    ProviderSampledImageAllocation *const out,
    std::string *const detail) noexcept {
  if (host_ == nullptr || out == nullptr) return SetDetail(detail, "invalid host");
  try {
    auto owned = std::make_shared<SampledImageAllocation>();
    if (!host_->CreateSampledImageAllocation(spec, owned.get(), detail)) {
      return false;
    }
    ProviderSampledImageAllocation candidate;
    candidate.image_handle = owned->opaque_image_handle();
    candidate.image_view_handle = owned->opaque_image_view_handle();
    candidate.sampler_handle = owned->opaque_sampler_handle();
    candidate.spec = spec;
    candidate.lifetime = std::move(owned);
    *out = std::move(candidate);
    return true;
  } catch (...) {
    return SetDetail(detail, "sampled image allocation ownership failed");
  }
}

ResourceArenaBatch::ResourceArenaBatch() noexcept = default;
ResourceArenaBatch::ResourceArenaBatch(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
ResourceArenaBatch::ResourceArenaBatch(ResourceArenaBatch &&) noexcept = default;
ResourceArenaBatch &ResourceArenaBatch::operator=(ResourceArenaBatch &&) noexcept =
    default;
ResourceArenaBatch::~ResourceArenaBatch() = default;

const ImageResources *ResourceArenaBatch::images() const noexcept {
  return impl_ == nullptr || impl_->image_views.empty()
             ? nullptr
             : impl_->image_views.data();
}
std::size_t ResourceArenaBatch::image_count() const noexcept {
  return impl_ == nullptr ? 0U : impl_->image_views.size();
}
bool ResourceArenaBatch::empty() const noexcept { return image_count() == 0U; }
void ResourceArenaBatch::Reset() noexcept { impl_.reset(); }

#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)

bool ResourceArenaBatch::DiagnosticReadbackForImage(
    const std::size_t image_slot, DiagnosticImageReadback *const out) const
    noexcept {
  if (out == nullptr || impl_ == nullptr ||
      image_slot >= impl_->owned_images.size()) {
    return false;
  }
  const OwnedImage &owned = impl_->owned_images[image_slot];
  *out = owned.diagnostic_readback;
  out->consistency_graph_values = owned.graph_values.data();
  // reference 0 的那一片;批处理时其余 reference 由调用方按 r 取片。
  out->consistency_graph_value_count =
      owned.graph_value_counts.empty() ? 0U : owned.graph_value_counts[0];
  out->consistency_graph_value_counts = owned.graph_value_counts.data();
  out->consistency_graph_batch_count = owned.graph_value_counts.size();
  out->consistency_graph_value_capacity_per_reference =
      owned.graph_value_counts.empty()
          ? 0U
          : owned.graph_values.size() / owned.graph_value_counts.size();
  if (out->width == 0U || out->height == 0U) return false;
  const bool has_photo = out->photometric_depth != nullptr &&
                         out->photometric_normal != nullptr;
  const bool has_geo = out->geometric_depth != nullptr &&
                       out->geometric_normal != nullptr &&
                       out->geometric_mask != nullptr;
  switch (owned.phase) {
    case PlanPhase::kPhotometricOnly:
      return has_photo && !has_geo;
    case PlanPhase::kGeometricOnly:
      return !has_photo && has_geo;
    case PlanPhase::kFull:
      return has_photo && has_geo;
  }
  return false;
}

#endif

bool BuildResourceArenaBatch(const ResourceArenaImageInput *const inputs,
                             const std::size_t input_count,
                             ResourceAllocationProvider *const provider,
                             ResourceArenaBatch *const out,
                             std::string *const detail) noexcept {
  if (inputs == nullptr || input_count == 0U || provider == nullptr ||
      out == nullptr) {
    return SetDetail(detail, "invalid resource arena request");
  }
  try {
    for (std::size_t image = 0U; image < input_count; ++image) {
      if (inputs[image].image_index < 0) {
        return SetDetail(detail, "invalid batch image index");
      }
      for (std::size_t other = image + 1U; other < input_count; ++other) {
        if (inputs[image].image_index == inputs[other].image_index) {
          return SetDetail(detail, "duplicate batch image index");
        }
      }
    }
    std::vector<PlannedImage> planned(input_count);
    std::map<AliasKey, AllocationPlan> buffer_plans;
    std::map<AliasKey, AllocationPlan> image_plans;
    for (std::size_t image = 0U; image < input_count; ++image) {
      if (!ValidInput(inputs[image], inputs, input_count, &planned[image]) ||
          !CollectPlans(image, planned[image].plan, &buffer_plans,
                        &image_plans)) {
        return SetDetail(detail, "resource arena validation failed");
      }
    }

    auto candidate = std::make_unique<ResourceArenaBatch::Impl>();
    candidate->buffers.reserve(buffer_plans.size());
    candidate->sampled_images.reserve(image_plans.size());
    std::map<AliasKey, std::size_t> buffer_indices;
    std::map<AliasKey, std::size_t> image_indices;
    std::set<std::uint64_t> used_buffer_handles;
    std::set<std::uint64_t> used_image_handles;
    std::set<std::uint64_t> used_image_view_handles;
    std::map<std::uint64_t, ImageSamplerKind> sampler_contracts;

    for (const auto &[key, plan] : buffer_plans) {
      BufferAllocationSpec spec;
      ProviderBufferAllocation allocation;
      if (!BufferSpecFor(plan, &spec) ||
          !provider->CreateBufferAllocation(spec, &allocation, detail) ||
          allocation.buffer_handle == 0U || !allocation.lifetime ||
          allocation.byte_count != spec.byte_count ||
          ((plan.memory_class == MemoryClass::kHostUpload ||
            plan.memory_class == MemoryClass::kHostReadback) &&
           (allocation.mapped_pointer == nullptr ||
            !allocation.host_coherent))) {
        return SetDetail(detail, "buffer allocation failed contract");
      }
      if (!used_buffer_handles.insert(allocation.buffer_handle).second) {
        return SetDetail(detail, "distinct buffer aliases share a handle");
      }
      buffer_indices.emplace(key, candidate->buffers.size());
      candidate->buffers.push_back({plan, std::move(allocation)});
    }
    for (const auto &[key, plan] : image_plans) {
      SampledImageSpec spec;
      ProviderSampledImageAllocation allocation;
      if (!ImageSpecFor(planned[key.first].plan, plan, &spec) ||
          !provider->CreateSampledImageAllocation(spec, &allocation, detail) ||
          allocation.image_handle == 0U || allocation.image_view_handle == 0U ||
          allocation.sampler_handle == 0U || !allocation.lifetime ||
          allocation.spec.width != spec.width ||
          allocation.spec.height != spec.height ||
          allocation.spec.array_layers != spec.array_layers ||
          allocation.spec.format != spec.format ||
          allocation.spec.sampler != spec.sampler) {
        return SetDetail(detail, "sampled image allocation failed contract");
      }
      if (used_image_handles.find(allocation.image_handle) !=
              used_image_handles.end() ||
          used_image_view_handles.find(allocation.image_view_handle) !=
              used_image_view_handles.end()) {
        return SetDetail(detail, "distinct sampled image aliases share a handle");
      }
      const auto sampler_contract =
          sampler_contracts.find(allocation.sampler_handle);
      if (sampler_contract != sampler_contracts.end() &&
          sampler_contract->second != allocation.spec.sampler) {
        return SetDetail(detail,
                         "one sampler handle represents distinct contracts");
      }
      used_image_handles.insert(allocation.image_handle);
      used_image_view_handles.insert(allocation.image_view_handle);
      sampler_contracts.emplace(allocation.sampler_handle,
                                allocation.spec.sampler);
      image_indices.emplace(key, candidate->sampled_images.size());
      candidate->sampled_images.push_back({plan, std::move(allocation)});
    }

    const auto buffer_for = [&](const std::size_t image,
                                const AllocationPlan &plan)
        -> const ProviderBufferAllocation & {
      return candidate->buffers[buffer_indices.at({image, plan.alias_group})]
          .allocation;
    };
    const auto image_for = [&](const std::size_t image,
                               const AllocationPlan &plan)
        -> const ProviderSampledImageAllocation & {
      return candidate->sampled_images[image_indices.at(
          {image, plan.alias_group})]
          .allocation;
    };

    candidate->owned_images.resize(input_count);
    candidate->image_views.resize(input_count);
    for (std::size_t image = 0U; image < input_count; ++image) {
      const ResourceArenaImageInput &input = inputs[image];
      const ResourceArenaPlan &plan = planned[image].plan;
      OwnedImage &owned = candidate->owned_images[image];
      owned.phase = input.resources.phase;
      // [BATCH-REF] 源清单是 N 份首尾相接:层号 = ref*num_sources + source,
      // 与 shader 的 SourceLayer() 和 kUploadSourceDepthMaps 的逐层拷贝
      // 逐字对应。batch_sources 为空时把单份复制 N 遍(N 个槽装同一帧)。
      const std::size_t batch_size = static_cast<std::size_t>(
          std::max<std::uint64_t>(input.resources.batch_count, 1U));
      const std::size_t total_sources = input.source_count * batch_size;
      owned.source_indices.reserve(total_sources);
      owned.source_depth_layers.reserve(total_sources);
      for (std::size_t layer = 0U; layer < total_sources; ++layer) {
        const SourceResourceRef &ref =
            input.batch_sources != nullptr
                ? input.batch_sources[layer]
                : input.sources[layer % input.source_count];
        owned.source_indices.push_back(ref.image_index);
        owned.source_depth_layers.push_back({ref.image_slot,
                                             static_cast<std::uint32_t>(layer),
                                             ref.width, ref.height});
      }
      owned.graph_values.resize(plan.consistency_graph_value_capacity);
      owned.graph_value_counts.assign(
          static_cast<std::size_t>(
              std::max<std::uint64_t>(input.resources.batch_count, 1U)),
          0U);

      for (std::size_t mode_index = 0U; mode_index < kModeCount; ++mode_index) {
        const ModePlan &mode_plan = plan.modes[mode_index];
        if (!mode_plan.reference_upload_staging.present()) continue;
        ModeResources &mode = mode_index == 0U ? owned.resources.photometric
                                               : owned.resources.geometric;
        for (std::size_t rotation = 0U; rotation < kRotationCount; ++rotation) {
          for (std::size_t binding = 0U; binding < kBindingCount; ++binding) {
            const BindingPlan &binding_plan =
                mode_plan.rotations[rotation].bindings[binding];
            BoundResource bound;
            if (binding_plan.buffer.present()) {
              std::uint64_t identity = 0U;
              if (binding == 8U) identity = input.reference_content_identity;
              if (mode_index == 1U && rotation == 0U && binding == 0U &&
                  input.resources.streamed_reference_state) {
                identity = input.reference_depth_content_identity;
              }
              if (mode_index == 1U && rotation == 0U && binding == 1U &&
                  input.resources.streamed_reference_state) {
                identity = input.reference_normal_content_identity;
              }
              if (binding == 13U) {
                identity = input.pose_content_identities[rotation];
              }
              if (binding == 14U) identity = input.source_gray_content_identity;
              bound = BindBuffer(binding_plan.buffer,
                                 buffer_for(image, binding_plan.buffer), identity);
            }
            if (binding_plan.sampled_image.present()) {
              const std::uint64_t identity = binding == 12U
                  ? input.source_depth_content_identity
                  : input.source_gray_content_identity;
              BindImage(binding_plan.sampled_image,
                        image_for(image, binding_plan.sampled_image), identity,
                        &bound);
            }
            mode.bindings[binding][rotation] = bound;
          }
        }
        mode.reference_upload_staging = BindBuffer(
            mode_plan.reference_upload_staging,
            buffer_for(image, mode_plan.reference_upload_staging),
            input.reference_content_identity);
        if (mode_plan.reference_depth_upload_staging.present()) {
          mode.reference_depth_upload_staging = BindBuffer(
              mode_plan.reference_depth_upload_staging,
              buffer_for(image, mode_plan.reference_depth_upload_staging),
              input.reference_depth_content_identity);
          mode.reference_depth_transfer_byte_count =
              mode_plan.reference_depth_upload_staging.exact_bytes;
        }
        if (mode_plan.reference_normal_upload_staging.present()) {
          mode.reference_normal_upload_staging = BindBuffer(
              mode_plan.reference_normal_upload_staging,
              buffer_for(image, mode_plan.reference_normal_upload_staging),
              input.reference_normal_content_identity);
          mode.reference_normal_transfer_byte_count =
              mode_plan.reference_normal_upload_staging.exact_bytes;
        }
        if (mode_plan.source_depth_upload_staging.present()) {
          mode.source_depth_upload_staging = BindBuffer(
              mode_plan.source_depth_upload_staging,
              buffer_for(image, mode_plan.source_depth_upload_staging),
              input.source_depth_content_identity);
          mode.source_depth_transfer_byte_count =
              mode_plan.source_depth_upload_staging.exact_bytes;
        }
        mode.source_gray_upload_staging = BindBuffer(
            mode_plan.source_gray_buffer_upload_staging,
            buffer_for(image, mode_plan.source_gray_buffer_upload_staging),
            input.source_gray_content_identity);
        mode.source_gray_image_upload_staging = BindBuffer(
            mode_plan.source_gray_image_upload_staging,
            buffer_for(image, mode_plan.source_gray_image_upload_staging),
            input.source_gray_content_identity);
        mode.depth_readback = BindBuffer(
            mode_plan.depth_readback,
            buffer_for(image, mode_plan.depth_readback));
        mode.normal_readback = BindBuffer(
            mode_plan.normal_readback,
            buffer_for(image, mode_plan.normal_readback));
        mode.mask_readback = BindBuffer(
            mode_plan.mask_readback,
            buffer_for(image, mode_plan.mask_readback));
        mode.reference_transfer_byte_count =
            mode_plan.reference_upload_staging.exact_bytes;
        mode.source_gray_transfer_byte_count =
            mode_plan.source_gray_buffer_upload_staging.exact_bytes;
        mode.source_gray_image_transfer_byte_count =
            mode_plan.source_gray_image_upload_staging.exact_bytes;
      }

      for (std::size_t rotation = 0U; rotation < kRotationCount; ++rotation) {
        runtime::RotationCalibration &calibration =
            owned.resources.calibration[rotation];
        calibration.patch = planned[image].patches[rotation];
        // [BATCH-REF] batch_count 份逐 reference 的 patch。目前 N 个槽装
        // 同一个 reference,故是 N 份相同值;换成 N 份不同输入时,这里
        // 会由 N 份各自的 BuildRotationCalibrationHost 结果填充。
        {
          const std::size_t batch = static_cast<std::size_t>(
              std::max<std::uint64_t>(input.resources.batch_count, 1U));
          std::vector<PatchPC> &patches =
              owned.reference_patches[rotation];
          patches = planned[image].reference_patches[rotation];
          if (patches.size() != batch)
            patches.assign(batch, planned[image].patches[rotation]);
          calibration.reference_patches = patches.data();
          calibration.reference_patch_count = patches.size();
        }
        calibration.active_pose_table = BindBuffer(
            plan.poses[rotation].active_pose_table,
            buffer_for(image, plan.poses[rotation].active_pose_table),
            input.pose_content_identities[rotation]);
        calibration.pose_upload_staging = BindBuffer(
            plan.poses[rotation].pose_upload_staging,
            buffer_for(image, plan.poses[rotation].pose_upload_staging),
            input.pose_content_identities[rotation]);
      }

      if (input.resources.phase != PlanPhase::kPhotometricOnly) {
        owned.resources.consistency_graph = {
            owned.source_indices.data(), owned.source_indices.size()};
        const ProviderBufferAllocation &mask =
            buffer_for(image, plan.modes[1].mask_readback);
        owned.resources.consistency_graph_readback = {
            static_cast<const std::uint32_t *>(mask.mapped_pointer),
            static_cast<std::size_t>(
                plan.modes[1].mask_readback.exact_bytes / sizeof(std::uint32_t)),
            owned.graph_values.data(), owned.graph_values.size(),
            owned.graph_value_counts.data(), mask.host_coherent};
        owned.resources.source_depth_layers = owned.source_depth_layers.data();
        owned.resources.source_depth_layer_count =
            owned.source_depth_layers.size();
      }
#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)
      const ProviderBufferAllocation *photo_depth = nullptr;
      const ProviderBufferAllocation *photo_normal = nullptr;
      const ProviderBufferAllocation *geo_depth = nullptr;
      const ProviderBufferAllocation *geo_normal = nullptr;
      const ProviderBufferAllocation *mask = nullptr;
      if (input.resources.phase != PlanPhase::kGeometricOnly) {
        photo_depth = &buffer_for(image, plan.modes[0].depth_readback);
        photo_normal = &buffer_for(image, plan.modes[0].normal_readback);
      }
      if (input.resources.phase != PlanPhase::kPhotometricOnly) {
        geo_depth = &buffer_for(image, plan.modes[1].depth_readback);
        geo_normal = &buffer_for(image, plan.modes[1].normal_readback);
        mask = &buffer_for(image, plan.modes[1].mask_readback);
      }
      owned.diagnostic_readback = {
          static_cast<std::uint32_t>(input.resources.width),
          static_cast<std::uint32_t>(input.resources.height),
          static_cast<std::uint32_t>(input.source_count),
          photo_depth == nullptr ? nullptr
                                 : static_cast<const float *>(photo_depth->mapped_pointer),
          photo_normal == nullptr ? nullptr
                                  : static_cast<const float *>(photo_normal->mapped_pointer),
          geo_depth == nullptr ? nullptr
                               : static_cast<const float *>(geo_depth->mapped_pointer),
          geo_normal == nullptr ? nullptr
                                : static_cast<const float *>(geo_normal->mapped_pointer),
          mask == nullptr ? nullptr
                          : static_cast<const std::uint32_t *>(mask->mapped_pointer),
          owned.graph_values.data(), 0U};
#endif
    }

    // Upload bytes are copied only after every provider allocation and every
    // output view has been assembled successfully.
    for (std::size_t image = 0U; image < input_count; ++image) {
      const ResourceArenaImageInput &input = inputs[image];
      const ResourceArenaPlan &plan = planned[image].plan;
      // [BATCH-REF 2026-08-30] batch_count = N 时,每个 staging 缓冲都是
      // 「N 个 reference 平面首尾相接」(arena 把每个字节量都乘了 N,
      // stride 由 shader 从 push constant 的 width/height/num_sources 推出)。
      // 输入数组仍是 1 份 ⇒ 把它铺满 N 个平面。
      //
      // 这一步同时是**验收手段**:N 个槽装同一个 reference,则 N 个输出平面
      // 每一个都必须与单跑基线逐字节相同,任何跨 reference 的越界读写、
      // stride 算错、RNG 平面串台都会立刻暴露。
      const std::size_t batch =
          static_cast<std::size_t>(std::max<std::uint64_t>(
              input.resources.batch_count, 1U));
      // [BATCH-REF] 输入数组本身就是 N 份首尾相接(ValidInput 已按 batch
      // 核过计数),整块拷即可。
      (void)batch;
      const auto copy = [&](const AllocationPlan &allocation, const void *bytes) {
        std::memcpy(buffer_for(image, allocation).mapped_pointer, bytes,
                    static_cast<std::size_t>(allocation.exact_bytes));
      };
      const std::size_t input_mode =
          input.resources.phase == PlanPhase::kGeometricOnly ? 1U : 0U;
      copy(plan.modes[input_mode].reference_upload_staging, input.reference_u32);
      if (input.source_depth_f32 != nullptr) {
        copy(plan.modes[1].source_depth_upload_staging,
             input.source_depth_f32);
      }
      if (input.reference_depth_f32 != nullptr) {
        copy(plan.modes[1].reference_depth_upload_staging,
             input.reference_depth_f32);
        copy(plan.modes[1].reference_normal_upload_staging,
             input.reference_normal_f32);
      }
      copy(plan.modes[input_mode].source_gray_buffer_upload_staging,
           input.source_gray_u32);
      copy(plan.modes[input_mode].source_gray_image_upload_staging,
           input.source_gray_u8);
      for (std::size_t rotation = 0U; rotation < kRotationCount; ++rotation) {
        const std::size_t offset =
            rotation *
            static_cast<std::size_t>(
                std::max<std::uint64_t>(input.resources.batch_count, 1U)) *
            kPoseFloatsPerReference(input.source_count);
        copy(plan.poses[rotation].pose_upload_staging,
             planned[image].pose_values.data() + offset);
      }
      candidate->image_views[image] = candidate->owned_images[image].resources;
    }

    *out = ResourceArenaBatch(std::move(candidate));
    if (detail != nullptr) detail->clear();
    return true;
  } catch (...) {
    return SetDetail(detail, "resource arena construction failed");
  }
}

}  // namespace pocketworld::official_dense::vulkan::resource_arena
