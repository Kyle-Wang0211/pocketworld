// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_HOST_VULKAN_HOST_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_HOST_VULKAN_HOST_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include "../include/official_dense/patch_match_abi.h"

namespace pocketworld::official_dense::vulkan {

// The public boundary deliberately contains no Vulkan SDK types. Apple and
// Harmony inject their loader without making this module link MoltenVK or a
// vendor loader. Android resolves the platform Vulkan loader directly.
struct ExternalLoader {
  void* get_instance_proc_addr = nullptr;
};

enum class HostStatus : std::uint8_t {
  kReady,
  kVulkanUnavailable,
  kExternalLoaderRequired,
  kInstanceCreationFailed,
  kNoPhysicalDevice,
  kNoComputeQueue,
  kInsufficientComputeInvocations,
  kInsufficientStorageBuffers,
  kInsufficientStorageImages,
  kInsufficientSampledImages,
  kRequiredFormatUnavailable,
  kRequiredFeatureUnavailable,
  kDeviceCreationFailed,
  kCommandBufferAllocationFailed,
};

struct CapabilityReport {
  HostStatus status = HostStatus::kVulkanUnavailable;
  std::string detail;
  std::uint32_t api_version = 0;
  std::uint32_t compute_queue_family = UINT32_MAX;
  std::uint32_t max_compute_work_group_invocations = 0;
  std::uint32_t max_per_stage_storage_buffers = 0;
  std::uint32_t max_per_stage_storage_images = 0;
  std::uint32_t max_per_stage_sampled_images = 0;

  [[nodiscard]] bool ready() const noexcept {
    return status == HostStatus::kReady;
  }
};

struct CreateOptions {
  ExternalLoader external_loader;
};

#if defined(PW_OFFICIAL_DENSE_VULKAN_TESTING)
struct AllocationLifetimeTestTrace {
  std::uint32_t unmap_order = 0;
  std::uint32_t destroy_buffer_order = 0;
  std::uint32_t free_memory_order = 0;
  std::uint32_t destroy_device_order = 0;
  std::uint32_t destroy_instance_order = 0;
};

struct ImageLifetimeTestTrace {
  std::uint32_t destroy_sampler_order = 0;
  std::uint32_t destroy_image_view_order = 0;
  std::uint32_t destroy_image_order = 0;
  std::uint32_t free_memory_order = 0;
  std::uint32_t destroy_device_order = 0;
  std::uint32_t destroy_instance_order = 0;
};

enum class SampledImageFailurePoint : std::uint8_t {
  kCreateImage,
  kInvalidMemoryRequirements,
  kMemoryTypeSelection,
  kAllocateMemory,
  kBindImageMemory,
  kCreateImageView,
  kCreateSampler,
  kRetainLifetime,
};

struct SampledImageFailureTestTrace {
  std::uint32_t create_image_calls = 0;
  std::uint32_t allocate_memory_calls = 0;
  std::uint32_t bind_image_memory_calls = 0;
  std::uint32_t create_image_view_calls = 0;
  std::uint32_t create_sampler_calls = 0;
  std::uint32_t destroy_sampler_calls = 0;
  std::uint32_t destroy_image_view_calls = 0;
  std::uint32_t destroy_image_calls = 0;
  std::uint32_t free_memory_calls = 0;
  std::uint32_t destroy_sampler_order = 0;
  std::uint32_t destroy_image_view_order = 0;
  std::uint32_t destroy_image_order = 0;
  std::uint32_t free_memory_order = 0;
  std::uint32_t sentinel_release_calls = 0;
  bool output_unchanged = false;
  bool detail_nonempty = false;
};
#endif

// SDK-independent handle bundle consumed by the Vulkan runtime adapter. These
// are opaque Vulkan handle bits; callers must not destroy them.
struct NativeHandles {
  std::uint64_t instance = 0;
  std::uint64_t device = 0;
  std::uint64_t queue = 0;
  std::uint64_t command_buffer = 0;

