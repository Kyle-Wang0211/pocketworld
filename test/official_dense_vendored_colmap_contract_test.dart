import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const vendoredRoot =
      'vendor/official_dense/third_party/colmap-4.1.1';
  const importRoot = 'vendor/official_dense/upstream_import';
  const verifier = '$importRoot/verify_colmap_4_1_1.py';
  const canonicalManifest = '$importRoot/colmap_4_1_1_manifest.json';

  test('vendored COLMAP archive matches every frozen official file', () async {
    final temp = await Directory.systemTemp.createTemp(
      'vendored-colmap-contract-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));

    final manifest =
        jsonDecode(File(canonicalManifest).readAsStringSync())
            as Map<String, dynamic>;
    // A GitHub source archive intentionally has no nested .git directory.
    // Exact commit/tree identity remains frozen in the canonical manifest,
    // while this copied switch lets the existing verifier check file hashes.
    manifest['require_git_identity'] = false;
    final testManifest = File('${temp.path}/manifest.json')
      ..writeAsStringSync(jsonEncode(manifest));

    final result = await Process.run('python3', <String>[
      verifier,
      '--source-root',
      vendoredRoot,
      '--manifest',
      testManifest.path,
      '--json',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final report = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(report['ok'], isTrue, reason: '${report['errors']}');
  });

  test('vendored archive contains licenses and no nested Git metadata', () {
    final root = Directory(vendoredRoot);
    expect(root.existsSync(), isTrue);
    expect(File('$vendoredRoot/COPYING.txt').existsSync(), isTrue);
    expect(
      File('$vendoredRoot/src/thirdparty/VLFeat/LICENSE').existsSync(),
      isTrue,
    );
    expect(File('$vendoredRoot/.git').existsSync(), isFalse);
    expect(Directory('$vendoredRoot/.git').existsSync(), isFalse);
  });

  test('new dense integration contains no Swift or SiftGPU build edge', () {
    final denseRoot = Directory('vendor/official_dense');
    final integrationFiles = denseRoot
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) => !file.path.startsWith(
            '${denseRoot.path}/third_party/colmap-4.1.1/',
          ),
        );

    expect(
      integrationFiles.where(
        (file) => file.path.toLowerCase().endsWith('.swift'),
      ),
      isEmpty,
    );

    final cmakeSources = integrationFiles
        .where(
          (file) =>
              file.path.endsWith('CMakeLists.txt') ||
              file.path.endsWith('.cmake'),
        )
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(cmakeSources, isNot(contains('SiftGPU')));
  });
}
