import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'vendor/official_dense/ffi';
  const header = '$root/include/pwofficial_dense_c.h';
  const source = '$root/src/pwofficial_dense_c.cc';
  const unavailableBackend = '$root/src/backend_unavailable.cc';

  test('C ABI surface is versioned, zero-Swift, and symbol-frozen', () {
    final headerText = File(header).readAsStringSync();
    final backendContract = File('$root/src/backend_contract.h').readAsStringSync();
    final symbols = File('$root/pwofficial_dense_abi_symbols.txt')
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .toList();

    expect(headerText, contains('PW_OFFICIAL_DENSE_ABI_VERSION 1u'));
    expect(headerText, contains('uint32_t struct_size'));
    expect(headerText, contains('uint32_t abi_version'));
    expect(headerText, contains('pwofficial_dense_version'));
    expect(headerText, contains('pwofficial_dense_last_error'));
    expect(headerText, contains('pwofficial_dense_default_options'));
    expect(headerText, contains('pwofficial_dense_is_available'));
    expect(headerText, contains('pwofficial_dense_run'));
    expect(headerText, contains('pwofficial_dense_cancel'));
    expect(
      backendContract,
      contains('a0d785fba74b2664f31edc4a29026a8b27c00f67'),
    );
    expect(
      backendContract,
      contains('6f10ea037800b375467b7b0511cc35aef248ca2becd834e260056dddb653be28'),
    );
    expect(backendContract, contains('SourceIdentityReady'));
    expect(
      symbols,
      equals(const <String>[
        'pwofficial_dense_version',
        'pwofficial_dense_last_error',
        'pwofficial_dense_default_options',
        'pwofficial_dense_is_available',
        'pwofficial_dense_run',
        'pwofficial_dense_cancel',
      ]),
    );
    expect(
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.swift')),
      isEmpty,
    );
  });

  test('macOS clang executes defaults, validation, and fail-closed run', () {
    final temp = Directory.systemTemp.createTempSync('pwofficial-dense-abi-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final harness = File('${temp.path}/abi_test.cc');
    final executable = '${temp.path}/abi_test';
    final output = '${temp.path}/must_not_exist.ply';
    harness.writeAsStringSync(r'''
#include "pwofficial_dense_c.h"
#include "backend_contract.h"

#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>

namespace {
bool Near(double lhs, double rhs) { return std::abs(lhs - rhs) < 1e-12; }
}

int main(int argc, char** argv) {
  if (argc != 2) return 1;
  if (pwofficial_dense_version() != PW_OFFICIAL_DENSE_ABI_VERSION) return 2;
  if (pwofficial_dense_default_options(nullptr) !=
      PW_OFFICIAL_DENSE_INVALID_ARGUMENT) return 3;

  pwofficial_dense_options_t options{};
  if (pwofficial_dense_default_options(&options) != PW_OFFICIAL_DENSE_OK) return 4;
  if (options.struct_size != sizeof(options)) return 5;
  if (options.abi_version != PW_OFFICIAL_DENSE_ABI_VERSION) return 6;
  if (!Near(options.depth_min, -1.0) || !Near(options.depth_max, -1.0)) return 7;
  if (!Near(options.sigma_spatial, -1.0) || !Near(options.sigma_color, 0.2)) return 8;
  if (!Near(options.ncc_sigma, 0.6) ||
      !Near(options.min_triangulation_angle, 1.0)) return 9;
  if (!Near(options.incident_angle_sigma, 0.9) ||
      !Near(options.geom_consistency_regularizer, 0.3) ||
      !Near(options.geom_consistency_max_cost, 3.0)) return 10;
  if (!Near(options.filter_min_ncc, 0.1) ||
      !Near(options.filter_min_triangulation_angle, 3.0) ||
      !Near(options.filter_geom_consistency_max_cost, 1.0)) return 11;
  if (!Near(options.patch_match_cache_size, 32.0)) return 12;
  if (std::strcmp(options.gpu_index, "-1") != 0) return 13;
  if (options.patch_match_max_image_size != -1 || options.window_radius != 5 ||
      options.window_step != 1 || options.num_samples != 15 ||
      options.num_iterations != 5 || options.filter_min_num_consistent != 2 ||
      options.patch_match_num_threads != -1) return 14;
  if (options.geom_consistency != 1 || options.filter != 1 ||
      options.allow_missing_files != 0 ||
      options.write_consistency_graph != 0) return 15;

  if (options.fusion_num_threads != -1 ||
      options.fusion_max_image_size != -1 || options.min_num_pixels != 5 ||
      options.max_num_pixels != 10000 || options.max_traversal_depth != 100 ||
      options.check_num_images != 50 || options.use_cache != 0) return 16;
  if (!Near(options.max_reproj_error, 2.0) ||
      !Near(options.max_depth_error, 0.01) ||
      !Near(options.max_normal_error, 10.0) ||
      !Near(options.fusion_cache_size, 32.0)) return 17;
  if (options.mask_path[0] != '\0') return 18;
  for (int i = 0; i < 3; ++i) {
    if (options.bounding_box_min[i] != -FLT_MAX ||
        options.bounding_box_max[i] != FLT_MAX) return 19;
  }

  if (pwofficial_dense_is_available() != 0) return 20;
  const char* unavailable = pwofficial_dense_last_error();
  if (unavailable == nullptr || std::strstr(unavailable, "source-hash") == nullptr ||
      std::strstr(unavailable, "vulkan-loader-caps") == nullptr ||
      std::strstr(unavailable, "xorwow") == nullptr ||
      std::strstr(unavailable, "texture-parity") == nullptr ||
      std::strstr(unavailable, "shader-dispatch") == nullptr ||
      std::strstr(unavailable, "fusion") == nullptr) return 21;

  if (pwofficial_dense_run(nullptr, argv[1], &options) !=
      PW_OFFICIAL_DENSE_INVALID_ARGUMENT) return 22;
  if (pwofficial_dense_run("workspace", nullptr, &options) !=
      PW_OFFICIAL_DENSE_INVALID_ARGUMENT) return 23;
  if (pwofficial_dense_run("", argv[1], &options) !=
      PW_OFFICIAL_DENSE_INVALID_ARGUMENT) return 32;
  if (pwofficial_dense_run("workspace", "", &options) !=
      PW_OFFICIAL_DENSE_INVALID_ARGUMENT) return 33;
  if (pwofficial_dense_run("workspace", argv[1], nullptr) !=
      PW_OFFICIAL_DENSE_INVALID_ARGUMENT) return 34;
  options.struct_size -= 1;
  if (pwofficial_dense_run("workspace", argv[1], &options) !=
      PW_OFFICIAL_DENSE_INVALID_ARGUMENT) return 24;
  if (std::filesystem::exists(argv[1])) return 25;

  if (pwofficial_dense_default_options(&options) != PW_OFFICIAL_DENSE_OK) return 26;
  if (pwofficial_dense_run("workspace", argv[1], &options) !=
      PW_OFFICIAL_DENSE_UNAVAILABLE) return 27;
  if (std::filesystem::exists(argv[1])) return 28;
  if (pwofficial_dense_cancel() != PW_OFFICIAL_DENSE_OK) return 29;

  pocketworld::official_dense::ffi::BackendReadiness identity;
  identity.source_hash_ready = true;
  identity.vulkan_loader_caps_ready = true;
  identity.xorwow_ready = true;
  identity.texture_parity_ready = true;
  identity.shader_dispatch_ready = true;
  identity.fusion_ready = true;
  identity.upstream_commit = "wrong";
  identity.source_manifest_sha256 = "wrong";
  if (identity.AllReady()) return 30;
  identity.upstream_commit =
      pocketworld::official_dense::ffi::kColmapUpstreamCommit;
  identity.source_manifest_sha256 =
      pocketworld::official_dense::ffi::kColmapSourceManifestSha256;
  if (!identity.AllReady()) return 31;
  return 0;
}
''');

    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$root/include',
      '-I$root/src',
      harness.path,
      source,
      unavailableBackend,
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');

    final run = Process.runSync(executable, <String>[output]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(File(output).existsSync(), isFalse);

    final nm = Process.runSync('nm', <String>['-g', executable]);
    expect(nm.exitCode, 0, reason: '${nm.stderr}');
    final exported = nm.stdout as String;
    for (final symbol in File('$root/pwofficial_dense_abi_symbols.txt')
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)) {
      expect(exported, contains('_$symbol'));
    }
  });

  test('public header is valid C11', () {
    final temp = Directory.systemTemp.createTempSync('pwofficial-dense-c-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final harness = File('${temp.path}/header_test.c')
      ..writeAsStringSync('''
#include "pwofficial_dense_c.h"
int main(void) {
  pwofficial_dense_options_t options;
  return (int)pwofficial_dense_default_options(&options);
}
''');
    final result = Process.runSync('clang', <String>[
      '-std=c11',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$root/include',
      '-fsyntax-only',
      harness.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('C ABI catches backend exceptions instead of crossing the boundary', () {
    final temp =
        Directory.systemTemp.createTempSync('pwofficial-dense-exception-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final backend = File('${temp.path}/throwing_backend.cc')
      ..writeAsStringSync(r'''
#include "backend_contract.h"
#include <stdexcept>
namespace pocketworld::official_dense::ffi {
BackendReadiness QueryBackendReadiness() { throw std::runtime_error("probe"); }
BackendRunResult RunBackend(const BackendRunRequest&) {
  throw std::runtime_error("run");
}
void CancelBackend() noexcept {}
}  // namespace pocketworld::official_dense::ffi
''');
    final harness = File('${temp.path}/exception_test.cc')
      ..writeAsStringSync(r'''
#include "pwofficial_dense_c.h"
#include <cstring>
int main() {
  if (pwofficial_dense_is_available() != 0) return 1;
  const char* error = pwofficial_dense_last_error();
  return error != nullptr && std::strstr(error, "probe") != nullptr ? 0 : 2;
}
''');
    final executable = '${temp.path}/exception_test';
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$root/include',
      '-I$root/src',
      harness.path,
      backend.path,
      source,
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('Android NDK syntax is exercised when an audited NDK is configured', () {
    final ndk = Platform.environment['ANDROID_NDK_HOME'] ??
        Platform.environment['ANDROID_NDK_ROOT'];
    if (ndk == null || ndk.isEmpty) return;
    final compiler = File(
      '$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang++',
    );
    expect(compiler.existsSync(), isTrue,
        reason: 'configured Android NDK has no arm64 clang++');
    final result = Process.runSync(compiler.path, <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$root/include',
      '-fsyntax-only',
      source,
      unavailableBackend,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
