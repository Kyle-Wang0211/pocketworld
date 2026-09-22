// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "device_probe.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <vulkan/vulkan.h>

#include "moltenvk_loader.h"
#include "../vulkan_shader_bundle/shader_bundle.h"

namespace pocketworld::official_dense::vulkan {
namespace {

constexpr std::uint32_t kWidth = 4;
constexpr std::uint32_t kHeight = 4;
constexpr std::size_t kPixelCount =
    static_cast<std::size_t>(kWidth) * static_cast<std::size_t>(kHeight);
constexpr std::int32_t kWindowRadius = 1;
constexpr std::int32_t kWindowStep = 1;
constexpr float kSigmaSpatial = 1.0F;
constexpr float kSigmaColor = 0.2F;
constexpr float kFloatTolerance = 5.0e-5F;

constexpr std::array<std::uint32_t, kPixelCount> kInput = {
    0U,   17U,  34U,  51U,  68U,  85U,  102U, 119U,
    136U, 153U, 170U, 187U, 204U, 221U, 238U, 255U,
};

struct FilterPushConstants {
  std::uint32_t width;
  std::uint32_t height;
  std::int32_t window_radius;
  std::int32_t window_step;
  float sigma_spatial;
  float sigma_color;
};

static_assert(sizeof(FilterPushConstants) == 24U);

template <typename Handle>
Handle DecodeHandle(const std::uint64_t encoded) noexcept {
  static_assert(sizeof(Handle) == sizeof(encoded));
  Handle handle{};
  std::memcpy(&handle, &encoded, sizeof(handle));
  return handle;
}

void SetResult(DeviceProbeResult* const result, const bool ok,
               const char* const stage, const HostStatus host_status,
               const float max_error) noexcept {
  result->ok = ok;
  const auto& identity = shader_bundle::FrozenShaderManifest()[0];
  std::snprintf(
      result->json.data(), result->json.size(),
      "{\"ok\":%s,\"stage\":\"%s\",\"host_status\":%u,"
      "\"width\":%u,\"height\":%u,\"shader\":\"%s\","
      "\"spirv_sha256\":\"%s\",\"max_abs_error\":%.9g}",
      ok ? "true" : "false", stage,
      static_cast<unsigned int>(host_status), kWidth, kHeight,
      identity.source_path, identity.spirv_sha256,
      static_cast<double>(max_error));
}

float SampleInput(const std::int32_t row, const std::int32_t column) noexcept {
  if (row < 0 || column < 0 || row >= static_cast<std::int32_t>(kHeight) ||
      column >= static_cast<std::int32_t>(kWidth)) {
    return 0.0F;
  }
  const auto index = static_cast<std::size_t>(row) * kWidth +
                     static_cast<std::size_t>(column);
  return static_cast<float>(kInput[index]) / 255.0F;
}

void CpuReferenceFilter(std::array<std::uint32_t, kPixelCount>* const output,
                        std::array<float, kPixelCount>* const sum,
                        std::array<float, kPixelCount>* const squared_sum)
    noexcept {
  const float spatial_normalization =
      1.0F / (2.0F * kSigmaSpatial * kSigmaSpatial);
  const float color_normalization =
      1.0F / (2.0F * kSigmaColor * kSigmaColor);
  for (std::int32_t row = 0; row < static_cast<std::int32_t>(kHeight); ++row) {
    for (std::int32_t column = 0;
         column < static_cast<std::int32_t>(kWidth); ++column) {
      const float center = SampleInput(row, column);
      float color_sum = 0.0F;
      float color_squared_sum = 0.0F;
      float bilateral_weight_sum = 0.0F;
      for (std::int32_t window_row = -kWindowRadius;
           window_row <= kWindowRadius; window_row += kWindowStep) {
        for (std::int32_t window_column = -kWindowRadius;
             window_column <= kWindowRadius;
             window_column += kWindowStep) {
          const float color =
              SampleInput(row + window_row, column + window_column);
          const auto spatial_squared = static_cast<float>(
              window_row * window_row + window_column * window_column);
          const float color_distance = center - color;
          const float weight = std::exp(
              -spatial_squared * spatial_normalization -
              color_distance * color_distance * color_normalization);
          color_sum += weight * color;
          color_squared_sum += weight * color * color;
          bilateral_weight_sum += weight;
        }
      }
      const auto index = static_cast<std::size_t>(row) * kWidth +
                         static_cast<std::size_t>(column);
      (*output)[index] = static_cast<std::uint32_t>(255.0F * center);
      (*sum)[index] = color_sum / bilateral_weight_sum;
      (*squared_sum)[index] = color_squared_sum / bilateral_weight_sum;
    }
  }
}

const runtime::ShaderBinary* ReferenceShader() noexcept {
  const auto& bundle = shader_bundle::CanonicalShaderBundle();
  for (const auto& binary : bundle.binaries) {
    if (binary.kind == runtime::PipelineKind::kReferenceFilter) return &binary;
  }
  return nullptr;
}

}  // namespace

DeviceProbeResult RunMoltenVkDeviceProbe() noexcept {
  DeviceProbeResult result;
  const ExternalLoader loader = MoltenVkExternalLoader();
  const CreateOptions options{loader};
  const CapabilityReport probed = VulkanHost::Probe(options);
  if (!probed.ready()) {
    SetResult(&result, false, "host_probe", probed.status, 0.0F);
    return result;
  }

  CapabilityReport created;
  std::unique_ptr<VulkanHost> host = VulkanHost::Create(options, &created);
  if (host == nullptr || !created.ready()) {
    SetResult(&result, false, "host_create", created.status, 0.0F);
    return result;
  }
  const NativeHandles native = host->native_handles();
  if (!native.valid()) {
    SetResult(&result, false, "native_handles", created.status, 0.0F);
    return result;
  }

  constexpr std::uint64_t kUintBytes =
      static_cast<std::uint64_t>(kPixelCount * sizeof(std::uint32_t));
  constexpr std::uint64_t kFloatBytes =
      static_cast<std::uint64_t>(kPixelCount * sizeof(float));
  BufferAllocation input;
  BufferAllocation output;
  BufferAllocation sum;
  BufferAllocation squared_sum;
  const BufferAllocationSpec input_spec{kUintBytes, kBufferUsageStorage,
                                         BufferMemoryClass::kHostUpload};
  const BufferAllocationSpec uint_readback_spec{
      kUintBytes, kBufferUsageStorage, BufferMemoryClass::kHostReadback};
  const BufferAllocationSpec float_readback_spec{
      kFloatBytes, kBufferUsageStorage, BufferMemoryClass::kHostReadback};
  if (!host->CreateBufferAllocation(input_spec, &input, nullptr) ||
      !host->CreateBufferAllocation(uint_readback_spec, &output, nullptr) ||
      !host->CreateBufferAllocation(float_readback_spec, &sum, nullptr) ||
      !host->CreateBufferAllocation(float_readback_spec, &squared_sum,
                                    nullptr)) {
    SetResult(&result, false, "buffer_allocation", created.status, 0.0F);
    return result;
  }
  std::memcpy(input.mapped_pointer(), kInput.data(),
              static_cast<std::size_t>(kUintBytes));
  std::memset(output.mapped_pointer(), 0, static_cast<std::size_t>(kUintBytes));
  std::memset(sum.mapped_pointer(), 0, static_cast<std::size_t>(kFloatBytes));
  std::memset(squared_sum.mapped_pointer(), 0,
              static_cast<std::size_t>(kFloatBytes));

  const VkDevice device = DecodeHandle<VkDevice>(native.device);
  const VkQueue queue = DecodeHandle<VkQueue>(native.queue);
  const VkCommandBuffer command_buffer =
      DecodeHandle<VkCommandBuffer>(native.command_buffer);
  const std::array<VkBuffer, 4> buffers = {
      DecodeHandle<VkBuffer>(input.opaque_buffer_handle()),
      DecodeHandle<VkBuffer>(output.opaque_buffer_handle()),
      DecodeHandle<VkBuffer>(sum.opaque_buffer_handle()),
      DecodeHandle<VkBuffer>(squared_sum.opaque_buffer_handle()),
  };

  VkDescriptorSetLayout descriptor_layout = VK_NULL_HANDLE;
  VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
  VkShaderModule shader_module = VK_NULL_HANDLE;
  VkPipeline pipeline = VK_NULL_HANDLE;
  VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
  auto cleanup = [&]() noexcept {
    if (descriptor_pool != VK_NULL_HANDLE)
      vkDestroyDescriptorPool(device, descriptor_pool, nullptr);
    if (pipeline != VK_NULL_HANDLE) vkDestroyPipeline(device, pipeline, nullptr);
    if (shader_module != VK_NULL_HANDLE)
      vkDestroyShaderModule(device, shader_module, nullptr);
    if (pipeline_layout != VK_NULL_HANDLE)
      vkDestroyPipelineLayout(device, pipeline_layout, nullptr);
    if (descriptor_layout != VK_NULL_HANDLE)
      vkDestroyDescriptorSetLayout(device, descriptor_layout, nullptr);
  };
  auto fail = [&](const char* const stage) noexcept {
    cleanup();
    SetResult(&result, false, stage, created.status, 0.0F);
    return result;
  };

  std::array<VkDescriptorSetLayoutBinding, 4> layout_bindings{};
  for (std::uint32_t index = 0; index < layout_bindings.size(); ++index) {
    layout_bindings[index].binding = index;
    layout_bindings[index].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    layout_bindings[index].descriptorCount = 1;
    layout_bindings[index].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
  }
  VkDescriptorSetLayoutCreateInfo descriptor_layout_info{};
  descriptor_layout_info.sType =
      VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  descriptor_layout_info.bindingCount =
      static_cast<std::uint32_t>(layout_bindings.size());
  descriptor_layout_info.pBindings = layout_bindings.data();
  if (vkCreateDescriptorSetLayout(device, &descriptor_layout_info, nullptr,
                                  &descriptor_layout) != VK_SUCCESS) {
    return fail("descriptor_layout");
  }

  const VkPushConstantRange push_range{VK_SHADER_STAGE_COMPUTE_BIT, 0,
                                       sizeof(FilterPushConstants)};
  VkPipelineLayoutCreateInfo pipeline_layout_info{};
  pipeline_layout_info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  pipeline_layout_info.setLayoutCount = 1;
  pipeline_layout_info.pSetLayouts = &descriptor_layout;
  pipeline_layout_info.pushConstantRangeCount = 1;
  pipeline_layout_info.pPushConstantRanges = &push_range;
  if (vkCreatePipelineLayout(device, &pipeline_layout_info, nullptr,
                             &pipeline_layout) != VK_SUCCESS) {
    return fail("pipeline_layout");
  }

  const runtime::ShaderBinary* const reference_shader = ReferenceShader();
  if (reference_shader == nullptr || reference_shader->words == nullptr ||
      reference_shader->word_count == 0U) {
    return fail("frozen_reference_shader");
  }
  VkShaderModuleCreateInfo shader_info{};
  shader_info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
  shader_info.codeSize = reference_shader->word_count * sizeof(std::uint32_t);
  shader_info.pCode = reference_shader->words;
  if (vkCreateShaderModule(device, &shader_info, nullptr, &shader_module) !=
      VK_SUCCESS) {
    return fail("shader_module");
  }
  VkPipelineShaderStageCreateInfo stage_info{};
  stage_info.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  stage_info.stage = VK_SHADER_STAGE_COMPUTE_BIT;
  stage_info.module = shader_module;
  stage_info.pName = "main";
  VkComputePipelineCreateInfo pipeline_info{};
  pipeline_info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
  pipeline_info.stage = stage_info;
  pipeline_info.layout = pipeline_layout;
  if (vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info,
                               nullptr, &pipeline) != VK_SUCCESS) {
    return fail("compute_pipeline");
  }

