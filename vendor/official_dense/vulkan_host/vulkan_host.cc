// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "vulkan_host.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <new>
#include <type_traits>
#include <utility>
#include <vector>

#if !defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
#include <vulkan/vulkan.h>
#endif

namespace pocketworld::official_dense::vulkan {
namespace {

static_assert(kBindingCount == 15);
static_assert(sizeof(PatchPC) == 128);
static_assert(noexcept(std::declval<std::string&>().clear()));

template <typename DetailSink>
void SetDetailSinkNoexcept(DetailSink* const detail,
                           const char* const message) noexcept {
  if (detail == nullptr) return;
  try {
    detail->assign(message);
  } catch (...) {
    // Diagnostic text must never turn a fail-closed allocation into terminate.
  }
}

void SetDetailNoexcept(std::string* const detail,
                       const char* const message) noexcept {
  SetDetailSinkNoexcept(detail, message);
}

#if !defined(PW_OFFICIAL_DENSE_VULKAN_STUB)

inline constexpr std::uint32_t kRequiredMaxComputeInvocations = 128;
inline constexpr std::uint32_t kRequiredMaxComputeSizeX = 32;
inline constexpr std::uint32_t kRequiredMaxComputeSizeY = 8;
inline constexpr std::uint32_t kRequiredMaxComputeSizeZ = 1;
inline constexpr std::uint32_t kRequiredSampledImages = 2;
inline constexpr std::uint32_t kRequiredStorageBuffers = kBindingCount;

using GetInstanceProcAddr = PFN_vkGetInstanceProcAddr;

GetInstanceProcAddr ResolveLoader(const CreateOptions& options,
                                  HostStatus* failure) noexcept {
#if defined(__ANDROID__)
  (void)options;
  (void)failure;
  return &vkGetInstanceProcAddr;
#elif defined(__APPLE__) || defined(PW_OFFICIAL_DENSE_HARMONY)
  if (options.external_loader.get_instance_proc_addr == nullptr) {
    *failure = HostStatus::kExternalLoaderRequired;
    return nullptr;
  }
  return reinterpret_cast<GetInstanceProcAddr>(
      options.external_loader.get_instance_proc_addr);
#else
  // Desktop probing is intentionally disabled unless a loader is explicitly
  // supplied. A development machine must never masquerade as mobile support.
  if (options.external_loader.get_instance_proc_addr == nullptr) {
    *failure = HostStatus::kVulkanUnavailable;
    return nullptr;
  }
  return reinterpret_cast<GetInstanceProcAddr>(
      options.external_loader.get_instance_proc_addr);
#endif
}

template <typename T>
T LoadGlobal(GetInstanceProcAddr get_proc, const char* name) noexcept {
  return reinterpret_cast<T>(get_proc(VK_NULL_HANDLE, name));
}

template <typename T>
T LoadInstance(GetInstanceProcAddr get_proc,
               VkInstance instance,
               const char* name) noexcept {
  return reinterpret_cast<T>(get_proc(instance, name));
}

struct InstanceDispatch {
  GetInstanceProcAddr get_instance_proc_addr = nullptr;
  PFN_vkDestroyInstance destroy_instance = nullptr;
  PFN_vkEnumeratePhysicalDevices enumerate_physical_devices = nullptr;
  PFN_vkGetPhysicalDeviceProperties get_physical_device_properties = nullptr;
  PFN_vkGetPhysicalDeviceFeatures get_physical_device_features = nullptr;
  PFN_vkGetPhysicalDeviceMemoryProperties
      get_physical_device_memory_properties = nullptr;
  PFN_vkGetPhysicalDeviceQueueFamilyProperties
      get_physical_device_queue_family_properties = nullptr;
  PFN_vkGetPhysicalDeviceFormatProperties get_physical_device_format_properties =
      nullptr;
  PFN_vkEnumerateDeviceExtensionProperties
      enumerate_device_extension_properties = nullptr;
  PFN_vkCreateDevice create_device = nullptr;
  PFN_vkGetDeviceProcAddr get_device_proc_addr = nullptr;
};

struct DeviceDispatch {
  PFN_vkDestroyDevice destroy_device = nullptr;
  PFN_vkGetDeviceQueue get_device_queue = nullptr;
  PFN_vkCreateCommandPool create_command_pool = nullptr;
  PFN_vkDestroyCommandPool destroy_command_pool = nullptr;
  PFN_vkAllocateCommandBuffers allocate_command_buffers = nullptr;
  PFN_vkFreeCommandBuffers free_command_buffers = nullptr;
  PFN_vkCreateBuffer create_buffer = nullptr;
  PFN_vkDestroyBuffer destroy_buffer = nullptr;
  PFN_vkGetBufferMemoryRequirements get_buffer_memory_requirements = nullptr;
  PFN_vkAllocateMemory allocate_memory = nullptr;
  PFN_vkFreeMemory free_memory = nullptr;
  PFN_vkBindBufferMemory bind_buffer_memory = nullptr;
  PFN_vkMapMemory map_memory = nullptr;
  PFN_vkUnmapMemory unmap_memory = nullptr;
  PFN_vkCreateImage create_image = nullptr;
  PFN_vkDestroyImage destroy_image = nullptr;
  PFN_vkGetImageMemoryRequirements get_image_memory_requirements = nullptr;
  PFN_vkBindImageMemory bind_image_memory = nullptr;
  PFN_vkCreateImageView create_image_view = nullptr;
  PFN_vkDestroyImageView destroy_image_view = nullptr;
  PFN_vkCreateSampler create_sampler = nullptr;
  PFN_vkDestroySampler destroy_sampler = nullptr;
};

struct SharedVulkanLifetime {
  std::atomic<std::uint32_t> references{1};
  VkInstance instance = VK_NULL_HANDLE;
  VkDevice device = VK_NULL_HANDLE;
  PFN_vkDestroyInstance destroy_instance = nullptr;
  PFN_vkDestroyDevice destroy_device = nullptr;
  PFN_vkDestroyBuffer destroy_buffer = nullptr;
  PFN_vkFreeMemory free_memory = nullptr;
  PFN_vkUnmapMemory unmap_memory = nullptr;
  PFN_vkDestroyImage destroy_image = nullptr;
  PFN_vkDestroyImageView destroy_image_view = nullptr;
  PFN_vkDestroySampler destroy_sampler = nullptr;
};

template <typename Handle>
Handle DecodeHandle(std::uint64_t bits) noexcept;

bool RetainVulkanLifetime(SharedVulkanLifetime* const lifetime) noexcept {
  if (lifetime == nullptr) return false;
  std::uint32_t count = lifetime->references.load(std::memory_order_relaxed);
  while (count != 0 && count != UINT32_MAX) {
    if (lifetime->references.compare_exchange_weak(
            count, count + 1, std::memory_order_relaxed,
            std::memory_order_relaxed)) {
      return true;
    }
  }
  return false;
}

void ReleaseVulkanLifetime(SharedVulkanLifetime* const lifetime) noexcept {
  if (lifetime == nullptr) return;
  if (lifetime->references.fetch_sub(1, std::memory_order_acq_rel) != 1) return;
  lifetime->destroy_device(lifetime->device, nullptr);
  lifetime->destroy_instance(lifetime->instance, nullptr);
  delete lifetime;
}

void ReleaseOwnedBufferAllocation(const std::uint64_t buffer_handle,
                                  const std::uint64_t memory_handle,
                                  void* const mapped_pointer,
                                  void* const context) noexcept {
  auto* lifetime = static_cast<SharedVulkanLifetime*>(context);
  const VkDeviceMemory owned_memory =
      DecodeHandle<VkDeviceMemory>(memory_handle);
  if (mapped_pointer != nullptr) {
    lifetime->unmap_memory(lifetime->device, owned_memory);
  }
  lifetime->destroy_buffer(lifetime->device,
                           DecodeHandle<VkBuffer>(buffer_handle), nullptr);
  lifetime->free_memory(lifetime->device, owned_memory, nullptr);
  ReleaseVulkanLifetime(lifetime);
}

void ReleaseOwnedSampledImageAllocation(
    const std::uint64_t image_handle,
    const std::uint64_t memory_handle,
    const std::uint64_t image_view_handle,
    const std::uint64_t sampler_handle,
    void* const context) noexcept {
  auto* lifetime = static_cast<SharedVulkanLifetime*>(context);
  lifetime->destroy_sampler(
      lifetime->device, DecodeHandle<VkSampler>(sampler_handle), nullptr);
  lifetime->destroy_image_view(
      lifetime->device, DecodeHandle<VkImageView>(image_view_handle), nullptr);
  lifetime->destroy_image(
      lifetime->device, DecodeHandle<VkImage>(image_handle), nullptr);
  lifetime->free_memory(
      lifetime->device, DecodeHandle<VkDeviceMemory>(memory_handle), nullptr);
  ReleaseVulkanLifetime(lifetime);
}

#if defined(PW_OFFICIAL_DENSE_VULKAN_TESTING)
AllocationLifetimeTestTrace* g_lifetime_test_trace = nullptr;
std::uint32_t g_lifetime_test_sequence = 0;
ImageLifetimeTestTrace* g_image_lifetime_test_trace = nullptr;
std::uint32_t g_image_lifetime_test_sequence = 0;
SampledImageFailureTestTrace* g_image_failure_test_trace = nullptr;
SampledImageFailurePoint g_image_failure_point =
    SampledImageFailurePoint::kCreateImage;
std::uint32_t g_image_failure_cleanup_sequence = 0;

void TestUnmapMemory(VkDevice, VkDeviceMemory) {
  g_lifetime_test_trace->unmap_order = ++g_lifetime_test_sequence;
}
void TestDestroyBuffer(VkDevice, VkBuffer, const VkAllocationCallbacks*) {
  g_lifetime_test_trace->destroy_buffer_order = ++g_lifetime_test_sequence;
}
void TestFreeMemory(VkDevice, VkDeviceMemory, const VkAllocationCallbacks*) {
  g_lifetime_test_trace->free_memory_order = ++g_lifetime_test_sequence;
}
void TestDestroyDevice(VkDevice, const VkAllocationCallbacks*) {
  g_lifetime_test_trace->destroy_device_order = ++g_lifetime_test_sequence;
}
void TestDestroyInstance(VkInstance, const VkAllocationCallbacks*) {
  g_lifetime_test_trace->destroy_instance_order = ++g_lifetime_test_sequence;
}
void TestDestroyImage(VkDevice, VkImage, const VkAllocationCallbacks*) {
  g_image_lifetime_test_trace->destroy_image_order =
      ++g_image_lifetime_test_sequence;
}
void TestDestroyImageView(VkDevice, VkImageView, const VkAllocationCallbacks*) {
  g_image_lifetime_test_trace->destroy_image_view_order =
      ++g_image_lifetime_test_sequence;
}
void TestDestroySampler(VkDevice, VkSampler, const VkAllocationCallbacks*) {
  g_image_lifetime_test_trace->destroy_sampler_order =
      ++g_image_lifetime_test_sequence;
}
void TestImageFreeMemory(VkDevice, VkDeviceMemory,
                         const VkAllocationCallbacks*) {
  g_image_lifetime_test_trace->free_memory_order =
      ++g_image_lifetime_test_sequence;
}
void TestImageDestroyDevice(VkDevice, const VkAllocationCallbacks*) {
  g_image_lifetime_test_trace->destroy_device_order =
      ++g_image_lifetime_test_sequence;
}
void TestImageDestroyInstance(VkInstance, const VkAllocationCallbacks*) {
  g_image_lifetime_test_trace->destroy_instance_order =
      ++g_image_lifetime_test_sequence;
}

VkResult FailureTestCreateImage(VkDevice, const VkImageCreateInfo*,
                                const VkAllocationCallbacks*, VkImage* image) {
  ++g_image_failure_test_trace->create_image_calls;
  if (g_image_failure_point == SampledImageFailurePoint::kCreateImage) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  *image = DecodeHandle<VkImage>(101);
  return VK_SUCCESS;
}
void FailureTestGetImageMemoryRequirements(VkDevice, VkImage,
                                           VkMemoryRequirements* requirements) {
  requirements->size =
      g_image_failure_point ==
              SampledImageFailurePoint::kInvalidMemoryRequirements
          ? 0
          : 4096;
  requirements->alignment = 16;
  requirements->memoryTypeBits = 1;
}
void FailureTestGetMemoryProperties(
    VkPhysicalDevice, VkPhysicalDeviceMemoryProperties* properties) {
  properties->memoryTypeCount = 1;
  properties->memoryTypes[0].propertyFlags =
      g_image_failure_point == SampledImageFailurePoint::kMemoryTypeSelection
          ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
          : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
}
VkResult FailureTestAllocateMemory(VkDevice, const VkMemoryAllocateInfo*,
                                   const VkAllocationCallbacks*,
                                   VkDeviceMemory* memory) {
  ++g_image_failure_test_trace->allocate_memory_calls;
  if (g_image_failure_point == SampledImageFailurePoint::kAllocateMemory) {
    return VK_ERROR_OUT_OF_DEVICE_MEMORY;
  }
  *memory = DecodeHandle<VkDeviceMemory>(102);
  return VK_SUCCESS;
}
VkResult FailureTestBindImageMemory(VkDevice, VkImage, VkDeviceMemory,
                                    VkDeviceSize) {
  ++g_image_failure_test_trace->bind_image_memory_calls;
  return g_image_failure_point == SampledImageFailurePoint::kBindImageMemory
             ? VK_ERROR_MEMORY_MAP_FAILED
             : VK_SUCCESS;
}
VkResult FailureTestCreateImageView(VkDevice, const VkImageViewCreateInfo*,
                                    const VkAllocationCallbacks*,
                                    VkImageView* image_view) {
  ++g_image_failure_test_trace->create_image_view_calls;
  if (g_image_failure_point == SampledImageFailurePoint::kCreateImageView) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  *image_view = DecodeHandle<VkImageView>(103);
  return VK_SUCCESS;
}
VkResult FailureTestCreateSampler(VkDevice, const VkSamplerCreateInfo*,
                                  const VkAllocationCallbacks*,
                                  VkSampler* sampler) {
  ++g_image_failure_test_trace->create_sampler_calls;
  if (g_image_failure_point == SampledImageFailurePoint::kCreateSampler) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  *sampler = DecodeHandle<VkSampler>(104);
  return VK_SUCCESS;
}
void FailureTestDestroySampler(VkDevice, VkSampler,
                               const VkAllocationCallbacks*) {
  ++g_image_failure_test_trace->destroy_sampler_calls;
  g_image_failure_test_trace->destroy_sampler_order =
      ++g_image_failure_cleanup_sequence;
}
void FailureTestDestroyImageView(VkDevice, VkImageView,
                                 const VkAllocationCallbacks*) {
  ++g_image_failure_test_trace->destroy_image_view_calls;
  g_image_failure_test_trace->destroy_image_view_order =
      ++g_image_failure_cleanup_sequence;
}
void FailureTestDestroyImage(VkDevice, VkImage,
                             const VkAllocationCallbacks*) {
  ++g_image_failure_test_trace->destroy_image_calls;
  g_image_failure_test_trace->destroy_image_order =
      ++g_image_failure_cleanup_sequence;
}
void FailureTestFreeMemory(VkDevice, VkDeviceMemory,
                           const VkAllocationCallbacks*) {
  ++g_image_failure_test_trace->free_memory_calls;
  g_image_failure_test_trace->free_memory_order =
      ++g_image_failure_cleanup_sequence;
}
void FailureTestDestroyDevice(VkDevice, const VkAllocationCallbacks*) {}
void FailureTestDestroyInstance(VkInstance, const VkAllocationCallbacks*) {}
void FailureTestReleaseSentinel(std::uint64_t, std::uint64_t, std::uint64_t,
                                std::uint64_t, void* context) noexcept {
  auto* trace = static_cast<SampledImageFailureTestTrace*>(context);
  ++trace->sentinel_release_calls;
}
#endif

bool LoadInstanceDispatch(GetInstanceProcAddr get_proc,
                          VkInstance instance,
                          InstanceDispatch* dispatch) noexcept {
  dispatch->get_instance_proc_addr = get_proc;
  dispatch->destroy_instance = LoadInstance<PFN_vkDestroyInstance>(
      get_proc, instance, "vkDestroyInstance");
  dispatch->enumerate_physical_devices =
      LoadInstance<PFN_vkEnumeratePhysicalDevices>(
          get_proc, instance, "vkEnumeratePhysicalDevices");
  dispatch->get_physical_device_properties =
      LoadInstance<PFN_vkGetPhysicalDeviceProperties>(
          get_proc, instance, "vkGetPhysicalDeviceProperties");
  dispatch->get_physical_device_features =
      LoadInstance<PFN_vkGetPhysicalDeviceFeatures>(
          get_proc, instance, "vkGetPhysicalDeviceFeatures");
  dispatch->get_physical_device_memory_properties =
      LoadInstance<PFN_vkGetPhysicalDeviceMemoryProperties>(
          get_proc, instance, "vkGetPhysicalDeviceMemoryProperties");
  dispatch->get_physical_device_queue_family_properties =
      LoadInstance<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
          get_proc, instance, "vkGetPhysicalDeviceQueueFamilyProperties");
  dispatch->get_physical_device_format_properties =
      LoadInstance<PFN_vkGetPhysicalDeviceFormatProperties>(
          get_proc, instance, "vkGetPhysicalDeviceFormatProperties");
  dispatch->enumerate_device_extension_properties =
      LoadInstance<PFN_vkEnumerateDeviceExtensionProperties>(
          get_proc, instance, "vkEnumerateDeviceExtensionProperties");
  dispatch->create_device = LoadInstance<PFN_vkCreateDevice>(
      get_proc, instance, "vkCreateDevice");
  dispatch->get_device_proc_addr = LoadInstance<PFN_vkGetDeviceProcAddr>(
      get_proc, instance, "vkGetDeviceProcAddr");
  return dispatch->destroy_instance != nullptr &&
         dispatch->enumerate_physical_devices != nullptr &&
         dispatch->get_physical_device_properties != nullptr &&
         dispatch->get_physical_device_features != nullptr &&
         dispatch->get_physical_device_memory_properties != nullptr &&
         dispatch->get_physical_device_queue_family_properties != nullptr &&
         dispatch->get_physical_device_format_properties != nullptr &&
         dispatch->enumerate_device_extension_properties != nullptr &&
         dispatch->create_device != nullptr &&
         dispatch->get_device_proc_addr != nullptr;
}

template <typename Handle>
std::uint64_t EncodeHandle(const Handle handle) noexcept {
  if constexpr (std::is_pointer_v<Handle>) {
    return static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(handle));
  } else {
    return static_cast<std::uint64_t>(handle);
  }
}

