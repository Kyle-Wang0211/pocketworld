#include "vulkan_runtime.h"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

using namespace pocketworld::official_dense::vulkan;
using namespace pocketworld::official_dense::vulkan::runtime;

namespace pocketworld::official_dense::vulkan::runtime {
using NativeCommandStepForTesting = bool (*)(void *) noexcept;
bool ResetThenBeginCommandBufferForTesting(
    void *context, NativeCommandStepForTesting reset,
    NativeCommandStepForTesting begin) noexcept;
} // namespace pocketworld::official_dense::vulkan::runtime

namespace {
constexpr std::array<std::array<std::uint32_t, 5>, kShaderCount> kSpv = {{
    {{0x07230203U, 0x10000U, 0, 1, 0}},
    {{0x07230203U, 0x10000U, 0, 2, 0}},
    {{0x07230203U, 0x10000U, 0, 3, 0}},
    {{0x07230203U, 0x10000U, 0, 4, 0}},
    {{0x07230203U, 0x10000U, 0, 5, 0}},
    {{0x07230203U, 0x10000U, 0, 6, 0}},
    {{0x07230203U, 0x10000U, 0, 7, 0}},
    {{0x07230203U, 0x10000U, 0, 8, 0}},
    {{0x07230203U, 0x10000U, 0, 9, 0}},
    {{0x07230203U, 0x10000U, 0, 10, 0}},
    {{0x07230203U, 0x10000U, 0, 11, 0}},
}};
constexpr std::uint64_t kPlane = 64U * 48U * 4U;
constexpr std::size_t kPixelCount = 64U * 48U;
constexpr std::array<std::int32_t, 2> kSources = {10, 20};
std::array<std::uint32_t, kPixelCount * kSources.size()> kMappedMask{};
std::array<std::int32_t, kPixelCount * (3U + kSources.size())> kGraphValues{};
std::size_t kGraphValueCount = 0;
struct Pair {
  std::uint64_t a, b;
};

class State final : public FakeDispatchBackend {
public:
  bool CreatePipeline(PipelineKind kind,
                      const ShaderBinary &binary) noexcept override {
    if (!Ready() || begun || static_cast<std::size_t>(kind) != pipelines ||
        binary.words != kSpv[static_cast<std::size_t>(kind)].data())
      return false;
    ++pipelines;
    ++calls;
    return true;
  }
  bool Begin() noexcept override {
    if (!Ready() || begun || pipelines != kShaderCount)
      return false;
    begun = true;
    ++calls;
    return true;
  }
  bool AllocateAndBindDescriptorSet(PipelineKind kind,
                                    const DescriptorWrite *writes,
                                    std::size_t count) noexcept override {
    if (!Ready() || !begun || pending || writes == nullptr || count == 0)
      return false;
    pending_kind = kind;
    pending_writes.assign(writes, writes + count);
    pending = true;
    ++descriptor_sets;
    ++calls;
    return true;
  }
  bool BindAndDispatch(PipelineKind kind, std::uint32_t mask, const void *pc,
                       std::size_t size, std::uint32_t x, std::uint32_t y,
                       std::uint32_t z) noexcept override {
    if (!Ready() || !pending || pending_kind != kind || pc == nullptr ||
        size == 0 || x == 0 || y == 0 || z == 0)
      return false;
    if (kind == PipelineKind::kOpenMvsPcgInitialize ||
        kind == PipelineKind::kOpenMvsPcgDepthInitialize ||
        kind == PipelineKind::kNormalInitialize) {
      const auto &patch = *static_cast<const PatchPC *>(pc);
      if (x != (patch.width + 31U) / 32U ||
          y != (patch.height + 15U) / 16U || z != 1U) {
        return false;
      }
    }
    if (kind == PipelineKind::kReferenceFilter) {
      const auto *dimensions = static_cast<const std::uint32_t *>(pc);
      if (x != (dimensions[0] + 15U) / 16U ||
          y != (dimensions[1] + 7U) / 8U || z != 1U) {
        return false;
      }
    }
    if (kind == PipelineKind::kRotateNormalF32) {
      const auto &patch = *static_cast<const PatchPC *>(pc);
      if (x != (patch.width + 15U) / 16U ||
          y != (patch.height + 7U) / 8U || z != 1U) {
        return false;
      }
    }
    if (kind == PipelineKind::kRotateU32) {
      const auto *dimensions = static_cast<const std::int32_t *>(pc);
      if (dimensions[0] <= 0 || dimensions[1] <= 0 ||
          x != (static_cast<std::uint32_t>(dimensions[0]) + 31U) / 32U ||
          y != static_cast<std::uint32_t>(dimensions[1]) || z != 1U) {
        return false;
      }
    }
    if (kind == PipelineKind::kTransposeF32 ||
        kind == PipelineKind::kFlipHorizontalF32) {
      const auto *dimensions = static_cast<const std::int32_t *>(pc);
      if (dimensions[0] <= 0 || dimensions[1] <= 0 ||
          x != (static_cast<std::uint32_t>(dimensions[0]) + 31U) / 32U ||
          y != (static_cast<std::uint32_t>(dimensions[1]) + 31U) / 32U ||
          z != 1U) {
        return false;
      }
    }
    if (kind == PipelineKind::kFullSweep && (y != 1U || z != 1U))
      return false;
    if (kind == PipelineKind::kFullSweep) {
      if (mask != 0 && mask != 1 && mask != 7)
        return false;
      sweeps.push_back(*static_cast<const PatchPC *>(pc));
      masks.push_back(mask);
      poses.push_back(Write(13).resource.buffer);
      if (mask == 0)
        ++photo_sweeps;
      if (mask == 1)
        ++geom_sweeps;
      if (mask == 7)
        ++filtered_sweeps;
    } else if (mask != 0)
      return false;
    if (kind == PipelineKind::kRotateF32)
      float_rotations.push_back(
          {Write(0).resource.buffer, Write(1).resource.buffer});
    if (kind == PipelineKind::kRotateU32)
      uint_rotations.push_back(
          {Write(0).resource.buffer, Write(1).resource.buffer});
    if (kind == PipelineKind::kRotateNormalF32) {
      awaiting_normal_barrier = true;
      ++normal_vectors;
    }
    if (kind == PipelineKind::kNormalInitialize) {
      if (init_phase != 4U)
        return false;
      init_phase = 5U;
      ++normal_inits;
      normal_init_rng = Write(6).resource.buffer;
      init_order.push_back(3U);
    }
    if (kind == PipelineKind::kOpenMvsPcgInitialize) {
      ++rng_inits;
      init_order.push_back(1U);
      if (rng_inits == 1U)
        init_phase = 1U;
    }
    if (kind == PipelineKind::kOpenMvsPcgDepthInitialize) {
      if (init_phase != 2U)
        return false;
      init_phase = 3U;
      depth_inits.push_back(
          {Write(6).resource.buffer, Write(0).resource.buffer});
      init_order.push_back(2U);
    }
    pending = false;
    ++dispatches;
    ++calls;
    return true;
  }
  bool BindAndDispatchPartitioned(
      PipelineKind kind, std::uint32_t mask, const void *pc,
      std::size_t size, std::uint32_t x, std::uint32_t y,
      std::uint32_t z) noexcept override {
    if ((kind != PipelineKind::kInitialCost &&
         kind != PipelineKind::kFullSweep) ||
        pc == nullptr ||
        size != sizeof(PatchPC))
      return false;
    const PatchPC &patch = *static_cast<const PatchPC *>(pc);
    const std::uint64_t physical_count =
        PhysicalPartitionCount(kind, patch.height, x);
    if (physical_count < 2U)
      return false;
    if (kind == PipelineKind::kFullSweep) {
      for (std::uint64_t index = 0U; index < physical_count; ++index) {
        const PartitionDispatch partition =
            PartitionDispatchAt(kind, patch.height, x, index);
        if (!partition.valid)
          return false;
        partition_group_bases.push_back(partition.base_group_x);
        partition_backward_phases.push_back(partition.backward);
        partition_row_ranges.push_back(
            {partition.row_begin, partition.row_end});
      }
    }
    partition_submit_count +=
        PartitionInternalSubmitCount(kind, patch.height, x);
    return BindAndDispatch(kind, mask, pc, size, x, y, z);
  }
  bool PipelineBarrier() noexcept override {
    if (!begun || pending)
      return false;
    if (awaiting_normal_barrier) {
      awaiting_normal_barrier = false;
      ++normal_barriers;
    }
    if (awaiting_image_clear_barrier) {
      image_operations.push_back(5U);
      awaiting_image_clear_barrier = false;
    }
    ++barriers;
    if (init_phase == 1U)
      init_phase = 2U;
    else if (init_phase == 3U)
      init_phase = 4U;
    else if (init_phase == 5U)
      init_phase = 6U;
    ++calls;
    return true;
  }
  bool CopyBuffer(std::uint64_t s, std::uint64_t, std::uint64_t d,
                  std::uint64_t, std::uint64_t bytes) noexcept override {
    if (!Ready() || s == 0 || d == 0 || bytes == 0)
      return false;
    copies.push_back({s, d});
    ++calls;
    return true;
  }
  bool TransitionSampledImage(std::uint64_t image,
                              bool to_transfer_destination) noexcept override {
    if (!Ready() || image == 0)
      return false;
    image_transitions.push_back({image, to_transfer_destination ? 1U : 0U});
    image_operations.push_back(to_transfer_destination ? 1U : 4U);
    ++calls;
    return true;
  }
  bool ClearSampledImageFloat(std::uint64_t image,
                              float value) noexcept override {
    if (!Ready() || image == 0)
      return false;
    image_clear_values.push_back(value);
    image_operations.push_back(2U);
    awaiting_image_clear_barrier = true;
    ++calls;
    return true;
  }
  bool CopyBufferToImage(std::uint64_t source, std::uint64_t,
                         std::uint64_t image, std::uint32_t layer,
                         std::uint32_t width, std::uint32_t height,
                         std::uint32_t bytes_per_texel) noexcept override {
    if (!Ready() || source == 0 || image == 0 || width == 0 || height == 0 ||
        bytes_per_texel == 0)
      return false;
    image_copies.push_back({source, image});
    image_copy_layers.push_back(layer);
    image_copy_extents.push_back({width, height});
    image_operations.push_back(3U);
    ++calls;
    return true;
  }
  bool FillBuffer(std::uint64_t buffer, std::uint64_t, std::uint64_t bytes,
                  std::uint32_t value) noexcept override {
    if (!Ready() || buffer == 0 || bytes == 0)
      return false;
    fills.push_back(value);
    ++calls;
    return true;
  }
  bool CopyBufferRotatedU32(std::uint64_t s, std::uint64_t, std::uint64_t d,
                            std::uint64_t, std::uint32_t w, std::uint32_t h,
                            std::uint32_t layers) noexcept override {
    if (!Ready() || s == 0 || d == 0 || s == d || w == 0 || h == 0 ||
        layers == 0)
      return false;
    uint_rotations.push_back({s, d});
    ++calls;
    return true;
  }
  bool EndSubmitAndWait() noexcept override {
    if (!Ready() || pending || !begun)
      return false;
    ended = true;
    ++calls;
    return true;
  }
  bool SubmitWaitAndContinue() noexcept override {
    if (!Ready() || pending || !begun)
      return false;
    ++submit_wait_continue_count;
    ++calls;
    return true;
  }
  bool Ready() noexcept {
    if (awaiting_normal_barrier) {
      normal_violation = true;
      return false;
    }
    if (awaiting_image_clear_barrier) {
      image_clear_violation = true;
      return false;
    }
    return true;
  }
  const DescriptorWrite &Write(std::uint32_t binding) const {
    for (const auto &write : pending_writes)
      if (write.shader_binding == binding)
        return write;
    return pending_writes.front();
  }

