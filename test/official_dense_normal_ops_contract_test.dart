import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

List<double> _marsagliaNormal(
  double u1,
  double u2, {
  required int row,
  required int col,
  required List<double> refInvK,
}) {
  final v1 = 2.0 * u1 - 1.0;
  final v2 = 2.0 * u2 - 1.0;
  final s = v1 * v1 + v2 * v2;
  if (s >= 1.0) {
    throw ArgumentError('The frozen draw pair must pass Marsaglia rejection');
  }

  final sNorm = math.sqrt(1.0 - s);
  final normal = <double>[2.0 * v1 * sNorm, 2.0 * v2 * sNorm, 1.0 - 2.0 * s];
  final viewRay = <double>[
    refInvK[0] * col + refInvK[1],
    refInvK[2] * row + refInvK[3],
    1.0,
  ];
  final dot =
      normal[0] * viewRay[0] + normal[1] * viewRay[1] + normal[2] * viewRay[2];
  if (dot > 0.0) {
    for (var axis = 0; axis < 3; axis++) {
      normal[axis] = -normal[axis];
    }
  }
  return normal;
}

List<double> _rotateNormal(List<double> normal) => <double>[
  normal[1],
  -normal[0],
  normal[2],
];

void main() {
  const shaderRoot = 'vendor/official_dense/normal_ops';
  const depthRoot = 'vendor/official_dense/depth_ops';
  const rngRoot = 'vendor/official_dense/rng';

  test('reference PCG init chain preserves COLMAP depth then normal order', () {
    final depth = File(
      '$depthRoot/init_depth_openmvs_pcg.comp',
    ).readAsStringSync();
    final normal = File(
      '$shaderRoot/init_normal_openmvs_pcg.comp',
    ).readAsStringSync();
    final layout = File(
      '$rngRoot/openmvs_pcg_initialization_layout.glsl',
    ).readAsStringSync();

    for (final shader in <String>[depth, normal]) {
      expect(shader, contains('#include "../rng/openmvs_pcg.glsl"'));
      expect(
        shader,
        contains('local_size_x = 16, local_size_y = 8, local_size_z = 1'),
      );
      expect(
        shader,
        contains('#include "../rng/openmvs_pcg_initialization_layout.glsl"'),
      );
      expect(shader, contains('uint state = states.values[pixel_index]'));
      expect(shader, contains('states.values[pixel_index] = state'));
      expect(
        shader,
        contains('COLMAP initialization control flow + OpenMVS-PCG adaptation'),
      );
      expect(shader, contains('reference-only, non-production'));
      expect(shader, contains('not exact CUDA/XORWOW parity'));
    }
    expect(layout, contains('buffer OpenMvsPcgStates'));
    expect(layout, contains('layout(push_constant) uniform PatchPC'));

    expect(depth, contains('openmvs_pcg_next_uniform(state)'));
    expect(depth, contains('pc.depth_min'));
    expect(depth, contains('pc.depth_max'));
    expect(depth, contains('depth_map.values[pixel_index]'));

    expect(normal, contains('while (s >= 1.0)'));
    expect(normal, contains('openmvs_pcg_next_uniform(state)'));
    expect(normal, contains('sqrt(1.0 - s)'));
    expect(normal, contains('if (dot(normal, view_ray) > 0.0)'));
    expect(
      normal,
      contains('component * pc.width * pc.height + row * pc.width + col'),
    );

    // A single uint state is initialized once, then persisted across the depth
    // and normal dispatches. No stage may reseed the stream.
    expect(depth, isNot(contains('openmvs_pcg_seed')));
    expect(normal, isNot(contains('openmvs_pcg_seed')));
  });

  test('all PCG init shaders compile and validate for Vulkan 1.1', () async {
    final shaders = <String>[
      '$rngRoot/init_openmvs_pcg.comp',
      '$depthRoot/init_depth_openmvs_pcg.comp',
      '$shaderRoot/init_normal_openmvs_pcg.comp',
    ];
    final temporary = await Directory.systemTemp.createTemp(
      'official_dense_pcg_init_spirv_',
    );
    addTearDown(() => temporary.delete(recursive: true));

    for (var index = 0; index < shaders.length; index++) {
      final output = '${temporary.path}/$index.spv';
      final compile = await Process.run('glslangValidator', <String>[
        '-V',
        '--target-env',
        'vulkan1.1',
        '-S',
        'comp',
        '-o',
        output,
        shaders[index],
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${shaders[index]}\n${compile.stdout}\n${compile.stderr}',
      );
      final validate = await Process.run('spirv-val', <String>[
        '--target-env',
        'vulkan1.1',
        output,
      ]);
      expect(
        validate.exitCode,
        0,
        reason: '${shaders[index]}\n${validate.stdout}\n${validate.stderr}',
      );
      if (index > 0) {
        final disassembly = await Process.run('spirv-dis', <String>[output]);
        expect(
          disassembly.exitCode,
          0,
          reason: '${disassembly.stdout}\n${disassembly.stderr}',
        );
        expect(
          disassembly.stdout,
          contains('NoContraction'),
          reason: 'float32 init arithmetic must not contract into FMA',
        );
      }
    }
  });

  test('normal shaders pin COLMAP 4.1.1 geometry and planar storage', () {
    final init = File(
      '$shaderRoot/init_normal_unavailable.comp',
    ).readAsStringSync();
    final rotate = File(
      '$shaderRoot/rotate_normal_f32.comp',
    ).readAsStringSync();

    for (final shader in <String>[init, rotate]) {
      expect(shader, contains('COLMAP 4.1.1 a0d785f'));
      expect(
        shader,
        contains(
          '1aebd4482de0ea6f1f3aad45150c09e0479119c607a843959c8aaa381c0d4448',
        ),
      );
      expect(shader, contains('layout(push_constant) uniform PatchPC'));
      expect(
        shader,
        contains('component * pc.width * pc.height + row * pc.width + col'),
      );
      expect(shader, isNot(contains('normal_pitch_bytes')));
    }
    expect(
      rotate,
      contains('local_size_x = 16, local_size_y = 8, local_size_z = 1'),
    );
  });

  test('InitNormalMap preserves Marsaglia and camera-facing semantics', () {
    final init = File(
      '$shaderRoot/init_normal_unavailable.comp',
    ).readAsStringSync();

    expect(init, contains('#ifndef COLMAP_XORWOW_UNIFORM_BOUND'));
    expect(init, contains('#error COLMAP_XORWOW_UNIFORM_REQUIRED'));
    expect(init, contains('colmap_curand_uniform'));
    expect(init, contains('while (s >= 1.0)'));
    expect(init, contains('sqrt(1.0 - s)'));
    expect(init, contains('if (dot(normal, view_ray) > 0.0)'));
    expect(init.toLowerCase(), isNot(contains('xorshift')));
    expect(init.toLowerCase(), isNot(contains('pcg')));
    expect(init.toLowerCase(), isNot(contains('philox')));
    expect(init.toLowerCase(), isNot(contains('splitmix')));
  });

  test(
    'InitNormalMap fails closed until official XORWOW uniform is bound',
    () async {
      final result = await Process.run('glslangValidator', <String>[
        '-V',
        '$shaderRoot/init_normal_unavailable.comp',
        '-o',
        '${Directory.systemTemp.path}/official_dense_init_normal.spv',
      ]);

      expect(result.exitCode, isNot(0));
      expect(
        '${result.stdout}${result.stderr}',
        contains('COLMAP_XORWOW_UNIFORM_REQUIRED'),
      );
    },
  );

  test('RotateNormalMap is the exact counter-clockwise z rotation', () {
    final rotate = File(
      '$shaderRoot/rotate_normal_f32.comp',
    ).readAsStringSync();
    expect(
      rotate,
      contains('rotated_normal = vec3(normal.y, -normal.x, normal.z)'),
    );

    expect(_rotateNormal(<double>[1.25, -2.5, 3.75]), <double>[
      -2.5,
      -1.25,
      3.75,
    ]);
  });

  test('CPU oracle fixes rejection, unit length, and view-ray reversal', () {
    expect(
      () => _marsagliaNormal(
        1.0,
        1.0,
        row: 0,
        col: 0,
        refInvK: <double>[1, 0, 1, 0],
      ),
      throwsArgumentError,
    );

    final normal = _marsagliaNormal(
      0.5,
      0.5,
      row: 2,
      col: 3,
      refInvK: <double>[0.25, -0.5, 0.5, -0.25],
    );
    final length = math.sqrt(normal.fold<double>(0, (sum, v) => sum + v * v));
    final viewRay = <double>[0.25, 0.75, 1.0];
    final dot =
        normal[0] * viewRay[0] +
        normal[1] * viewRay[1] +
        normal[2] * viewRay[2];
    expect(length, closeTo(1.0, 1e-12));
    expect(dot, lessThanOrEqualTo(0.0));
    expect(normal, <double>[-0.0, -0.0, -1.0]);
  });

  test('normal-operation module contains no Swift', () {
    final swiftFiles = Directory(shaderRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.swift'))
        .toList();
    expect(swiftFiles, isEmpty);
  });
}
