import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

double _photoCostOracle({
  required List<double> reference,
  required List<double> source,
}) {
  expect(reference.length, source.length);
  final refMean = reference.reduce((a, b) => a + b) / reference.length;
  final refSquaredMean =
      reference.map((value) => value * value).reduce((a, b) => a + b) /
      reference.length;
  final srcMean = source.reduce((a, b) => a + b) / source.length;
  final srcSquaredMean =
      source.map((value) => value * value).reduce((a, b) => a + b) /
      source.length;
  var srcRefMean = 0.0;
  for (var index = 0; index < reference.length; index++) {
    srcRefMean += source[index] * reference[index];
  }
  srcRefMean /= reference.length;

  final refVariance = refSquaredMean - refMean * refMean;
  final srcVariance = srcSquaredMean - srcMean * srcMean;
  if (refVariance < 1e-5 || srcVariance < 1e-5) {
    return 2.0;
  }
  final covariance = srcRefMean - refMean * srcMean;
  final varianceProduct = math.sqrt(refVariance * srcVariance);
  return math.max(0.0, math.min(2.0, 1.0 - covariance / varianceProduct));
}

double _geometryCostOracle({
  required double row,
  required double col,
  required double depth,
  required List<double> refInvK,
  required List<double> refK,
  required List<double> projection,
  required List<double> inverseProjection,
  required double sourceDepth,
  required double maxCost,
}) {
  final forwardPoint = <double>[
    depth * (refInvK[0] * col + refInvK[1]),
    depth * (refInvK[2] * row + refInvK[3]),
    depth,
  ];
  final inverseForwardZ =
      1.0 /
      (projection[8] * forwardPoint[0] +
          projection[9] * forwardPoint[1] +
          projection[10] * forwardPoint[2] +
          projection[11]);
  var sourceCol =
      inverseForwardZ *
      (projection[0] * forwardPoint[0] +
          projection[1] * forwardPoint[1] +
          projection[2] * forwardPoint[2] +
          projection[3]);
  var sourceRow =
      inverseForwardZ *
      (projection[4] * forwardPoint[0] +
          projection[5] * forwardPoint[1] +
          projection[6] * forwardPoint[2] +
          projection[7]);
  if (sourceDepth == 0.0) {
    return maxCost;
  }

  sourceCol *= sourceDepth;
  sourceRow *= sourceDepth;
  final backwardX =
      inverseProjection[0] * sourceCol +
      inverseProjection[1] * sourceRow +
      inverseProjection[2] * sourceDepth +
      inverseProjection[3];
  final backwardY =
      inverseProjection[4] * sourceCol +
      inverseProjection[5] * sourceRow +
      inverseProjection[6] * sourceDepth +
      inverseProjection[7];
  final backwardZ =
      inverseProjection[8] * sourceCol +
      inverseProjection[9] * sourceRow +
      inverseProjection[10] * sourceDepth +
      inverseProjection[11];
  final inverseBackwardZ = 1.0 / backwardZ;
  final backwardCol =
      inverseBackwardZ * (refK[0] * backwardX + refK[1] * backwardZ);
  final backwardRow =
      inverseBackwardZ * (refK[2] * backwardY + refK[3] * backwardZ);
  final diffCol = col - backwardCol;
  final diffRow = row - backwardRow;
  return math.min(maxCost, math.sqrt(diffCol * diffCol + diffRow * diffRow));
}