template <typename Handle>
Handle DecodeHandle(const std::uint64_t bits) noexcept {
  if constexpr (std::is_pointer_v<Handle>) {
    return reinterpret_cast<Handle>(static_cast<std::uintptr_t>(bits));
  } else {
    return static_cast<Handle>(bits);
  }
}

bool FormatSupports(PFN_vkGetPhysicalDeviceFormatProperties get_properties,
                    VkPhysicalDevice physical_device,
                    VkFormat format,
                    VkFormatFeatureFlags required) noexcept {
  VkFormatProperties properties{};
  get_properties(physical_device, format, &properties);
  return (properties.optimalTilingFeatures & required) == required;
}

struct ProbeObjects {
  VkInstance instance = VK_NULL_HANDLE;
  VkPhysicalDevice physical_device = VK_NULL_HANDLE;
  std::uint32_t queue_family = UINT32_MAX;
  bool requires_portability_subset = false;
  InstanceDispatch dispatch{};

  ~ProbeObjects() {
    if (instance != VK_NULL_HANDLE && dispatch.destroy_instance != nullptr) {
      dispatch.destroy_instance(instance, nullptr);
    }
  }
};

CapabilityReport ProbeVulkan(const CreateOptions& options,
                             ProbeObjects* objects) noexcept {
  CapabilityReport report;
  HostStatus loader_failure = HostStatus::kVulkanUnavailable;
  const GetInstanceProcAddr get_proc = ResolveLoader(options, &loader_failure);
  if (get_proc == nullptr) {
    report.status = loader_failure;
    report.detail = "Vulkan loader is unavailable or was not injected";
    return report;
  }

  const auto create_instance =
      LoadGlobal<PFN_vkCreateInstance>(get_proc, "vkCreateInstance");
  const auto enumerate_instance_extensions =
      LoadGlobal<PFN_vkEnumerateInstanceExtensionProperties>(
          get_proc, "vkEnumerateInstanceExtensionProperties");
  if (create_instance == nullptr) {
    report.detail = "vkCreateInstance is unavailable";
    return report;
  }

  VkApplicationInfo application_info{};
  application_info.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  application_info.pApplicationName = "PocketWorldOfficialDense";
  application_info.apiVersion = VK_API_VERSION_1_1;
  VkInstanceCreateInfo instance_info{};
  instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  instance_info.pApplicationInfo = &application_info;
  const char* instance_extension = nullptr;
  if (enumerate_instance_extensions != nullptr) {
    std::uint32_t extension_count = 0;
    if (enumerate_instance_extensions(nullptr, &extension_count, nullptr) ==
        VK_SUCCESS) {
      std::vector<VkExtensionProperties> extensions(extension_count);
      if (enumerate_instance_extensions(nullptr, &extension_count,
                                        extensions.data()) == VK_SUCCESS) {
        const bool has_portability = std::any_of(
            extensions.begin(), extensions.end(),
            [](const VkExtensionProperties& value) {
              return std::strcmp(value.extensionName,
                                 "VK_KHR_portability_enumeration") == 0;
            });
        if (has_portability) {
          instance_extension = "VK_KHR_portability_enumeration";
          instance_info.enabledExtensionCount = 1;
          instance_info.ppEnabledExtensionNames = &instance_extension;
#if defined(VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR)
          instance_info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
#endif
        }
      }
    }
  }
  if (create_instance(&instance_info, nullptr, &objects->instance) != VK_SUCCESS) {
    report.status = HostStatus::kInstanceCreationFailed;
    report.detail = "vkCreateInstance failed";
    return report;
  }
  if (!LoadInstanceDispatch(get_proc, objects->instance, &objects->dispatch)) {
    report.status = HostStatus::kVulkanUnavailable;
    report.detail = "required Vulkan instance entry points are unavailable";
    return report;
  }

  std::uint32_t device_count = 0;
  if (objects->dispatch.enumerate_physical_devices(
          objects->instance, &device_count, nullptr) != VK_SUCCESS ||
      device_count == 0) {
    report.status = HostStatus::kNoPhysicalDevice;
    report.detail = "no Vulkan physical device";
    return report;
  }
  std::vector<VkPhysicalDevice> devices(device_count);
  if (objects->dispatch.enumerate_physical_devices(
          objects->instance, &device_count, devices.data()) != VK_SUCCESS) {
    report.status = HostStatus::kNoPhysicalDevice;
    report.detail = "physical-device enumeration failed";
    return report;
  }

  for (const VkPhysicalDevice device : devices) {
    VkPhysicalDeviceProperties properties{};
    VkPhysicalDeviceFeatures features{};
    objects->dispatch.get_physical_device_properties(device, &properties);
    objects->dispatch.get_physical_device_features(device, &features);

    std::uint32_t queue_count = 0;
    objects->dispatch.get_physical_device_queue_family_properties(
        device, &queue_count, nullptr);
    std::vector<VkQueueFamilyProperties> queues(queue_count);
    objects->dispatch.get_physical_device_queue_family_properties(
        device, &queue_count, queues.data());
    const auto queue = std::find_if(
        queues.begin(), queues.end(), [](const VkQueueFamilyProperties& value) {
          return value.queueCount > 0 &&
                 (value.queueFlags & VK_QUEUE_COMPUTE_BIT) != 0;
        });
    if (queue == queues.end()) continue;

    report.api_version = properties.apiVersion;
    report.compute_queue_family =
        static_cast<std::uint32_t>(queue - queues.begin());
    report.max_compute_work_group_invocations =
        properties.limits.maxComputeWorkGroupInvocations;
    report.max_per_stage_storage_buffers =
        properties.limits.maxPerStageDescriptorStorageBuffers;
    report.max_per_stage_storage_images =
        properties.limits.maxPerStageDescriptorStorageImages;
    report.max_per_stage_sampled_images =
        properties.limits.maxPerStageDescriptorSampledImages;

    if (properties.limits.maxComputeWorkGroupInvocations <
            kRequiredMaxComputeInvocations ||
        properties.limits.maxComputeWorkGroupSize[0] <
            kRequiredMaxComputeSizeX ||
        properties.limits.maxComputeWorkGroupSize[1] <
            kRequiredMaxComputeSizeY ||
        properties.limits.maxComputeWorkGroupSize[2] <
            kRequiredMaxComputeSizeZ) {
      report.status = HostStatus::kInsufficientComputeInvocations;
      report.detail = "active shaders require workgroups up to 32x8x1 / 128";
      continue;
    }
    if (properties.limits.maxPerStageDescriptorStorageBuffers <
        kRequiredStorageBuffers) {
      report.status = HostStatus::kInsufficientStorageBuffers;
      report.detail = "descriptor storage-buffer limit is below frozen ABI";
      continue;
    }
    if (properties.limits.maxPerStageDescriptorSampledImages <
        kRequiredSampledImages) {
      report.status = HostStatus::kInsufficientSampledImages;
      report.detail = "two sampled image arrays are required";
      continue;
    }
    constexpr VkFormatFeatureFlags kDepthFormatFeatures =
        VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
        VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
    constexpr VkFormatFeatureFlags kGrayFormatFeatures =
        kDepthFormatFeatures |
        VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    if (!FormatSupports(objects->dispatch.get_physical_device_format_properties,
                        device, VK_FORMAT_R32_SFLOAT, kDepthFormatFeatures) ||
        !FormatSupports(objects->dispatch.get_physical_device_format_properties,
                        device, VK_FORMAT_R8_UNORM, kGrayFormatFeatures)) {
      report.status = HostStatus::kRequiredFormatUnavailable;
      report.detail = "VK_FORMAT_R32_SFLOAT or VK_FORMAT_R8_UNORM is unsupported";
      continue;
    }

    objects->physical_device = device;
    objects->queue_family = report.compute_queue_family;
    std::uint32_t extension_count = 0;
    if (objects->dispatch.enumerate_device_extension_properties(
            device, nullptr, &extension_count, nullptr) == VK_SUCCESS) {
      std::vector<VkExtensionProperties> extensions(extension_count);
      if (objects->dispatch.enumerate_device_extension_properties(
              device, nullptr, &extension_count, extensions.data()) ==
          VK_SUCCESS) {
        objects->requires_portability_subset = std::any_of(
            extensions.begin(), extensions.end(),
            [](const VkExtensionProperties& value) {
              return std::strcmp(value.extensionName,
                                 "VK_KHR_portability_subset") == 0;
            });
      }
    }
    report.status = HostStatus::kReady;
    report.detail = "Vulkan compute device satisfies frozen PatchMatch ABI";
    return report;
  }

  if (report.compute_queue_family == UINT32_MAX) {
    report.status = HostStatus::kNoComputeQueue;
    report.detail = "no compute-capable queue family";
  }
  return report;
}
#endif

}  // namespace

