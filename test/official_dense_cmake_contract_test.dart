import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const cmakePath = 'vendor/official_dense/CMakeLists.txt';

  test('official dense CMake defaults to a fail-closed portable core', () {
    final source = File(cmakePath).readAsStringSync();

    expect(source, contains('project(PocketWorldOfficialDense'));
    expect(source, contains('option(PW_DENSE_ENABLE_VULKAN_RUNTIME'));
    expect(source, contains('option(PW_DENSE_ENABLE_OFFICIAL_FUSION'));
    expect(
      source,
      matches(RegExp(r'option\(PW_DENSE_ENABLE_VULKAN_RUNTIME[\s\S]*?OFF\)')),
    );
    expect(
      source,
      matches(RegExp(r'option\(PW_DENSE_ENABLE_OFFICIAL_FUSION[\s\S]*?OFF\)')),
    );
    expect(source, contains('workspace_io/workspace_io.cc'));
    expect(
      source,
      contains('patch_match_controller/patch_match_controller.cc'),
    );
    expect(source, contains('vulkan_host/dispatch_plan.cc'));
    expect(source, contains('vulkan_host/vulkan_host.cc'));
    expect(source, contains('file_transaction/anchored_transaction.cc'));
    expect(source, contains('ffi/src/pwofficial_dense_c.cc'));
    expect(source, contains('ffi/src/backend_unavailable.cc'));
    expect(
      source,
      contains(r'$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/ffi/include>'),
    );
    expect(source, contains('PW_OFFICIAL_DENSE_VULKAN_STUB'));
    expect(source, contains('EXPORT_NAME OfficialDense'));
    expect(source, isNot(contains('PW_OFFICIAL_DENSE_PRODUCTION_READY')));
  });

  test('optional runtimes fail instead of selecting another algorithm', () {
    final source = File(cmakePath).readAsStringSync();

    expect(source, contains('message(FATAL_ERROR'));
    expect(source, contains('PW_DENSE_ENABLE_VULKAN_RUNTIME=ON'));
    expect(source, contains('vulkan_runtime/vulkan_runtime.cc'));
    expect(source, contains('vulkan_runtime/vulkan_runtime.h'));
    expect(source, contains('PW_DENSE_ENABLE_OFFICIAL_FUSION=ON'));
    expect(source, contains('add_subdirectory(official_cpu_mvs'));
    expect(source, contains('pw_official_cpu_mvs_objects'));
    expect(
      source,
      contains(r'${CMAKE_CURRENT_SOURCE_DIR}/third_party/colmap-4.1.1'),
    );
    expect(source, contains(r'$<TARGET_OBJECTS:pw_official_cpu_mvs_objects>'));
    expect(
      source,
      contains(r'$<LINK_LIBRARY:WHOLE_ARCHIVE,pw_official_dense_portable>'),
    );
    expect(source, contains('PW_OFFICIAL_DENSE_WITH_COLMAP_4_1_1'));
    expect(source, isNot(contains('find_package(colmap')));
    expect(source, isNot(contains('colmap::colmap')));
    expect(source, isNot(contains('FetchContent')));
    expect(source, isNot(contains('ExternalProject')));
    expect(source.toLowerCase(), isNot(contains('download')));
    expect(source.toLowerCase(), isNot(contains('fallback')));
    expect(source, isNot(contains('patch_match_cuda.cu')));
    expect(source, isNot(contains('SiftGPU')));
    expect(source, isNot(contains('LSD')));
    expect(source, isNot(contains('Qt')));
  });

  test('shader gate writes generated artifacts only below the build tree', () {
    final source = File(cmakePath).readAsStringSync();

    expect(source, contains('build/build_gate.py'));
    expect(source, contains(r'${CMAKE_CURRENT_BINARY_DIR}/generated/shaders'));
    expect(source, contains('pw_official_dense_shaders'));
    expect(source, contains('overall_ready'));
    expect(source, contains('FALSE'));
    expect(source, contains(r'"-DMANIFEST_PATH=${_pw_dense_shader_manifest}"'));
    expect(
      source,
      isNot(contains(r'-DMANIFEST_PATH="${_pw_dense_shader_manifest}"')),
    );
  });

  test('COLMAP and local license evidence have install rules', () {
    final source = File(cmakePath).readAsStringSync();

    expect(source, contains('third_party/colmap-4.1.1/COPYING.txt'));
    expect(
      source,
      contains('third_party/colmap-4.1.1/src/thirdparty/VLFeat/LICENSE'),
    );
    expect(source, contains('VLFeat-LICENSE.txt'));
    expect(source, contains('install(FILES'));
    expect(source, contains('licenses'));
    expect(source, contains('workspace_io/workspace_io.h'));
    expect(source, contains('patch_match_controller/patch_match_controller.h'));
    expect(source, contains('vulkan_host/vulkan_host.h'));
    expect(source, contains('file_transaction/anchored_transaction.h'));
    expect(source, contains('ffi/include/pwofficial_dense_c.h'));
    expect(source, contains('pwofficial_dense_abi_symbols.txt'));
    expect(source, contains('pw_official_dense_ffi_fail_closed_test'));
  });
}