void main() {
  const root = 'vendor/official_dense/cost_ops';
  const includePath = '$root/cost_ops.glsl';
  const shaderPath = '$root/cost_ops_contract.comp';

  test('photo cost retains the literal COLMAP 4.1.1 expression order', () {
    final source = File(includePath).readAsStringSync();

    expect(source, contains('COLMAP 4.1.1 a0d785f'));
    expect(
      source,
      contains(
        'patch_match_cuda.cu sha256 '
        '1aebd4482de0ea6f1f3aad45150c09e0479119c607a843959c8aaa381c0d4448',
      ),
    );
    expect(source, contains('constant_id = 0'));
    expect(source, contains('kWindowRadius = 5'));
    expect(source, contains('constant_id = 1'));
    expect(source, contains('kWindowStep = 1'));
    expect(source, contains('shared float local_ref_image'));
    expect(source, contains('kThreadBlockSize * kThreadsPerBlock'));
    expect(source, contains('float base_col_src = col_src'));
    expect(source, contains('float base_row_src = row_src'));
    expect(source, contains('float base_z = z'));
    expect(source, contains('col_src += tform_step[0]'));
    expect(source, contains('row_src += tform_step[3]'));
    expect(source, contains('z += tform_step[6]'));
    expect(source, contains('col_src = base_col_src'));
    expect(source, contains('row_src = base_row_src'));
    expect(source, contains('z = base_z'));
    expect(source, contains('const float kMinVar = 1e-5'));
    expect(
      source,
      contains(
        'max(0.0, min(kMaxCost, '
        '1.0 - src_ref_color_covar / src_ref_color_var))',
      ),
    );
    expect(source, isNot(contains('epsilon')));
    expect(source, isNot(contains('fma(')));
  });

  test('photo cost uses the official COLMAP circular reference window', () {
    final source = File(includePath).readAsStringSync();

    expect(source, contains('COLMAP speedup commit 112da5e'));
    expect(source, contains('int local_ref_row_offset = 0;'));
    expect(source, contains('int LocalRefImagePhysicalRow(int logical_row)'));
    expect(source, contains('float LocalRefImageGet(int logical_row, int col_idx)'));
    expect(source, contains('int target_row = local_ref_row_offset;'));
    expect(source, contains('local_ref_row_offset + 1) % kLocalRefNumRows;'));
    expect(
      source,
      isNot(contains('local_ref_image[(local_row - 1) *')),
    );
    expect(source, isNot(contains('__expf')));
  });

  test(
    'geometry cost retains point/border-zero and truncated reprojection',
    () {
      final source = File(includePath).readAsStringSync();
      final samplerContract = File(
        '$root/sampler_contract.h',
      ).readAsStringSync();

      expect(source, contains('if (src_depth == 0.0)'));
      expect(source, contains('return max_cost'));
      expect(source, contains('src_col *= src_depth'));
      expect(source, contains('src_row *= src_depth'));
      expect(
        source,
        contains(
          'min(max_cost, sqrt(diff_col * diff_col + diff_row * diff_row))',
        ),
      );
      expect(samplerContract, contains('VK_FILTER_LINEAR'));
      expect(samplerContract, contains('VK_FILTER_NEAREST'));
      expect(
        samplerContract,
        contains('VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER'),
      );
      expect(
        samplerContract,
        contains('VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK'),
      );
      expect(
        samplerContract,
        contains('kRequiresCuda5090TextureFixture = true'),
      );
      expect(samplerContract, contains('return false'));
    },
  );

  test('RTX 5090 CUDA texture fixture contract is frozen before parity', () {
    final fixtureSchema =
        jsonDecode(
              File('$root/texture_fixture_schema_v1.json').readAsStringSync(),
            )
            as Map<String, dynamic>;

    expect(
      fixtureSchema['schema'],
      'pocketworld.colmap411.texture_sampler_golden.v1',
    );
    expect(
      fixtureSchema['upstream_commit'],
      'a0d785fba74b2664f31edc4a29026a8b27c00f67',
    );
    expect(fixtureSchema['required_cuda_device'], 'NVIDIA GeForce RTX 5090');
    expect(fixtureSchema['coordinate_encoding'], 'float32_bits_little_endian');
    expect(fixtureSchema['sample_encoding'], 'float32_bits_little_endian');
    final samplers = fixtureSchema['samplers'] as Map<String, dynamic>;
    expect(samplers['source_image']['filter'], 'linear');
    expect(samplers['source_image']['address'], 'border_zero');
    expect(samplers['source_image']['read'], 'normalized_float_from_uint8');
    expect(samplers['source_depth']['filter'], 'point');
    expect(samplers['source_depth']['address'], 'border_zero');
    expect(samplers['source_depth']['read'], 'float32_element');
    expect(fixtureSchema['parity_enabled_without_fixture'], isFalse);
  });

  test('CPU oracle fixes flat-window and simple reprojection behavior', () {
    expect(
      _photoCostOracle(
        reference: List<double>.filled(121, 0.25),
        source: List<double>.filled(121, 0.25),
      ),
      2.0,
    );
    final ramp = List<double>.generate(121, (index) => index / 120.0);
    expect(
      _photoCostOracle(reference: ramp, source: ramp),
      closeTo(0.0, 1e-14),
    );

    const identityProjection = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];
    expect(
      _geometryCostOracle(
        row: 2,
        col: 3,
        depth: 4,
        refInvK: const <double>[1, 0, 1, 0],
        refK: const <double>[1, 0, 1, 0],
        projection: identityProjection,
        inverseProjection: identityProjection,
        sourceDepth: 4,
        maxCost: 5,
      ),
      closeTo(0.0, 1e-15),
    );
    expect(
      _geometryCostOracle(
        row: 2,
        col: 3,
        depth: 4,
        refInvK: const <double>[1, 0, 1, 0],
        refK: const <double>[1, 0, 1, 0],
        projection: identityProjection,
        inverseProjection: identityProjection,
        sourceDepth: 0,
        maxCost: 5,
      ),
      5.0,
    );
  });

  test('contract shader compiles for Vulkan 1.1 and validates as SPIR-V', () {
    final temporary = Directory.systemTemp.createTempSync('pw-cost-ops-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final spv = '${temporary.path}/cost_ops.spv';

    final compile = Process.runSync('glslangValidator', <String>[
      '-V',
      '--target-env',
      'vulkan1.1',
      '-I$root',
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

  test('cost module contains no Swift', () {
    final swiftFiles = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.swift'))
        .toList();
    expect(swiftFiles, isEmpty);
  });
}