bool SelectMemoryType(const std::uint32_t compatible_type_bits,
                      const MemoryTypeTable& table,
                      const BufferMemoryClass memory_class,
                      MemoryTypeSelection* const out) noexcept {
  if (out == nullptr || table.count > table.types.size()) return false;

  std::uint32_t required = 0;
  switch (memory_class) {
    case BufferMemoryClass::kDeviceLocal:
      required = kMemoryPropertyDeviceLocal;
      break;
    case BufferMemoryClass::kHostUpload:
    case BufferMemoryClass::kHostReadback:
      required = kMemoryPropertyHostVisible | kMemoryPropertyHostCoherent;
      break;
    default:
      return false;
  }

  std::uint32_t selected = UINT32_MAX;
  for (std::uint32_t index = 0; index < table.count; ++index) {
    if ((compatible_type_bits & (std::uint32_t{1} << index)) == 0) continue;
    const std::uint32_t flags = table.types[index].property_flags;
    if ((flags & required) != required) continue;
    if (selected == UINT32_MAX) selected = index;
    if (memory_class == BufferMemoryClass::kHostReadback &&
        (flags & kMemoryPropertyHostCached) != 0) {
      selected = index;
      break;
    }
  }
  if (selected == UINT32_MAX) return false;

  const MemoryTypeSelection result{
      selected,
      (table.types[selected].property_flags & kMemoryPropertyHostCoherent) != 0,
  };
  *out = result;
  return true;
}

