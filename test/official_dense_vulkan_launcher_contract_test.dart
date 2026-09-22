import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/dense_stage.dart';
import 'package:pocketworld_flutter/official_dense/dense_transaction_manifest.dart';
import 'package:pocketworld_flutter/official_dense/vulkan_dense_launcher.dart';

final class _FakeNativeAdapter implements OfficialDenseNativeAdapter {
  _FakeNativeAdapter({required this.available, required this.onRun});

  final bool available;
  final Future<OfficialDenseNativeResult> Function(
    OfficialDenseNativeRequest request,
  )
  onRun;
  var runCount = 0;
  OfficialDenseNativeRequest? seen;

  @override
  Future<OfficialDenseNativeTransaction> openTransaction({
    required String captureDirectory,
    required String denseRelativeDirectory,
    required String runRelativeDirectory,
  }) {
    return _FakeNativeTransaction.open(
      captureDirectory: captureDirectory,
      denseRelativeDirectory: denseRelativeDirectory,
      runRelativeDirectory: runRelativeDirectory,
    );
  }

  @override
  bool get isAvailable => available;

  @override
  Future<OfficialDenseNativeResult> run(
    OfficialDenseNativeRequest request,
  ) async {
    runCount += 1;
    seen = request;
    return onRun(request);
  }
}

final class _RecordingExecutor implements OfficialDenseExecutor {
  var runCount = 0;

  @override
  Future<T> run<T>(Future<T> Function() operation) async {
    runCount += 1;
    return operation();
  }
}

final class _IsolateProbeAdapter implements OfficialDenseNativeAdapter {
  const _IsolateProbeAdapter(this.probePath);

  final String probePath;

  @override
  bool get isAvailable => true;

  @override
  Future<OfficialDenseNativeTransaction> openTransaction({
    required String captureDirectory,
    required String denseRelativeDirectory,
    required String runRelativeDirectory,
  }) {
    return _FakeNativeTransaction.open(
      captureDirectory: captureDirectory,
      denseRelativeDirectory: denseRelativeDirectory,
      runRelativeDirectory: runRelativeDirectory,
    );
  }

  @override
  Future<OfficialDenseNativeResult> run(
    OfficialDenseNativeRequest request,
  ) async {
    await File(probePath).writeAsString('${Isolate.current.hashCode}');
    await File(request.fusedPlyPath).writeAsString('ply');
    return const OfficialDenseNativeResult.success();
  }
}

final class _FakeNativeTransaction implements OfficialDenseNativeTransaction {
  _FakeNativeTransaction._({
    required String densePath,
    required String denseIdentity,
    required String runRelativePath,
  }) : _densePath = densePath,
       _denseIdentity = denseIdentity,
       _runRelativePath = runRelativePath;

  final String _densePath;
  final String _denseIdentity;
  final String _runRelativePath;
  bool _closed = false;

