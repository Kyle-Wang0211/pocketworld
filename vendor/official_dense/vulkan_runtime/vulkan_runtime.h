// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_RUNTIME_VULKAN_RUNTIME_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_RUNTIME_VULKAN_RUNTIME_H_

#include <array>
#include <cstddef>
#include <cstdint>

#include "../include/official_dense/patch_match_abi.h"
#include "../vulkan_host/dispatch_plan.h"

namespace pocketworld::official_dense::vulkan::runtime {

inline constexpr char kUpstreamCommit[] =
    "a0d785fba74b2664f31edc4a29026a8b27c00f67";
inline constexpr std::size_t kShaderCount = 11;
inline constexpr std::uint32_t kSweepRowTileHeight = 8U;
// A partition remains one exact shader dispatch. Only the queue-submit
// boundary is batched: barriers preserve the recurrence dependency between
// adjacent partitions, while this bound keeps each mobile command buffer well
// below the watchdog-sized command streams used by the original diagnostic.
inline constexpr std::uint64_t kPartitionDispatchesPerSubmit = 256U;

[[nodiscard]] constexpr std::size_t AdditionalPartitionSubmitCount(
    const std::uint64_t physical_partition_count) noexcept {
  return physical_partition_count == 0U
      ? 0U
      : static_cast<std::size_t>(
            (physical_partition_count - 1U) /
            kPartitionDispatchesPerSubmit);
}

// One pipeline module per existing shader used by the recorder. The order is
// frozen because build tooling supplies a fixed-size binary bundle.
enum class PipelineKind : std::uint8_t {
  kReferenceFilter = 0,
  kOpenMvsPcgInitialize = 1,
  kNormalInitialize = 2,
  kInitialCost = 3,
  kFullSweep = 4,
  kRotateF32 = 5,
  kTransposeF32 = 6,
  kFlipHorizontalF32 = 7,
  kRotateNormalF32 = 8,
  kOpenMvsPcgDepthInitialize = 9,
  kRotateU32 = 10,
};

enum class PartitionBoundary : std::uint8_t {
  kNone,
  kBarrier,
  kSubmitWait,
};

struct PartitionDispatch {
  bool valid = false;
  std::uint32_t base_group_x = 0U;
  std::uint32_t row_begin = 0U;
  std::uint32_t row_end = 0U;
  bool backward = false;
  PartitionBoundary boundary_after = PartitionBoundary::kNone;
};

[[nodiscard]] constexpr std::uint64_t PhysicalPartitionCount(
    const PipelineKind kind, const std::uint32_t height,
    const std::uint32_t group_count_x) noexcept {
  if (height == 0U || group_count_x == 0U ||
      (kind != PipelineKind::kInitialCost &&
       kind != PipelineKind::kFullSweep)) {
    return 0U;
  }
  const std::uint64_t tile_count =
      (static_cast<std::uint64_t>(height) + kSweepRowTileHeight - 1U) /
      kSweepRowTileHeight;
  const std::uint64_t phase_count =
      kind == PipelineKind::kFullSweep ? 2U : 1U;
  return phase_count * tile_count * group_count_x;
}

// Counts only the queue boundaries introduced inside the partitioned native
// path. Full sweep owns one pre-sweep boundary in addition to the periodic
// batch boundaries; initial cost has no pre-dispatch boundary.
[[nodiscard]] constexpr std::size_t PartitionInternalSubmitCount(
    const PipelineKind kind, const std::uint32_t height,
    const std::uint32_t group_count_x) noexcept {
  const std::uint64_t physical_count =
      PhysicalPartitionCount(kind, height, group_count_x);
  if (physical_count < 2U)
    return 0U;
  return AdditionalPartitionSubmitCount(physical_count) +
         (kind == PipelineKind::kFullSweep ? 1U : 0U);
}

// Exact queue-submit budget for one frozen COLMAP PatchMatch reference at the
// official whole-image launch granularity. This includes the upstream
// synchronization points and final readback submit; it does not estimate GPU
// execution time.
[[nodiscard]] constexpr std::size_t FrozenReferenceQueueSubmitCount(
    const std::uint32_t width, const std::uint32_t height,
    const PlanPhase phase) noexcept {
  if (width == 0U || height == 0U)
    return 0U;
  // Each mode has two upstream initialization synchronizations and one after
  // each of its 20 sweeps. A split phase then owns one final readback submit.
  constexpr std::size_t kUpstreamSubmitsPerMode = 2U + 20U;
  if (phase == PlanPhase::kPhotometricOnly ||
      phase == PlanPhase::kGeometricOnly) {
    return kUpstreamSubmitsPerMode + 1U;
  }
  // The unsplit full plan adds the official wait between photometric and
  // geometric modes, then shares one final readback submit.
  return 2U * kUpstreamSubmitsPerMode + 2U;
}

// Produces the exact dispatch order used by the native implementation. The
// full sweep keeps COLMAP's backward pass followed by its forward pass for
// every x group; initial cost visits the same row tiles forward once.
[[nodiscard]] constexpr PartitionDispatch PartitionDispatchAt(
    const PipelineKind kind, const std::uint32_t height,
    const std::uint32_t group_count_x,
    const std::uint64_t partition_index) noexcept {
  PartitionDispatch dispatch;
  const std::uint64_t physical_count =
      PhysicalPartitionCount(kind, height, group_count_x);
  if (partition_index >= physical_count)
    return dispatch;

  const std::uint64_t tile_count =
      (static_cast<std::uint64_t>(height) + kSweepRowTileHeight - 1U) /
      kSweepRowTileHeight;
  const std::uint64_t partitions_per_group =
      tile_count * (kind == PipelineKind::kFullSweep ? 2U : 1U);
  const std::uint64_t local_index = partition_index % partitions_per_group;
  dispatch.valid = true;
  dispatch.base_group_x =
      static_cast<std::uint32_t>(partition_index / partitions_per_group);

  if (kind == PipelineKind::kFullSweep && local_index < tile_count) {
    dispatch.backward = true;
    const std::uint64_t consumed_rows =
        local_index * static_cast<std::uint64_t>(kSweepRowTileHeight);
    dispatch.row_end =
        static_cast<std::uint32_t>(static_cast<std::uint64_t>(height) -
                                   consumed_rows);
    dispatch.row_begin =
        dispatch.row_end > kSweepRowTileHeight
            ? dispatch.row_end - kSweepRowTileHeight
            : 0U;
  } else {
    const std::uint64_t forward_index =
        kind == PipelineKind::kFullSweep ? local_index - tile_count
                                         : local_index;
    dispatch.row_begin = static_cast<std::uint32_t>(
        forward_index * static_cast<std::uint64_t>(kSweepRowTileHeight));
    const std::uint64_t proposed_end =
        static_cast<std::uint64_t>(dispatch.row_begin) +
        kSweepRowTileHeight;
    dispatch.row_end = proposed_end < height
                           ? static_cast<std::uint32_t>(proposed_end)
                           : height;
  }

  const std::uint64_t completed_count = partition_index + 1U;
  if (completed_count < physical_count) {
    dispatch.boundary_after =
        completed_count % kPartitionDispatchesPerSubmit == 0U
            ? PartitionBoundary::kSubmitWait
            : PartitionBoundary::kBarrier;
  }
  return dispatch;
}

struct ShaderManifestEntry {
  PipelineKind kind;
  const char *source_path;
  const char *source_sha256;
  // Null means that no runnable canonical binary exists for this pipeline.
  // The runtime must remain fail-closed until a reviewed binary is pinned.
  const char *spirv_sha256;
};

[[nodiscard]] const std::array<ShaderManifestEntry, kShaderCount> &
CanonicalShaderManifest() noexcept;

struct ShaderBinary {
  PipelineKind kind = PipelineKind::kReferenceFilter;
  const std::uint32_t *words = nullptr;
  std::size_t word_count = 0;
  // Source identity remains part of the caller/build interface, but the
  // expected SPIR-V digest is compiled into CanonicalShaderManifest(). The
  // caller is never trusted to declare the digest of its own bytes.
  const char *source_sha256 = nullptr;
};

struct ShaderBundle {
  std::array<ShaderBinary, kShaderCount> binaries{};
};

enum class ResourceScalarType : std::uint8_t { kFloat32, kUint32 };
enum class SamplerFormat : std::uint8_t { kUndefined, kR8Unorm, kR32Sfloat };
enum class SamplerFilter : std::uint8_t { kUndefined, kNearest, kLinear };
enum class SamplerAddressMode : std::uint8_t {
  kUndefined,
  kClampToBorder,
};
enum class SamplerBorderColor : std::uint8_t {
  kUndefined,
  kFloatTransparentBlack,
};

struct SamplerMetadata {
  SamplerFormat format = SamplerFormat::kUndefined;
  SamplerFilter min_filter = SamplerFilter::kUndefined;
  SamplerFilter mag_filter = SamplerFilter::kUndefined;
  SamplerAddressMode address_u = SamplerAddressMode::kUndefined;
  SamplerAddressMode address_v = SamplerAddressMode::kUndefined;
  SamplerBorderColor border_color = SamplerBorderColor::kUndefined;
  bool normalized_coordinates = false;
};

// Public handles stay SDK-independent. The native implementation converts
// these values to Vulkan non-dispatchable/dispatchable handles internally.
struct BoundResource {
  std::uint64_t buffer = 0;
  std::uint64_t offset = 0;
  std::uint64_t range = 0;
  std::uint64_t image_view = 0;
  std::uint64_t image = 0;
  std::uint64_t sampler = 0;
  std::uint32_t array_layers = 1;
  std::uint32_t element_size = 4;
  ResourceScalarType scalar_type = ResourceScalarType::kFloat32;
  SamplerMetadata sampler_metadata;
  // Identity of the bytes from which both the storage-buffer and sampled-image
  // representations were made. Zero is invalid for uploaded inputs.
  std::uint64_t content_identity = 0;
};

struct SourceDepthLayerCopy {
  std::uint32_t source_image_slot = UINT32_MAX;
  std::uint32_t destination_layer = UINT32_MAX;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
};

struct ModeResources {
  std::array<std::array<BoundResource, 4>, kBindingCount> bindings{};
  BoundResource reference_upload_staging;
  BoundResource reference_depth_upload_staging;
  BoundResource reference_normal_upload_staging;
  BoundResource source_depth_upload_staging;
  BoundResource source_gray_upload_staging;
  BoundResource source_gray_image_upload_staging;
  BoundResource depth_readback;
  BoundResource normal_readback;
  BoundResource mask_readback;
  std::uint64_t reference_transfer_byte_count = 0;
  std::uint64_t reference_depth_transfer_byte_count = 0;
  std::uint64_t reference_normal_transfer_byte_count = 0;
  std::uint64_t source_depth_transfer_byte_count = 0;
  std::uint64_t source_gray_transfer_byte_count = 0;
  std::uint64_t source_gray_image_transfer_byte_count = 0;
};

struct RotationCalibration {
  PatchPC patch{};
  // [BATCH-REF 2026-08-30] 逐 reference 的 PatchPC(本 rotation 的那一份)。
  // 为什么需要:按 reference 逐次 dispatch 的 kernel 里,
  //   init_depth_openmvs_pcg.comp  用 pc.depth_min / pc.depth_max
  //   init_normal_openmvs_pcg.comp 用 pc.ref_inv_*
  // 而实测 132 帧的内参与深度范围**逐帧都不同**,共用一份 push constant
  // 会让 reference 1..N-1 全都拿 reference 0 的参数。
  // (shader 内批处理的 sweep / compute_initial_cost 不走这里,它们按
  //  RefIndex() 从位姿表尾部取。)
  // 长度 = batch_count;batch_count == 1 时与 patch 等价。
  const PatchPC *reference_patches = nullptr;
  std::size_t reference_patch_count = 0;
  BoundResource active_pose_table;
  BoundResource pose_upload_staging;
};

struct CameraCalibrationInput {
  std::array<float, 9> K{};
  std::array<float, 9> R{};
  std::array<float, 3> T{};
};

struct CalibrationBuildInput {
  PatchPC base_patch{};
  CameraCalibrationInput reference;
  const CameraCalibrationInput *sources = nullptr;
  std::size_t source_count = 0;
};

// Mechanical host translation of PatchMatchCuda::InitTransforms. pose_values
// must hold 4 * source_count * kPoseFloatCount floats, rotation-major.
[[nodiscard]] bool BuildRotationCalibrationHost(
    const CalibrationBuildInput &input,
    std::array<PatchPC, 4> *patches,
    float *pose_values,
    std::size_t pose_value_capacity) noexcept;

struct ConsistencyGraphLayout {
  const std::int32_t *source_image_indices = nullptr;
  std::size_t source_image_count = 0;
};

// The mask staging buffer must be host-coherent and remain mapped until
// Record() returns. Capacity is the official worst-case encoding size:
// width * height * (3 + num_sources) int32 values. This is deliberately a
// caller-owned view; the runtime does not invent an allocator or a graph
// format.
struct ConsistencyGraphReadback {
  const std::uint32_t *mapped_mask_words = nullptr;
  std::size_t mapped_mask_word_count = 0;
  std::int32_t *values = nullptr;
  std::size_t value_capacity = 0;
  // [BATCH-REF 2026-08-31] 指向 batch_count 个计数(每 reference 一个)。
  // 每个 reference 的图写在 values + r * (value_capacity / batch_count),
  // 各自独立、互不追加,这样导出时按 r 取片即可。
  // batch_count == 1 时与原来完全一致(一个指针指向一个 size_t)。
  std::size_t *value_count = nullptr;
  bool host_coherent = false;
};

struct ImageResources {
  ModeResources photometric;
  ModeResources geometric;
  std::array<RotationCalibration, 4> calibration{};
  ConsistencyGraphLayout consistency_graph;
  ConsistencyGraphReadback consistency_graph_readback;
  const SourceDepthLayerCopy *source_depth_layers = nullptr;
  std::size_t source_depth_layer_count = 0;
};

struct ConsistencyGraphInput {
  const std::uint32_t *mask_words = nullptr;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t depth = 0;
  const std::int32_t *source_image_indices = nullptr;
  std::size_t source_image_count = 0;
};

[[nodiscard]] std::size_t
RequiredConsistencyGraphValueCount(const ConsistencyGraphInput &input) noexcept;
[[nodiscard]] bool SerializeConsistencyGraph(const ConsistencyGraphInput &input,
                                             std::int32_t *output,
                                             std::size_t output_count) noexcept;
[[nodiscard]] std::uint32_t
OfficialNccNormalizationBits(float ncc_sigma) noexcept;

struct NativeContext {
  std::uint64_t instance = 0;
  std::uint64_t device = 0;
  std::uint64_t command_buffer = 0;
  std::uint64_t queue = 0;

