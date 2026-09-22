import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'vendor/official_dense/official_cpu_mvs';
  const upstream = 'vendor/official_dense/third_party/colmap-4.1.1';

  List<String> sourceObjects() => File('$root/SOURCE_OBJECTS.txt')
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .toList(growable: false);

  test('CPU MVS closure has one explicit, existing upstream object manifest', () {
    final objects = sourceObjects();
    expect(objects, isNotEmpty);
    expect(objects.toSet().length, objects.length, reason: 'duplicate object');

    for (final object in objects) {
      expect(
        File('$upstream/$object').existsSync(),
        isTrue,
        reason: 'missing frozen source: $object',
      );
    }

    final cmake = File('$root/CMakeLists.txt').readAsStringSync();
    for (final object in objects) {
      expect(cmake, contains(object), reason: 'CMake omits $object');
    }
  });

  test('object manifest excludes non-dense and accelerated subsystems', () {
    final manifest = sourceObjects().join('\n').toLowerCase();
    const forbidden = <String>[
      'siftgpu',
      '/sift.',
      '/lsd',
      'cuda',
      '/ui/',
      'qt',
      'opengl',
      'meshing',
      'mesh_simplification',
      'texture_mapping',
      '/feature/',
      '/matching/',
    ];
    for (final token in forbidden) {
      expect(manifest, isNot(contains(token)), reason: 'forbidden: $token');
    }
    expect(manifest, contains('src/colmap/mvs/fusion.cc'));
    expect(manifest, contains('src/colmap/mvs/workspace.cc'));
    expect(manifest, contains('src/colmap/mvs/model.cc'));
    expect(manifest, contains('src/colmap/util/ply.cc'));
  });

  test('standalone CMake is zero-download and whole-archive verified', () {
    final cmake = File('$root/CMakeLists.txt').readAsStringSync();

    expect(cmake, contains('add_library(pw_official_cpu_mvs_objects OBJECT'));
    expect(cmake, contains('add_library(pw_official_cpu_mvs STATIC'));
    expect(cmake, contains(r'$<LINK_LIBRARY:WHOLE_ARCHIVE'));
    expect(cmake, contains('find_package(Eigen3'));
    expect(cmake, contains('find_package(Boost'));
    expect(cmake, contains('find_package(glog'));
    expect(cmake, contains('find_package(OpenImageIO'));
    expect(cmake, isNot(contains('FetchContent')));
    expect(cmake, isNot(contains('ExternalProject_Add')));
    expect(cmake, isNot(contains('file(DOWNLOAD')));
    expect(cmake, isNot(contains('execute_process(COMMAND brew')));
    expect(cmake, isNot(contains('/opt/homebrew')));
  });

  test('glog 0.7 compatibility is version-selected without source patch', () {
    final cmake = File('$root/CMakeLists.txt').readAsStringSync();

    expect(cmake, contains('GLOG_VERSION_MAJOR=0'));
    expect(cmake, contains('GLOG_VERSION_MINOR=7'));
    expect(cmake, contains('GLOG_USE_GLOG_EXPORT'));
    expect(cmake, contains('find_package(glog 0.7.1 EXACT CONFIG REQUIRED)'));
  });

  test('bridge constructs official defaults and remains fail closed', () {
    final bridge = File('$root/src/official_cpu_mvs_bridge.cc')
        .readAsStringSync();
    final smoke = File('$root/test/official_cpu_mvs_smoke.cc')
        .readAsStringSync();

    expect(bridge, contains('colmap::mvs::StereoFusionOptions options'));
    expect(bridge, contains('pw_official_cpu_mvs_run_unavailable'));
    expect(bridge, contains('return -1;'));
    expect(smoke, contains('pw_official_cpu_mvs_default_options_smoke'));
    expect(smoke, contains('pw_official_cpu_mvs_run_unavailable'));
  });

  test('license inputs remain the frozen upstream files', () {
    expect(File('$upstream/COPYING.txt').existsSync(), isTrue);
    expect(File('$upstream/src/thirdparty/VLFeat/LICENSE').existsSync(), isTrue);
  });

  test('every compiled upstream source and license is hash locked', () async {
    final locked = File('$root/SOURCE_SHA256SUMS.txt')
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => line.split(RegExp(r'\s+')).last)
        .toSet();
    expect(
      locked,
      containsAll(<String>{
        ...sourceObjects(),
        'COPYING.txt',
        'src/thirdparty/VLFeat/LICENSE',
      }),
    );

    final result = await Process.run('python3', <String>[
      '$root/verify_source_manifest.py',
      '--source-root',
      upstream,
      '--manifest',
      '$root/SOURCE_SHA256SUMS.txt',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('source verifier fails closed when a locked byte changes', () async {
    final temp = await Directory.systemTemp.createTemp('cpu_mvs_hash_lock_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final source = File('${temp.path}/source.cc')..writeAsStringSync('official\n');
    final good = await Process.run('shasum', <String>['-a', '256', source.path]);
    expect(good.exitCode, 0);
    final digest = (good.stdout as String).split(RegExp(r'\s+')).first;
    final manifest = File('${temp.path}/SHA256SUMS.txt')
      ..writeAsStringSync('$digest  source.cc\n');

    source.writeAsStringSync('changed\n');
    final result = await Process.run('python3', <String>[
      '$root/verify_source_manifest.py',
      '--source-root',
      temp.path,
      '--manifest',
      manifest.path,
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('SHA-256 mismatch'));
  });
}