  static Future<_FakeNativeTransaction> open({
    required String captureDirectory,
    required String denseRelativeDirectory,
    required String runRelativeDirectory,
  }) async {
    final dense = Directory(
      '$captureDirectory${Platform.pathSeparator}$denseRelativeDirectory',
    ).absolute;
    final denseIdentity = await dense.resolveSymbolicLinks();
    final run = Directory(
      '${dense.path}${Platform.pathSeparator}$runRelativeDirectory',
    );
    if (await FileSystemEntity.type(run.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('run is not a real directory', run.path);
    }
    return _FakeNativeTransaction._(
      densePath: dense.path,
      denseIdentity: denseIdentity,
      runRelativePath: runRelativeDirectory,
    );
  }

  @override
  Future<void> removeRunEntry(String runRelativePath) async {
    final run = await _runRoot();
    await _remove('$run${Platform.pathSeparator}$runRelativePath');
  }

  @override
  Future<void> removeRunDirectory() async {
    final dense = await _denseRoot();
    await _remove('$dense${Platform.pathSeparator}$_runRelativePath');
  }

  @override
  Future<void> publishPly({
    required String runRelativeSource,
    required String denseRelativeDestination,
  }) async {
    final run = await _runRoot();
    final dense = await _denseRoot();
    final source = File('$run${Platform.pathSeparator}$runRelativeSource');
    final destination = File(
      '$dense${Platform.pathSeparator}$denseRelativeDestination',
    );
    final sourceType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (sourceType != FileSystemEntityType.file ||
        (await source.stat()).size <= 0) {
      throw FileSystemException(
        'source PLY must be a non-empty regular file',
        source.path,
      );
    }
    final destinationType = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (destinationType != FileSystemEntityType.notFound &&
        destinationType != FileSystemEntityType.file) {
      throw FileSystemException(
        'destination PLY is not a regular file',
        destination.path,
      );
    }
    await source.rename(destination.path);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  Future<String> _denseRoot() async {
    if (_closed) throw StateError('transaction is closed');
    final currentType = await FileSystemEntity.type(
      _densePath,
      followLinks: false,
    );
    if (currentType != FileSystemEntityType.directory ||
        await Directory(_densePath).resolveSymbolicLinks() != _denseIdentity) {
      throw FileSystemException('anchored dense identity changed', _densePath);
    }
    return _densePath;
  }

  Future<String> _runRoot() async {
    final dense = await _denseRoot();
    return '$dense${Platform.pathSeparator}$_runRelativePath';
  }

  Future<void> _remove(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    }
  }
}

void main() {
  late Directory root;
  late Directory capture;
  late Directory sparse;
  late File fedManifest;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('official_dense_launcher_');
    capture = await Directory('${root.path}/capture').create();
    sparse = await Directory(
      '${capture.path}/official_dense/sparse',
    ).create(recursive: true);
    for (final name in const ['cameras.bin', 'points3D.bin']) {
      await File('${sparse.path}/$name').writeAsBytes(utf8.encode(name));
    }
    fedManifest = File('${capture.path}/official_sfm_fed_frames.jsonl');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> writeSource(int frameId) async {
    final file = File('${capture.path}/source_$frameId.jpg');
    await file.writeAsBytes(<int>[frameId, frameId + 1, frameId + 2]);
    return file;
  }

  Future<void> writeInput({List<int> frameIds = const [0]}) async {
    await File(
      '${sparse.path}/images.bin',
    ).writeAsBytes(_colmapImagesBin(frameIds));
    final rows = <String>[];
    for (final frameId in frameIds) {
      final source = await writeSource(frameId);
      rows.add(
        jsonEncode(<String, Object?>{
          'frameId': frameId,
          'jpegPath': source.path,
        }),
      );
    }
    await fedManifest.writeAsString('${rows.join('\n')}\n');
    DenseTransactionManifest.writeSync(
      stagedModelDirectory: sparse.path,
      fedFramesManifestPath: fedManifest.path,
      generation: 'test-generation',
    );
  }

  DenseStageRequest request() => DenseStageRequest(
    captureDir: capture.path,
    sparsePlyPath: '${capture.path}/official_sfm_sparse.ply',
    pointCount: 1,
  );

  test('Dart FFI uses only the frozen six-symbol native C ABI', () {
    final source = File(
      'lib/official_dense/vulkan_dense_launcher.dart',
    ).readAsStringSync();
    const symbols = <String>{
      'pwofficial_dense_version',
      'pwofficial_dense_last_error',
      'pwofficial_dense_default_options',
      'pwofficial_dense_is_available',
      'pwofficial_dense_run',
      'pwofficial_dense_cancel',
    };
    for (final symbol in symbols) {
      expect(source, contains("'$symbol'"));
    }
    final referencedSymbols = RegExp(
      r"'(?<symbol>pwofficial_dense_[a-z_]+)'",
    ).allMatches(source).map((match) => match.namedGroup('symbol')!).toSet();
    expect(referencedSymbols, symbols);
  });

  test('Dart delegates run cleanup and PLY publication to versioned native '
      'fd transaction ABI', () {
    final source = File(
      'lib/official_dense/vulkan_dense_launcher.dart',
    ).readAsStringSync();
    for (final symbol in const <String>{
      'pwofficial_dense_tx_open_v1',
      'pwofficial_dense_tx_remove_run_entry_v1',
      'pwofficial_dense_tx_remove_run_directory_v1',
      'pwofficial_dense_tx_publish_ply_v1',
      'pwofficial_dense_tx_last_error_v1',
      'pwofficial_dense_tx_close_v1',
    }) {
      expect(source, contains("'$symbol'"));
    }
    expect(source, isNot(contains('Directory(real).delete(recursive: true)')));
    expect(source, isNot(contains('File(paths.temporaryFusedPly).rename')));
    expect(source, contains("runRelativeSource: 'fused.ply.pending'"));
    expect(source, contains("denseRelativeDestination: 'fused.ply'"));
  });

  test('Dart options struct matches the macOS arm64 C layout oracle', () {
    expect(Platform.isMacOS, isTrue);
    expect(
      Process.runSync('uname', const ['-m']).stdout.toString().trim(),
      'arm64',
    );
    final temporary = Directory.systemTemp.createTempSync(
      'official_dense_options_layout_',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final oracle = File('${temporary.path}/layout.c')
      ..writeAsStringSync(r'''
#include "pwofficial_dense_c.h"
#include <stddef.h>
#include <stdio.h>
#define P(member) printf(#member "=%zu\n", offsetof(pwofficial_dense_options_t, member))
int main(void) {
  printf("size=%zu\n", sizeof(pwofficial_dense_options_t));
  P(struct_size); P(abi_version); P(depth_min); P(depth_max);
  P(sigma_spatial); P(sigma_color); P(ncc_sigma);
  P(min_triangulation_angle); P(incident_angle_sigma);
  P(geom_consistency_regularizer); P(geom_consistency_max_cost);
  P(filter_min_ncc); P(filter_min_triangulation_angle);
  P(filter_geom_consistency_max_cost); P(patch_match_cache_size);
  P(gpu_index); P(patch_match_max_image_size); P(window_radius);
  P(window_step); P(num_samples); P(num_iterations);
  P(filter_min_num_consistent); P(patch_match_num_threads);
  P(geom_consistency); P(filter); P(allow_missing_files);
  P(write_consistency_graph); P(mask_path); P(fusion_num_threads);
  P(fusion_max_image_size); P(min_num_pixels); P(max_num_pixels);
  P(max_traversal_depth); P(max_reproj_error); P(max_depth_error);
  P(max_normal_error); P(check_num_images); P(use_cache);
  P(fusion_cache_size); P(bounding_box_min); P(bounding_box_max);
  return 0;
}
''');
    final executable = '${temporary.path}/layout';
    final compile = Process.runSync('clang', <String>[
      '-std=c11',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-arch',
      'arm64',
      '-Ivendor/official_dense/ffi/include',
      oracle.path,
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = Process.runSync(executable, const <String>[]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    final cLayout = <String, int>{};
    for (final line in LineSplitter.split(run.stdout as String)) {
      final parts = line.split('=');
      cLayout[parts[0]] = int.parse(parts[1]);
    }

    expect(sizeOf<PwOfficialDenseOptions>(), cLayout.remove('size'));
    expect(PwOfficialDenseOptionsLayout.offsets, cLayout);
  });

  test('production start remains immediately unavailable until a completion '
      'status contract exists', () async {
    final adapter = _FakeNativeAdapter(
      available: true,
      onRun: (_) async => const OfficialDenseNativeResult.success(),
    );
    final executor = _RecordingExecutor();
    final launcher = VulkanOfficialDenseStageLauncher(
      native: adapter,
      executor: executor,
    );

    expect(launcher.isNativeReady, isTrue);
    expect(launcher.isAvailable, isFalse);
    final result = await launcher.start(request());

    expect(result.status, DenseStageStatus.unavailable);
    expect(result.message, contains('completion status'));
    expect(adapter.runCount, 0);
    expect(executor.runCount, 0);
    expect(
      File('${capture.path}/official_dense/fused.ply').existsSync(),
      isFalse,
    );
  });

  test(
    'missing frozen sparse model returns failed and never invokes native',
    () async {
      final adapter = _FakeNativeAdapter(
        available: true,
        onRun: (_) async => const OfficialDenseNativeResult.success(),
      );
      final executor = _RecordingExecutor();
      final launcher = VulkanOfficialDenseStageLauncher(
        native: adapter,
        executor: executor,
      );

      final stale = File('${capture.path}/official_dense/fused.ply');
      await stale.writeAsString('stale');
      final result = await launcher.runForVerification(request());

      expect(result.status, DenseStageStatus.failed);
      expect(adapter.runCount, 0);
      expect(executor.runCount, 1);
      expect(await stale.readAsString(), 'stale');
    },
  );

  test('missing handoff.ready fails closed before native and cannot promote '
      'stale published output', () async {
    await writeInput();
    await File('${sparse.path}/handoff.ready').delete();
    final published = File('${capture.path}/official_dense/fused.ply');
    await published.writeAsString('stale');
    final adapter = _FakeNativeAdapter(
      available: true,
      onRun: (_) async => const OfficialDenseNativeResult.success(),
    );
    final launcher = VulkanOfficialDenseStageLauncher(
      native: adapter,
      executor: _RecordingExecutor(),
    );

    final result = await launcher.runForVerification(request());

    expect(result.status, DenseStageStatus.failed);
    expect(result.message, contains('handoff.ready'));
    expect(adapter.runCount, 0);
    expect(await published.readAsString(), 'stale');
  });

  test(
    'JPEG changed after model export transaction fails before native',
    () async {
      await writeInput();
      await File('${capture.path}/source_0.jpg').writeAsBytes(<int>[9, 8, 7]);
      final adapter = _FakeNativeAdapter(
        available: true,
        onRun: (_) async => const OfficialDenseNativeResult.success(),
      );
      final launcher = VulkanOfficialDenseStageLauncher(
        native: adapter,
        executor: _RecordingExecutor(),
      );

      final result = await launcher.runForVerification(request());

      expect(result.status, DenseStageStatus.failed);
      expect(result.message, contains('frame 0'));
      expect(adapter.runCount, 0);
    },
  );

  test('symlinked task-owned runs directory is rejected without deleting its '
      'victim', () async {
    await writeInput();
    final victim = await Directory('${root.path}/victim').create();
    final sentinel = File('${victim.path}/sentinel')..writeAsStringSync('safe');
    final runsLink = Link(
      '${capture.path}/official_dense/.pwofficial_dense_runs',
    );
    await runsLink.create(victim.path);
    final adapter = _FakeNativeAdapter(
      available: true,
      onRun: (_) async => const OfficialDenseNativeResult.success(),
    );
    final launcher = VulkanOfficialDenseStageLauncher(
      native: adapter,
      executor: _RecordingExecutor(),
    );

    final result = await launcher.runForVerification(request());

    expect(result.status, DenseStageStatus.failed);
    expect(result.message, contains('symlink'));
    expect(adapter.runCount, 0);
    expect(await sentinel.readAsString(), 'safe');
    expect(await runsLink.exists(), isTrue);
  });

  test('same capture is single-flight and a concurrent run fails busy without '
      'cross-cancellation', () async {
    await writeInput();
    final entered = Completer<void>();
    final release = Completer<void>();
    final adapter = _FakeNativeAdapter(
      available: true,
      onRun: (nativeRequest) async {
        entered.complete();
        await release.future;
        await File(nativeRequest.fusedPlyPath).writeAsString('ply');
        return const OfficialDenseNativeResult.success();
      },
    );
    final executor = _RecordingExecutor();
    final launcher = VulkanOfficialDenseStageLauncher(
      native: adapter,
      executor: executor,
    );

    final first = launcher.runForVerification(request());
    await entered.future;
    final second = await launcher.runForVerification(request());

    expect(second.status, DenseStageStatus.failed);
    expect(second.message, contains('busy'));
    expect(adapter.runCount, 1);
    expect(executor.runCount, 1);
    release.complete();
    expect((await first).status, DenseStageStatus.started);
  });

  test(
    'freezes registered COLMAP images and accepts only a non-empty fused PLY',
    () async {
      await writeInput(frameIds: const [12, 0]);
      final copiedImages = <String, List<int>>{};
      final adapter = _FakeNativeAdapter(
        available: true,
        onRun: (nativeRequest) async {
          for (final entry in nativeRequest.materializationPlan) {
            copiedImages[entry.imageName] = await File(
              entry.destinationPath,
            ).readAsBytes();
          }
          await File(
            nativeRequest.fusedPlyPath,
          ).writeAsBytes(utf8.encode('ply\nformat binary_little_endian 1.0\n'));
          return const OfficialDenseNativeResult.success();
        },
      );
      final executor = _RecordingExecutor();
      final launcher = VulkanOfficialDenseStageLauncher(
        native: adapter,
        executor: executor,
      );

      final result = await launcher.runForVerification(request());

      expect(result.status, DenseStageStatus.started);
      expect(executor.runCount, 1);
      expect(adapter.runCount, 1);
      expect(
        adapter.seen!.workspaceDirectory,
        startsWith(
          await Directory(
            '${capture.path}/official_dense/.pwofficial_dense_runs',
          ).resolveSymbolicLinks(),
        ),
      );
      expect(adapter.seen!.modelDirectory, isNot(sparse.absolute.path));
      expect(
        adapter.seen!.modelFiles.map((entry) => entry.fileName),
        contains('handoff.ready'),
      );
      expect(
        adapter.seen!.materializationPlan.map((entry) => entry.imageName),
        const ['frame_000000.jpg', 'frame_000012.jpg'],
      );
      expect(
        adapter.seen!.materializationDirectory,
        startsWith(adapter.seen!.workspaceDirectory),
      );
      expect(
        adapter.seen!.fedFramesManifest.path,
        startsWith(adapter.seen!.workspaceDirectory),
      );
      expect(
        adapter.seen!.fusedPlyPath,
        isNot(File('${capture.path}/official_dense/fused.ply').absolute.path),
      );
      expect(copiedImages['frame_000000.jpg'], <int>[0, 1, 2]);
      expect(copiedImages['frame_000012.jpg'], <int>[12, 13, 14]);
      expect(
        await File('${capture.path}/official_dense/fused.ply').readAsString(),
        startsWith('ply'),
      );
      expect(
        await Directory(adapter.seen!.workspaceDirectory).exists(),
        isFalse,
      );
    },
  );

  test(
    'native success without a non-empty fused PLY is reported failed',
    () async {
      await writeInput();
      final adapter = _FakeNativeAdapter(
        available: true,
        onRun: (_) async => const OfficialDenseNativeResult.success(),
      );
      final launcher = VulkanOfficialDenseStageLauncher(
        native: adapter,
        executor: _RecordingExecutor(),
      );

      final result = await launcher.runForVerification(request());

      expect(result.status, DenseStageStatus.failed);
      expect(result.message, contains('fused.ply'));
    },
  );

  test('default executor runs dense I/O outside the UI isolate', () async {
    await writeInput();
    final probe = File('${root.path}/isolate_probe.txt');
    final uiIsolateIdentity = Isolate.current.hashCode;
    final launcher = VulkanOfficialDenseStageLauncher(
      native: _IsolateProbeAdapter(probe.path),
    );

    final result = await launcher.runForVerification(request());

    expect(result.status, DenseStageStatus.started);
    expect(int.parse(await probe.readAsString()), isNot(uiIsolateIdentity));
  });

  test(
    'native failure remains failed and cannot be promoted by a stale PLY',
    () async {
      await writeInput();
      final fused = File('${capture.path}/official_dense/fused.ply');
      await fused.parent.create(recursive: true);
      await fused.writeAsString('stale');
      final adapter = _FakeNativeAdapter(
        available: true,
        onRun: (_) async => const OfficialDenseNativeResult.failed('gpu error'),
      );
      final launcher = VulkanOfficialDenseStageLauncher(
        native: adapter,
        executor: _RecordingExecutor(),
      );

      final result = await launcher.runForVerification(request());

      expect(result.status, DenseStageStatus.failed);
      expect(result.message, contains('gpu error'));
      expect(await fused.readAsString(), 'stale');
    },
  );
}

List<int> _colmapImagesBin(List<int> frameIds) {
  final builder = BytesBuilder(copy: false);
  void uint32(int value) {
    final bytes = ByteData(4)..setUint32(0, value, Endian.little);
    builder.add(bytes.buffer.asUint8List());
  }

  void uint64(int value) {
    final bytes = ByteData(8)..setUint64(0, value, Endian.little);
    builder.add(bytes.buffer.asUint8List());
  }

  void float64(double value) {
    final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
    builder.add(bytes.buffer.asUint8List());
  }

  uint64(frameIds.length);
  for (final frameId in frameIds) {
    uint32(frameId + 1);
    for (final value in const [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]) {
      float64(value);
    }
    uint32(1);
    builder.add(utf8.encode('frame_${frameId.toString().padLeft(6, '0')}.jpg'));
    builder.addByte(0);
    uint64(0);
  }
  return builder.takeBytes();
}
