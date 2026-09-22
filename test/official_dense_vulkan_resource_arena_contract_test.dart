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
    'Vulkan headers are required for strict ResourceArena tests. Set '
    'PW_VULKAN_HEADERS to an include directory containing vulkan/vulkan.h, '
    'or provide one of: ${candidates.join(', ')}',
  );
}

void main() {
  const root = 'vendor/official_dense/vulkan_resource_arena';

  test('batch arena is transactional, provider-injected, and zero-Swift', () {
    final header = File('$root/resource_arena.h').readAsStringSync();
    final source = File('$root/resource_arena.cc').readAsStringSync();
    expect(header, contains('class ResourceAllocationProvider'));
    expect(header, contains('class ResourceArenaBatch final'));
    expect(header, contains('VulkanHostResourceAllocationProvider'));
    expect(source, contains('BuildResourceArenaPlan'));
    expect(source, contains('BuildRotationCalibrationHost'));
    expect(source, contains('used_buffer_handles'));
    expect(source, contains('used_image_view_handles'));
    expect(source, contains('sampler_contracts'));
    expect(source, contains('one sampler handle represents distinct contracts'));
    expect(source, contains('source_depth_layers'));
    expect(source, contains('consistency_graph_readback'));
    expect(source, contains('*out = ResourceArenaBatch'));
    expect(source, isNot(contains('vkQueueSubmit')));
    expect(source, isNot(contains('decode')));
    expect(source, isNot(contains('cv::resize')));
    for (final forbidden in const <String>[
      'bool AddPlan(const std::size_t image, const AllocationPlan &plan,\n'
          '             std::map<AliasKey, AllocationPlan> *plans,\n'
          '             const bool image_kind) noexcept',
      'bool CollectPlans(const std::size_t image, const ResourceArenaPlan &plan,\n'
          '                  std::map<AliasKey, AllocationPlan> *buffers,\n'
          '                  std::map<AliasKey, AllocationPlan> *images) noexcept',
      'PlannedImage *planned) noexcept',
    ]) {
      expect(source, isNot(contains(forbidden)));
    }
    expect(Directory(root)
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.swift')), isEmpty);
  });

  test('strict fake provider contract compiles and runs', () {
    final vulkanHeaders = _vulkanHeadersPath();
    final temp = Directory.systemTemp.createTempSync('pw-arena-batch-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = '${temp.path}/resource_arena_test';
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Wpedantic',
      '-Wconversion',
      '-Wsign-conversion',
      '-Werror',
      '-DPW_OFFICIAL_DENSE_VULKAN_STUB=1',
      '-I$root',
      '-Ivendor/official_dense',
      '-I$vulkanHeaders',
      '$root/resource_arena_test.cc',
      '$root/resource_arena.cc',
      '$root/resource_arena_plan.cc',
      'vendor/official_dense/vulkan_runtime/vulkan_runtime.cc',
      'vendor/official_dense/vulkan_host/dispatch_plan.cc',
      'vendor/official_dense/vulkan_host/vulkan_host.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('CMake only includes real arena with the Vulkan runtime gate', () {
    final cmake = File('vendor/official_dense/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('vulkan_resource_arena/resource_arena.cc'));
    expect(cmake, contains('vulkan_resource_arena/resource_arena.h'));
    expect(cmake, contains('pw_official_dense_resource_arena_test'));
    expect(cmake, contains('if(PW_DENSE_ENABLE_VULKAN_RUNTIME)'));
    expect(cmake, contains('set(PW_DENSE_OVERALL_READY FALSE'));
  });
}
