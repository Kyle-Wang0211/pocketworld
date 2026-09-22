import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('glslang optimizer stays disabled for strict operation ordering', () {
    final source = File(
      'vendor/official_dense/build/build_gate.py',
    ).readAsStringSync();
    final compileStart = source.indexOf('def compile_shader(');
    final compileEnd = source.indexOf('\ndef ', compileStart + 1);
    expect(compileStart, greaterThanOrEqualTo(0));
    expect(compileEnd, greaterThan(compileStart));
    final compileFunction = source.substring(compileStart, compileEnd);
    expect(compileFunction, isNot(contains('"-O"')));
  });

  test('official dense build gate is fail-closed and emits audited SPIR-V', () async {
    final root = Directory.current.path;
    final output = await Directory.systemTemp.createTemp(
      'official_dense_gate_',
    );
    addTearDown(() => output.deleteSync(recursive: true));

    final result = await Process.run('python3', <String>[
      '$root/vendor/official_dense/build/build_gate.py',
      '--output',
      output.path,
    ], workingDirectory: root);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final manifestFile = File('${output.path}/manifest.json');
    expect(manifestFile.existsSync(), isTrue);
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;

    expect(manifest['schema_version'], 1);
    expect(
      manifest['upstream_commit'],
      'a0d785fba74b2664f31edc4a29026a8b27c00f67',
    );
    expect(manifest['target_environment'], 'vulkan1.1');
    expect(manifest['overall_ready'], isFalse);
    expect(manifest['rng_backend_dispatchable'], isFalse);
    expect(manifest['sweep_backend_dispatchable'], isFalse);
    expect(
      manifest['backend_status'],
      'unavailable-pending-licensed-xorwow-and-parity',
    );

    final blockers = (manifest['blockers'] as List).cast<String>();
    expect(blockers, contains('cuda-xorwow-golden-required'));
    expect(
      blockers,
      contains('commercially-permitted-xorwow-semantics-required'),
    );
    expect(blockers, contains('patchmatch-sweep-parity-required'));
    expect(blockers, contains('openmvs-pcg-adaptation-parity-required'));

    final shaders = (manifest['shaders'] as List).cast<Map<String, dynamic>>();
    expect(shaders, isNotEmpty);
    expect(
      shaders.where(
        (shader) => shader['classification'] == 'runnable-structural',
      ),
      isNotEmpty,
    );

    final openMvsPcgInit = shaders.singleWhere(
      (shader) => shader['source_path'] == 'rng/init_openmvs_pcg.comp',
    );
    expect(openMvsPcgInit['classification'], 'reference-only-non-runnable');
    expect(openMvsPcgInit['runnable'], isFalse);
    expect(openMvsPcgInit['compiled'], isTrue);
    expect(
      openMvsPcgInit['blockers'],
      containsAll(<String>[
        'production-rng-dispatch-disabled',
        'agpl-reference-not-production-backend',
      ]),
    );
    expect(
      openMvsPcgInit['classification'],
      isNot('runnable-structural'),
      reason: 'CanDispatchRngBackend() remains false',
    );

    final dependencyIdentities =
        (openMvsPcgInit['dependency_identities'] as List)
            .cast<Map<String, dynamic>>();
    final expectedDependencies = <String, String>{
      'src/colmap/mvs/gpu_mat_prng.cu': sha256
          .convert(
            File(
              '$root/vendor/official_dense/third_party/colmap-4.1.1/src/colmap/mvs/gpu_mat_prng.cu',
            ).readAsBytesSync(),
          )
          .toString(),
      'rng/openmvs_pcg.glsl': sha256
          .convert(
            File(
              '$root/vendor/official_dense/rng/openmvs_pcg.glsl',
            ).readAsBytesSync(),
          )
          .toString(),
      'rng/openmvs_pcg_initialization_layout.glsl': sha256
          .convert(
            File(
              '$root/vendor/official_dense/rng/openmvs_pcg_initialization_layout.glsl',
            ).readAsBytesSync(),
          )
          .toString(),
      'rng/third_party/openmvs_pcg/LICENSE': sha256
          .convert(
            File(
              '$root/vendor/official_dense/rng/third_party/openmvs_pcg/LICENSE',
            ).readAsBytesSync(),
          )
          .toString(),
      'rng/third_party/openmvs_pcg/provenance.json': sha256
          .convert(
            File(
              '$root/vendor/official_dense/rng/third_party/openmvs_pcg/provenance.json',
            ).readAsBytesSync(),
          )
          .toString(),
    };
    expect(
      dependencyIdentities.map((entry) => entry['path']).toSet(),
      expectedDependencies.keys.toSet(),
    );
    for (final dependency in dependencyIdentities) {
      expect(
        dependency['sha256'],
        expectedDependencies[dependency['path'] as String],
      );
    }
    expect(
      dependencyIdentities.singleWhere(
        (entry) => entry['path'].toString().endsWith('/LICENSE'),
      )['license'],
      'AGPL-3.0-or-later',
    );

    final adaptedInitPaths = <String>{
      'rng/init_openmvs_pcg.comp',
      'depth_ops/init_depth_openmvs_pcg.comp',
      'normal_ops/init_normal_openmvs_pcg.comp',
    };
    for (final path in adaptedInitPaths) {
      final shader = shaders.singleWhere(
        (entry) => entry['source_path'] == path,
      );
      expect(shader['classification'], 'reference-only-non-runnable');
      expect(shader['runnable'], isFalse);
      expect(shader['compiled'], isTrue);
      expect(shader['local_size'], <dynamic>[16, 8, 1]);
      expect(
        (shader['blockers'] as List).cast<String>(),
        containsAll(<String>[
          'production-rng-dispatch-disabled',
          'openmvs-pcg-adaptation-parity-required',
        ]),
      );
      final dependencyPaths = (shader['dependency_identities'] as List)
          .cast<Map<String, dynamic>>()
          .map((entry) => entry['path'])
          .toSet();
      expect(dependencyPaths, contains('rng/openmvs_pcg.glsl'));
      expect(
        dependencyPaths,
        contains('rng/third_party/openmvs_pcg/provenance.json'),
      );
      expect(dependencyPaths, contains('rng/third_party/openmvs_pcg/LICENSE'));
    }

    final adaptedSweep = shaders.singleWhere(
      (shader) => shader['source_path'] == 'sweep/sweep_full_openmvs_pcg.comp',
    );
    expect(adaptedSweep['classification'], 'reference-only-non-runnable');
    expect(adaptedSweep['runnable'], isFalse);
    expect(adaptedSweep['compiled'], isTrue);
    expect(adaptedSweep['local_size'], <dynamic>[32, 1, 1]);
    expect(
      (adaptedSweep['blockers'] as List).cast<String>(),
      containsAll(<String>[
        'production-rng-dispatch-disabled',
        'production-sweep-dispatch-disabled',
        'openmvs-pcg-adaptation-parity-required',
        'cuda-texture-parity-required',
        'agpl-reference-not-production-backend',
      ]),
    );
    final sweepDependencyPaths = (adaptedSweep['dependency_identities'] as List)
        .cast<Map<String, dynamic>>()
        .map((entry) => entry['path'])
        .toSet();
    expect(
      sweepDependencyPaths,
      containsAll(<String>[
        'src/colmap/mvs/patch_match_cuda.cu',
        'cost_ops/cost_ops.glsl',
        'rng/openmvs_pcg.glsl',
        'rng/third_party/openmvs_pcg/LICENSE',
        'rng/third_party/openmvs_pcg/provenance.json',
      ]),
    );
    expect(
      shaders.where(
        (shader) =>
            shader['classification'] ==
            'unavailable-pending-licensed-xorwow-and-parity',
      ),
      isNotEmpty,
    );

    for (final shader in shaders) {
      expect(shader['source_sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(shader['local_size'], isA<List<dynamic>>());
      expect((shader['local_size'] as List), hasLength(3));
      expect(shader['dependencies'], isA<List<dynamic>>());
      expect(shader['blockers'], isA<List<dynamic>>());
      if (shader['compiled'] == true) {
        expect(shader['spirv_sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
        final relativeSpirv = shader['spirv_path'] as String;
        expect(relativeSpirv, isNot(startsWith(root)));
        expect(File('${output.path}/$relativeSpirv').existsSync(), isTrue);
      } else {
        expect(shader['spirv_sha256'], isNull);
        expect(
          shader['classification'],
          'unavailable-pending-licensed-xorwow-and-parity',
        );
      }
    }
  });

  test('build gate stores no generated SPIR-V outside frozen runtime assets', () {
    final sourceDir = Directory('vendor/official_dense');
    final generated = sourceDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.spv'))
        .toList();
    final manifest =
        jsonDecode(
              File(
                'vendor/official_dense/vulkan_shader_bundle/frozen_manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final shaders = (manifest['shaders'] as List).cast<Map<String, dynamic>>();
    expect(shaders, hasLength(10));
    final allowedAssets = shaders
        .map(
          (shader) =>
              'vendor/official_dense/vulkan_shader_bundle/${shader['asset_path']}',
        )
        .toSet();
    expect(allowedAssets, hasLength(10));
    expect(generated.map((file) => file.path).toSet(), allowedAssets);
    for (final shader in shaders) {
      final asset = File(
        'vendor/official_dense/vulkan_shader_bundle/${shader['asset_path']}',
      );
      expect(asset.existsSync(), isTrue);
      expect(
        sha256.convert(asset.readAsBytesSync()).toString(),
        shader['spirv_sha256'],
      );
    }
  });

  test(
    'build gate fails closed when the required shader tools are absent',
    () async {
      final root = Directory.current.path;
      final output = await Directory.systemTemp.createTemp(
        'official_dense_gate_',
      );
      addTearDown(() => output.deleteSync(recursive: true));

      final result = await Process.run(
        '/usr/bin/python3',
        <String>[
          '$root/vendor/official_dense/build/build_gate.py',
          '--output',
          output.path,
        ],
        workingDirectory: root,
        environment: const <String, String>{'PATH': '/usr/bin:/bin'},
        includeParentEnvironment: false,
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('required tool unavailable'));
      expect(File('${output.path}/manifest.json').existsSync(), isFalse);
    },
  );
}
