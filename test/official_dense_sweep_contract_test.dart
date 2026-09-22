import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

int _findMinCostLastTie(List<double> costs) {
  var minCost = costs.first;
  var minCostIndex = 0;
  for (var index = 1; index < costs.length; index++) {
    if (costs[index] <= minCost) {
      minCost = costs[index];
      minCostIndex = index;
    }
  }
  return minCostIndex;
}

List<double> _transformPdfToCdf(List<double> probabilities) {
  final output = List<double>.of(probabilities);
  final sum = output.fold<double>(0, (value, element) => value + element);
  final inverseSum = 1 / sum;
  var cumulative = 0.0;
  for (var index = 0; index < output.length; index++) {
    cumulative += output[index] * inverseSum;
    output[index] = cumulative;
  }
  return output;
}

int _strictCdfSelect(List<double> cdf, double draw) {
  for (var index = 0; index < cdf.length; index++) {
    if (cdf[index] > draw) return index;
  }
  return -1;
}

double _nccProbability({
  required double cost,
  required double sigma,
  required double normalization,
}) => math.exp(cost * cost * (-0.5 / (sigma * sigma))) * normalization;

double _message({
  required double cost,
  required double previous,
  required double sigma,
  required double normalization,
  required bool forward,
}) {
  const uniformProbability = 0.5;
  const noChangeProbability = 0.99999;
  const changeProbability = 1 - noChangeProbability;
  final emission = _nccProbability(
    cost: cost,
    sigma: sigma,
    normalization: normalization,
  );
  late final double zn0;
  late final double zn1;
  if (forward) {
    zn0 =
        (previous * changeProbability + (1 - previous) * noChangeProbability) *
        uniformProbability;
    zn1 =
        (previous * noChangeProbability + (1 - previous) * changeProbability) *
        emission;
  } else {
    zn0 =
        previous * emission * changeProbability +
        (1 - previous) * uniformProbability * noChangeProbability;
    zn1 =
        previous * emission * noChangeProbability +
        (1 - previous) * uniformProbability * changeProbability;
  }
  return zn1 / (zn0 + zn1);
}

double _propagateDepth({
  required double depth,
  required List<double> normal,
  required double row1,
  required double row2,
  required double inverseFy,
  required double inverseNegCyFy,
}) {
  final x1 = depth * (inverseFy * row1 + inverseNegCyFy);
  final y1 = depth;
  final x2 = x1 + normal[2];
  final y2 = y1 - normal[1];
  final x4 = inverseFy * row2 + inverseNegCyFy;
  final denominator = x2 - x1 + x4 * (y1 - y2);
  if (denominator.abs() < 1e-5) return depth;
  final numerator = y1 * x2 - x1 * y2;
  return numerator / denominator;
}

