import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _vulkanHeadersPath() {
  final override = Platform.environment['PW_VULKAN_HEADERS'];
  final candidates = <String>[
    if (override != null && override.isNotEmpty) override,
    'vendor/official_dense/third_party/vulkan-headers/include',
    '../Aether3D-cross/aether_cpp/third_party/dawn/third_party/'
        'vulkan-headers/src/include',
  ];
  for (final candidate in candidates) {
    if (File('$candidate/vulkan/vulkan.h').existsSync()) return candidate;
  }
  throw StateError(
    'Vulkan headers are required for strict host tests. Set '
    'PW_VULKAN_HEADERS to an include directory containing vulkan/vulkan.h, '
    'or provide one of the repository/toolchain-relative candidates: '
    '${candidates.join(', ')}',
  );
}

void main() {
  const root = 'vendor/official_dense/vulkan_host';

  test('host backend is fail-closed and binds the frozen PatchMatch ABI', () {
    final header = File('$root/vulkan_host.h').readAsStringSync();
    final source = File('$root/vulkan_host.cc').readAsStringSync();

    expect(header, contains('../include/official_dense/patch_match_abi.h'));
    expect(header, contains('class VulkanHost'));
    expect(header, contains('class Instance'));
    expect(header, contains('class Device'));
    expect(header, contains('class Buffer'));
    expect(header, contains('class DescriptorSet'));
    expect(header, contains('class ComputePipeline'));
    expect(header, contains('class CommandPool'));
    expect(header, contains('class CommandBuffer'));
    expect(header, contains('struct NativeHandles'));
    expect(header, contains('NativeHandles native_handles() const noexcept'));
    expect(header, contains('ExternalLoader'));
    expect(header, contains('CapabilityReport Probe'));
    expect(source, contains('kBindingCount'));
    expect(source, contains('sizeof(PatchPC)'));
    expect(source, contains('kRequiredMaxComputeInvocations = 128'));
    expect(source, contains('kRequiredMaxComputeSizeX = 32'));
    expect(source, contains('kRequiredMaxComputeSizeY = 8'));
    expect(source, contains('kRequiredSampledImages = 2'));
    expect(source, contains('kRequiredStorageBuffers = kBindingCount'));
    expect(source, contains('VK_FORMAT_R32_SFLOAT'));
    expect(source, contains('VK_FORMAT_R8_UNORM'));
    expect(source, isNot(contains('VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT')));
    expect(source, isNot(contains('shaderStorageImageExtendedFormats')));
    expect(source, isNot(contains('maxPerStageDescriptorStorageImages <')));
    expect(source, contains('PFN_vkAllocateCommandBuffers'));
    expect(source, contains('PFN_vkFreeCommandBuffers'));
    expect(source, contains('VK_COMMAND_BUFFER_LEVEL_PRIMARY'));
    expect(source, contains('vkAllocateCommandBuffers'));
    expect(source, contains('vkFreeCommandBuffers'));
  });

  test('Apple and Harmony require injection while Android uses its loader', () {
    final source = File('$root/vulkan_host.cc').readAsStringSync();

    expect(source, contains('__ANDROID__'));
    expect(source, contains('vkGetInstanceProcAddr'));
    expect(source, contains('__APPLE__'));
    expect(source, contains('PW_OFFICIAL_DENSE_HARMONY'));
    expect(source, contains('kExternalLoaderRequired'));
    expect(source, contains('kVulkanUnavailable'));
  });

  test('module contains no Swift and owns no public build configuration', () {
    final files = Directory(root).listSync(recursive: true).whereType<File>();
    expect(
      files.where((file) => file.path.toLowerCase().endsWith('.swift')),
      isEmpty,
    );
    expect(File('$root/CMakeLists.txt').existsSync(), isFalse);
  });

  test('stub backend compiles and fails closed without a loader', () {
    final temp = Directory.systemTemp.createTempSync('pw-vulkan-host-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final harness = File('${temp.path}/host_state_test.cc');
    final executable = '${temp.path}/host_state_test';
    harness.writeAsStringSync(r'''
#include "vulkan_host.h"

using namespace pocketworld::official_dense::vulkan;

int main() {
  CreateOptions options;
  const CapabilityReport probe = VulkanHost::Probe(options);
  if (probe.ready()) return 1;
  if (probe.status != HostStatus::kExternalLoaderRequired &&
      probe.status != HostStatus::kVulkanUnavailable) return 2;
  CapabilityReport create_report;
  if (VulkanHost::Create(options, &create_report) != nullptr) return 3;
  NativeHandles handles;
  if (handles.valid()) return 4;
  if (handles.instance != 0 || handles.device != 0 || handles.queue != 0 ||
      handles.command_buffer != 0) return 5;
  Buffer original;
  Buffer moved(std::move(original));
  if (original.valid() || moved.valid()) return 6;
  moved.Reset();
  CommandBuffer command_buffer;
  CommandBuffer moved_command_buffer(std::move(command_buffer));
  if (command_buffer.valid() || moved_command_buffer.valid()) return 7;
  moved_command_buffer.Reset();
  return 0;
}
''');
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-DPW_OFFICIAL_DENSE_VULKAN_STUB=1',
      '-I$root',
      '-Ivendor/official_dense',
      harness.path,
      '$root/vulkan_host.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
  });

  test(
    'portable memory selector and buffer allocation contract are deterministic',
    () {
      final header = File('$root/vulkan_host.h').readAsStringSync();
      final source = File('$root/vulkan_host.cc').readAsStringSync();

      expect(header, contains('struct BufferAllocationSpec'));
      expect(header, contains('enum class BufferMemoryClass'));
      expect(header, contains('class BufferAllocation'));
      expect(header, contains('SelectMemoryType'));
      expect(header, contains('CreateBufferAllocation'));
      expect(header, contains('mapped_pointer() const noexcept'));
      expect(header, contains('host_coherent() const noexcept'));
      expect(source, contains('PFN_vkCreateBuffer'));
      expect(source, contains('PFN_vkGetBufferMemoryRequirements'));
      expect(source, contains('PFN_vkGetPhysicalDeviceMemoryProperties'));
      expect(source, contains('PFN_vkAllocateMemory'));
      expect(source, contains('PFN_vkBindBufferMemory'));
      expect(source, contains('PFN_vkMapMemory'));
      expect(source, contains('PFN_vkUnmapMemory'));
      expect(source, contains('PFN_vkDestroyBuffer'));
      expect(source, contains('PFN_vkFreeMemory'));
    },
  );

  test(
    'sampled 2D-array image resource contract is fixed and SDK-independent',
    () {
      final header = File('$root/vulkan_host.h').readAsStringSync();
      final source = File('$root/vulkan_host.cc').readAsStringSync();

      expect(header, contains('enum class SampledImageFormat'));
      expect(header, contains('kR8Unorm'));
      expect(header, contains('kR32Sfloat'));
      expect(header, contains('enum class ImageSamplerKind'));
      expect(header, contains('kGrayLinear'));
      expect(header, contains('kDepthNearest'));
      expect(header, contains('struct SampledImageSpec'));
      expect(header, contains('class SampledImageAllocation'));
      expect(header, contains('CreateSampledImageAllocation'));
      expect(header, contains('opaque_image_handle() const noexcept'));
      expect(header, contains('opaque_memory_handle() const noexcept'));
      expect(header, contains('opaque_image_view_handle() const noexcept'));
      expect(header, contains('opaque_sampler_handle() const noexcept'));
      expect(source, contains('PFN_vkCreateImage'));
      expect(source, contains('PFN_vkGetImageMemoryRequirements'));
      expect(source, contains('PFN_vkBindImageMemory'));
      expect(source, contains('PFN_vkCreateImageView'));
      expect(source, contains('PFN_vkCreateSampler'));
      expect(source, contains('VK_IMAGE_USAGE_TRANSFER_DST_BIT'));
      expect(source, contains('VK_IMAGE_USAGE_SAMPLED_BIT'));
      expect(source, contains('VK_IMAGE_VIEW_TYPE_2D_ARRAY'));
      expect(source, contains('VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER'));
      expect(source, contains('VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK'));
      expect(source, contains('VK_FILTER_LINEAR'));
      expect(source, contains('VK_FILTER_NEAREST'));
      expect(
        source,
        contains('VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT'),
      );
    },
  );

  test('allocation failure detail writes cannot escape noexcept', () {
    final source = File('$root/vulkan_host.cc').readAsStringSync();
    expect(source, isNot(contains('*detail = message')));
    expect(
      RegExp(
        r'SetDetailNoexcept\(detail, message\);',
      ).allMatches(source).length,
      2,
    );

    final temp = Directory.systemTemp.createTempSync('pw-vulkan-detail-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final harness = File('${temp.path}/detail_noexcept_test.cc');
    final executable = '${temp.path}/detail_noexcept_test';
    harness.writeAsStringSync(r'''
#include "vulkan_host.h"

using namespace pocketworld::official_dense::vulkan;

int main() {
  return VulkanHost::TestDetailAssignmentFailureIsContained() ? 0 : 1;
}
''');
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-Wconversion',
      '-Wsign-conversion',
      '-DPW_OFFICIAL_DENSE_VULKAN_STUB=1',
      '-DPW_OFFICIAL_DENSE_VULKAN_TESTING=1',
      '-I$root',
      '-Ivendor/official_dense',
      harness.path,
      '$root/vulkan_host.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
  });

  test(
    'sampled image allocation is move-only and invalid specs preserve output',
    () {
      final temp = Directory.systemTemp.createTempSync('pw-vulkan-image-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final harness = File('${temp.path}/sampled_image_contract_test.cc');
      final executable = '${temp.path}/sampled_image_contract_test';
      harness.writeAsStringSync(r'''
#include "vulkan_host.h"
#include <type_traits>

using namespace pocketworld::official_dense::vulkan;

int main() {
  static_assert(!std::is_copy_constructible_v<SampledImageAllocation>);
  static_assert(!std::is_copy_assignable_v<SampledImageAllocation>);
  static_assert(std::is_move_constructible_v<SampledImageAllocation>);
  static_assert(std::is_move_assignable_v<SampledImageAllocation>);

  SampledImageAllocation output;
  SampledImageSpec invalid{};
  invalid.width = 0;
  invalid.height = 8;
  invalid.array_layers = 2;
  invalid.format = SampledImageFormat::kR8Unorm;
  invalid.sampler = ImageSamplerKind::kGrayLinear;
  VulkanHost* host = nullptr;
  if (host != nullptr) return 1;
  if (output.valid() || output.opaque_image_handle() != 0 ||
      output.opaque_memory_handle() != 0 ||
      output.opaque_image_view_handle() != 0 ||
      output.opaque_sampler_handle() != 0) return 2;
  SampledImageAllocation moved(std::move(output));
  if (output.valid() || moved.valid()) return 3;
  return 0;
}
''');
      final compile = Process.runSync('clang++', <String>[
        '-std=c++17',
        '-Wall',
        '-Wextra',
        '-Werror',
        '-DPW_OFFICIAL_DENSE_VULKAN_STUB=1',
        '-I$root',
        '-Ivendor/official_dense',
        harness.path,
        '$root/vulkan_host.cc',
        '-o',
        executable,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final run = Process.runSync(executable, const <String>[]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
    },
  );

  test(
    'sampled image can outlive host and unwinds children before parents',
    () {
      final dawnHeaders = _vulkanHeadersPath();
      final temp = Directory.systemTemp.createTempSync('pw-vulkan-image-life-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final harness = File('${temp.path}/image_outlives_host_test.cc');
      final executable = '${temp.path}/image_outlives_host_test';
      harness.writeAsStringSync(r'''
#include "vulkan_host.h"

using namespace pocketworld::official_dense::vulkan;

int main() {
  ImageLifetimeTestTrace trace{};
  if (!VulkanHost::TestImageOutlivesHost(&trace)) return 1;
  if (trace.destroy_sampler_order != 1 ||
      trace.destroy_image_view_order != 2 ||
      trace.destroy_image_order != 3 ||
      trace.free_memory_order != 4 ||
      trace.destroy_device_order != 5 ||
      trace.destroy_instance_order != 6) return 2;
  return 0;
}
''');
      final compile = Process.runSync('clang++', <String>[
        '-std=c++17',
        '-Wall',
        '-Wextra',
        '-Werror',
        '-Wconversion',
        '-Wsign-conversion',
        '-DPW_OFFICIAL_DENSE_VULKAN_TESTING=1',
        '-DVK_NO_PROTOTYPES=1',
        '-I$dawnHeaders',
        '-I$root',
        '-Ivendor/official_dense',
        harness.path,
        '$root/vulkan_host.cc',
        '-o',
        executable,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final run = Process.runSync(executable, const <String>[]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
    },
  );

  test(
    'every sampled-image failure point unwinds and preserves non-empty output',
    () {
      final dawnHeaders = _vulkanHeadersPath();
      final temp = Directory.systemTemp.createTempSync('pw-vulkan-image-fail-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final harness = File('${temp.path}/image_failure_unwind_test.cc');
      final executable = '${temp.path}/image_failure_unwind_test';
      harness.writeAsStringSync(r'''
#include "vulkan_host.h"

using namespace pocketworld::official_dense::vulkan;

struct Expected {
  SampledImageFailurePoint point;
  std::uint32_t allocate_calls;
  std::uint32_t bind_calls;
  std::uint32_t view_calls;
  std::uint32_t sampler_calls;
  std::uint32_t destroy_sampler;
  std::uint32_t destroy_view;
  std::uint32_t destroy_image;
  std::uint32_t free_memory;
  std::uint32_t sampler_order;
  std::uint32_t view_order;
  std::uint32_t image_order;
  std::uint32_t memory_order;
};

int main() {
  const Expected cases[] = {
      {SampledImageFailurePoint::kCreateImage, 0, 0, 0, 0, 0, 0, 0, 0,
       0, 0, 0, 0},
      {SampledImageFailurePoint::kInvalidMemoryRequirements, 0, 0, 0, 0,
       0, 0, 1, 0, 0, 0, 1, 0},
      {SampledImageFailurePoint::kMemoryTypeSelection, 0, 0, 0, 0,
       0, 0, 1, 0, 0, 0, 1, 0},
      {SampledImageFailurePoint::kAllocateMemory, 1, 0, 0, 0,
       0, 0, 1, 0, 0, 0, 1, 0},
      {SampledImageFailurePoint::kBindImageMemory, 1, 1, 0, 0,
       0, 0, 1, 1, 0, 0, 1, 2},
      {SampledImageFailurePoint::kCreateImageView, 1, 1, 1, 0,
       0, 0, 1, 1, 0, 0, 1, 2},
      {SampledImageFailurePoint::kCreateSampler, 1, 1, 1, 1,
       0, 1, 1, 1, 0, 1, 2, 3},
      {SampledImageFailurePoint::kRetainLifetime, 1, 1, 1, 1,
       1, 1, 1, 1, 1, 2, 3, 4},
  };
  for (std::uint32_t index = 0; index < 8; ++index) {
    const Expected& expected = cases[index];
    SampledImageFailureTestTrace trace{};
    if (!VulkanHost::TestSampledImageFailureUnwind(expected.point, &trace)) {
      return static_cast<int>(10 + index);
    }
    if (trace.create_image_calls != 1 ||
        trace.allocate_memory_calls != expected.allocate_calls ||
        trace.bind_image_memory_calls != expected.bind_calls ||
        trace.create_image_view_calls != expected.view_calls ||
        trace.create_sampler_calls != expected.sampler_calls ||
        trace.destroy_sampler_calls != expected.destroy_sampler ||
        trace.destroy_image_view_calls != expected.destroy_view ||
        trace.destroy_image_calls != expected.destroy_image ||
        trace.free_memory_calls != expected.free_memory ||
        trace.destroy_sampler_order != expected.sampler_order ||
        trace.destroy_image_view_order != expected.view_order ||
        trace.destroy_image_order != expected.image_order ||
        trace.free_memory_order != expected.memory_order ||
        !trace.output_unchanged || !trace.detail_nonempty ||
        trace.sentinel_release_calls != 1) {
      return static_cast<int>(30 + index);
    }
  }
  return 0;
}
''');
      final compile = Process.runSync('clang++', <String>[
        '-std=c++17',
        '-Wall',
        '-Wextra',
        '-Werror',
        '-Wconversion',
        '-Wsign-conversion',
        '-DPW_OFFICIAL_DENSE_VULKAN_TESTING=1',
        '-DVK_NO_PROTOTYPES=1',
        '-I$dawnHeaders',
        '-I$root',
        '-Ivendor/official_dense',
        harness.path,
        '$root/vulkan_host.cc',
        '-o',
        executable,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final run = Process.runSync(executable, const <String>[]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
    },
  );

  test(
    'pure memory selector and move-only allocation pass strict C++ tests',
    () {
      final temp = Directory.systemTemp.createTempSync('pw-vulkan-memory-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final harness = File('${temp.path}/memory_selector_test.cc');
      final executable = '${temp.path}/memory_selector_test';
      harness.writeAsStringSync(r'''
#include "vulkan_host.h"
#include <type_traits>

using namespace pocketworld::official_dense::vulkan;

int main() {
  static_assert(!std::is_copy_constructible_v<BufferAllocation>);
  static_assert(!std::is_copy_assignable_v<BufferAllocation>);
  static_assert(std::is_move_constructible_v<BufferAllocation>);
  static_assert(std::is_move_assignable_v<BufferAllocation>);

  MemoryTypeTable table{};
  table.count = 5;
  table.types[0].property_flags = kMemoryPropertyDeviceLocal;
  table.types[1].property_flags =
      kMemoryPropertyHostVisible | kMemoryPropertyHostCoherent;
  table.types[2].property_flags = kMemoryPropertyHostVisible;
  table.types[3].property_flags = kMemoryPropertyHostVisible |
      kMemoryPropertyHostCoherent | kMemoryPropertyHostCached;
  table.types[4].property_flags = kMemoryPropertyDeviceLocal |
      kMemoryPropertyHostVisible | kMemoryPropertyHostCoherent;

  MemoryTypeSelection selection{};
  if (!SelectMemoryType(0x1fu, table, BufferMemoryClass::kDeviceLocal,
                        &selection)) return 1;
  if (selection.index != 0 || selection.host_coherent) return 2;
  if (!SelectMemoryType(0x1fu, table, BufferMemoryClass::kHostUpload,
                        &selection)) return 3;
  if (selection.index != 1 || !selection.host_coherent) return 4;
  if (!SelectMemoryType(0x1fu, table, BufferMemoryClass::kHostReadback,
                        &selection)) return 5;
  if (selection.index != 3 || !selection.host_coherent) return 6;
  if (SelectMemoryType(1u << 2, table, BufferMemoryClass::kHostUpload,
                       &selection)) return 7;
  const MemoryTypeSelection unchanged = selection;
  if (SelectMemoryType(0, table, BufferMemoryClass::kDeviceLocal,
                       &selection)) return 8;
  if (selection.index != unchanged.index ||
      selection.host_coherent != unchanged.host_coherent) return 9;

  BufferAllocationSpec spec{};
  spec.byte_count = 4096;
  spec.usage_flags = kBufferUsageStorage | kBufferUsageTransferDst;
  spec.memory_class = BufferMemoryClass::kDeviceLocal;
  BufferAllocation allocation;
  if (allocation.valid() || allocation.byte_count() != 0 ||
      allocation.mapped_pointer() != nullptr || allocation.host_coherent()) {
    return 10;
  }
  BufferAllocation moved(std::move(allocation));
  if (allocation.valid() || moved.valid()) return 11;
  return 0;
}
''');
      final compile = Process.runSync('clang++', <String>[
        '-std=c++17',
        '-Wall',
        '-Wextra',
        '-Werror',
        '-DPW_OFFICIAL_DENSE_VULKAN_STUB=1',
        '-I$root',
        '-Ivendor/official_dense',
        harness.path,
        '$root/vulkan_host.cc',
        '-o',
        executable,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final run = Process.runSync(executable, const <String>[]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
    },
  );

  test(
    'allocations retain device and instance lifetime until final release',
    () {
      final source = File('$root/vulkan_host.cc').readAsStringSync();

      expect(source, contains('struct SharedVulkanLifetime'));
      expect(source, contains('std::atomic<std::uint32_t> references{1}'));
      expect(source, contains('RetainVulkanLifetime(shared_lifetime)'));
      expect(source, contains('ReleaseVulkanLifetime(lifetime)'));
      expect(source, contains('impl->device.context_ = shared_lifetime'));
      expect(source, contains('impl->instance.release_ = nullptr'));
      expect(source, isNot(contains('BufferAllocationReleaseContext')));
      final allocationRelease = source.indexOf(
        'lifetime->destroy_buffer(lifetime->device',
      );
      final memoryRelease = source.indexOf(
        'lifetime->free_memory(lifetime->device',
      );
      final parentRelease = source.indexOf(
        'ReleaseVulkanLifetime(lifetime)',
        allocationRelease,
      );
      expect(allocationRelease, greaterThanOrEqualTo(0));
      expect(memoryRelease, greaterThan(allocationRelease));
      expect(parentRelease, greaterThan(memoryRelease));
      final deviceRelease = source.indexOf(
        'lifetime->destroy_device(lifetime->device',
      );
      final instanceRelease = source.indexOf(
        'lifetime->destroy_instance(lifetime->instance',
      );
      expect(deviceRelease, greaterThanOrEqualTo(0));
      expect(instanceRelease, greaterThan(deviceRelease));
    },
  );

  test(
    'allocation can outlive host in the real Vulkan lifetime implementation',
    () {
      final dawnHeaders = _vulkanHeadersPath();
      expect(File('$dawnHeaders/vulkan/vulkan.h').existsSync(), isTrue);
      final temp = Directory.systemTemp.createTempSync('pw-vulkan-lifetime-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final harness = File('${temp.path}/allocation_outlives_host_test.cc');
      final executable = '${temp.path}/allocation_outlives_host_test';
      harness.writeAsStringSync(r'''
#include "vulkan_host.h"

using namespace pocketworld::official_dense::vulkan;

int main() {
  AllocationLifetimeTestTrace trace{};
  if (!VulkanHost::TestAllocationOutlivesHost(&trace)) return 1;
  if (trace.unmap_order != 1 || trace.destroy_buffer_order != 2 ||
      trace.free_memory_order != 3 || trace.destroy_device_order != 4 ||
      trace.destroy_instance_order != 5) return 2;
  return 0;
}
''');
      final compile = Process.runSync('clang++', <String>[
        '-std=c++17',
        '-Wall',
        '-Wextra',
        '-Werror',
        '-Wconversion',
        '-Wsign-conversion',
        '-DPW_OFFICIAL_DENSE_VULKAN_TESTING=1',
        '-DVK_NO_PROTOTYPES=1',
        '-I$dawnHeaders',
        '-I$root',
        '-Ivendor/official_dense',
        harness.path,
        '$root/vulkan_host.cc',
        '-o',
        executable,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final run = Process.runSync(executable, const <String>[]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
    },
  );

  test(
    'command buffer is owned after its pool and freed before pool teardown',
    () {
      final header = File('$root/vulkan_host.h').readAsStringSync();
      final source = File('$root/vulkan_host.cc').readAsStringSync();

      expect(
        header,
        contains('const CommandBuffer& command_buffer() const noexcept'),
      );
      expect(
        source,
        contains('CommandPool command_pool;\n  CommandBuffer command_buffer;'),
      );
      expect(
        source,
        contains(
          'command_buffer_allocate_info.level =\n      VK_COMMAND_BUFFER_LEVEL_PRIMARY',
        ),
      );
      expect(
        source,
        contains('command_buffer_allocate_info.commandBufferCount = 1'),
      );
      expect(source, contains('free_command_buffers'));
      expect(source, contains('impl_->instance.handle_'));
      expect(source, contains('impl_->device.handle_'));
      expect(source, contains('impl_->queue.handle_'));
      expect(source, contains('impl_->command_buffer.handle_'));
    },
  );

  test('canonical PatchMatch dispatch plan passes its C++ state machine', () {
    final temp = Directory.systemTemp.createTempSync('pw-dispatch-plan-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = '${temp.path}/dispatch_plan_test';
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$root',
      '$root/dispatch_plan_test.cc',
      '$root/dispatch_plan.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
  });

  test('dispatch plan pins corrected COLMAP 4.1.1 sweep semantics', () {
    final header = File('$root/dispatch_plan.h').readAsStringSync();
    final source = File('$root/dispatch_plan.cc').readAsStringSync();

    expect(source, contains('a0d785fba74b2664f31edc4a29026a8b27c00f67'));
    expect(source, contains('kFrozenIterations = 5'));
    expect(header, contains('kInitializeRandomDepth'));
    expect(header, contains('kInitializeRandomNormal'));
    expect(header, contains('kCopyPhotometricDepth'));
    expect(header, contains('kCopyPhotometricNormal'));
    expect(header, contains('perturbation'));
    expect(header, contains('prev_sel_prob_weight'));
    expect(header, contains('kSelectCalibrationAndPose'));
    expect(header, contains('kRotateFinalMask'));
    expect(header, contains('kReadbackDepth'));
    expect(header, contains('kReadbackNormal'));
    expect(header, contains('kReadbackMask'));
    expect(source, isNot(contains('Operation::kFilterMask')));
  });
}
