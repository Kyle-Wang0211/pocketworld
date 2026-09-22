import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('frozen Vulkan shader bundle regenerates byte-for-byte', () async {
    final root = Directory.current.path;
    const bundle = 'vendor/official_dense/vulkan_shader_bundle';
    final output = await Directory.systemTemp.createTemp('pw_shader_bundle_');
    addTearDown(() => output.deleteSync(recursive: true));

    final result = await Process.run('python3', <String>[
      '$root/$bundle/regenerate_frozen_bundle.py',
      '--output',
      output.path,
    ], workingDirectory: root);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

    final manifest =
        jsonDecode(
              File('$root/$bundle/frozen_manifest.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(manifest['schema_version'], 1);
    expect(manifest['target_environment'], 'vulkan1.1');
    expect(
      manifest['compiler'],
      containsPair('version', 'Glslang Version: 11:16.5.0'),
    );
    expect(
      manifest['validator'],
      containsPair(
        'version',
        'SPIRV-Tools v2026.3 unknown hash, 2026-07-22T20:34:54+00:00',
      ),
    );

    final shaders = (manifest['shaders'] as List).cast<Map<String, dynamic>>();
    expect(shaders, hasLength(10));
    expect(shaders.map((shader) => shader['kind']).toList(), <String>[
      'kReferenceFilter',
      'kOpenMvsPcgInitialize',
      'kNormalInitialize',
      'kInitialCost',
      'kFullSweep',
      'kRotateF32',
      'kTransposeF32',
      'kFlipHorizontalF32',
      'kRotateNormalF32',
      'kOpenMvsPcgDepthInitialize',
    ]);
    final assetPaths = shaders
        .map((shader) => shader['asset_path'] as String)
        .toSet();
    expect(assetPaths, hasLength(10));
    final carrierSource = File(
      '$root/$bundle/shader_bundle.cc',
    ).readAsStringSync();
    final checkedInAssets = Directory('$root/$bundle/assets')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.spv'))
        .toList();
    expect(checkedInAssets, hasLength(10));

    for (final shader in shaders) {
      final assetPath = shader['asset_path'] as String;
      expect(assetPaths, contains(assetPath));
      final checkedIn = File('$root/$bundle/$assetPath');
      final regenerated = File('${output.path}/$assetPath');
      expect(checkedIn.existsSync(), isTrue);
      expect(regenerated.existsSync(), isTrue);
      final checkedInBytes = checkedIn.readAsBytesSync();
      expect(regenerated.readAsBytesSync(), checkedInBytes);
      expect(checkedInBytes.length % 4, 0);
      expect(checkedInBytes.length ~/ 4, shader['word_count']);
      expect(sha256.convert(checkedInBytes).toString(), shader['spirv_sha256']);
      expect(
        sha256
            .convert(
              File(
                '$root/vendor/official_dense/${shader['source_path']}',
              ).readAsBytesSync(),
            )
            .toString(),
        shader['source_sha256'],
      );
      expect(carrierSource, contains(shader['source_path']));
      expect(carrierSource, contains(shader['source_sha256']));
      expect(carrierSource, contains(shader['spirv_sha256']));
      final validation = await Process.run('spirv-val', <String>[
        '--target-env',
        'vulkan1.1',
        checkedIn.path,
      ]);
      expect(
        validation.exitCode,
        0,
        reason: '${validation.stdout}\n${validation.stderr}',
      );
    }
    expect(
      File('${output.path}/shader_bundle_data.inc').readAsBytesSync(),
      File('$root/$bundle/shader_bundle_data.inc').readAsBytesSync(),
    );
  });

  test('production shader carrier accepts no caller hash or bytes', () {
    final header = File(
      'vendor/official_dense/vulkan_shader_bundle/shader_bundle.h',
    ).readAsStringSync();
    expect(header, contains('CanonicalShaderBundle() noexcept'));
    expect(header, isNot(contains('CanonicalShaderBundle(' + 'const')));
    expect(header, isNot(contains('expected_sha256')));
    expect(header, isNot(contains('caller_sha256')));
  });
}
