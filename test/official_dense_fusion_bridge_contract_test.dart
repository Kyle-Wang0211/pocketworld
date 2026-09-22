import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const sourceRoot = 'vendor/official_dense/fusion_bridge';
  const header = '$sourceRoot/stereo_fusion_bridge.h';
  const implementation = '$sourceRoot/stereo_fusion_bridge.cc';

  test('fusion bridge freezes COLMAP 4.1.1 defaults', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'official_dense_fusion_bridge_',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    final fixture = File('${temporary.path}/fusion_options_fixture.cc');
    await fixture.writeAsString(r'''
#include "stereo_fusion_bridge.h"

#include <cfloat>
#include <cmath>
#include <iostream>
#include <string>

int Fail(const std::string& message) {
  std::cerr << message << std::endl;
  return 1;
}

int main() {
  const pocketworld::official_dense::fusion::FusionOptions options;
  if (!options.mask_path.empty()) return Fail("mask_path");
  if (options.num_threads != -1) return Fail("num_threads");
  if (options.max_image_size != -1) return Fail("max_image_size");
  if (options.min_num_pixels != 5) return Fail("min_num_pixels");
  if (options.max_num_pixels != 10000) return Fail("max_num_pixels");
  if (options.max_traversal_depth != 100) {
    return Fail("max_traversal_depth");
  }
  if (options.max_reproj_error != 2.0) return Fail("max_reproj_error");
  if (options.max_depth_error != 0.01) return Fail("max_depth_error");
  if (options.max_normal_error != 10.0) return Fail("max_normal_error");
  if (options.check_num_images != 50) return Fail("check_num_images");
  if (options.use_cache) return Fail("use_cache");
  if (options.cache_size != 32.0) return Fail("cache_size");
  for (const float value : options.bounding_box_min) {
    if (value != -FLT_MAX) return Fail("bounding_box_min");
  }
  for (const float value : options.bounding_box_max) {
    if (value != FLT_MAX) return Fail("bounding_box_max");
  }
  return 0;
}
''');

    final executable = '${temporary.path}/fusion_options_fixture';
    final compile = await Process.run('xcrun', <String>[
      'clang++',
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$sourceRoot',
      fixture.path,
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
  });

  test('bridge calls only official StereoFusion and official writers', () {
    final source = File(implementation).readAsStringSync();
    expect(source, contains('colmap::mvs::StereoFusionOptions'));
    expect(source, contains('colmap::mvs::StereoFusion fuser('));
    expect(source, contains('"COLMAP"'));
    expect(source, contains('fuser.Run();'));
    expect(source, contains('colmap::WriteBinaryPlyPoints('));
    expect(source, contains('fuser.GetFusedPoints()'));
    expect(source, contains('colmap::mvs::WritePointsVisibility('));
    expect(source, contains('fuser.GetFusedPointsVisibility()'));
    for (final field in <String>[
      'mask_path',
      'num_threads',
      'max_image_size',
      'min_num_pixels',
      'max_num_pixels',
      'max_traversal_depth',
      'max_reproj_error',
      'max_depth_error',
      'max_normal_error',
      'check_num_images',
      'use_cache',
      'cache_size',
    ]) {
      expect(source, contains('official.$field = options.$field;'));
    }
    expect(source, contains('official.bounding_box = std::make_pair('));
    expect(source, isNot(contains('TSDF')));
    expect(source, isNot(contains('voxel')));
    expect(source, isNot(contains('downsampl')));
  });

  test('bridge is geometric-only, fail-closed, transactional, and zero Swift',
      () async {
    final source = File(implementation).readAsStringSync();
    final interface = File(header).readAsStringSync();
    expect(source, contains('input_type != "geometric"'));
    expect(source, contains('fused.ply'));
    expect(source, contains('fused.ply.vis'));
    expect(source, contains('pwofficial.tmp'));
    expect(source, contains('std::filesystem::rename'));
    expect(source, contains('std::filesystem::remove'));
    expect(interface, contains('kUnavailable'));
    expect(source, isNot(contains('system(')));

    final temporary = await Directory.systemTemp.createTemp(
      'official_dense_fusion_unavailable_',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final fixture = File('${temporary.path}/fusion_unavailable_fixture.cc');
    await fixture.writeAsString(r'''
#include "stereo_fusion_bridge.h"

#include <filesystem>
#include <iostream>

int main(int argc, char** argv) {
  if (argc != 2) return 1;
  const std::filesystem::path workspace = argv[1];
  std::filesystem::create_directories(workspace);
  using pocketworld::official_dense::fusion::FusionOptions;
  using pocketworld::official_dense::fusion::RunStereoFusion;
  using pocketworld::official_dense::fusion::StatusCode;
  if (RunStereoFusion(workspace, "photometric", FusionOptions()).code !=
      StatusCode::kInvalidArgument) {
    return 2;
  }
  if (RunStereoFusion(workspace, "geometric", FusionOptions()).code !=
      StatusCode::kUnavailable) {
    return 3;
  }
  if (std::filesystem::exists(workspace / "fused.ply") ||
      std::filesystem::exists(workspace / "fused.ply.vis")) {
    return 4;
  }
  return 0;
}
''');
    final executable = '${temporary.path}/fusion_unavailable_fixture';
    final compile = await Process.run('xcrun', <String>[
      'clang++',
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$sourceRoot',
      implementation,
      fixture.path,
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, <String>[
      '${temporary.path}/workspace',
    ]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');

    final swiftFiles = Directory(sourceRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.swift'));
    expect(swiftFiles, isEmpty);

    const androidClang =
        '/opt/homebrew/share/android-ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang++';
    expect(File(androidClang).existsSync(), isTrue);
    final syntax = await Process.run(androidClang, <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-fsyntax-only',
      '-I$sourceRoot',
      implementation,
    ]);
    expect(syntax.exitCode, 0, reason: '${syntax.stdout}\n${syntax.stderr}');
  });

  test('official fusion CLI is a zero-tuning wrapper around the bridge', () {
    final cmake = File('vendor/official_dense/CMakeLists.txt').readAsStringSync();
    final cli = File(
      'vendor/official_dense/tools/stereo_fusion_cli.cc',
    ).readAsStringSync();

    expect(cmake, contains('pw_official_dense_stereo_fusion'));
    expect(cmake, contains('tools/stereo_fusion_cli.cc'));
    expect(cli, contains('RunStereoFusion(workspace,'));
    expect(cli, contains('"geometric")'));
    expect(cli, contains('status.message'));
    expect(cli, isNot(contains('FusionOptions options')));
    expect(cli, isNot(contains('TSDF')));
    expect(cli, isNot(contains('voxel')));
  });
}
