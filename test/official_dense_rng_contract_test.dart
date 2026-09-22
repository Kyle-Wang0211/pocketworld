import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rngRoot = 'vendor/official_dense/rng';

  test('OpenMVS PCG reference is pinned and remains non-dispatchable', () {
    final header = File('$rngRoot/openmvs_pcg_reference.h').readAsStringSync();
    final glsl = File('$rngRoot/openmvs_pcg.glsl').readAsStringSync();
    final initShader = File(
      '$rngRoot/init_openmvs_pcg.comp',
    ).readAsStringSync();
    final provenance =
        jsonDecode(
              File(
                '$rngRoot/third_party/openmvs_pcg/provenance.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final license = File(
      '$rngRoot/third_party/openmvs_pcg/LICENSE',
    ).readAsBytesSync();

    const upstreamCommit = '8efd9c48e7249b4256ca3a778cb6bf062b871771';
    const shaderSha =
        '1e614e559d1b7ae6fb29e2525bae784023fc0b3b5f068dc46c24027cab9e6a68';
    const licenseSha =
        '0f072d4a0ef59e7f6864bb45629c37417ccef63025b58f4073109d1c830bc55f';

    expect(header, contains(upstreamCommit));
    expect(header, contains(shaderSha));
    expect(header, contains(licenseSha));
    expect(header, contains('SeedForPixel'));
    expect(header, contains('NextState'));
    expect(header, contains('OutputFromState'));
    expect(header, contains('UniformBits'));
    expect(header, contains('UniformFromOutput'));

    expect(glsl, contains('openmvs_pcg_seed'));
    expect(glsl, contains('openmvs_pcg_next_state'));
    expect(glsl, contains('openmvs_pcg_output'));
    expect(glsl, contains('openmvs_pcg_uniform_bits'));
    expect(glsl, contains('openmvs_pcg_uniform'));
    expect(glsl, contains('747796405u'));
    expect(glsl, contains('2891336453u'));
    expect(glsl, contains('277803737u'));

    expect(initShader, contains('#version 450'));
    expect(initShader, contains('#include "openmvs_pcg.glsl"'));
    expect(initShader, contains('openmvs_pcg_initialization_layout.glsl'));
    expect(initShader, contains('if (pixel.x >= pc.width'));
    expect(initShader, contains('states.values[pixel.y * pc.width + pixel.x]'));
    expect(initShader, contains('openmvs_pcg_seed(pixel)'));
    expect(
      initShader,
      contains('local_size_x = 16, local_size_y = 8, local_size_z = 1'),
    );

    expect(
      provenance['upstream_repository'],
      'https://github.com/cdcseacave/openMVS',
    );
    expect(provenance['upstream_commit'], upstreamCommit);
    expect(provenance['source_path'], 'libs/MVS/PatchMatchMetal.metal');
    expect(provenance['source_sha256'], shaderSha);
    expect(provenance['source_license'], 'AGPL-3.0-or-later');
    expect(provenance['license_file_version'], 'AGPL-3.0');
    expect(provenance['license_sha256'], licenseSha);
    expect(sha256.convert(license).toString(), licenseSha);

    final algorithmText = '$header\n$glsl'.toLowerCase();
    expect(algorithmText, isNot(contains('pcg32_random_r')));
    expect(algorithmText, isNot(contains('pcg_basic')));
    expect(algorithmText, isNot(contains('xorwow')));
    expect(algorithmText, isNot(contains('nvidia')));
    expect(initShader, contains('not exact CUDA/XORWOW parity'));

    // Adding this reference path must not enable the existing production gate.
    final dispatchContract = File('$rngRoot/rng_contract.h').readAsStringSync();
    expect(dispatchContract, contains('CanDispatchRngBackend'));
    expect(dispatchContract, contains('return false'));
  });

  test(
    'COLMAP-order OpenMVS-PCG initialization oracle passes strict C++17',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'official_dense_pcg_init_oracle_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final executable = '${temporary.path}/initialization_contract_test';
      final compile = await Process.run('clang++', <String>[
        '-std=c++17',
        '-Wall',
        '-Wextra',
        '-Werror',
        '-pedantic',
        '$rngRoot/initialization_contract_test.cc',
        '-I$rngRoot',
        '-o',
        executable,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final run = await Process.run(executable, const <String>[]);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');

      final oracle = File(
        '$rngRoot/openmvs_pcg_initialization_reference.h',
      ).readAsStringSync();
      expect(
        oracle,
        contains('COLMAP initialization control flow + OpenMVS-PCG adaptation'),
      );
      expect(oracle, contains('depth consumes exactly one draw'));
      expect(oracle, contains('normal continues the persisted state'));
      expect(oracle, contains('not exact CUDA/XORWOW parity'));
      expect(oracle, contains('NoContraction'));
      expect(oracle, contains('FMA'));
    },
  );

  test('compiled OpenMVS PCG SPIR-V produces the fixed vectors', () async {
    final result = await Process.run('python3', <String>[
      '$rngRoot/verify_openmvs_pcg_spirv.py',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final report = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(report['execution'], 'spirv-interpreter');
    expect(report['gpu_execution'], isFalse);
    expect(report['validated'], isTrue);
    expect(report['vector_count'], greaterThanOrEqualTo(12));
    expect(report['seed_0_0'], 1234);
    expect(report['next_state_0_0'], 2254131583);
    expect(report['raw_output_0_0'], 1819980427);
    expect(report['low24_0_0'], 8041099);
    expect(report['uniform_float_bits_0_0'], 0x3ef56516);
    expect(report['seed_wraparound'], 4294957280);
    expect(report['successive_state_2'], 2084420317);
    expect(report['successive_raw_2'], 1970291471);
  });

  test('COLMAP 4.1.1 XORWOW contract is pinned and fail-closed', () {
    final header = File('$rngRoot/rng_contract.h').readAsStringSync();

    expect(
      header,
      contains(
        'aac48adcc68e558b3634141d327a352895ea90d351c254bce3e7d289f5ffe15f',
      ),
    );
    expect(header, contains('kInitBlockSizeX = 32'));
    expect(header, contains('kInitBlockSizeY = 16'));
    expect(header, contains('SeedForInvocation'));
    expect(header, contains('return linear_thread_id'));
    expect(header, contains('kSubsequence = 0'));
    expect(header, contains('kOffset = 0'));
    expect(header, contains('StateWordIndex'));
    expect(header, contains('state_word * width * height'));
    expect(header, contains('kCurandUniformLowerExclusive'));
    expect(header, contains('kCurandUniformUpperInclusive'));
    expect(header, contains('kUnavailableUntilCudaXorwowParity'));
    expect(header, contains('return false'));
  });

  test(
    'structural shader compiles but cannot generate or mutate RNG state',
    () {
      final shader = File(
        '$rngRoot/init_xorwow_unavailable.comp',
      ).readAsStringSync();

      expect(shader, contains('#version 450'));
      expect(
        shader,
        contains('local_size_x = 32, local_size_y = 16, local_size_z = 1'),
      );
      expect(shader, contains('readonly buffer XorwowStateWords'));
      expect(shader, contains('ABI_ONLY_DO_NOT_DISPATCH'));
      expect(shader, isNot(contains('writeonly')));
      expect(shader, isNot(contains('state_words.values[')));

      final forbiddenSubstitutes = <String>[
        'pcg',
        'xorshift',
        'philox',
        'splitmix',
        'wang_hash',
      ];
      final lower = shader.toLowerCase();
      for (final substitute in forbiddenSubstitutes) {
        expect(lower, isNot(contains(substitute)));
      }
    },
  );

  test('5090 golden manifest fixes state and draw ordering', () {
    final schema =
        jsonDecode(File('$rngRoot/golden_schema_v1.json').readAsStringSync())
            as Map<String, dynamic>;

    expect(schema['schema'], 'pocketworld.colmap411.curand_xorwow_golden.v1');
    expect(
      schema['upstream_commit'],
      'a0d785fba74b2664f31edc4a29026a8b27c00f67',
    );
    expect(
      schema['gpu_mat_prng_sha256'],
      'aac48adcc68e558b3634141d327a352895ea90d351c254bce3e7d289f5ffe15f',
    );
    expect(schema['init_block'], <dynamic>[32, 16, 1]);
    expect(schema['seed'], 'linear_thread_id');
    expect(schema['subsequence'], 0);
    expect(schema['offset'], 0);
    expect(schema['state_order'], 'state_word,row,col');
    expect(schema['uniform_order'], 'draw,row,col');
    expect(schema['uniform_range'], '(0,1]');
    expect(schema['endianness'], 'little');
  });

  test(
    'golden verifier rejects incomplete captures before parity is enabled',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'official_dense_rng_golden_',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final manifest = File('${temporary.path}/manifest.json');
      await manifest.writeAsString(
        jsonEncode(<String, Object?>{
          'schema': 'pocketworld.colmap411.curand_xorwow_golden.v1',
        }),
      );

      final result = await Process.run('python3', <String>[
        '$rngRoot/verify_golden.py',
        manifest.path,
      ]);

      expect(result.exitCode, isNot(0));
      expect('${result.stdout}${result.stderr}', contains('INVALID'));
    },
  );

  test(
    'golden verifier accepts an internally consistent capture package',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'official_dense_rng_valid_golden_',
      );
      addTearDown(() => temporary.delete(recursive: true));

      Uint8List littleEndianWords(List<int> words) {
        final bytes = ByteData(words.length * 4);
        for (var index = 0; index < words.length; index++) {
          bytes.setUint32(index * 4, words[index], Endian.little);
        }
        return bytes.buffer.asUint8List();
      }

      final stateBytes = littleEndianWords(<int>[1, 2]);
      final uniformBytes = littleEndianWords(<int>[0x3f000000, 0x3f800000]);
      await File('${temporary.path}/state.bin').writeAsBytes(stateBytes);
      await File('${temporary.path}/uniform.bin').writeAsBytes(uniformBytes);

      final manifest = <String, Object?>{
        'schema': 'pocketworld.colmap411.curand_xorwow_golden.v1',
        'upstream_commit': 'a0d785fba74b2664f31edc4a29026a8b27c00f67',
        'gpu_mat_prng_sha256':
            'aac48adcc68e558b3634141d327a352895ea90d351c254bce3e7d289f5ffe15f',
        'cuda_runtime_version': 'synthetic-test',
        'cuda_driver_version': 'synthetic-test',
        'cuda_device_name': 'NVIDIA GeForce RTX 5090 synthetic-test',
        'cuda_device_uuid': 'synthetic-test',
        'init_block': <int>[32, 16, 1],
        'width': 2,
        'height': 1,
        'seed': 'linear_thread_id',
        'subsequence': 0,
        'offset': 0,
        'state_word_count': 1,
        'state_order': 'state_word,row,col',
        'state_file': 'state.bin',
        'state_sha256': sha256.convert(stateBytes).toString(),
        'draws_per_state': 1,
        'uniform_order': 'draw,row,col',
        'uniform_range': '(0,1]',
        'uniform_bits_file': 'uniform.bin',
        'uniform_bits_sha256': sha256.convert(uniformBytes).toString(),
        'endianness': 'little',
      };
      final manifestFile = File('${temporary.path}/manifest.json');
      await manifestFile.writeAsString(jsonEncode(manifest));

      final result = await Process.run('python3', <String>[
        '$rngRoot/verify_golden.py',
        manifestFile.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('VALID'));

      manifest['cuda_device_name'] = 'NVIDIA GeForce RTX 4090 synthetic-test';
      await manifestFile.writeAsString(jsonEncode(manifest));
      final wrongGpuResult = await Process.run('python3', <String>[
        '$rngRoot/verify_golden.py',
        manifestFile.path,
      ]);
      expect(wrongGpuResult.exitCode, isNot(0));
      expect(
        '${wrongGpuResult.stdout}${wrongGpuResult.stderr}',
        contains('INVALID'),
      );
    },
  );

  test('RNG module contains no Swift', () {
    final swiftFiles = Directory(rngRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.swift'))
        .toList();

    expect(swiftFiles, isEmpty);
  });
}
