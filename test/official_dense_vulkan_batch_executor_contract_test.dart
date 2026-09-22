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
  throw StateError('Vulkan headers are required for strict executor tests.');
}

void main() {
  const root = 'vendor/official_dense/vulkan_batch_executor';

  test('executor freezes defaults and keeps production gates fail closed', () {
    final header = File('$root/batch_executor.h').readAsStringSync();
    final source = File('$root/batch_executor.cc').readAsStringSync();
    expect(header, contains('kOfficialWindowRadius = 5'));
    expect(header, contains('kOfficialWindowStep = 1'));
    expect(header, contains('PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING'));
    expect(source, contains('CreateDispatchPlan'));
    expect(source, contains('runtime::Record(runtime_request)'));
    expect(source, contains('runtime::RecordForTesting'));
    expect(source, isNot(contains('TestCertifications certifications')));
    expect(source, isNot(contains('vkQueueSubmit')));
    expect(Directory(root)
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.swift')), isEmpty);
  });

  test('strict arena-to-runtime integration compiles and runs', () {
    final vulkanHeaders = _vulkanHeadersPath();
    final temp = Directory.systemTemp.createTempSync('pw-batch-executor-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = '${temp.path}/batch_executor_test';
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Wpedantic',
      '-Wconversion',
      '-Wsign-conversion',
      '-Werror',
      '-DPW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING=1',
      '-I$root',
      '-Ivendor/official_dense',
      '-I$vulkanHeaders',
      '$root/batch_executor_test.cc',
      '$root/batch_executor.cc',
      'vendor/official_dense/vulkan_resource_arena/resource_arena.cc',
      'vendor/official_dense/vulkan_resource_arena/resource_arena_plan.cc',
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

  test('CMake runtime gate owns executor target and installed header', () {
    final cmake = File('vendor/official_dense/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('vulkan_batch_executor/batch_executor.cc'));
    expect(cmake, contains('pw_official_dense_batch_executor_test'));
    expect(cmake, contains('vulkan_batch_executor/batch_executor.h'));
    expect(cmake, contains('if(PW_DENSE_ENABLE_VULKAN_RUNTIME)'));
    expect(cmake, contains('set(PW_DENSE_OVERALL_READY FALSE'));
  });
}