  const VkDescriptorPoolSize pool_size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4};
  VkDescriptorPoolCreateInfo pool_info{};
  pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  pool_info.maxSets = 1;
  pool_info.poolSizeCount = 1;
  pool_info.pPoolSizes = &pool_size;
  if (vkCreateDescriptorPool(device, &pool_info, nullptr, &descriptor_pool) !=
      VK_SUCCESS) {
    return fail("descriptor_pool");
  }
  VkDescriptorSetAllocateInfo set_info{};
  set_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  set_info.descriptorPool = descriptor_pool;
  set_info.descriptorSetCount = 1;
  set_info.pSetLayouts = &descriptor_layout;
  VkDescriptorSet descriptor_set = VK_NULL_HANDLE;
  if (vkAllocateDescriptorSets(device, &set_info, &descriptor_set) !=
      VK_SUCCESS) {
    return fail("descriptor_set");
  }

  std::array<VkDescriptorBufferInfo, 4> buffer_infos{};
  std::array<VkWriteDescriptorSet, 4> writes{};
  for (std::uint32_t index = 0; index < writes.size(); ++index) {
    buffer_infos[index].buffer = buffers[index];
    buffer_infos[index].offset = 0;
    buffer_infos[index].range =
        index < 2U ? static_cast<VkDeviceSize>(kUintBytes)
                   : static_cast<VkDeviceSize>(kFloatBytes);
    writes[index].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[index].dstSet = descriptor_set;
    writes[index].dstBinding = index;
    writes[index].descriptorCount = 1;
    writes[index].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    writes[index].pBufferInfo = &buffer_infos[index];
  }
  vkUpdateDescriptorSets(device, static_cast<std::uint32_t>(writes.size()),
                         writes.data(), 0, nullptr);

  if (vkResetCommandBuffer(command_buffer, 0) != VK_SUCCESS) {
    return fail("command_reset");
  }
  VkCommandBufferBeginInfo begin_info{};
  begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  if (vkBeginCommandBuffer(command_buffer, &begin_info) != VK_SUCCESS) {
    return fail("command_begin");
  }
  const FilterPushConstants push_constants{kWidth, kHeight, kWindowRadius,
                                            kWindowStep, kSigmaSpatial,
                                            kSigmaColor};
  vkCmdBindPipeline(command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
  vkCmdBindDescriptorSets(command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                          pipeline_layout, 0, 1, &descriptor_set, 0, nullptr);
  vkCmdPushConstants(command_buffer, pipeline_layout,
                     VK_SHADER_STAGE_COMPUTE_BIT, 0,
                     sizeof(push_constants), &push_constants);
  vkCmdDispatch(command_buffer, 1, 1, 1);
  VkMemoryBarrier host_read_barrier{};
  host_read_barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
  host_read_barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
  host_read_barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
  vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                       VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host_read_barrier, 0,
                       nullptr, 0, nullptr);
  if (vkEndCommandBuffer(command_buffer) != VK_SUCCESS) {
    return fail("command_end");
  }
  VkSubmitInfo submit_info{};
  submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
  submit_info.commandBufferCount = 1;
  submit_info.pCommandBuffers = &command_buffer;
  if (vkQueueSubmit(queue, 1, &submit_info, VK_NULL_HANDLE) != VK_SUCCESS ||
      vkQueueWaitIdle(queue) != VK_SUCCESS) {
    return fail("queue_submit");
  }

  std::array<std::uint32_t, kPixelCount> gpu_output{};
  std::array<float, kPixelCount> gpu_sum{};
  std::array<float, kPixelCount> gpu_squared_sum{};
  std::memcpy(gpu_output.data(), output.mapped_pointer(),
              static_cast<std::size_t>(kUintBytes));
  std::memcpy(gpu_sum.data(), sum.mapped_pointer(),
              static_cast<std::size_t>(kFloatBytes));
  std::memcpy(gpu_squared_sum.data(), squared_sum.mapped_pointer(),
              static_cast<std::size_t>(kFloatBytes));
  std::array<std::uint32_t, kPixelCount> cpu_output{};
  std::array<float, kPixelCount> cpu_sum{};
  std::array<float, kPixelCount> cpu_squared_sum{};
  CpuReferenceFilter(&cpu_output, &cpu_sum, &cpu_squared_sum);

  float max_error = 0.0F;
  bool matches = true;
  for (std::size_t index = 0; index < kPixelCount; ++index) {
    matches = matches && gpu_output[index] == cpu_output[index];
    max_error = std::max(max_error, std::fabs(gpu_sum[index] - cpu_sum[index]));
    max_error = std::max(
        max_error,
        std::fabs(gpu_squared_sum[index] - cpu_squared_sum[index]));
  }
  matches = matches && std::isfinite(max_error) &&
            max_error <= kFloatTolerance;
  cleanup();
  SetResult(&result, matches, matches ? "complete" : "cpu_mismatch",
            created.status, max_error);
  return result;
}

}  // namespace pocketworld::official_dense::vulkan