  // Android uses the system vkGetInstanceProcAddr when this is null. Apple
  // and Harmony must inject vkGetInstanceProcAddr; there is no Swift bridge.
  void *get_instance_proc_addr = nullptr;
};

struct RecordRequest {
  const DispatchPlan *plan = nullptr;
  NativeContext native;
  ShaderBundle shaders;
  const ImageResources *images = nullptr;
  std::size_t image_count = 0;
  std::int32_t window_radius = 5;
  std::int32_t window_step = 1;
  // [BATCH-REF] 一次 sweep dispatch 覆盖的 reference 数(grid.y)。
  // 1 = 官方逐 reference 行为。
  std::uint32_t batch_count = 1;
};

enum class RuntimeStatus : std::uint8_t {
  kRecorded,
  kInvalidPlan,
  kInvalidRequest,
  kPcgAdaptationNotCertified,
  kTextureParityNotCertified,
  kFullSweepNotCertified,
  kExternalLoaderRequired,
  kVulkanFunctionUnavailable,
  kVulkanError,
};

struct RecordResult {
  RuntimeStatus status = RuntimeStatus::kInvalidRequest;
  const char *detail = "invalid request";
  std::size_t recorded_plan_steps = 0;
  std::size_t dispatch_count = 0;
  std::size_t barrier_count = 0;
  // Physical queue boundaries inserted only to keep an otherwise identical
  // full-sweep dispatch below mobile GPU watchdog limits. Logical dispatch
  // counts and shader work remain unchanged.
  std::size_t partition_submit_count = 0;
  // Total successful queue submits, including partition boundaries, official
  // synchronization points, and the final readback submission.
  std::size_t queue_submit_count = 0;
  std::size_t consistency_graph_value_count = 0;