BufferAllocation::BufferAllocation(BufferAllocation&& other) noexcept
    : buffer_handle_(std::exchange(other.buffer_handle_, 0)),
      memory_handle_(std::exchange(other.memory_handle_, 0)),
      byte_count_(std::exchange(other.byte_count_, 0)),
      mapped_pointer_(std::exchange(other.mapped_pointer_, nullptr)),
      host_coherent_(std::exchange(other.host_coherent_, false)),
      context_(std::exchange(other.context_, nullptr)),
      release_(std::exchange(other.release_, nullptr)) {}

BufferAllocation& BufferAllocation::operator=(BufferAllocation&& other) noexcept {
  if (this != &other) {
    Reset();
    buffer_handle_ = std::exchange(other.buffer_handle_, 0);
    memory_handle_ = std::exchange(other.memory_handle_, 0);
    byte_count_ = std::exchange(other.byte_count_, 0);
    mapped_pointer_ = std::exchange(other.mapped_pointer_, nullptr);
    host_coherent_ = std::exchange(other.host_coherent_, false);
    context_ = std::exchange(other.context_, nullptr);
    release_ = std::exchange(other.release_, nullptr);
  }
  return *this;
}

BufferAllocation::~BufferAllocation() { Reset(); }

void BufferAllocation::Reset() noexcept {
  if (buffer_handle_ != 0 && memory_handle_ != 0 && release_ != nullptr) {
    release_(buffer_handle_, memory_handle_, mapped_pointer_, context_);
  }
  buffer_handle_ = 0;
  memory_handle_ = 0;
  byte_count_ = 0;
  mapped_pointer_ = nullptr;
  host_coherent_ = false;
  context_ = nullptr;
  release_ = nullptr;
}

SampledImageAllocation::SampledImageAllocation(
    SampledImageAllocation&& other) noexcept
    : image_handle_(std::exchange(other.image_handle_, 0)),
      memory_handle_(std::exchange(other.memory_handle_, 0)),
      image_view_handle_(std::exchange(other.image_view_handle_, 0)),
      sampler_handle_(std::exchange(other.sampler_handle_, 0)),
      width_(std::exchange(other.width_, 0)),
      height_(std::exchange(other.height_, 0)),
      array_layers_(std::exchange(other.array_layers_, 0)),
      format_(std::exchange(other.format_, SampledImageFormat::kR8Unorm)),
      sampler_kind_(std::exchange(other.sampler_kind_,
                                  ImageSamplerKind::kGrayLinear)),
      context_(std::exchange(other.context_, nullptr)),
      release_(std::exchange(other.release_, nullptr)) {}

SampledImageAllocation& SampledImageAllocation::operator=(
    SampledImageAllocation&& other) noexcept {
  if (this != &other) {
    Reset();
    image_handle_ = std::exchange(other.image_handle_, 0);
    memory_handle_ = std::exchange(other.memory_handle_, 0);
    image_view_handle_ = std::exchange(other.image_view_handle_, 0);
    sampler_handle_ = std::exchange(other.sampler_handle_, 0);
    width_ = std::exchange(other.width_, 0);
    height_ = std::exchange(other.height_, 0);
    array_layers_ = std::exchange(other.array_layers_, 0);
    format_ = std::exchange(other.format_, SampledImageFormat::kR8Unorm);
    sampler_kind_ = std::exchange(other.sampler_kind_,
                                  ImageSamplerKind::kGrayLinear);
    context_ = std::exchange(other.context_, nullptr);
    release_ = std::exchange(other.release_, nullptr);
  }
  return *this;
}

SampledImageAllocation::~SampledImageAllocation() { Reset(); }

void SampledImageAllocation::Reset() noexcept {
  if (valid() && release_ != nullptr) {
    release_(image_handle_, memory_handle_, image_view_handle_, sampler_handle_,
             context_);
  }
  image_handle_ = 0;
  memory_handle_ = 0;
  image_view_handle_ = 0;
  sampler_handle_ = 0;
  width_ = 0;
  height_ = 0;
  array_layers_ = 0;
  format_ = SampledImageFormat::kR8Unorm;
  sampler_kind_ = ImageSamplerKind::kGrayLinear;
  context_ = nullptr;
  release_ = nullptr;
}

#define PW_DEFINE_OWNED_HANDLE(Type)                                  \
  Type::Type(Type&& other) noexcept                                   \
      : parent_(std::exchange(other.parent_, 0)),                      \
        handle_(std::exchange(other.handle_, 0)),                      \
        context_(std::exchange(other.context_, nullptr)),              \
        release_(std::exchange(other.release_, nullptr)) {}            \
  Type& Type::operator=(Type&& other) noexcept {                       \
    if (this != &other) {                                              \
      Reset();                                                         \
      parent_ = std::exchange(other.parent_, 0);                       \
      handle_ = std::exchange(other.handle_, 0);                       \
      context_ = std::exchange(other.context_, nullptr);               \
      release_ = std::exchange(other.release_, nullptr);               \
    }                                                                  \
    return *this;                                                      \
  }                                                                    \
  Type::~Type() { Reset(); }                                           \
  void Type::Reset() noexcept {                                        \
    if (handle_ != 0 && release_ != nullptr) {                         \
      release_(parent_, handle_, context_);                            \
    }                                                                  \
    parent_ = 0;                                                       \
    handle_ = 0;                                                       \
    context_ = nullptr;                                                \
    release_ = nullptr;                                                \
  }

PW_DEFINE_OWNED_HANDLE(Instance)
PW_DEFINE_OWNED_HANDLE(Device)
PW_DEFINE_OWNED_HANDLE(Buffer)
PW_DEFINE_OWNED_HANDLE(DescriptorSet)
PW_DEFINE_OWNED_HANDLE(ComputePipeline)
PW_DEFINE_OWNED_HANDLE(CommandPool)
PW_DEFINE_OWNED_HANDLE(CommandBuffer)

#undef PW_DEFINE_OWNED_HANDLE

struct VulkanHost::Impl {
  CapabilityReport report;
#if !defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  InstanceDispatch instance_dispatch{};
  DeviceDispatch device_dispatch{};
  VkPhysicalDevice physical_device = VK_NULL_HANDLE;
#endif
  Instance instance;
  Device device;
  Queue queue;
  CommandPool command_pool;
  CommandBuffer command_buffer;
};

