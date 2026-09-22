import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

({List<double> cost, List<String> callOrder}) _initialCostOracle({
  required int width,
  required int height,
  required int numSources,
  required double Function(int row, int col, int source) photoCost,
}) {
  final cost = List<double>.filled(width * height * numSources, -1);
  final callOrder = <String>[];

  // One invocation owns one column and serially visits every row and source,
  // exactly as COLMAP ComputeInitialCost does.
  for (var col = 0; col < width; ++col) {
    for (var row = 0; row < height; ++row) {
      for (var source = 0; source < numSources; ++source) {
        callOrder.add('$col:$row:$source');
        final index = source * width * height + row * width + col;
        cost[index] = photoCost(row, col, source);
      }
    }
  }

  return (cost: cost, callOrder: callOrder);
}

void main() {
  const root = 'vendor/official_dense/initial_cost';
  const shaderPath = '$root/compute_initial_cost.comp';

  test('initial cost is a literal COLMAP 4.1.1 CUDA translation', () {
    final source = File(shaderPath).readAsStringSync();

    expect(source, contains('COLMAP 4.1.1 a0d785f'));
    expect(
      source,
      contains(
        'patch_match_cuda.cu sha256 '
        '1aebd4482de0ea6f1f3aad45150c09e0479119c607a843959c8aaa381c0d4448',
      ),
    );
    expect(
      source,
      contains('local_size_x = 32, local_size_y = 1, local_size_z = 1'),
    );
    expect(source, contains('shared float local_ref_image_data[1056]'));
    expect(source, contains('uint row_begin = pc.rotation_0_to_3 & 0xffffu'));
    expect(
      source,
      contains(
        'uint row_end = (pc.rotation_0_to_3 >> 16u) & 0x7fffu',
      ),
    );
    expect(
      source,
      contains(
        'for (int row = int(row_begin); row < int(row_end); ++row)',
      ),
    );
    expect(source, contains('read_local_ref_image(row, int(row_begin))'));
    expect(
      source,
      contains(
        'for (uint image_idx = 0u; image_idx < pc.num_sources; ++image_idx)',
      ),
    );
    expect(source, contains('memoryBarrierShared();'));
    expect(source, contains('barrier();'));
    expect(source, contains('compose_homography('));
    expect(source, contains('float inv_z = 1.0 / z'));
    expect(source, contains('src_color_sum += bilateral_weight_src'));
    expect(source, contains('const float k_min_var = 1e-5'));
    expect(source, contains('return max(0.0, min(2.0,'));
    expect(
      source,
      contains(
        'layout(set = 0, binding = 14) uniform sampler2DArray '
        'source_gray_images;',
      ),
      reason:
          'official ComputeInitialCost and SweepFromTopToBottom share the '
          'same CUDA src_images_texture',
    );
    expect(source, contains('textureLod('));
    expect(source, contains('source_gray_images'));
    expect(source, isNot(contains('buffer SourceGrayImages')));
    expect(source, isNot(contains('sample_source_linear_border')));
    expect(
      source,
      contains('image_idx * pc.width * pc.height + uint(row) * pc.width + col'),
    );
    expect(source, isNot(contains('epsilon')));
    expect(source, isNot(contains('safe_')));
  });

  test('no out-of-range column exits before the shared-memory barrier', () {
    final source = File(shaderPath).readAsStringSync();
    final mainStart = source.indexOf('void main()');
    expect(mainStart, greaterThan(0));
    final mainSource = source.substring(mainStart);
    final firstBarrier = mainSource.indexOf('barrier();');
    expect(firstBarrier, greaterThan(0));
    final prefix = mainSource.substring(0, firstBarrier);
    expect(prefix, isNot(contains('if (col >= pc.width)')));
    expect(prefix, isNot(contains('if (col >= int(pc.width))')));
    expect(prefix, isNot(contains('return;')));
  });

  test('CPU oracle fixes slice-major output and per-column serial order', () {
    final output = _initialCostOracle(
      width: 2,
      height: 3,
      numSources: 2,
      photoCost: (row, col, source) =>
          (source * 100 + row * 10 + col).toDouble(),
    );

    expect(output.cost, <double>[
      0,
      1,
      10,
      11,
      20,
      21,
      100,
      101,
      110,
      111,
      120,
      121,
    ]);
    expect(output.callOrder, <String>[
      '0:0:0',
      '0:0:1',
      '0:1:0',
      '0:1:1',
      '0:2:0',
      '0:2:1',
      '1:0:0',
      '1:0:1',
      '1:1:0',
      '1:1:1',
      '1:2:0',
      '1:2:1',
    ]);
  });

  test('shader compiles for Vulkan 1.1 and validates as SPIR-V', () {
    final temp = Directory.systemTemp.createTempSync('pw-initial-cost-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final spv = '${temp.path}/compute_initial_cost.spv';

    final compile = Process.runSync('glslangValidator', <String>[
      '-V',
      '--target-env',
      'vulkan1.1',
      '-o',
      spv,
      shaderPath,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}${compile.stderr}');

    final validate = Process.runSync('spirv-val', <String>[
      '--target-env',
      'vulkan1.1',
      spv,
    ]);
    expect(
      validate.exitCode,
      0,
      reason: '${validate.stdout}${validate.stderr}',
    );
  });

  test('initial-cost module contains no Swift', () {
    final swiftFiles = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.swift'))
        .toList();
    expect(swiftFiles, isEmpty);
  });
}