  [[nodiscard]] bool recorded() const noexcept {
    return status == RuntimeStatus::kRecorded;
  }
};

[[nodiscard]] RecordResult Record(const RecordRequest &request) noexcept;

#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)

// Benchmark-only native execution seam. This symbol is compiled only into an
// explicitly opted-in diagnostic build and is never installed as a certified
// production API. It executes the frozen resource/dispatch contracts while
// truthfully reporting that the three production certifications are bypassed.
[[nodiscard]] RecordResult
RecordNativeForDiagnostic(const RecordRequest &request) noexcept;

#endif

#if defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)

// Test-only seam. It cannot be compiled into production by accident because
// both the certification override and fake backend API are macro-gated.
struct TestCertifications {
  bool pcg = false;
  bool texture = false;
  bool full_sweep = false;
};

struct DescriptorWrite {
  std::uint32_t shader_binding = 0;
  bool combined_image_sampler = false;
  BoundResource resource;
};

class FakeDispatchBackend {
public:
  virtual ~FakeDispatchBackend() = default;
  virtual bool CreatePipeline(PipelineKind kind,
                              const ShaderBinary &binary) noexcept = 0;
  virtual bool Begin() noexcept = 0;
  virtual bool
  AllocateAndBindDescriptorSet(PipelineKind kind, const DescriptorWrite *writes,
                               std::size_t write_count) noexcept = 0;
  virtual bool
  BindAndDispatch(PipelineKind kind, std::uint32_t specialization_mask,
                  const void *push_constants, std::size_t push_constant_size,
                  std::uint32_t group_count_x, std::uint32_t group_count_y,
                  std::uint32_t group_count_z) noexcept = 0;
  virtual bool BindAndDispatchPartitioned(
      PipelineKind kind, std::uint32_t specialization_mask,
      const void *push_constants, std::size_t push_constant_size,
      std::uint32_t group_count_x, std::uint32_t group_count_y,
      std::uint32_t group_count_z) noexcept = 0;
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
  virtual bool SubmitWaitAndContinue() noexcept { return false; }
  virtual bool EndSubmitAndWait() noexcept = 0;
};

[[nodiscard]] RecordResult
RecordForTesting(const RecordRequest &request,
                 const TestCertifications &certifications,
                 FakeDispatchBackend *backend) noexcept;

#endif

} // namespace pocketworld::official_dense::vulkan::runtime

#endif // POCKETWORLD_OFFICIAL_DENSE_VULKAN_RUNTIME_VULKAN_RUNTIME_H_
