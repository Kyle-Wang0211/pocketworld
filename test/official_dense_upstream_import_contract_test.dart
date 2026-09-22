import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const importRoot = 'vendor/official_dense/upstream_import';
  const verifier = '$importRoot/verify_colmap_4_1_1.py';
  const canonicalManifest = '$importRoot/colmap_4_1_1_manifest.json';

  test('canonical import manifest freezes official COLMAP 4.1.1 scope', () {
    final manifest =
        jsonDecode(File(canonicalManifest).readAsStringSync())
            as Map<String, dynamic>;

    expect(manifest['commit'], 'a0d785fba74b2664f31edc4a29026a8b27c00f67');
    expect(manifest['tree'], '8e1e5240ea77d4271c7453f8b679952e78ee379e');

    final scopes = manifest['scopes'] as Map<String, dynamic>;
    expect(
      (scopes['mvs_direct_sources'] as List).length,
      greaterThanOrEqualTo(20),
    );
    expect(
      (scopes['known_local_differences'] as List).map(
        (entry) => (entry as Map<String, dynamic>)['path'],
      ),
      containsAll(<String>[
        'src/colmap/controllers/undistorters.cc',
        'src/colmap/image/undistortion.cc',
        'src/colmap/util/logging.h',
      ]),
    );
    expect(
      (scopes['cuda_reference_only'] as List).length,
      greaterThanOrEqualTo(8),
    );
    expect(
      manifest['excluded_build_components'],
      containsAll(<String>['SiftGPU', 'LSD', 'Qt', 'CUDA']),
    );
    expect(
      (manifest['licenses'] as List).map(
        (entry) => (entry as Map<String, dynamic>)['path'],
      ),
      containsAll(<String>['COPYING.txt', 'src/thirdparty/VLFeat/LICENSE']),
    );
  });

  test('verifier accepts an exact fixture and fails closed on drift', () async {
    final temp = await Directory.systemTemp.createTemp('colmap-import-gate-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final source = Directory('${temp.path}/source')..createSync();
    final code = File('${source.path}/src/colmap/mvs/model.cc')
      ..createSync(recursive: true)
      ..writeAsStringSync('official fixture\n');
    final colmapNotice = File('${source.path}/COPYING.txt')
      ..writeAsStringSync('COLMAP BSD fixture\n');
    final vlfeatNotice = File('${source.path}/src/thirdparty/VLFeat/LICENSE')
      ..createSync(recursive: true)
      ..writeAsStringSync('VLFeat BSD fixture\n');

    String blobSha(File file) =>
        (Process.runSync('git', <String>['hash-object', file.path]).stdout
                as String)
            .trim();

    String sha256(File file) =>
        (Process.runSync('shasum', <String>['-a', '256', file.path]).stdout
                as String)
            .split(' ')
            .first;

    Map<String, dynamic> fileEntry(File file, String relativePath) => {
      'path': relativePath,
      'git_blob': blobSha(file),
      'sha256': sha256(file),
    };

    final fixtureManifest = File('${temp.path}/manifest.json')
      ..writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'schema_version': 1,
          'commit': 'fixture-commit',
          'tree': 'fixture-tree',
          'require_git_identity': false,
          'scopes': <String, dynamic>{
            'mvs_direct_sources': <dynamic>[
              fileEntry(code, 'src/colmap/mvs/model.cc'),
            ],
            'known_local_differences': <dynamic>[],
            'cuda_reference_only': <dynamic>[],
          },
          'licenses': <dynamic>[
            fileEntry(colmapNotice, 'COPYING.txt'),
            fileEntry(vlfeatNotice, 'src/thirdparty/VLFeat/LICENSE'),
          ],
          'excluded_build_components': <String>['SiftGPU', 'LSD', 'Qt', 'CUDA'],
        }),
      );

    Future<ProcessResult> verify() => Process.run('python3', <String>[
      verifier,
      '--source-root',
      source.path,
      '--manifest',
      fixtureManifest.path,
    ]);

    final valid = await verify();
    expect(valid.exitCode, 0, reason: '${valid.stdout}\n${valid.stderr}');

    code.writeAsStringSync('locally modified\n');
    final drifted = await verify();
    expect(drifted.exitCode, isNonZero);
    expect('${drifted.stdout}${drifted.stderr}', contains('model.cc'));
    expect('${drifted.stdout}${drifted.stderr}', contains('hash mismatch'));

    code.writeAsStringSync('official fixture\n');
    vlfeatNotice.deleteSync();
    final missingNotice = await verify();
    expect(missingNotice.exitCode, isNonZero);
    expect(
      '${missingNotice.stdout}${missingNotice.stderr}',
      contains('VLFeat/LICENSE'),
    );
    expect(
      '${missingNotice.stdout}${missingNotice.stderr}',
      contains('missing'),
    );
  });

  test(
    'upstream import gate contains no Swift and performs no network fetch',
    () {
      final files = Directory(
        importRoot,
      ).listSync(recursive: true).whereType<File>();
      expect(
        files.where((file) => file.path.toLowerCase().endsWith('.swift')),
        isEmpty,
      );
      final verifierSource = File(verifier).readAsStringSync();
      expect(verifierSource, contains('timeout=5'));
      expect(verifierSource, contains('source root has no .git identity'));
      expect(verifierSource, contains('embedded src layout'));
      expect(verifierSource, isNot(contains('urllib')));
      expect(verifierSource, isNot(contains('requests')));
      expect(verifierSource, isNot(contains('curl')));
      expect(verifierSource, isNot(contains('wget')));
    },
  );
}