  [[nodiscard]] bool valid() const noexcept {
    return instance != 0 && device != 0 && queue != 0 && command_buffer != 0;
  }
};

// SDK-independent buffer contract. Numeric values deliberately do not mirror
// Vulkan so this boundary remains usable by C++ callers that do not include an
// SDK header.
inline constexpr std::uint32_t kBufferUsageStorage = 1U << 0U;
inline constexpr std::uint32_t kBufferUsageTransferSrc = 1U << 1U;
inline constexpr std::uint32_t kBufferUsageTransferDst = 1U << 2U;
inline constexpr std::uint32_t kKnownBufferUsageFlags =
    kBufferUsageStorage | kBufferUsageTransferSrc | kBufferUsageTransferDst;

inline constexpr std::uint32_t kMemoryPropertyDeviceLocal = 1U << 0U;
inline constexpr std::uint32_t kMemoryPropertyHostVisible = 1U << 1U;
inline constexpr std::uint32_t kMemoryPropertyHostCoherent = 1U << 2U;
inline constexpr std::uint32_t kMemoryPropertyHostCached = 1U << 3U;

enum class BufferMemoryClass : std::uint8_t {
  kDeviceLocal,
  kHostUpload,
  kHostReadback,
};

struct BufferAllocationSpec {
  std::uint64_t byte_count = 0;
  std::uint32_t usage_flags = 0;
  BufferMemoryClass memory_class = BufferMemoryClass::kDeviceLocal;
};

struct MemoryTypeInfo {
  std::uint32_t property_flags = 0;
};

struct MemoryTypeTable {
  std::uint32_t count = 0;
  std::array<MemoryTypeInfo, 32> types{};
};

struct MemoryTypeSelection {
  std::uint32_t index = UINT32_MAX;
  bool host_coherent = false;
};

// Pure deterministic selector used both by the Vulkan host and strict tests.
// The output is not modified when no compatible type exists.
[[nodiscard]] bool SelectMemoryType(
    std::uint32_t compatible_type_bits,
    const MemoryTypeTable& table,
    BufferMemoryClass memory_class,
    MemoryTypeSelection* out) noexcept;

using ReleaseBufferAllocation = void (*)(
    std::uint64_t buffer_handle,
    std::uint64_t memory_handle,
    void* mapped_pointer,
    void* context) noexcept;

class BufferAllocation final {
 public:
  BufferAllocation() noexcept = default;
  BufferAllocation(const BufferAllocation&) = delete;
  BufferAllocation& operator=(const BufferAllocation&) = delete;
  BufferAllocation(BufferAllocation&& other) noexcept;
  BufferAllocation& operator=(BufferAllocation&& other) noexcept;
  ~BufferAllocation();

  [[nodiscard]] bool valid() const noexcept {
    return buffer_handle_ != 0 && memory_handle_ != 0;
  }
  [[nodiscard]] std::uint64_t opaque_buffer_handle() const noexcept {
    return buffer_handle_;
  }
  [[nodiscard]] std::uint64_t opaque_memory_handle() const noexcept {
    return memory_handle_;
  }
  [[nodiscard]] std::uint64_t byte_count() const noexcept {
    return byte_count_;
  }
  [[nodiscard]] void* mapped_pointer() const noexcept {
    return mapped_pointer_;
  }
  [[nodiscard]] bool host_coherent() const noexcept {
    return host_coherent_;
  }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t buffer_handle_ = 0;
  std::uint64_t memory_handle_ = 0;
  std::uint64_t byte_count_ = 0;
  void* mapped_pointer_ = nullptr;
  bool host_coherent_ = false;
  void* context_ = nullptr;
  ReleaseBufferAllocation release_ = nullptr;
};

// The image boundary exposes only the two formats and two sampling contracts
// consumed by the frozen PatchMatch descriptor ABI. Images are always optimal-
// tiled 2D arrays with TRANSFER_DST|SAMPLED usage and device-local memory.
enum class SampledImageFormat : std::uint8_t {
  kR8Unorm,
  kR32Sfloat,
};

enum class ImageSamplerKind : std::uint8_t {
  kGrayLinear,
  kDepthNearest,
};

struct SampledImageSpec {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t array_layers = 0;
  SampledImageFormat format = SampledImageFormat::kR8Unorm;
  ImageSamplerKind sampler = ImageSamplerKind::kGrayLinear;
};

using ReleaseSampledImageAllocation = void (*)(
    std::uint64_t image_handle,
    std::uint64_t memory_handle,
    std::uint64_t image_view_handle,
    std::uint64_t sampler_handle,
    void* context) noexcept;

class SampledImageAllocation final {
 public:
  SampledImageAllocation() noexcept = default;
  SampledImageAllocation(const SampledImageAllocation&) = delete;
  SampledImageAllocation& operator=(const SampledImageAllocation&) = delete;
  SampledImageAllocation(SampledImageAllocation&& other) noexcept;
  SampledImageAllocation& operator=(SampledImageAllocation&& other) noexcept;
  ~SampledImageAllocation();