VulkanHost::VulkanHost(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
VulkanHost::VulkanHost(VulkanHost&&) noexcept = default;
VulkanHost& VulkanHost::operator=(VulkanHost&&) noexcept = default;
VulkanHost::~VulkanHost() = default;

CapabilityReport VulkanHost::Probe(const CreateOptions& options) noexcept {
#if defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  (void)options;
  CapabilityReport report;
#if defined(__APPLE__) || defined(PW_OFFICIAL_DENSE_HARMONY)
  report.status = HostStatus::kExternalLoaderRequired;
  report.detail = "runtime disabled until an external Vulkan loader is injected";
#else
  report.status = HostStatus::kVulkanUnavailable;
  report.detail = "Vulkan headers or runtime are unavailable";
#endif
  return report;
#else
  ProbeObjects objects;
  return ProbeVulkan(options, &objects);
#endif
}

std::unique_ptr<VulkanHost> VulkanHost::Create(
    const CreateOptions& options,
    CapabilityReport* report) noexcept {
#if defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  const CapabilityReport unavailable = Probe(options);
  if (report != nullptr) *report = unavailable;
  return nullptr;
#else
  ProbeObjects objects;
  CapabilityReport capabilities = ProbeVulkan(options, &objects);
  if (!capabilities.ready()) {
    if (report != nullptr) *report = capabilities;
    return nullptr;
  }

  const float queue_priority = 1.0F;
  VkDeviceQueueCreateInfo queue_info{};
  queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  queue_info.queueFamilyIndex = objects.queue_family;
  queue_info.queueCount = 1;
  queue_info.pQueuePriorities = &queue_priority;
  VkPhysicalDeviceFeatures features{};
  VkDeviceCreateInfo device_info{};
  device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  device_info.queueCreateInfoCount = 1;
  device_info.pQueueCreateInfos = &queue_info;
  device_info.pEnabledFeatures = &features;
  const char* device_extension = "VK_KHR_portability_subset";
  if (objects.requires_portability_subset) {
    device_info.enabledExtensionCount = 1;
    device_info.ppEnabledExtensionNames = &device_extension;
  }

  VkDevice device = VK_NULL_HANDLE;
  if (objects.dispatch.create_device(objects.physical_device, &device_info,
                                     nullptr, &device) != VK_SUCCESS) {
    capabilities.status = HostStatus::kDeviceCreationFailed;
    capabilities.detail = "vkCreateDevice failed";
    if (report != nullptr) *report = capabilities;
    return nullptr;
  }

  auto impl = std::make_unique<Impl>();
  impl->report = capabilities;
  impl->instance_dispatch = objects.dispatch;
  impl->physical_device = objects.physical_device;
  impl->instance.handle_ = EncodeHandle(
      std::exchange(objects.instance, VK_NULL_HANDLE));
  impl->instance.context_ = &impl->instance_dispatch;
  impl->instance.release_ = [](std::uint64_t, std::uint64_t handle,
                               void* context) noexcept {
    auto* dispatch = static_cast<InstanceDispatch*>(context);
    dispatch->destroy_instance(DecodeHandle<VkInstance>(handle), nullptr);
  };
  auto load_device = [&](const char* name) {
    return objects.dispatch.get_device_proc_addr(device, name);
  };
  impl->device_dispatch.destroy_device =
      reinterpret_cast<PFN_vkDestroyDevice>(load_device("vkDestroyDevice"));
  impl->device_dispatch.get_device_queue =
      reinterpret_cast<PFN_vkGetDeviceQueue>(load_device("vkGetDeviceQueue"));
  impl->device_dispatch.create_command_pool =
      reinterpret_cast<PFN_vkCreateCommandPool>(load_device("vkCreateCommandPool"));
  impl->device_dispatch.destroy_command_pool =
      reinterpret_cast<PFN_vkDestroyCommandPool>(load_device("vkDestroyCommandPool"));
  impl->device_dispatch.allocate_command_buffers =
      reinterpret_cast<PFN_vkAllocateCommandBuffers>(
          load_device("vkAllocateCommandBuffers"));
  impl->device_dispatch.free_command_buffers =
      reinterpret_cast<PFN_vkFreeCommandBuffers>(
          load_device("vkFreeCommandBuffers"));
  impl->device_dispatch.create_buffer =
      reinterpret_cast<PFN_vkCreateBuffer>(load_device("vkCreateBuffer"));
  impl->device_dispatch.destroy_buffer =
      reinterpret_cast<PFN_vkDestroyBuffer>(load_device("vkDestroyBuffer"));
  impl->device_dispatch.get_buffer_memory_requirements =
      reinterpret_cast<PFN_vkGetBufferMemoryRequirements>(
          load_device("vkGetBufferMemoryRequirements"));
  impl->device_dispatch.allocate_memory =
      reinterpret_cast<PFN_vkAllocateMemory>(load_device("vkAllocateMemory"));
  impl->device_dispatch.free_memory =
      reinterpret_cast<PFN_vkFreeMemory>(load_device("vkFreeMemory"));
  impl->device_dispatch.bind_buffer_memory =
      reinterpret_cast<PFN_vkBindBufferMemory>(
          load_device("vkBindBufferMemory"));
  impl->device_dispatch.map_memory =
      reinterpret_cast<PFN_vkMapMemory>(load_device("vkMapMemory"));
  impl->device_dispatch.unmap_memory =
      reinterpret_cast<PFN_vkUnmapMemory>(load_device("vkUnmapMemory"));
  impl->device_dispatch.create_image =
      reinterpret_cast<PFN_vkCreateImage>(load_device("vkCreateImage"));
  impl->device_dispatch.destroy_image =
      reinterpret_cast<PFN_vkDestroyImage>(load_device("vkDestroyImage"));
  impl->device_dispatch.get_image_memory_requirements =
      reinterpret_cast<PFN_vkGetImageMemoryRequirements>(
          load_device("vkGetImageMemoryRequirements"));
  impl->device_dispatch.bind_image_memory =
      reinterpret_cast<PFN_vkBindImageMemory>(load_device("vkBindImageMemory"));
  impl->device_dispatch.create_image_view =
      reinterpret_cast<PFN_vkCreateImageView>(load_device("vkCreateImageView"));
  impl->device_dispatch.destroy_image_view =
      reinterpret_cast<PFN_vkDestroyImageView>(
          load_device("vkDestroyImageView"));
  impl->device_dispatch.create_sampler =
      reinterpret_cast<PFN_vkCreateSampler>(load_device("vkCreateSampler"));
  impl->device_dispatch.destroy_sampler =
      reinterpret_cast<PFN_vkDestroySampler>(load_device("vkDestroySampler"));
  if (impl->device_dispatch.destroy_device != nullptr) {
    impl->device.handle_ = EncodeHandle(device);
    impl->device.context_ = &impl->device_dispatch;
    impl->device.release_ = [](std::uint64_t, std::uint64_t handle,
                               void* context) noexcept {
      auto* dispatch = static_cast<DeviceDispatch*>(context);
      dispatch->destroy_device(DecodeHandle<VkDevice>(handle), nullptr);
    };
  }
  if (impl->device_dispatch.destroy_device == nullptr ||
      impl->device_dispatch.get_device_queue == nullptr ||
      impl->device_dispatch.create_command_pool == nullptr ||
      impl->device_dispatch.destroy_command_pool == nullptr ||
      impl->device_dispatch.allocate_command_buffers == nullptr ||
      impl->device_dispatch.free_command_buffers == nullptr ||
      impl->device_dispatch.create_buffer == nullptr ||
      impl->device_dispatch.destroy_buffer == nullptr ||
      impl->device_dispatch.get_buffer_memory_requirements == nullptr ||
      impl->device_dispatch.allocate_memory == nullptr ||
      impl->device_dispatch.free_memory == nullptr ||
      impl->device_dispatch.bind_buffer_memory == nullptr ||
      impl->device_dispatch.map_memory == nullptr ||
      impl->device_dispatch.unmap_memory == nullptr ||
      impl->device_dispatch.create_image == nullptr ||
      impl->device_dispatch.destroy_image == nullptr ||
      impl->device_dispatch.get_image_memory_requirements == nullptr ||
      impl->device_dispatch.bind_image_memory == nullptr ||
      impl->device_dispatch.create_image_view == nullptr ||
      impl->device_dispatch.destroy_image_view == nullptr ||
      impl->device_dispatch.create_sampler == nullptr ||
      impl->device_dispatch.destroy_sampler == nullptr) {
    capabilities.status = HostStatus::kVulkanUnavailable;
    capabilities.detail = "required device entry points are unavailable";
    if (report != nullptr) *report = capabilities;
    return nullptr;
  }
  VkQueue queue = VK_NULL_HANDLE;
  impl->device_dispatch.get_device_queue(device, objects.queue_family, 0, &queue);
  impl->queue.handle_ = EncodeHandle(queue);

  VkCommandPoolCreateInfo pool_info{};
  pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
  pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
  pool_info.queueFamilyIndex = objects.queue_family;
  VkCommandPool pool = VK_NULL_HANDLE;
  if (impl->device_dispatch.create_command_pool(device, &pool_info, nullptr,
                                                &pool) != VK_SUCCESS) {
    capabilities.status = HostStatus::kDeviceCreationFailed;
    capabilities.detail = "vkCreateCommandPool failed";
    if (report != nullptr) *report = capabilities;
    return nullptr;
  }
  impl->command_pool.parent_ = EncodeHandle(device);
  impl->command_pool.handle_ = EncodeHandle(pool);
  impl->command_pool.context_ = &impl->device_dispatch;
  impl->command_pool.release_ = [](std::uint64_t parent, std::uint64_t handle,
                                   void* context) noexcept {
    auto* dispatch = static_cast<DeviceDispatch*>(context);
    dispatch->destroy_command_pool(DecodeHandle<VkDevice>(parent),
                                   DecodeHandle<VkCommandPool>(handle),
                                   nullptr);
  };

  VkCommandBufferAllocateInfo command_buffer_allocate_info{};
  command_buffer_allocate_info.sType =
      VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
  command_buffer_allocate_info.commandPool = pool;
  command_buffer_allocate_info.level =
      VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  command_buffer_allocate_info.commandBufferCount = 1;
  VkCommandBuffer command_buffer = VK_NULL_HANDLE;
  if (impl->device_dispatch.allocate_command_buffers(
          device, &command_buffer_allocate_info, &command_buffer) != VK_SUCCESS ||
      command_buffer == VK_NULL_HANDLE) {
    capabilities.status = HostStatus::kCommandBufferAllocationFailed;
    capabilities.detail = "vkAllocateCommandBuffers failed";
    if (report != nullptr) *report = capabilities;
    return nullptr;
  }
  impl->command_buffer.parent_ = EncodeHandle(device);
  impl->command_buffer.handle_ = EncodeHandle(command_buffer);
  impl->command_buffer.context_ = impl.get();
  impl->command_buffer.release_ = [](std::uint64_t parent,
                                     std::uint64_t handle,
                                     void* context) noexcept {
    auto* host = static_cast<Impl*>(context);
    const VkCommandPool command_pool =
        DecodeHandle<VkCommandPool>(host->command_pool.handle_);
    const VkCommandBuffer owned_command_buffer =
        DecodeHandle<VkCommandBuffer>(handle);
    host->device_dispatch.free_command_buffers(
        DecodeHandle<VkDevice>(parent), command_pool, 1,
        &owned_command_buffer);
  };
  auto* shared_lifetime = new (std::nothrow) SharedVulkanLifetime{};
  if (shared_lifetime == nullptr) {
    capabilities.status = HostStatus::kDeviceCreationFailed;
    capabilities.detail = "shared Vulkan lifetime allocation failed";
    if (report != nullptr) *report = capabilities;
    return nullptr;
  }
  shared_lifetime->instance =
      DecodeHandle<VkInstance>(impl->instance.handle_);
  shared_lifetime->device = device;
  shared_lifetime->destroy_instance =
      impl->instance_dispatch.destroy_instance;
  shared_lifetime->destroy_device = impl->device_dispatch.destroy_device;
  shared_lifetime->destroy_buffer = impl->device_dispatch.destroy_buffer;
  shared_lifetime->free_memory = impl->device_dispatch.free_memory;
  shared_lifetime->unmap_memory = impl->device_dispatch.unmap_memory;
  shared_lifetime->destroy_image = impl->device_dispatch.destroy_image;
  shared_lifetime->destroy_image_view =
      impl->device_dispatch.destroy_image_view;
  shared_lifetime->destroy_sampler = impl->device_dispatch.destroy_sampler;
  // The host's device reference now owns the instance and device together.
  // Allocations retain the same lifetime, so neither parent can be destroyed
  // while an allocation is still alive.
  impl->instance.context_ = nullptr;
  impl->instance.release_ = nullptr;
  impl->device.context_ = shared_lifetime;
  impl->device.release_ = [](std::uint64_t, std::uint64_t,
                             void* context) noexcept {
    ReleaseVulkanLifetime(static_cast<SharedVulkanLifetime*>(context));
  };
  if (report != nullptr) *report = capabilities;
  return std::unique_ptr<VulkanHost>(new VulkanHost(std::move(impl)));
#endif
}

const CapabilityReport& VulkanHost::capabilities() const noexcept {
  return impl_->report;
}

const Queue& VulkanHost::compute_queue() const noexcept { return impl_->queue; }

const CommandPool& VulkanHost::command_pool() const noexcept {
  return impl_->command_pool;
}

const CommandBuffer& VulkanHost::command_buffer() const noexcept {
  return impl_->command_buffer;
}

NativeHandles VulkanHost::native_handles() const noexcept {
  return NativeHandles{
      impl_->instance.handle_,
      impl_->device.handle_,
      impl_->queue.handle_,
      impl_->command_buffer.handle_,
  };
}

bool VulkanHost::CreateBufferAllocation(const BufferAllocationSpec& spec,
                                        BufferAllocation* const out,
                                        std::string* const detail) noexcept {
  auto fail = [&](const char* message) noexcept {
    SetDetailNoexcept(detail, message);
    return false;
  };
  if (out == nullptr) return fail("buffer allocation output is null");
  if (spec.byte_count == 0) return fail("buffer byte_count must be positive");
  if (spec.usage_flags == 0 ||
      (spec.usage_flags & ~kKnownBufferUsageFlags) != 0) {
    return fail("buffer usage flags are empty or unsupported");
  }
  switch (spec.memory_class) {
    case BufferMemoryClass::kDeviceLocal:
    case BufferMemoryClass::kHostUpload:
    case BufferMemoryClass::kHostReadback:
      break;
    default:
      return fail("buffer memory class is unsupported");
  }

#if defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  return fail("Vulkan buffer allocation is unavailable in the stub backend");
#else
  if (impl_ == nullptr || !impl_->device.valid() ||
      impl_->physical_device == VK_NULL_HANDLE) {
    return fail("Vulkan host is not ready for buffer allocation");
  }
  if (spec.byte_count >
      static_cast<std::uint64_t>(std::numeric_limits<VkDeviceSize>::max())) {
    return fail("buffer byte_count exceeds VkDeviceSize");
  }

  VkBufferUsageFlags usage = 0;
  if ((spec.usage_flags & kBufferUsageStorage) != 0) {
    usage |= VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
  }
  if ((spec.usage_flags & kBufferUsageTransferSrc) != 0) {
    usage |= VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
  }
  if ((spec.usage_flags & kBufferUsageTransferDst) != 0) {
    usage |= VK_BUFFER_USAGE_TRANSFER_DST_BIT;
  }

  const VkDevice device = DecodeHandle<VkDevice>(impl_->device.handle_);
  VkBuffer buffer = VK_NULL_HANDLE;
  VkDeviceMemory memory = VK_NULL_HANDLE;
  void* mapped = nullptr;
  auto cleanup = [&]() noexcept {
    if (mapped != nullptr) {
      impl_->device_dispatch.unmap_memory(device, memory);
      mapped = nullptr;
    }
    if (buffer != VK_NULL_HANDLE) {
      impl_->device_dispatch.destroy_buffer(device, buffer, nullptr);
      buffer = VK_NULL_HANDLE;
    }
    if (memory != VK_NULL_HANDLE) {
      impl_->device_dispatch.free_memory(device, memory, nullptr);
      memory = VK_NULL_HANDLE;
    }
  };

  VkBufferCreateInfo buffer_info{};
  buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  buffer_info.size = static_cast<VkDeviceSize>(spec.byte_count);
  buffer_info.usage = usage;
  buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  if (impl_->device_dispatch.create_buffer(device, &buffer_info, nullptr,
                                           &buffer) != VK_SUCCESS ||
      buffer == VK_NULL_HANDLE) {
    cleanup();
    return fail("vkCreateBuffer failed");
  }

  VkMemoryRequirements requirements{};
  impl_->device_dispatch.get_buffer_memory_requirements(device, buffer,
                                                        &requirements);
  if (requirements.size < static_cast<VkDeviceSize>(spec.byte_count) ||
      requirements.memoryTypeBits == 0) {
    cleanup();
    return fail("Vulkan returned invalid buffer memory requirements");
  }

  VkPhysicalDeviceMemoryProperties properties{};
  impl_->instance_dispatch.get_physical_device_memory_properties(
      impl_->physical_device, &properties);
  if (properties.memoryTypeCount > 32) {
    cleanup();
    return fail("physical device reports too many memory types");
  }
  MemoryTypeTable table{};
  table.count = properties.memoryTypeCount;
  for (std::uint32_t index = 0; index < table.count; ++index) {
    const VkMemoryPropertyFlags flags =
        properties.memoryTypes[index].propertyFlags;
    std::uint32_t portable_flags = 0;
    if ((flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0) {
      portable_flags |= kMemoryPropertyDeviceLocal;
    }
    if ((flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
      portable_flags |= kMemoryPropertyHostVisible;
    }
    if ((flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0) {
      portable_flags |= kMemoryPropertyHostCoherent;
    }
    if ((flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) != 0) {
      portable_flags |= kMemoryPropertyHostCached;
    }
    table.types[index].property_flags = portable_flags;
  }

  MemoryTypeSelection selection{};
  if (!SelectMemoryType(requirements.memoryTypeBits, table, spec.memory_class,
                        &selection)) {
    cleanup();
    return fail("no compatible Vulkan memory type satisfies the requested class");
  }

  VkMemoryAllocateInfo allocate_info{};
  allocate_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  allocate_info.allocationSize = requirements.size;
  allocate_info.memoryTypeIndex = selection.index;
  if (impl_->device_dispatch.allocate_memory(device, &allocate_info, nullptr,
                                              &memory) != VK_SUCCESS ||
      memory == VK_NULL_HANDLE) {
    cleanup();
    return fail("vkAllocateMemory failed");
  }
  if (impl_->device_dispatch.bind_buffer_memory(device, buffer, memory, 0) !=
      VK_SUCCESS) {
    cleanup();
    return fail("vkBindBufferMemory failed");
  }

  if (spec.memory_class != BufferMemoryClass::kDeviceLocal) {
    if (!selection.host_coherent) {
      cleanup();
      return fail("host memory is not coherent");
    }
    if (impl_->device_dispatch.map_memory(
            device, memory, 0, static_cast<VkDeviceSize>(spec.byte_count), 0,
            &mapped) != VK_SUCCESS ||
        mapped == nullptr) {
      cleanup();
      return fail("vkMapMemory failed");
    }
  }

  auto* shared_lifetime =
      static_cast<SharedVulkanLifetime*>(impl_->device.context_);
  if (!RetainVulkanLifetime(shared_lifetime)) {
    cleanup();
    return fail("shared Vulkan lifetime cannot be retained");
  }

  BufferAllocation result;
  result.buffer_handle_ = EncodeHandle(buffer);
  result.memory_handle_ = EncodeHandle(memory);
  result.byte_count_ = spec.byte_count;
  result.mapped_pointer_ = mapped;
  result.host_coherent_ = selection.host_coherent;
  result.context_ = shared_lifetime;
  result.release_ = &ReleaseOwnedBufferAllocation;
  buffer = VK_NULL_HANDLE;
  memory = VK_NULL_HANDLE;
  mapped = nullptr;
  *out = std::move(result);
  if (detail != nullptr) detail->clear();
  return true;
#endif
}

bool VulkanHost::CreateSampledImageAllocation(
    const SampledImageSpec& spec,
    SampledImageAllocation* const out,
    std::string* const detail) noexcept {
  auto fail = [&](const char* message) noexcept {
    SetDetailNoexcept(detail, message);
    return false;
  };
  if (out == nullptr) return fail("sampled image output is null");
  if (spec.width == 0 || spec.height == 0 || spec.array_layers == 0) {
    return fail("sampled image dimensions and array_layers must be positive");
  }
#if !defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  VkFormat format = VK_FORMAT_UNDEFINED;
#endif
  switch (spec.format) {
    case SampledImageFormat::kR8Unorm:
      if (spec.sampler != ImageSamplerKind::kGrayLinear) {
        return fail("R8_UNORM requires the gray linear sampler");
      }
#if !defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
      format = VK_FORMAT_R8_UNORM;
#endif
      break;
    case SampledImageFormat::kR32Sfloat:
      if (spec.sampler != ImageSamplerKind::kDepthNearest) {
        return fail("R32_SFLOAT requires the depth nearest sampler");
      }
#if !defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
      format = VK_FORMAT_R32_SFLOAT;
#endif
      break;
    default:
      return fail("sampled image format is unsupported");
  }

#if defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  return fail("Vulkan sampled image allocation is unavailable in the stub backend");
#else
  if (impl_ == nullptr || !impl_->device.valid() ||
      impl_->physical_device == VK_NULL_HANDLE) {
    return fail("Vulkan host is not ready for sampled image allocation");
  }

  const VkDevice device = DecodeHandle<VkDevice>(impl_->device.handle_);
  VkImage image = VK_NULL_HANDLE;
  VkDeviceMemory memory = VK_NULL_HANDLE;
  VkImageView image_view = VK_NULL_HANDLE;
  VkSampler sampler = VK_NULL_HANDLE;
  auto cleanup = [&]() noexcept {
    if (sampler != VK_NULL_HANDLE) {
      impl_->device_dispatch.destroy_sampler(device, sampler, nullptr);
      sampler = VK_NULL_HANDLE;
    }
    if (image_view != VK_NULL_HANDLE) {
      impl_->device_dispatch.destroy_image_view(device, image_view, nullptr);
      image_view = VK_NULL_HANDLE;
    }
    if (image != VK_NULL_HANDLE) {
      impl_->device_dispatch.destroy_image(device, image, nullptr);
      image = VK_NULL_HANDLE;
    }
    if (memory != VK_NULL_HANDLE) {
      impl_->device_dispatch.free_memory(device, memory, nullptr);
      memory = VK_NULL_HANDLE;
    }
  };

  VkImageCreateInfo image_info{};
  image_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  image_info.imageType = VK_IMAGE_TYPE_2D;
  image_info.format = format;
  image_info.extent = VkExtent3D{spec.width, spec.height, 1};
  image_info.mipLevels = 1;
  image_info.arrayLayers = spec.array_layers;
  image_info.samples = VK_SAMPLE_COUNT_1_BIT;
  image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
  image_info.usage =
      VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
  image_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
  if (impl_->device_dispatch.create_image(device, &image_info, nullptr,
                                           &image) != VK_SUCCESS ||
      image == VK_NULL_HANDLE) {
    cleanup();
    return fail("vkCreateImage failed");
  }

  VkMemoryRequirements requirements{};
  impl_->device_dispatch.get_image_memory_requirements(device, image,
                                                       &requirements);
  if (requirements.size == 0 || requirements.memoryTypeBits == 0) {
    cleanup();
    return fail("Vulkan returned invalid image memory requirements");
  }

  VkPhysicalDeviceMemoryProperties properties{};
  impl_->instance_dispatch.get_physical_device_memory_properties(
      impl_->physical_device, &properties);
  if (properties.memoryTypeCount > 32) {
    cleanup();
    return fail("physical device reports too many memory types");
  }
  MemoryTypeTable table{};
  table.count = properties.memoryTypeCount;
  for (std::uint32_t index = 0; index < table.count; ++index) {
    const VkMemoryPropertyFlags flags =
        properties.memoryTypes[index].propertyFlags;
    std::uint32_t portable_flags = 0;
    if ((flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0) {
      portable_flags |= kMemoryPropertyDeviceLocal;
    }
    if ((flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
      portable_flags |= kMemoryPropertyHostVisible;
    }
    if ((flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0) {
      portable_flags |= kMemoryPropertyHostCoherent;
    }
    if ((flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) != 0) {
      portable_flags |= kMemoryPropertyHostCached;
    }
    table.types[index].property_flags = portable_flags;
  }
  MemoryTypeSelection selection{};
  if (!SelectMemoryType(requirements.memoryTypeBits, table,
                        BufferMemoryClass::kDeviceLocal, &selection)) {
    cleanup();
    return fail("no device-local memory type is compatible with the image");
  }

  VkMemoryAllocateInfo allocate_info{};
  allocate_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  allocate_info.allocationSize = requirements.size;
  allocate_info.memoryTypeIndex = selection.index;
  if (impl_->device_dispatch.allocate_memory(device, &allocate_info, nullptr,
                                              &memory) != VK_SUCCESS ||
      memory == VK_NULL_HANDLE) {
    cleanup();
    return fail("vkAllocateMemory failed for sampled image");
  }
  if (impl_->device_dispatch.bind_image_memory(device, image, memory, 0) !=
      VK_SUCCESS) {
    cleanup();
    return fail("vkBindImageMemory failed");
  }

  VkImageViewCreateInfo view_info{};
  view_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  view_info.image = image;
  view_info.viewType = VK_IMAGE_VIEW_TYPE_2D_ARRAY;
  view_info.format = format;
  view_info.components = VkComponentMapping{
      VK_COMPONENT_SWIZZLE_IDENTITY,
      VK_COMPONENT_SWIZZLE_IDENTITY,
      VK_COMPONENT_SWIZZLE_IDENTITY,
      VK_COMPONENT_SWIZZLE_IDENTITY,
  };
  view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
  view_info.subresourceRange.baseMipLevel = 0;
  view_info.subresourceRange.levelCount = 1;
  view_info.subresourceRange.baseArrayLayer = 0;
  view_info.subresourceRange.layerCount = spec.array_layers;
  if (impl_->device_dispatch.create_image_view(device, &view_info, nullptr,
                                                &image_view) != VK_SUCCESS ||
      image_view == VK_NULL_HANDLE) {
    cleanup();
    return fail("vkCreateImageView failed");
  }

  const VkFilter filter = spec.sampler == ImageSamplerKind::kGrayLinear
                              ? VK_FILTER_LINEAR
                              : VK_FILTER_NEAREST;
  VkSamplerCreateInfo sampler_info{};
  sampler_info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
  sampler_info.magFilter = filter;
  sampler_info.minFilter = filter;
  sampler_info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
  sampler_info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
  sampler_info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
  sampler_info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
  sampler_info.mipLodBias = 0.0F;
  sampler_info.anisotropyEnable = VK_FALSE;
  sampler_info.maxAnisotropy = 1.0F;
  sampler_info.compareEnable = VK_FALSE;
  sampler_info.compareOp = VK_COMPARE_OP_NEVER;
  sampler_info.minLod = 0.0F;
  sampler_info.maxLod = 0.0F;
  sampler_info.borderColor = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
  sampler_info.unnormalizedCoordinates = VK_FALSE;
  if (impl_->device_dispatch.create_sampler(device, &sampler_info, nullptr,
                                             &sampler) != VK_SUCCESS ||
      sampler == VK_NULL_HANDLE) {
    cleanup();
    return fail("vkCreateSampler failed");
  }

  auto* shared_lifetime =
      static_cast<SharedVulkanLifetime*>(impl_->device.context_);
  if (!RetainVulkanLifetime(shared_lifetime)) {
    cleanup();
    return fail("shared Vulkan lifetime cannot be retained for sampled image");
  }

  SampledImageAllocation result;
  result.image_handle_ = EncodeHandle(image);
  result.memory_handle_ = EncodeHandle(memory);
  result.image_view_handle_ = EncodeHandle(image_view);
  result.sampler_handle_ = EncodeHandle(sampler);
  result.width_ = spec.width;
  result.height_ = spec.height;
  result.array_layers_ = spec.array_layers;
  result.format_ = spec.format;
  result.sampler_kind_ = spec.sampler;
  result.context_ = shared_lifetime;
  result.release_ = &ReleaseOwnedSampledImageAllocation;
  image = VK_NULL_HANDLE;
  memory = VK_NULL_HANDLE;
  image_view = VK_NULL_HANDLE;
  sampler = VK_NULL_HANDLE;
  *out = std::move(result);
  if (detail != nullptr) detail->clear();
  return true;
#endif
}

#if defined(PW_OFFICIAL_DENSE_VULKAN_TESTING)
bool VulkanHost::TestDetailAssignmentFailureIsContained() noexcept {
  struct ThrowingDetailSink {
    bool assignment_attempted = false;

    void assign(const char*) {
      assignment_attempted = true;
      throw 1;
    }
  } detail;
  SetDetailSinkNoexcept(&detail, "deterministic throwing detail sink");
  return detail.assignment_attempted;
}

bool VulkanHost::TestAllocationOutlivesHost(
    AllocationLifetimeTestTrace* const trace) noexcept {
  if (trace == nullptr) return false;
  *trace = AllocationLifetimeTestTrace{};
#if defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  return false;
#else
  g_lifetime_test_trace = trace;
  g_lifetime_test_sequence = 0;
  auto* lifetime = new (std::nothrow) SharedVulkanLifetime{};
  if (lifetime == nullptr) {
    g_lifetime_test_trace = nullptr;
    return false;
  }
  lifetime->instance = DecodeHandle<VkInstance>(1);
  lifetime->device = DecodeHandle<VkDevice>(2);
  lifetime->destroy_instance = &TestDestroyInstance;
  lifetime->destroy_device = &TestDestroyDevice;
  lifetime->destroy_buffer = &TestDestroyBuffer;
  lifetime->free_memory = &TestFreeMemory;
  lifetime->unmap_memory = &TestUnmapMemory;
  if (!RetainVulkanLifetime(lifetime)) {
    ReleaseVulkanLifetime(lifetime);
    g_lifetime_test_trace = nullptr;
    return false;
  }

  BufferAllocation allocation;
  allocation.buffer_handle_ = EncodeHandle(DecodeHandle<VkBuffer>(3));
  allocation.memory_handle_ = EncodeHandle(DecodeHandle<VkDeviceMemory>(4));
  allocation.byte_count_ = 16;
  allocation.mapped_pointer_ = reinterpret_cast<void*>(
      static_cast<std::uintptr_t>(5));
  allocation.host_coherent_ = true;
  allocation.context_ = lifetime;
  allocation.release_ = &ReleaseOwnedBufferAllocation;

  // Simulate VulkanHost destruction while the allocation escapes. The shared
  // host reference drops, but neither parent may be destroyed yet.
  ReleaseVulkanLifetime(lifetime);
  if (trace->destroy_device_order != 0 || trace->destroy_instance_order != 0) {
    allocation.Reset();
    g_lifetime_test_trace = nullptr;
    return false;
  }
  allocation.Reset();
  g_lifetime_test_trace = nullptr;
  return trace->unmap_order == 1 && trace->destroy_buffer_order == 2 &&
         trace->free_memory_order == 3 && trace->destroy_device_order == 4 &&
         trace->destroy_instance_order == 5;
#endif
}

bool VulkanHost::TestImageOutlivesHost(
    ImageLifetimeTestTrace* const trace) noexcept {
  if (trace == nullptr) return false;
  *trace = ImageLifetimeTestTrace{};
#if defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  return false;
#else
  g_image_lifetime_test_trace = trace;
  g_image_lifetime_test_sequence = 0;
  auto* lifetime = new (std::nothrow) SharedVulkanLifetime{};
  if (lifetime == nullptr) {
    g_image_lifetime_test_trace = nullptr;
    return false;
  }
  lifetime->instance = DecodeHandle<VkInstance>(1);
  lifetime->device = DecodeHandle<VkDevice>(2);
  lifetime->destroy_instance = &TestImageDestroyInstance;
  lifetime->destroy_device = &TestImageDestroyDevice;
  lifetime->destroy_image = &TestDestroyImage;
  lifetime->destroy_image_view = &TestDestroyImageView;
  lifetime->destroy_sampler = &TestDestroySampler;
  lifetime->free_memory = &TestImageFreeMemory;
  if (!RetainVulkanLifetime(lifetime)) {
    ReleaseVulkanLifetime(lifetime);
    g_image_lifetime_test_trace = nullptr;
    return false;
  }

  SampledImageAllocation allocation;
  allocation.image_handle_ = EncodeHandle(DecodeHandle<VkImage>(3));
  allocation.memory_handle_ = EncodeHandle(DecodeHandle<VkDeviceMemory>(4));
  allocation.image_view_handle_ = EncodeHandle(DecodeHandle<VkImageView>(5));
  allocation.sampler_handle_ = EncodeHandle(DecodeHandle<VkSampler>(6));
  allocation.width_ = 8;
  allocation.height_ = 8;
  allocation.array_layers_ = 2;
  allocation.context_ = lifetime;
  allocation.release_ = &ReleaseOwnedSampledImageAllocation;

  // Simulate VulkanHost destruction while the image escapes. The retained
  // allocation keeps the instance/device alive until all child handles unwind.
  ReleaseVulkanLifetime(lifetime);
  if (trace->destroy_device_order != 0 || trace->destroy_instance_order != 0) {
    allocation.Reset();
    g_image_lifetime_test_trace = nullptr;
    return false;
  }
  allocation.Reset();
  g_image_lifetime_test_trace = nullptr;
  return trace->destroy_sampler_order == 1 &&
         trace->destroy_image_view_order == 2 &&
         trace->destroy_image_order == 3 && trace->free_memory_order == 4 &&
         trace->destroy_device_order == 5 &&
         trace->destroy_instance_order == 6;
#endif
}

std::unique_ptr<VulkanHost> VulkanHost::CreateSampledImageFailureTestHost(
    const SampledImageFailurePoint failure_point,
    SampledImageFailureTestTrace* const trace) noexcept {
  if (trace == nullptr) return nullptr;
#if defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  (void)failure_point;
  return nullptr;
#else
  g_image_failure_point = failure_point;
  g_image_failure_test_trace = trace;
  g_image_failure_cleanup_sequence = 0;

  auto impl = std::make_unique<Impl>();
  impl->report.status = HostStatus::kReady;
  impl->physical_device = DecodeHandle<VkPhysicalDevice>(201);
  impl->instance.handle_ = EncodeHandle(DecodeHandle<VkInstance>(202));
  impl->instance_dispatch.get_physical_device_memory_properties =
      &FailureTestGetMemoryProperties;
  impl->device_dispatch.create_image = &FailureTestCreateImage;
  impl->device_dispatch.destroy_image = &FailureTestDestroyImage;
  impl->device_dispatch.get_image_memory_requirements =
      &FailureTestGetImageMemoryRequirements;
  impl->device_dispatch.allocate_memory = &FailureTestAllocateMemory;
  impl->device_dispatch.free_memory = &FailureTestFreeMemory;
  impl->device_dispatch.bind_image_memory = &FailureTestBindImageMemory;
  impl->device_dispatch.create_image_view = &FailureTestCreateImageView;
  impl->device_dispatch.destroy_image_view = &FailureTestDestroyImageView;
  impl->device_dispatch.create_sampler = &FailureTestCreateSampler;
  impl->device_dispatch.destroy_sampler = &FailureTestDestroySampler;

  auto* lifetime = new (std::nothrow) SharedVulkanLifetime{};
  if (lifetime == nullptr) return nullptr;
  lifetime->instance = DecodeHandle<VkInstance>(202);
  lifetime->device = DecodeHandle<VkDevice>(203);
  lifetime->destroy_instance = &FailureTestDestroyInstance;
  lifetime->destroy_device = &FailureTestDestroyDevice;
  lifetime->destroy_image = &FailureTestDestroyImage;
  lifetime->destroy_image_view = &FailureTestDestroyImageView;
  lifetime->destroy_sampler = &FailureTestDestroySampler;
  lifetime->free_memory = &FailureTestFreeMemory;
  impl->device.handle_ = EncodeHandle(lifetime->device);
  impl->device.context_ = lifetime;
  impl->device.release_ = [](std::uint64_t, std::uint64_t,
                             void* context) noexcept {
    ReleaseVulkanLifetime(static_cast<SharedVulkanLifetime*>(context));
  };
  return std::unique_ptr<VulkanHost>(new VulkanHost(std::move(impl)));
#endif
}

bool VulkanHost::TestSampledImageFailureUnwind(
    const SampledImageFailurePoint failure_point,
    SampledImageFailureTestTrace* const trace) noexcept {
  if (trace == nullptr) return false;
  *trace = SampledImageFailureTestTrace{};
#if defined(PW_OFFICIAL_DENSE_VULKAN_STUB)
  (void)failure_point;
  return false;
#else
  auto host = CreateSampledImageFailureTestHost(failure_point, trace);
  if (host == nullptr) return false;
  auto* lifetime =
      static_cast<SharedVulkanLifetime*>(host->impl_->device.context_);
  if (failure_point == SampledImageFailurePoint::kRetainLifetime) {
    lifetime->references.store(UINT32_MAX, std::memory_order_relaxed);
  }

  SampledImageAllocation output;
  output.image_handle_ = 901;
  output.memory_handle_ = 902;
  output.image_view_handle_ = 903;
  output.sampler_handle_ = 904;
  output.width_ = 905;
  output.height_ = 906;
  output.array_layers_ = 907;
  output.format_ = SampledImageFormat::kR32Sfloat;
  output.sampler_kind_ = ImageSamplerKind::kDepthNearest;
  output.context_ = trace;
  output.release_ = &FailureTestReleaseSentinel;

  SampledImageSpec spec{};
  spec.width = 64;
  spec.height = 48;
  spec.array_layers = 3;
  spec.format = SampledImageFormat::kR8Unorm;
  spec.sampler = ImageSamplerKind::kGrayLinear;
  std::string detail;
  const bool created = host->CreateSampledImageAllocation(spec, &output, &detail);
  trace->detail_nonempty = !detail.empty();
  trace->output_unchanged =
      !created && output.opaque_image_handle() == 901 &&
      output.opaque_memory_handle() == 902 &&
      output.opaque_image_view_handle() == 903 &&
      output.opaque_sampler_handle() == 904 && output.width() == 905 &&
      output.height() == 906 && output.array_layers() == 907 &&
      output.format() == SampledImageFormat::kR32Sfloat &&
      output.sampler_kind() == ImageSamplerKind::kDepthNearest &&
      trace->sentinel_release_calls == 0;

  if (failure_point == SampledImageFailurePoint::kRetainLifetime) {
    lifetime->references.store(1, std::memory_order_relaxed);
  }
  host.reset();
  output.Reset();
  g_image_failure_test_trace = nullptr;
  return !created && trace->output_unchanged && trace->detail_nonempty &&
         trace->sentinel_release_calls == 1;
#endif
}
#endif

}  // namespace pocketworld::official_dense::vulkan