void main() {
  const root = 'vendor/official_dense/sweep';
  const shaderPath = '$root/sweep_unavailable.comp';

  test('sweep host contract is pinned and fail-closed', () {
    final header = File('$root/sweep_contract.h').readAsStringSync();

    expect(header, contains('a0d785fba74b2664f31edc4a29026a8b27c00f67'));
    expect(
      header,
      contains(
        '1aebd4482de0ea6f1f3aad45150c09e0479119c607a843959c8aaa381c0d4448',
      ),
    );
    expect(header, contains('8efd9c48e7249b4256ca3a778cb6bf062b871771'));
    expect(
      header,
      contains(
        '1e614e559d1b7ae6fb29e2525bae784023fc0b3b5f068dc46c24027cab9e6a68',
      ),
    );
    expect(header, contains('kLocalSizeX = 32'));
    expect(header, contains('kLocalSizeY = 1'));
    expect(header, contains('kCandidatesPerPixel = 5'));
    expect(header, contains('kCurrentDepthCurrentNormal = 0'));
    expect(header, contains('kPreviousDepthPreviousNormal = 1'));
    expect(header, contains('kRandomDepthRandomNormal = 2'));
    expect(header, contains('kCurrentDepthRandomNormal = 3'));
    expect(header, contains('kRandomDepthCurrentNormal = 4'));
    expect(header, contains('kGeomConsistencySpecializationId = 2'));
    expect(header, contains('kFilterPhotoSpecializationId = 3'));
    expect(header, contains('kFilterGeomSpecializationId = 4'));
    expect(header, contains('kFinalGeometricMask = 7'));
    expect(header, contains('kFinalMaskRequiresAdditionalSweep = false'));
    expect(header, contains('kNccNormFactorPatchPcByteOffset = 28'));
    expect(header, contains('ComputeNccCostNormFactor'));
    expect(header, contains('EncodeNccNormFactorForPatchPcReservedBits'));
    expect(header, contains('kUnavailableUntilCudaXorwowAndTextureParity'));
    expect(header, contains('return false'));
  });

  test('CPU oracle fixes last-tie, strict CDF, and unguarded zero PDF', () {
    expect(_findMinCostLastTie(<double>[3, 1, 2, 1, 1]), 4);
    expect(_transformPdfToCdf(<double>[1, 1, 2]), <double>[0.25, 0.5, 1]);
    expect(_strictCdfSelect(<double>[0.25, 0.5, 1], 0.25), 1);
    expect(_strictCdfSelect(<double>[0.25, 0.5, 1], 1), -1);

    final zero = _transformPdfToCdf(<double>[0, 0]);
    expect(zero.every((value) => value.isNaN), isTrue);
  });

  test('row zero propagates from row -1 and perturbation is not clamped', () {
    final rowZero = _propagateDepth(
      depth: 2,
      normal: <double>[0, 0.25, -0.5],
      row1: -1,
      row2: 0,
      inverseFy: 0.5,
      inverseNegCyFy: -0.25,
    );
    expect(rowZero, closeTo(22 / 9, 1e-12));

    const perturbation = 2.0;
    const depth = 4.0;
    const uniformDraw = 0.0;
    final depthMin = (1 - perturbation) * depth;
    final depthMax = (1 + perturbation) * depth;
    final perturbed = uniformDraw * (depthMax - depthMin) + depthMin;
    expect(perturbed, -4);
  });

  test('CPU oracle fixes backward, forward, and selection messages', () {
    final beta = _message(
      cost: 0.4,
      previous: 0.3,
      sigma: 0.6,
      normalization: 0.8,
      forward: false,
    );
    final alpha = _message(
      cost: 0.4,
      previous: 0.3,
      sigma: 0.6,
      normalization: 0.8,
      forward: true,
    );
    final zn0 = (1 - alpha) * (1 - beta);
    final zn1 = alpha * beta;
    final current = zn1 / (zn0 + zn1);
    final selected = 0.25 * 0.6 + 0.75 * current;

    expect(beta, closeTo(0.3544572403276211, 1e-15));
    expect(alpha, closeTo(0.3544586878184082, 1e-15));
    expect(selected, closeTo(0.32373971717107275, 1e-15));
  });

  test('structural sweep compiles but cannot dispatch or mutate outputs', () {
    final shader = File(shaderPath).readAsStringSync();

    expect(shader, contains('#version 450'));
    expect(
      shader,
      contains('local_size_x = 32, local_size_y = 1, local_size_z = 1'),
    );
    expect(shader, contains('ABI_ONLY_DO_NOT_DISPATCH'));
    expect(shader, contains('for (uint row = 0u; row < pc.height; ++row)'));
    expect(shader, contains('barrier(); // every lane, exactly once per row'));
    expect(shader, contains('propagate_depth'));
    expect(shader, contains('float(row) - 1.0'));
    expect(shader, contains('if (costs[index] <= min_cost)'));
    expect(shader, contains('if (cdf > draw)'));
    expect(shader, isNot(contains('epsilon')));
    expect(shader, isNot(contains('clamp(')));
    expect(shader, isNot(contains('writeonly buffer')));
    expect(shader, isNot(contains('depth_map.values[')));
    expect(shader, isNot(contains('normal_map.values[')));
    expect(shader, isNot(contains('rand_state.values[')));

    final temp = Directory.systemTemp.createTempSync('pw-sweep-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final spv = '${temp.path}/sweep.spv';
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

  test('host contract compiles and its CPU oracle executes', () {
    final temp = Directory.systemTemp.createTempSync('pw-sweep-host-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = '${temp.path}/sweep_contract_test';
    final compile = Process.runSync('clang++', <String>[
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I',
      root,
      '$root/sweep_contract_test.cc',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
  });

  test('full sweep source is complete but hard-gated on exact XORWOW', () {
    const fullShaderPath = '$root/sweep_full_unavailable.comp';
    final source = File(fullShaderPath).readAsStringSync();

    expect(source, contains('#include "../cost_ops/cost_ops.glsl"'));
    expect(source, contains('#error COLMAP_XORWOW_UNIFORM_REQUIRED'));
    expect(source, contains('CONTRACT_TEST_ONLY_NOT_RUNNABLE'));
    expect(source, contains('kFinalGeometricMask = 7u'));
    expect(source, contains('FINAL_MASK_REUSES_FINAL_SCHEDULED_SWEEP'));
    expect(source, contains('layout(local_size_x = 32'));
    for (final binding in <int>[
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      9,
      10,
      11,
      12,
      13,
      14,
    ]) {
      expect(source, contains('binding = $binding'));
    }
    expect(source, contains('float(col) - 5.0'));
    expect(source, contains('float(row) - 5.0'));
    expect(source, isNot(contains('float(col - 5u)')));
    expect(source, isNot(contains('float(row - 5u)')));

    final rowLoopStart = source.indexOf(
      'for (uint row = 0u; row < pc.height; ++row)',
    );
    final rowLoopEnd = source.indexOf(
      'if (col < pc.width) {\n    StoreXorwowState',
      rowLoopStart,
    );
    expect(rowLoopStart, greaterThanOrEqualTo(0));
    expect(rowLoopEnd, greaterThan(rowLoopStart));
    final rowLoop = source.substring(rowLoopStart, rowLoopEnd);
    expect(
      rowLoop,
      contains('barrier(); // row-start: publish complete shared tile'),
    );
    expect(
      rowLoop,
      contains('barrier(); // row-end: all photo-cost reads complete'),
    );
    expect(RegExp(r'\bbarrier\(\);').allMatches(rowLoop).length, 2);
    expect(rowLoop, isNot(contains('if (col >= pc.width) {\n      continue;')));
    expect(
      rowLoop.indexOf('barrier(); // row-end'),
      greaterThan(rowLoop.indexOf('previous_normal = best_normal;')),
    );

    final orderedTokens = <String>[
      'void ComputeBackwardMessages',
      'ComputeBackwardMessages(col);',
      'LoadXorwowState(0u, col)',
      'LocalRefImageRead(int(row));',
      'barrier();',
      'float(row) - 1.0',
      'float random_depth = PerturbDepth',
      'vec3 random_normal = PerturbNormal',
      'TransformPDFToCDF',
      'float random_probability = ColmapXorwowUniform',
      'StrictCDFSelection',
      'PhotoCandidateCost',
      'GeometricCandidateCost',
      'FindMinCostLastTie',
      'depth_map.values[pixel_index] = best_depth',
      'forward_message.values[forward_index] = alpha',
      'selection_probability.values[cost_index] = probability',
      'consistency_mask.values[cost_index] = 1u',
      'StoreXorwowState(0u, col, random_state);',
    ];
    var cursor = -1;
    for (final token in orderedTokens) {
      final next = source.indexOf(token, cursor + 1);
      expect(next, greaterThan(cursor), reason: 'missing/out-of-order: $token');
      cursor = next;
    }

    final blocked = Process.runSync('glslangValidator', <String>[
      '-V',
      '--target-env',
      'vulkan1.1',
      '-Ivendor/official_dense/cost_ops',
      fullShaderPath,
    ]);
    expect(blocked.exitCode, isNot(0));
    expect(
      '${blocked.stdout}${blocked.stderr}',
      contains('COLMAP_XORWOW_UNIFORM_REQUIRED'),
    );

    final temp = Directory.systemTemp.createTempSync('pw-sweep-full-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final spv = '${temp.path}/sweep_full_contract_only.spv';
    final syntaxOnly = Process.runSync('glslangValidator', <String>[
      '-V',
      '--target-env',
      'vulkan1.1',
      '-DCOLMAP_SWEEP_CONTRACT_TEST_ONLY=1',
      '-Ivendor/official_dense/cost_ops',
      '-o',
      spv,
      fullShaderPath,
    ]);
    expect(
      syntaxOnly.exitCode,
      0,
      reason: '${syntaxOnly.stdout}${syntaxOnly.stderr}',
    );
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

    final disassemblyPath = '${temp.path}/sweep_full_contract_only.spvasm';
    final disassemble = Process.runSync('spirv-dis', <String>[
      spv,
      '-o',
      disassemblyPath,
    ]);
    expect(
      disassemble.exitCode,
      0,
      reason: '${disassemble.stdout}${disassemble.stderr}',
    );
    final disassembly = File(disassemblyPath).readAsStringSync();
    expect(disassembly, contains('SpecId 2'));
    expect(disassembly, contains('SpecId 3'));
    expect(disassembly, contains('SpecId 4'));
    expect(RegExp(r'\bOpControlBarrier\b').allMatches(disassembly).length, 2);
  });

  test('full OpenMVS-PCG adaptation preserves the COLMAP sweep contract', () {
    const adaptedPath = '$root/sweep_full_openmvs_pcg.comp';
    final source = File(adaptedPath).readAsStringSync();

    expect(source, contains('#include "../cost_ops/cost_ops.glsl"'));
    expect(source, contains('#include "../rng/openmvs_pcg.glsl"'));
    expect(
      source,
      contains('COLMAP 4.1.1 sweep/control flow + OpenMVS-PCG adaptation'),
    );
    expect(source, contains('REFERENCE_ONLY_NON_RUNNABLE'));
    expect(source, contains('8efd9c48e7249b4256ca3a778cb6bf062b871771'));
    expect(
      source,
      contains(
        '1e614e559d1b7ae6fb29e2525bae784023fc0b3b5f068dc46c24027cab9e6a68',
      ),
    );
    expect(source, contains('layout(local_size_x = 32'));
    expect(source, contains('buffer OpenMvsPcgState'));
    expect(source, contains('random_state = openmvs_pcg_state.values[col];'));
    expect(source, contains('openmvs_pcg_state.values[col] = random_state;'));
    expect(
      RegExp(r'openmvs_pcg_state\.values\[col\]').allMatches(source).length,
      2,
      reason: 'exactly one pre-loop state load and one post-loop state store',
    );
    expect(source, isNot(contains('openmvs_pcg_state.values[GpuMatIndex')));
    expect(source, isNot(contains('ColmapXorwow')));
    expect(source, isNot(contains('reseed')));

    final rowLoopStart = source.indexOf(
      'for (uint row = 0u; row < pc.height; ++row)',
    );
    final rowLoopEnd = source.indexOf(
      'openmvs_pcg_state.values[col] = random_state;',
      rowLoopStart,
    );
    expect(rowLoopStart, greaterThanOrEqualTo(0));
    expect(rowLoopEnd, greaterThan(rowLoopStart));
    expect(source, contains('void ComputeBackwardMessages(uint col)'));
    expect(source, contains('ComputeBackwardMessages(col);'));
    expect(source, contains('float beta = uniform_probability;'));
    expect(
      source,
      contains('previous_depth = depth_map.values[PixelIndex(0u, col)];'),
    );
    expect(source, isNot(contains('packed_execution_range')));
    expect(source, isNot(contains('row_begin')));
    expect(source, isNot(contains('row_end')));
    final rowLoop = source.substring(rowLoopStart, rowLoopEnd);
    expect(RegExp(r'\bbarrier\(\);').allMatches(rowLoop).length, 2);
    expect(
      rowLoop,
      contains('barrier(); // row-start: publish complete shared tile'),
    );
    expect(
      rowLoop,
      contains('barrier(); // row-end: all photo-cost reads complete'),
    );
    expect(
      rowLoop,
      contains(
        'float random_probability = openmvs_pcg_next_uniform(random_state) -\n'
        '          1.1920928955078125e-7;',
      ),
    );
    expect(
      RegExp(
        r'openmvs_pcg_next_uniform\(random_state\)',
      ).allMatches(source).length,
      5,
      reason: 'one depth site, three normal sites, one selection site',
    );
    expect(source, contains('for (int trial = 0; trial <= 3; ++trial)'));
    expect(source, contains('perturbation *= 0.5;'));
    expect(source, contains('if (trial == 3)'));
    expect(source, contains('if (selected_source == -1)'));
    expect(source, contains('kFinalGeometricMask = 7u'));

    final temp = Directory.systemTemp.createTempSync('pw-sweep-pcg-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final spv = '${temp.path}/sweep_full_openmvs_pcg.spv';
    final compile = Process.runSync('glslangValidator', <String>[
      '-V',
      '--target-env',
      'vulkan1.1',
      '-o',
      spv,
      adaptedPath,
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

    final disassemblyPath = '${temp.path}/sweep_full_openmvs_pcg.spvasm';
    final disassemble = Process.runSync('spirv-dis', <String>[
      spv,
      '-o',
      disassemblyPath,
    ]);
    expect(
      disassemble.exitCode,
      0,
      reason: '${disassemble.stdout}${disassemble.stderr}',
    );
    final disassembly = File(disassemblyPath).readAsStringSync();
    expect(disassembly, contains('SpecId 2'));
    expect(disassembly, contains('SpecId 3'));
    expect(disassembly, contains('SpecId 4'));
    expect(RegExp(r'\bOpControlBarrier\b').allMatches(disassembly).length, 2);
  });

  test('sweep module contains no Swift', () {
    final swiftFiles = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.swift'))
        .toList();
    expect(swiftFiles, isEmpty);
  });
}