  [[nodiscard]] bool valid() const noexcept {
    return image_handle_ != 0 && memory_handle_ != 0 &&
           image_view_handle_ != 0 && sampler_handle_ != 0;
  }
  [[nodiscard]] std::uint64_t opaque_image_handle() const noexcept {
    return image_handle_;
  }
  [[nodiscard]] std::uint64_t opaque_memory_handle() const noexcept {
    return memory_handle_;
  }
  [[nodiscard]] std::uint64_t opaque_image_view_handle() const noexcept {
    return image_view_handle_;
  }
  [[nodiscard]] std::uint64_t opaque_sampler_handle() const noexcept {
    return sampler_handle_;
  }
  [[nodiscard]] std::uint32_t width() const noexcept { return width_; }
  [[nodiscard]] std::uint32_t height() const noexcept { return height_; }
  [[nodiscard]] std::uint32_t array_layers() const noexcept {
    return array_layers_;
  }
  [[nodiscard]] SampledImageFormat format() const noexcept { return format_; }
  [[nodiscard]] ImageSamplerKind sampler_kind() const noexcept {
    return sampler_kind_;
  }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t image_handle_ = 0;
  std::uint64_t memory_handle_ = 0;
  std::uint64_t image_view_handle_ = 0;
  std::uint64_t sampler_handle_ = 0;
  std::uint32_t width_ = 0;
  std::uint32_t height_ = 0;
  std::uint32_t array_layers_ = 0;
  SampledImageFormat format_ = SampledImageFormat::kR8Unorm;
  ImageSamplerKind sampler_kind_ = ImageSamplerKind::kGrayLinear;
  void* context_ = nullptr;
  ReleaseSampledImageAllocation release_ = nullptr;
};

using ReleaseHandle = void (*)(std::uint64_t parent,
                               std::uint64_t handle,
                               void* context) noexcept;

class Instance final {
 public:
  Instance() noexcept = default;
  Instance(const Instance&) = delete;
  Instance& operator=(const Instance&) = delete;
  Instance(Instance&& other) noexcept;
  Instance& operator=(Instance&& other) noexcept;
  ~Instance();

  [[nodiscard]] bool valid() const noexcept { return handle_ != 0; }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t parent_ = 0;
  std::uint64_t handle_ = 0;
  void* context_ = nullptr;
  ReleaseHandle release_ = nullptr;
};

class Device final {
 public:
  Device() noexcept = default;
  Device(const Device&) = delete;
  Device& operator=(const Device&) = delete;
  Device(Device&& other) noexcept;
  Device& operator=(Device&& other) noexcept;
  ~Device();

  [[nodiscard]] bool valid() const noexcept { return handle_ != 0; }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t parent_ = 0;
  std::uint64_t handle_ = 0;
  void* context_ = nullptr;
  ReleaseHandle release_ = nullptr;
};

class Buffer final {
 public:
  Buffer() noexcept = default;
  Buffer(const Buffer&) = delete;
  Buffer& operator=(const Buffer&) = delete;
  Buffer(Buffer&& other) noexcept;
  Buffer& operator=(Buffer&& other) noexcept;
  ~Buffer();

  [[nodiscard]] bool valid() const noexcept { return handle_ != 0; }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t parent_ = 0;
  std::uint64_t handle_ = 0;
  void* context_ = nullptr;
  ReleaseHandle release_ = nullptr;
};

class DescriptorSet final {
 public:
  DescriptorSet() noexcept = default;
  DescriptorSet(const DescriptorSet&) = delete;
  DescriptorSet& operator=(const DescriptorSet&) = delete;
  DescriptorSet(DescriptorSet&& other) noexcept;
  DescriptorSet& operator=(DescriptorSet&& other) noexcept;
  ~DescriptorSet();

  [[nodiscard]] bool valid() const noexcept { return handle_ != 0; }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t parent_ = 0;
  std::uint64_t handle_ = 0;
  void* context_ = nullptr;
  ReleaseHandle release_ = nullptr;
};

class ComputePipeline final {
 public:
  ComputePipeline() noexcept = default;
  ComputePipeline(const ComputePipeline&) = delete;
  ComputePipeline& operator=(const ComputePipeline&) = delete;
  ComputePipeline(ComputePipeline&& other) noexcept;
  ComputePipeline& operator=(ComputePipeline&& other) noexcept;
  ~ComputePipeline();