  std::size_t calls = 0, pipelines = 0, descriptor_sets = 0, dispatches = 0,
              barriers = 0, submit_wait_continue_count = 0,
              partition_submit_count = 0;
  std::size_t photo_sweeps = 0, geom_sweeps = 0, filtered_sweeps = 0;
  std::size_t rng_inits = 0, normal_inits = 0, normal_vectors = 0,
              normal_barriers = 0;
  std::uint64_t normal_init_rng = 0;
  std::uint32_t init_phase = 0;
  bool begun = false, ended = false, pending = false,
       awaiting_normal_barrier = false, awaiting_image_clear_barrier = false;
  bool normal_violation = false;
  bool image_clear_violation = false;
  PipelineKind pending_kind = PipelineKind::kReferenceFilter;
  std::vector<DescriptorWrite> pending_writes;
  std::vector<PatchPC> sweeps;
  std::vector<std::uint32_t> masks, fills;
  std::vector<std::uint32_t> init_order;
  std::vector<std::uint64_t> poses;
  std::vector<Pair> copies, float_rotations, uint_rotations, depth_inits;
  std::vector<Pair> image_transitions, image_copies;
  std::vector<std::uint32_t> image_copy_layers;
  std::vector<Pair> partition_row_ranges;
  std::vector<std::uint32_t> partition_group_bases;
  std::vector<bool> partition_backward_phases;
  std::vector<Pair> image_copy_extents;
  std::vector<std::uint32_t> image_operations;
  std::vector<float> image_clear_values;
};

BoundResource Buf(std::uint64_t handle, std::uint64_t range,
                  std::uint32_t layers, ResourceScalarType type) {
  BoundResource r;
  r.buffer = handle;
  r.range = range;
  r.array_layers = layers;
  r.scalar_type = type;
  return r;
}
SamplerMetadata DepthSampler() {
  return {SamplerFormat::kR32Sfloat,
          SamplerFilter::kNearest,
          SamplerFilter::kNearest,
          SamplerAddressMode::kClampToBorder,
          SamplerAddressMode::kClampToBorder,
          SamplerBorderColor::kFloatTransparentBlack,
          true};
}
SamplerMetadata GraySampler() {
  return {SamplerFormat::kR8Unorm,
          SamplerFilter::kLinear,
          SamplerFilter::kLinear,
          SamplerAddressMode::kClampToBorder,
          SamplerAddressMode::kClampToBorder,
          SamplerBorderColor::kFloatTransparentBlack,
          true};
}

void PopulateMode(ModeResources *m, std::uint64_t base) {
  for (std::size_t b = 0; b < kBindingCount; ++b)
    for (std::uint32_t r = 0; r < 4; ++r) {
      const bool u = b == 5 || b == 6 || b == 8 || b == 9 || b == 14;
      std::uint32_t layers = b == 1 ? 3U
                                    : ((b == 2 || b == 3 || b == 4 || b == 5)
                                           ? 2U
                                           : (b == 6 ? 6U
                                                     : ((b == 12 || b == 14)
                                                            ? 2U
                                                            : 1U)));
      auto resource =
          Buf(base + b * 10U + r, kPlane * layers, layers,
              u ? ResourceScalarType::kUint32 : ResourceScalarType::kFloat32);
      if (b == 12 || b == 14) {
        resource.image = base + 5000U + b * 10U + r;
        resource.image_view = base + 1000U + b * 10U + r;
        resource.sampler = base + 2000U + b * 10U + r;
        resource.sampler_metadata = b == 12 ? DepthSampler() : GraySampler();
      }
      m->bindings[b][r] = resource;
    }
  m->reference_upload_staging =
      Buf(base + 3000U, kPlane, 1, ResourceScalarType::kUint32);
  m->source_gray_upload_staging =
      Buf(base + 3004U, kPlane * 2U, 1, ResourceScalarType::kUint32);
  m->source_gray_image_upload_staging =
      Buf(base + 3005U, (kPlane / 4U) * 2U, 1,
          ResourceScalarType::kUint32);
  const std::uint64_t source_identity = base + 9000U;
  m->source_gray_upload_staging.content_identity = source_identity;
  m->source_gray_image_upload_staging.content_identity = source_identity;
  for (std::uint32_t r = 0; r < 4; ++r)
    m->bindings[14][r].content_identity = source_identity;
  for (std::uint32_t r = 1; r < 4; ++r) {
    m->bindings[12][r].image = m->bindings[12][0].image;
    m->bindings[12][r].image_view = m->bindings[12][0].image_view;
    m->bindings[12][r].sampler = m->bindings[12][0].sampler;
    m->bindings[12][r].array_layers = m->bindings[12][0].array_layers;
    m->bindings[12][r].range = m->bindings[12][0].range;
    m->bindings[12][r].content_identity =
        m->bindings[12][0].content_identity;
    m->bindings[12][r].sampler_metadata =
        m->bindings[12][0].sampler_metadata;
    m->bindings[14][r] = m->bindings[14][0];
  }
  m->depth_readback =
      Buf(base + 3001U, kPlane, 1, ResourceScalarType::kFloat32);
  m->normal_readback =
      Buf(base + 3002U, kPlane * 3U, 3, ResourceScalarType::kFloat32);
  m->mask_readback =
      Buf(base + 3003U, kPlane * 2U, 2, ResourceScalarType::kUint32);
  m->reference_transfer_byte_count = kPlane;
  m->source_gray_transfer_byte_count = kPlane * 2U;
  m->source_gray_image_transfer_byte_count = (kPlane / 4U) * 2U;
}

RecordRequest MakeRequest(DispatchPlan *plan, ImageResources *image) {
  RecordRequest request;
  request.plan = plan;
  request.images = image;
  request.image_count = 1;
  for (std::size_t i = 0; i < kShaderCount; ++i)
    request.shaders.binaries[i] = {
        static_cast<PipelineKind>(i), kSpv[i].data(), kSpv[i].size(),
        CanonicalShaderManifest()[i].source_sha256};
  PopulateMode(&image->photometric, 10000U);
  PopulateMode(&image->geometric, 20000U);
  for (std::uint32_t r = 0; r < 4; ++r) {
    PatchPC pc{};
    pc.width = (r & 1U) ? 48U : 64U;
    pc.height = (r & 1U) ? 64U : 48U;
    pc.num_sources = 2;
    pc.workspace_max_dim = 64;
    pc.source_width = 64;
    pc.source_height = 48;
    pc.rotation_0_to_3 = r;
    pc.ref_K_fx = 100.0F + static_cast<float>(r);
    pc.ref_K_cx = 30.0F + r;
    pc.ref_K_fy = 101.0F + r;
    pc.ref_K_cy = 20.0F + r;
    pc.ref_inv_fx = 0.01F + r;
    pc.ref_inv_neg_cx_fx = -0.3F - r;
    pc.ref_inv_fy = 0.02F + r;
    pc.ref_inv_neg_cy_fy = -0.4F - r;
    pc.depth_min = 0.2F;
    pc.depth_max = 20.0F;
    pc.sigma_spatial = 5.0F;
    pc.sigma_color = 0.2F;
    pc.ncc_sigma = 0.6F;
    image->calibration[r].patch = pc;
    image->calibration[r].active_pose_table =
        Buf(30000U + r, 43U * 2U * 4U, 1, ResourceScalarType::kFloat32);
    image->calibration[r].pose_upload_staging =
        Buf(31000U + r, 43U * 2U * 4U, 1, ResourceScalarType::kFloat32);
    image->calibration[r].active_pose_table.content_identity = 40000U + r;
    image->calibration[r].pose_upload_staging.content_identity = 40000U + r;
  }
  image->consistency_graph = {kSources.data(), kSources.size()};
  static constexpr std::array<SourceDepthLayerCopy, 2> depth_layers = {{
      {0U, 0U, 64U, 48U},
      {0U, 1U, 64U, 48U},
  }};
  image->source_depth_layers = depth_layers.data();
  image->source_depth_layer_count = depth_layers.size();
  kMappedMask.fill(0U);
  kGraphValues.fill(-1);
  kGraphValueCount = 0;
  kMappedMask[0] = 1U;
  kMappedMask[kPixelCount] = 1U;
  kMappedMask[kPixelCount + 1U] = 1U;
  image->consistency_graph_readback = {
      kMappedMask.data(),
      kMappedMask.size(),
      kGraphValues.data(),
      kGraphValues.size(),
      &kGraphValueCount,
      true,
  };
  return request;
}
bool Saw(const std::vector<Pair> &values, std::uint64_t a, std::uint64_t b) {
  for (auto value : values)
    if (value.a == a && value.b == b)
      return true;
  return false;
}
std::size_t Count(const std::vector<Pair> &values, std::uint64_t a,
                  std::uint64_t b) {
  std::size_t count = 0U;
  for (auto value : values)
    if (value.a == a && value.b == b)
      ++count;
  return count;
}
int Req(bool value, int code) { return value ? 0 : code; }

struct NativeCommandTrace {
  std::array<std::uint32_t, 8> events{};
  std::size_t event_count = 0;
  std::size_t begin_count = 0;
  std::size_t recorded_commands = 0;
  bool reset_succeeds = true;
};

bool TraceReset(void *opaque) noexcept {
  auto *trace = static_cast<NativeCommandTrace *>(opaque);
  trace->events[trace->event_count++] = 1U;
  if (!trace->reset_succeeds)
    return false;
  trace->recorded_commands = 0U;
  return true;
}

bool TraceBegin(void *opaque) noexcept {
  auto *trace = static_cast<NativeCommandTrace *>(opaque);
  trace->events[trace->event_count++] = 2U;
  ++trace->begin_count;
  ++trace->recorded_commands;
  return true;
}
} // namespace