  [[nodiscard]] bool valid() const noexcept { return handle_ != 0; }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t parent_ = 0;
  std::uint64_t handle_ = 0;
  void* context_ = nullptr;
  ReleaseHandle release_ = nullptr;
};

class CommandPool final {
 public:
  CommandPool() noexcept = default;
  CommandPool(const CommandPool&) = delete;
  CommandPool& operator=(const CommandPool&) = delete;
  CommandPool(CommandPool&& other) noexcept;
  CommandPool& operator=(CommandPool&& other) noexcept;
  ~CommandPool();

  [[nodiscard]] bool valid() const noexcept { return handle_ != 0; }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t parent_ = 0;
  std::uint64_t handle_ = 0;
  void* context_ = nullptr;
  ReleaseHandle release_ = nullptr;
};

class CommandBuffer final {
 public:
  CommandBuffer() noexcept = default;
  CommandBuffer(const CommandBuffer&) = delete;
  CommandBuffer& operator=(const CommandBuffer&) = delete;
  CommandBuffer(CommandBuffer&& other) noexcept;
  CommandBuffer& operator=(CommandBuffer&& other) noexcept;
  ~CommandBuffer();

  [[nodiscard]] bool valid() const noexcept { return handle_ != 0; }
  void Reset() noexcept;

 private:
  friend class VulkanHost;
  std::uint64_t parent_ = 0;
  std::uint64_t handle_ = 0;
  void* context_ = nullptr;
  ReleaseHandle release_ = nullptr;
};

class Queue final {
 public:
  Queue() noexcept = default;
  Queue(const Queue&) = delete;
  Queue& operator=(const Queue&) = delete;
  Queue(Queue&&) noexcept = default;
  Queue& operator=(Queue&&) noexcept = default;
  ~Queue() = default;

  [[nodiscard]] bool valid() const noexcept { return handle_ != 0; }

 private:
  friend class VulkanHost;
  std::uint64_t handle_ = 0;  // VkQueue is device-owned.
};

class VulkanHost final {
 public:
  VulkanHost(const VulkanHost&) = delete;
  VulkanHost& operator=(const VulkanHost&) = delete;
  VulkanHost(VulkanHost&&) noexcept;
  VulkanHost& operator=(VulkanHost&&) noexcept;
  ~VulkanHost();

  [[nodiscard]] static CapabilityReport Probe(
      const CreateOptions& options) noexcept;
  [[nodiscard]] static std::unique_ptr<VulkanHost> Create(
      const CreateOptions& options,
      CapabilityReport* report) noexcept;

  [[nodiscard]] const CapabilityReport& capabilities() const noexcept;
  [[nodiscard]] const Queue& compute_queue() const noexcept;
  [[nodiscard]] const CommandPool& command_pool() const noexcept;
  [[nodiscard]] const CommandBuffer& command_buffer() const noexcept;
  [[nodiscard]] NativeHandles native_handles() const noexcept;
  [[nodiscard]] bool CreateBufferAllocation(
      const BufferAllocationSpec& spec,
      BufferAllocation* out,
      std::string* detail) noexcept;
  [[nodiscard]] bool CreateSampledImageAllocation(
      const SampledImageSpec& spec,
      SampledImageAllocation* out,
      std::string* detail) noexcept;
#if defined(PW_OFFICIAL_DENSE_VULKAN_TESTING)
  [[nodiscard]] static bool TestDetailAssignmentFailureIsContained() noexcept;
  [[nodiscard]] static bool TestAllocationOutlivesHost(
      AllocationLifetimeTestTrace* trace) noexcept;
  [[nodiscard]] static bool TestImageOutlivesHost(
      ImageLifetimeTestTrace* trace) noexcept;
  [[nodiscard]] static std::unique_ptr<VulkanHost>
  CreateSampledImageFailureTestHost(
      SampledImageFailurePoint failure_point,
      SampledImageFailureTestTrace* trace) noexcept;
  [[nodiscard]] static bool TestSampledImageFailureUnwind(
      SampledImageFailurePoint failure_point,
      SampledImageFailureTestTrace* trace) noexcept;
#endif

 private:
  struct Impl;
  explicit VulkanHost(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
};

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_HOST_VULKAN_HOST_H_