int main() {
  NativeCommandTrace native_trace;
  if (int e = Req(ResetThenBeginCommandBufferForTesting(
                      &native_trace, &TraceReset, &TraceBegin) &&
                      native_trace.event_count == 2U &&
                      native_trace.events[0] == 1U &&
                      native_trace.events[1] == 2U &&
                      native_trace.begin_count == 1U &&
                      native_trace.recorded_commands == 1U,
                  42))
    return e;
  if (int e = Req(ResetThenBeginCommandBufferForTesting(
                      &native_trace, &TraceReset, &TraceBegin) &&
                      native_trace.event_count == 4U &&
                      native_trace.events[2] == 1U &&
                      native_trace.events[3] == 2U &&
                      native_trace.begin_count == 2U &&
                      native_trace.recorded_commands == 1U,
                  43))
    return e;
  NativeCommandTrace reset_failure;
  reset_failure.reset_succeeds = false;
  if (int e = Req(!ResetThenBeginCommandBufferForTesting(
                      &reset_failure, &TraceReset, &TraceBegin) &&
                      reset_failure.event_count == 1U &&
                      reset_failure.events[0] == 1U &&
                      reset_failure.begin_count == 0U &&
                      reset_failure.recorded_commands == 0U,
                  44))
    return e;

  const std::array<std::uint32_t, 8> mask = {1, 0, 0, 1, 0, 1, 0, 1};
  ConsistencyGraphInput graph = {mask.data(), 2, 2, 2, kSources.data(), 2};
  if (int e = Req(RequiredConsistencyGraphValueCount(graph) == 13, 1))
    return e;
  std::array<std::int32_t, 13> out{};
  constexpr std::array<std::int32_t, 13> expected = {0,  0, 1, 10, 1,  0, 1,
                                                     20, 1, 1, 2,  10, 20};
  if (int e = Req(SerializeConsistencyGraph(graph, out.data(), out.size()) &&
                      out == expected,
                  2))
    return e;

  DispatchPlan plan = CreateDispatchPlan(1);
  ImageResources image;
  RecordRequest request = MakeRequest(&plan, &image);
  const RecordResult production_result = Record(request);
  if (int e = Req(
          production_result.status ==
                  RuntimeStatus::kPcgAdaptationNotCertified &&
              production_result.recorded_plan_steps == 0U &&
              production_result.dispatch_count == 0U,
          20))
    return e;
  State state;
  TestCertifications gates;
  auto result = RecordForTesting(request, gates, &state);
  if (int e = Req(result.status == RuntimeStatus::kPcgAdaptationNotCertified &&
                      state.calls == 0,
                  3))
    return e;
  gates.pcg = true;
  result = RecordForTesting(request, gates, &state);
  if (int e = Req(result.status == RuntimeStatus::kTextureParityNotCertified &&
                      state.calls == 0,
                  4))
    return e;
  gates.texture = true;
  result = RecordForTesting(request, gates, &state);
  if (int e = Req(result.status == RuntimeStatus::kFullSweepNotCertified &&
                      state.calls == 0,
                  5))
    return e;
  gates.full_sweep = true;
  result = RecordForTesting(request, gates, &state);
  if (int e = Req(result.recorded() && result.recorded_plan_steps == 552 &&
                      result.consistency_graph_value_count == 9U &&
                      kGraphValueCount == 9U,
                  6))
    return e;
  constexpr std::array<std::int32_t, 9> expected_runtime_graph = {
      0, 0, 2, 10, 20, 1, 0, 1, 20};
  for (std::size_t index = 0; index < expected_runtime_graph.size(); ++index) {
    if (int e = Req(kGraphValues[index] == expected_runtime_graph[index], 16))
      return e;
  }
  if (int e = Req(state.rng_inits == 2 && state.depth_inits.size() == 1 &&
                      state.normal_inits == 1 &&
                      state.init_order.size() >= 3U &&
                      state.init_order[0] == 1U &&
                      state.init_order[1] == 2U &&
                      state.init_order[2] == 3U &&
                      state.init_phase == 6U &&
                      state.normal_init_rng ==
                          image.photometric.bindings[6][0].buffer,
                  7))
    return e;
  if (int e = Req(state.sweeps.size() == 40 && state.photo_sweeps == 20 &&
                      state.geom_sweeps == 19 && state.filtered_sweeps == 1,
                  8))
    return e;
  for (std::size_t i = 0; i < state.sweeps.size(); ++i) {
    const std::uint32_t local = static_cast<std::uint32_t>(i % 20U),
                        iter = local / 4U, sweep = local % 4U;
    const float perturb =
        1.0F / std::pow(2.0F, static_cast<float>(iter) +
                                  static_cast<float>(sweep) / 4.0F);
    const auto &pc = state.sweeps[i];
    if (int e = Req(std::abs(pc.perturbation - perturb) < 1e-7F &&
                        std::abs(pc.prev_sel_prob_weight -
                                 static_cast<float>(local) / 20.0F) < 1e-7F &&
                        pc.reserved == OfficialNccNormalizationBits(0.6F) &&
                        pc.rotation_0_to_3 == sweep &&
                        pc.ref_K_fx == 100.0F + sweep &&
                        pc.ref_inv_fx == 0.01F + sweep &&
                        pc.ref_inv_neg_cx_fx == -0.3F - sweep &&
                        pc.ref_inv_fy == 0.02F + sweep &&
                        pc.ref_inv_neg_cy_fy == -0.4F - sweep &&
                        state.poses[i] == 30000U + sweep,
                    9))
      return e;
  }
  for (std::size_t index = 0; index < state.masks.size(); ++index) {
    const std::uint32_t expected_mask =
        index < 20U ? 0U : (index == 39U ? 7U : 1U);
    if (int e = Req(state.masks[index] == expected_mask, 17))
      return e;
  }
  if (int e = Req(state.masks.back() == 7U && state.normal_vectors == 40 &&
                      state.normal_barriers == 40 && !state.normal_violation,
                  10))
    return e;
  if (int e = Req(Saw(state.float_rotations,
                      image.photometric.bindings[3][0].buffer,
                      image.photometric.bindings[4][1].buffer) &&
                      image.photometric.bindings[3][1].buffer !=
                          image.photometric.bindings[4][1].buffer,
                  11))
    return e;
  if (int e = Req(
          Saw(state.uint_rotations, image.photometric.bindings[6][0].buffer,
              image.photometric.bindings[6][1].buffer) &&
              Saw(state.uint_rotations, image.geometric.bindings[5][3].buffer,
                  image.geometric.bindings[5][0].buffer) &&
              state.uint_rotations.size() == 282,
          12))
    return e;
  if (int e = Req(state.fills.size() == 3 && state.fills[0] == 0x3f000000U &&
                      state.fills[1] == 0x3f000000U && state.fills[2] == 0U &&
                      state.image_clear_values.size() == 1U &&
                      state.image_clear_values[0] == 0.0F &&
                      state.copies.size() == 19 &&
                      state.image_copies.size() == 6 &&
                      state.image_transitions.size() == 6,
                  13))
    return e;
  for (std::uint32_t rotation = 0U; rotation < 4U; ++rotation) {
    if (int e = Req(
            Count(state.copies,
                  image.calibration[rotation].pose_upload_staging.buffer,
                  image.calibration[rotation].active_pose_table.buffer) == 2U,
            60))
      return e;
  }
  constexpr std::array<std::uint32_t, 6> depth_upload_sequence = {
      1U, 2U, 5U, 3U, 3U, 4U};
  if (int e = Req(state.image_operations.size() >= depth_upload_sequence.size() &&
                      std::equal(depth_upload_sequence.begin(),
                                 depth_upload_sequence.end(),
                                 state.image_operations.end() -
                                     depth_upload_sequence.size()),
                  33))
    return e;
  if (int e =
          Req(Saw(state.depth_inits, image.photometric.bindings[6][0].buffer,
                  image.photometric.bindings[0][0].buffer),
              14))
    return e;
  if (int e = Req(
          Saw(state.copies, image.photometric.bindings[0][0].buffer,
              image.geometric.bindings[0][0].buffer) &&
              Saw(state.copies, image.photometric.bindings[1][0].buffer,
                  image.geometric.bindings[1][0].buffer) &&
              Saw(state.copies, image.photometric.bindings[0][0].buffer,
                  image.photometric.depth_readback.buffer) &&
              Saw(state.copies, image.photometric.bindings[1][0].buffer,
                  image.photometric.normal_readback.buffer) &&
              Saw(state.copies, image.geometric.bindings[0][0].buffer,
                  image.geometric.depth_readback.buffer) &&
              Saw(state.copies, image.geometric.bindings[1][0].buffer,
                  image.geometric.normal_readback.buffer) &&
              Saw(state.copies, image.geometric.bindings[5][0].buffer,
                  image.geometric.mask_readback.buffer),
          18))
    return e;
  if (int e = Req(result.barrier_count == 423U, 19))
    return e;
  if (int e = Req(state.submit_wait_continue_count == 45U, 45))
    return e;
  if (int e = Req(result.partition_submit_count == 0U, 46))
    return e;
  if (int e = Req(result.queue_submit_count == 46U, 58))
    return e;
  if (int e = Req(state.partition_submit_count == 0U, 47))
    return e;
  if (int e = Req(AdditionalPartitionSubmitCount(0U) == 0U &&
                      AdditionalPartitionSubmitCount(256U) == 0U &&
                      AdditionalPartitionSubmitCount(257U) == 1U &&
                      AdditionalPartitionSubmitCount(512U) == 1U &&
                      AdditionalPartitionSubmitCount(513U) == 2U,
                  54))
    return e;
  if (int e = Req(
          PhysicalPartitionCount(PipelineKind::kInitialCost, 576U, 24U) ==
                  1728U &&
              PhysicalPartitionCount(PipelineKind::kFullSweep, 576U, 24U) ==
                  3456U &&
              PartitionInternalSubmitCount(PipelineKind::kInitialCost, 576U,
                                           24U) == 6U &&
              PartitionInternalSubmitCount(PipelineKind::kFullSweep, 576U,
                                           24U) == 14U,
          55))
    return e;
  if (int e = Req(
          FrozenReferenceQueueSubmitCount(768U, 576U,
                                          PlanPhase::kPhotometricOnly) ==
                  23U &&
              FrozenReferenceQueueSubmitCount(768U, 576U,
                                              PlanPhase::kGeometricOnly) ==
                  23U &&
              FrozenReferenceQueueSubmitCount(768U, 576U,
                                              PlanPhase::kFull) == 46U,
          59))
    return e;
  const PartitionDispatch initial_first = PartitionDispatchAt(
      PipelineKind::kInitialCost, 17U, 2U, 0U);
  const PartitionDispatch initial_next_group = PartitionDispatchAt(
      PipelineKind::kInitialCost, 17U, 2U, 3U);
  const PartitionDispatch sweep_first =
      PartitionDispatchAt(PipelineKind::kFullSweep, 17U, 2U, 0U);
  const PartitionDispatch sweep_forward =
      PartitionDispatchAt(PipelineKind::kFullSweep, 17U, 2U, 3U);
  const PartitionDispatch sweep_next_group =
      PartitionDispatchAt(PipelineKind::kFullSweep, 17U, 2U, 6U);
  if (int e = Req(
          initial_first.valid && initial_first.base_group_x == 0U &&
              initial_first.row_begin == 0U && initial_first.row_end == 8U &&
              !initial_first.backward &&
              initial_first.boundary_after == PartitionBoundary::kBarrier &&
              initial_next_group.valid &&
              initial_next_group.base_group_x == 1U &&
              initial_next_group.row_begin == 0U &&
              initial_next_group.row_end == 8U &&
              sweep_first.valid && sweep_first.base_group_x == 0U &&
              sweep_first.row_begin == 9U && sweep_first.row_end == 17U &&
              sweep_first.backward && sweep_forward.valid &&
              sweep_forward.row_begin == 0U && sweep_forward.row_end == 8U &&
              !sweep_forward.backward && sweep_next_group.valid &&
              sweep_next_group.base_group_x == 1U &&
              sweep_next_group.row_begin == 9U &&
              sweep_next_group.row_end == 17U &&
              sweep_next_group.backward,
          56))
    return e;
  const PartitionDispatch before_batch = PartitionDispatchAt(
      PipelineKind::kInitialCost, 513U, 8U, 254U);
  const PartitionDispatch at_batch = PartitionDispatchAt(
      PipelineKind::kInitialCost, 513U, 8U, 255U);
  const PartitionDispatch last_partition = PartitionDispatchAt(
      PipelineKind::kInitialCost, 513U, 8U,
      PhysicalPartitionCount(PipelineKind::kInitialCost, 513U, 8U) - 1U);
  const PartitionDispatch out_of_range = PartitionDispatchAt(
      PipelineKind::kInitialCost, 513U, 8U,
      PhysicalPartitionCount(PipelineKind::kInitialCost, 513U, 8U));
  if (int e = Req(
          before_batch.boundary_after == PartitionBoundary::kBarrier &&
              at_batch.boundary_after == PartitionBoundary::kSubmitWait &&
              last_partition.boundary_after == PartitionBoundary::kNone &&
              !out_of_range.valid,
          57))
    return e;
  if (int e = Req(state.partition_row_ranges.empty() &&
                      state.partition_group_bases.empty() &&
                      state.partition_backward_phases.empty(),
                  48))
    return e;

  // PatchMatchController's second pass reloads the persisted reference depth
  // and normal maps. A phase-split geometric run must copy those exact uploads
  // into binding 0/1 and must never read a non-resident photometric arena.
  const PlanOptions geometric_options{5U, true, true,
                                      PlanPhase::kGeometricOnly};
  DispatchPlan geometric_plan = CreateDispatchPlan(1U, geometric_options);
  ImageResources geometric_image;
  RecordRequest geometric_request =
      MakeRequest(&geometric_plan, &geometric_image);
  ModeResources &geometric = geometric_image.geometric;
  geometric.source_depth_upload_staging =
      Buf(90001U, 2U * kPlane, 1U, ResourceScalarType::kFloat32);
  geometric.source_depth_upload_staging.content_identity = 90002U;
  geometric.source_depth_transfer_byte_count = 2U * kPlane;
  for (std::uint32_t rotation = 0U; rotation < 4U; ++rotation) {
    geometric.bindings[12][rotation].content_identity = 90002U;
  }
  geometric.reference_depth_upload_staging =
      Buf(90003U, kPlane, 1U, ResourceScalarType::kFloat32);
  geometric.reference_depth_upload_staging.content_identity = 90004U;
  geometric.reference_depth_transfer_byte_count = kPlane;
  geometric.bindings[0][0].content_identity = 90004U;
  geometric.reference_normal_upload_staging =
      Buf(90005U, 3U * kPlane, 1U, ResourceScalarType::kFloat32);
  geometric.reference_normal_upload_staging.content_identity = 90006U;
  geometric.reference_normal_transfer_byte_count = 3U * kPlane;
  geometric.bindings[1][0].content_identity = 90006U;
  State geometric_backend;
  const RecordResult geometric_result =
      RecordForTesting(geometric_request, gates, &geometric_backend);
  if (int e = Req(
          geometric_result.recorded() && geometric_backend.rng_inits == 1U &&
              geometric_backend.depth_inits.empty() &&
              geometric_backend.normal_inits == 0U &&
              Saw(geometric_backend.copies,
                  geometric.reference_depth_upload_staging.buffer,
                  geometric.bindings[0][0].buffer) &&
              Saw(geometric_backend.copies,
                  geometric.reference_normal_upload_staging.buffer,
                  geometric.bindings[1][0].buffer) &&
              !Saw(geometric_backend.copies,
                   geometric_image.photometric.bindings[0][0].buffer,
                   geometric.bindings[0][0].buffer),
          58)) {
    return e;
  }
  for (std::uint32_t rotation = 0U; rotation < 4U; ++rotation) {
    if (int e = Req(
            Count(geometric_backend.copies,
                  geometric_image.calibration[rotation]
                      .pose_upload_staging.buffer,
                  geometric_image.calibration[rotation]
                      .active_pose_table.buffer) == 1U,
            61)) {
      return e;
    }
  }
  ImageResources missing_reference_seed = geometric_image;
  missing_reference_seed.geometric.reference_normal_upload_staging = {};
  geometric_request.images = &missing_reference_seed;
  State missing_reference_seed_backend;
  const RecordResult missing_reference_seed_result =
      RecordForTesting(geometric_request, gates,
                       &missing_reference_seed_backend);
  if (int e = Req(
          missing_reference_seed_result.status ==
                  RuntimeStatus::kInvalidRequest &&
              missing_reference_seed_backend.calls == 0U,
          59)) {
    return e;
  }

  ImageResources sampled_alias = image;
  sampled_alias.geometric.bindings[12][0].image =
      sampled_alias.geometric.bindings[14][0].image;
  request.images = &sampled_alias;
  State sampled_alias_backend;
  result = RecordForTesting(request, gates, &sampled_alias_backend);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      sampled_alias_backend.calls == 0U,
                  36))
    return e;

  ImageResources distinct_rotation_image = image;
  ++distinct_rotation_image.photometric.bindings[12][1].image;
  request.images = &distinct_rotation_image;
  State distinct_rotation_image_backend;
  result = RecordForTesting(request, gates, &distinct_rotation_image_backend);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      distinct_rotation_image_backend.calls == 0U,
                  38))
    return e;

  ImageResources distinct_rotation_view = image;
  ++distinct_rotation_view.photometric.bindings[14][2].image_view;
  request.images = &distinct_rotation_view;
  State distinct_rotation_view_backend;
  result = RecordForTesting(request, gates, &distinct_rotation_view_backend);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      distinct_rotation_view_backend.calls == 0U,
                  39))
    return e;

  ImageResources distinct_rotation_sampler = image;
  ++distinct_rotation_sampler.geometric.bindings[12][3].sampler;
  request.images = &distinct_rotation_sampler;
  State distinct_rotation_sampler_backend;
  result =
      RecordForTesting(request, gates, &distinct_rotation_sampler_backend);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      distinct_rotation_sampler_backend.calls == 0U,
                  40))
    return e;

  ImageResources distinct_rotation_gray_buffer = image;
  ++distinct_rotation_gray_buffer.geometric.bindings[14][1].buffer;
  request.images = &distinct_rotation_gray_buffer;
  State distinct_rotation_gray_buffer_backend;
  result = RecordForTesting(request, gates,
                            &distinct_rotation_gray_buffer_backend);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      distinct_rotation_gray_buffer_backend.calls == 0U,
                  41))
    return e;

  ImageResources cross_mode_alias = image;
  for (std::uint32_t rotation = 0; rotation < 4; ++rotation) {
    cross_mode_alias.geometric.bindings[12][rotation].image =
        cross_mode_alias.photometric.bindings[12][0].image;
    cross_mode_alias.geometric.bindings[14][rotation].image =
        cross_mode_alias.photometric.bindings[14][0].image;
  }
  request.images = &cross_mode_alias;
  result = RecordForTesting(request, gates, nullptr);
  if (int e = Req(result.status == RuntimeStatus::kVulkanFunctionUnavailable,
                  37))
    return e;

  DispatchPlan mixed_plan = CreateDispatchPlan(2);
  std::array<ImageResources, 2> mixed_images{};
  RecordRequest mixed_request = MakeRequest(&mixed_plan, &mixed_images[0]);
  mixed_images[1] = mixed_images[0];
  PopulateMode(&mixed_images[1].photometric, 50000U);
  PopulateMode(&mixed_images[1].geometric, 60000U);
  mixed_request.images = mixed_images.data();
  mixed_request.image_count = mixed_images.size();
  for (std::uint32_t rotation = 0; rotation < 4; ++rotation) {
    mixed_images[1].calibration[rotation].patch.width =
        (rotation & 1U) != 0U ? 24U : 32U;
    mixed_images[1].calibration[rotation].patch.height =
        (rotation & 1U) != 0U ? 32U : 24U;
    mixed_images[1].photometric.bindings[6][rotation].range =
        32U * 24U * 4U * 6U;
    mixed_images[1].geometric.bindings[6][rotation].range =
        32U * 24U * 4U * 6U;
    mixed_images[1].calibration[rotation].active_pose_table =
        Buf(70000U + rotation, 43U * 2U * 4U, 1,
            ResourceScalarType::kFloat32);
    mixed_images[1].calibration[rotation].pose_upload_staging =
        Buf(71000U + rotation, 43U * 2U * 4U, 1,
            ResourceScalarType::kFloat32);
    mixed_images[1].calibration[rotation].active_pose_table.content_identity =
        80000U + rotation;
    mixed_images[1].calibration[rotation].pose_upload_staging.content_identity =
        80000U + rotation;
  }
  mixed_images[1].photometric.bindings[0][0].range = 32U * 24U * 4U;
  mixed_images[1].consistency_graph_readback.mapped_mask_word_count =
      32U * 24U * kSources.size();
  std::array<SourceDepthLayerCopy, 2> mixed_target_layers = {{
      {1U, 0U, 32U, 24U},
      {0U, 1U, 64U, 48U},
  }};
  std::array<SourceDepthLayerCopy, 2> small_target_layers = {{
      {1U, 0U, 32U, 24U},
      {1U, 1U, 32U, 24U},
  }};
  mixed_images[0].source_depth_layers = mixed_target_layers.data();
  mixed_images[1].source_depth_layers = small_target_layers.data();
  result = RecordForTesting(mixed_request, gates, nullptr);
  if (int e = Req(result.status == RuntimeStatus::kVulkanFunctionUnavailable,
                  34))
    return e;

  std::array<SourceDepthLayerCopy, 2> oversized_layers = mixed_target_layers;
  oversized_layers[0].width = 65U;
  mixed_images[0].source_depth_layers = oversized_layers.data();
  State oversized_backend;
  result = RecordForTesting(mixed_request, gates, &oversized_backend);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      oversized_backend.calls == 0U,
                  35))
    return e;

  ImageResources bad = image;
  bad.geometric.bindings[14][0].sampler_metadata.min_filter =
      SamplerFilter::kNearest;
  request.images = &bad;
  State untouched;
  result = RecordForTesting(request, gates, &untouched);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      untouched.calls == 0,
                  15))
    return e;

  request = MakeRequest(&plan, &image);
  ImageResources layered_state = image;
  layered_state.photometric.bindings[6][2].array_layers = 2U;
  layered_state.photometric.bindings[6][2].range = 2U * kPlane;
  request.images = &layered_state;
  State layered_state_backend;
  result = RecordForTesting(request, gates, &layered_state_backend);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      layered_state_backend.calls == 0,
                  31))
    return e;

  request = MakeRequest(&plan, &image);
  ImageResources padded_state = image;
  padded_state.geometric.bindings[6][3].range = 6U * kPlane + 4U;
  request.images = &padded_state;
  State padded_state_backend;
  result = RecordForTesting(request, gates, &padded_state_backend);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      padded_state_backend.calls == 0,
                  32))
    return e;

  request = MakeRequest(&plan, &image);
  request.images = &image;
  request.window_radius = 6;
  State nondefault_window;
  result = RecordForTesting(request, gates, &nondefault_window);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      nondefault_window.calls == 0,
                  20))
    return e;

  request.window_radius = 5;
  ShaderBundle repeated_binary = request.shaders;
  repeated_binary.binaries[1].words = repeated_binary.binaries[0].words;
  request.shaders = repeated_binary;
  State untrusted_shader_hash;
  result = RecordForTesting(request, gates, &untrusted_shader_hash);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      untrusted_shader_hash.calls == 0,
                  21))
    return e;

  request = MakeRequest(&plan, &image);
  ImageResources bad_gray = image;
  ++bad_gray.photometric.source_gray_transfer_byte_count;
  request.images = &bad_gray;
  State gray_size_mismatch;
  result = RecordForTesting(request, gates, &gray_size_mismatch);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      gray_size_mismatch.calls == 0,
                  22))
    return e;

  ImageResources bad_gray_image = image;
  --bad_gray_image.photometric.source_gray_image_transfer_byte_count;
  request.images = &bad_gray_image;
  State gray_image_size_mismatch;
  result = RecordForTesting(request, gates, &gray_image_size_mismatch);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      gray_image_size_mismatch.calls == 0,
                  23))
    return e;

  ImageResources bad_depth_range = image;
  bad_depth_range.photometric.bindings[0][0].range = kPlane - 4U;
  request.images = &bad_depth_range;
  State depth_range_mismatch;
  result = RecordForTesting(request, gates, &depth_range_mismatch);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      depth_range_mismatch.calls == 0,
                  24))
    return e;

  ImageResources bad_depth_extent = image;
  std::array<SourceDepthLayerCopy, 2> bad_depth_layers = {{
      {0U, 0U, 63U, 48U},
      {0U, 1U, 64U, 48U},
  }};
  bad_depth_extent.source_depth_layers = bad_depth_layers.data();
  request.images = &bad_depth_extent;
  State depth_extent_mismatch;
  result = RecordForTesting(request, gates, &depth_extent_mismatch);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      depth_extent_mismatch.calls == 0,
                  25))
    return e;

  ImageResources bad_depth_destination = image;
  bad_depth_destination.geometric.bindings[12][0].range =
      2U * kPlane - 4U;
  request.images = &bad_depth_destination;
  State depth_destination_mismatch;
  result = RecordForTesting(request, gates, &depth_destination_mismatch);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      depth_destination_mismatch.calls == 0,
                  27))
    return e;

  ImageResources bad_depth_layer = image;
  std::array<SourceDepthLayerCopy, 2> bad_destination_layers = {{
      {0U, 0U, 64U, 48U},
      {0U, 2U, 64U, 48U},
  }};
  bad_depth_layer.source_depth_layers = bad_destination_layers.data();
  request.images = &bad_depth_layer;
  State depth_layer_mismatch;
  result = RecordForTesting(request, gates, &depth_layer_mismatch);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      depth_layer_mismatch.calls == 0,
                  28))
    return e;

  ImageResources overflow = image;
  for (auto &calibration : overflow.calibration) {
    calibration.patch.source_width = UINT32_MAX;
    calibration.patch.source_height = UINT32_MAX;
  }
  request.images = &overflow;
  State overflow_rejected;
  result = RecordForTesting(request, gates, &overflow_rejected);
  if (int e = Req(result.status == RuntimeStatus::kInvalidRequest &&
                      overflow_rejected.calls == 0,
                  26))
    return e;
  return 0;
}
