// Unit tests for lib/pipeline/local_pipeline_runner.dart — Plan G W6
// D1 orchestrator scaffold.
//
// What we're proving:
//   1. End-to-end: from a fresh captureDir with a fake photos/ dir, the
//      runner creates all five `stages/<name>/` output dirs and writes
//      a `done.json` checkpoint marker in each.
//   2. Each stage writes its declared stub artifact (depth_index.json,
//      pointcloud.ply, mesh.ply, mesh.obj + atlas.png, output.glb).
//   3. PipelineProgressEvents fire in PipelineStage order, with
//      monotonic overallFraction.
//   4. The terminal event is a PipelineCompletedEvent pointing at
//      stages/compress/output.glb.
//   5. Resume / idempotence: running twice over the same captureDir
//      doesn't re-do work; the second run emits a "skipped (cached)"
//      progress event for every stage.
//   6. Error path: a stage that throws → PipelineErrorEvent on the
//      stream + run() returns without advancing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:aether_capture_services/aether_capture_services.dart';

import 'package:pocketworld_flutter/capture/depth_meta.dart';
import 'package:pocketworld_flutter/pipeline/local_pipeline_runner.dart';

// Drives stages instantly (1 µs/tick) so the suite runs in well under a
// second regardless of CI machine. Production default is 2 s/stage.
const _fastDelay = Duration(microseconds: 4);

List<PipelineStageRunner> _fastStages() => const [
  DepthStage(stubDelay: _fastDelay),
  PointCloudStage(stubDelay: _fastDelay),
  MeshStage(stubDelay: _fastDelay),
  TextureStage(stubDelay: _fastDelay),
  CompressStage(stubDelay: _fastDelay),
];

/// Spins up a brand-new captureDir under the system temp dir with a
/// fake `photos/` subdir + a single placeholder JPEG inside so the
/// depth stage has something nominally pointing at it.
Future<Directory> _makeCaptureDir() async {
  final cap = await Directory.systemTemp.createTemp('plang_w6d1_');
  final photos = Directory('${cap.path}/photos')..createSync();
  await File('${photos.path}/cell_0_slot_0.jpg').writeAsBytes(const <int>[]);
  await File(
    '${photos.path}/cell_0_slot_0.json',
  ).writeAsString('{"placeholder": true}');
  return cap;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalPipelineRunner (W6 D1 scaffold)', () {
    test('end-to-end: all 5 stages write done.json + stub artifact', () async {
      final cap = await _makeCaptureDir();
      addTearDown(() => cap.delete(recursive: true));

      final runner = LocalPipelineRunner(
        captureDir: cap,
        stages: _fastStages(),
      );
      addTearDown(runner.dispose);

      final events = <PipelineEvent>[];
      final sub = runner.stream.listen(events.add);
      await runner.run();
      await sub.cancel();

      final stages = ['depth', 'pointcloud', 'mesh', 'texture', 'compress'];
      for (final s in stages) {
        final dir = Directory('${cap.path}/stages/$s');
        expect(dir.existsSync(), isTrue, reason: 'stages/$s not created');
        final done = File('${dir.path}/done.json');
        expect(
          done.existsSync(),
          isTrue,
          reason: 'stages/$s/done.json not written',
        );
        expect(done.readAsStringSync(), contains('"stage":"$s"'));
      }

      // Each stage's declared stub artifact lives in its outputDir.
      expect(
        File('${cap.path}/stages/depth/depth_index.json').existsSync(),
        isTrue,
      );
      expect(
        File('${cap.path}/stages/pointcloud/pointcloud.ply').existsSync(),
        isTrue,
      );
      expect(File('${cap.path}/stages/mesh/mesh.ply').existsSync(), isTrue);
      expect(File('${cap.path}/stages/texture/mesh.obj').existsSync(), isTrue);
      expect(File('${cap.path}/stages/texture/atlas.png').existsSync(), isTrue);
      expect(
        File('${cap.path}/stages/compress/output.glb').existsSync(),
        isTrue,
      );
    });

    test(
      'progress events fire in PipelineStage order with monotonic overall',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));

        final runner = LocalPipelineRunner(
          captureDir: cap,
          stages: _fastStages(),
        );
        addTearDown(runner.dispose);

        final progress = <PipelineProgressEvent>[];
        PipelineCompletedEvent? completed;
        final sub = runner.stream.listen((e) {
          if (e is PipelineProgressEvent) progress.add(e);
          if (e is PipelineCompletedEvent) completed = e;
        });
        await runner.run();
        await sub.cancel();

        // Should have seen each stage at least once (4 stub ticks + 1
        // defensive 1.00 tick = 5 events per stage, × 5 stages = 25).
        expect(
          progress.length,
          greaterThanOrEqualTo(5 * PipelineStage.values.length),
        );

        // Stage order: the FIRST progress event whose stage == X must
        // come strictly before the first whose stage == Y, for every
        // (X,Y) with X.index < Y.index.
        final firstIdx = <PipelineStage, int>{};
        for (var i = 0; i < progress.length; i++) {
          firstIdx.putIfAbsent(progress[i].progress.stage, () => i);
        }
        for (var i = 0; i < PipelineStage.values.length - 1; i++) {
          final a = PipelineStage.values[i];
          final b = PipelineStage.values[i + 1];
          expect(firstIdx[a], isNotNull, reason: 'no progress for $a');
          expect(firstIdx[b], isNotNull, reason: 'no progress for $b');
          expect(
            firstIdx[a]! < firstIdx[b]!,
            isTrue,
            reason: 'stage $a should report before $b',
          );
        }

        // overallFraction must be non-decreasing across the run.
        for (var i = 1; i < progress.length; i++) {
          expect(
            progress[i].progress.overallFraction,
            greaterThanOrEqualTo(progress[i - 1].progress.overallFraction),
            reason: 'overallFraction regressed at index $i',
          );
        }

        // Last progress event should be at overall 1.0 (final compress
        // 1.00 tick).
        expect(progress.last.progress.overallFraction, closeTo(1.0, 1e-9));

        // Completion event present and points at the compress stage's
        // output.glb.
        expect(completed, isNotNull);
        expect(
          completed!.outputGlb.path,
          endsWith('/stages/compress/output.glb'),
        );
        expect(completed!.outputGlb.existsSync(), isTrue);
      },
    );

    test(
      'second run() over a completed captureDir skips every stage',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));

        // First run: do real (stub) work.
        final r1 = LocalPipelineRunner(captureDir: cap, stages: _fastStages());
        await r1.run();
        await r1.dispose();

        // Second run: every stage should report skipped.
        final r2 = LocalPipelineRunner(captureDir: cap, stages: _fastStages());
        addTearDown(r2.dispose);

        final progress = <PipelineProgressEvent>[];
        PipelineCompletedEvent? completed;
        final sub = r2.stream.listen((e) {
          if (e is PipelineProgressEvent) progress.add(e);
          if (e is PipelineCompletedEvent) completed = e;
        });
        await r2.run();
        await sub.cancel();

        // On the cached path each stage emits exactly one event.
        expect(progress.length, PipelineStage.values.length);
        for (var i = 0; i < progress.length; i++) {
          expect(progress[i].progress.stage, PipelineStage.values[i]);
          expect(progress[i].progress.detail, 'skipped (cached)');
          expect(progress[i].progress.stageFraction, 1.0);
        }
        expect(completed, isNotNull);
      },
    );

    test(
      'photo_bundle captureDir derives COLMAP, view graph, validation',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));
        await _writePhotoBundleFixture(cap);

        final runner = LocalPipelineRunner(
          captureDir: cap,
          stages: _fastStages(),
        );
        addTearDown(runner.dispose);

        final progress = <PipelineProgressEvent>[];
        final sub = runner.stream.listen((e) {
          if (e is PipelineProgressEvent) progress.add(e);
        });
        await runner.run();
        await sub.cancel();

        expect(
          File('${cap.path}/colmap/sparse/0/cameras.txt').existsSync(),
          isTrue,
        );
        expect(
          File('${cap.path}/colmap/sparse/0/images.txt').existsSync(),
          isTrue,
        );
        expect(
          File('${cap.path}/colmap/sparse/0/points3D.txt').existsSync(),
          isTrue,
        );
        expect(File('${cap.path}/view_graph.json').existsSync(), isTrue);
        expect(File('${cap.path}/bundle_validation.json').existsSync(), isTrue);
        expect(File('${cap.path}/model_policy.json').existsSync(), isTrue);
        expect(File('${cap.path}/da3_k_windows.json').existsSync(), isTrue);
        expect(
          File('${cap.path}/da3_input_manifest.json').existsSync(),
          isTrue,
        );
        expect(File('${cap.path}/photos_depth/a.jpg').existsSync(), isTrue);
        expect(File('${cap.path}/photos_depth/b.jpg').existsSync(), isTrue);
        expect(
          File(
            '${cap.path}/stages/depth/visual_loop_retrieval_report.json',
          ).existsSync(),
          isTrue,
        );
        expect(
          File(
            '${cap.path}/stages/depth/dense_sim3_verification_report.json',
          ).existsSync(),
          isTrue,
        );
        expect(
          File(
            '${cap.path}/stages/depth/da3_real_device_audit.json',
          ).existsSync(),
          isTrue,
        );
        final da3Input =
            jsonDecode(
                  File(
                    '${cap.path}/da3_input_manifest.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(da3Input['input_width'] ?? da3Input['inputWidth'], 742);
        expect(da3Input['input_height'] ?? da3Input['inputHeight'], 476);
        expect(
          (da3Input['frames'] as List).first,
          containsPair('depthImageRelativePath', 'photos_depth/a.jpg'),
        );
        final depthIndex =
            jsonDecode(
                  File(
                    '${cap.path}/stages/depth/depth_index.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(depthIndex['model']['id'], 'DA3-BASE');
        expect(depthIndex['input_size_locked'], isTrue);
        expect(depthIndex['input_width'], 742);
        expect(depthIndex['input_height'], 476);
        expect(
          depthIndex['k_window_graph']['windowing_policy'],
          containsPair('targetBridgeOverlap', 18),
        );
        expect(
          depthIndex['k_window_graph']['loop_closure_policy'],
          containsPair(
            'symmetryGuard',
            contains('no loop edge is accepted by image similarity alone'),
          ),
        );
        expect(
          depthIndex['visual_loop_retrieval_report_path'],
          'visual_loop_retrieval_report.json',
        );
        expect(
          depthIndex['dense_sim3_verification_report_path'],
          'dense_sim3_verification_report.json',
        );
        expect(
          depthIndex['geometry_contract']['truth_gate_outputs'],
          contains('dense_sim3_verification_report.json'),
        );
        expect(
          depthIndex['geometry_contract']['truth_gate_outputs'],
          contains('da3_real_device_audit.json'),
        );
        expect(depthIndex['status'], 'pending');
        expect(depthIndex['pending_count'], 2);
        expect(
          progress.map((e) => e.progress.detail),
          contains('deriving photo bundle sidecars'),
        );
      },
    );

    test(
      'photo bundle derivation repairs zero image sizes and missing previews',
      () async {
        final cap = await Directory.systemTemp.createTemp(
          'photo_bundle_repair_',
        );
        addTearDown(() => cap.delete(recursive: true));
        final highres = Directory('${cap.path}/photos_highres')..createSync();
        Directory('${cap.path}/previews').createSync();
        for (final id in ['a', 'b']) {
          await File(
            '${highres.path}/$id.jpg',
          ).writeAsBytes(_jpegFixture(id == 'a' ? 24 : 48));
        }
        await File('${highres.path}/b.json').writeAsString(
          jsonEncode({
            't': 1167754.045757208,
            'image_w': 3840,
            'image_h': 2160,
            'extrinsic': List<double>.filled(16, 0)..[15] = 1,
            'intrinsics_fxfycxcy': [2626.2, 2626.2, 1928.1, 1079.1],
          }),
        );
        await File('${cap.path}/photo_bundle.json').writeAsString(
          jsonEncode({
            'schemaVersion': 'aether_photo_bundle_v1',
            'photosHighresDir': 'photos_highres',
            'previewsDir': 'previews',
            'frames': [
              _photoBundleFrame('a', 0, 0, 0, 0),
              {
                ..._photoBundleFrame('b', 0.14, 0, 0.12, 0.02),
                'imageWidth': 0,
                'imageHeight': 0,
              },
            ],
          }),
        );
        await File('${cap.path}/previews/a.jpg').writeAsBytes(_jpegFixture(24));

        await const PhotoBundleDerivationService().deriveDirectory(cap);

        final repaired =
            jsonDecode(File('${cap.path}/photo_bundle.json').readAsStringSync())
                as Map<String, dynamic>;
        final repairReport =
            jsonDecode(
                  File(
                    '${cap.path}/photo_bundle_repair_report.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final validation =
            jsonDecode(
                  File('${cap.path}/bundle_validation.json').readAsStringSync(),
                )
                as Map<String, dynamic>;
        final da3Input =
            jsonDecode(
                  File(
                    '${cap.path}/da3_input_manifest.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;

        expect(repairReport['repairedImageSizeCount'], 0);
        expect(repairReport['generatedPreviewCount'], 1);
        expect(repairReport['repairedMetadataCount'], 1);
        expect((repaired['frames'] as List).last['imageWidth'], 3840);
        expect((repaired['frames'] as List).last['imageHeight'], 2160);
        expect(
          (repaired['frames'] as List).last['timestamp'],
          1167754.045757208,
        );
        expect(
          (repaired['frames'] as List).last['captureKind'],
          'arkit_frame_fallback_jpeg',
        );
        expect(File('${cap.path}/previews/b.jpg').existsSync(), isTrue);
        expect(validation['status'], isNot('fail'));
        expect(da3Input['frameCount'], 2);
        expect(File('${cap.path}/photos_depth/b.jpg').existsSync(), isTrue);
      },
    );

    test(
      'depth stage reads model_policy + da3_k_windows and passes original image paths to runner',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));
        await _writePhotoBundleFixture(cap);

        final fakeRunner = _FakeDa3DepthRunner();
        final runner = LocalPipelineRunner(
          captureDir: cap,
          stages: [DepthStage(stubDelay: _fastDelay, depthRunner: fakeRunner)],
        );
        addTearDown(runner.dispose);

        await runner.run();

        expect(fakeRunner.requests, hasLength(1));
        final request = fakeRunner.requests.single;
        expect(request.model['id'], 'DA3-BASE');
        expect(request.model['inputSizeStatus'], contains('locked'));
        expect(request.windowID, 'window_000');
        expect(
          request.window['selectionMode'],
          'spherical_pose_graph_half_overlap_bridge_v1',
        );
        expect(request.window['bridgeRule'], 'root_window_no_parent');
        expect(request.frames, hasLength(35));
        expect(request.frames.take(2).map((f) => f.frameID), ['a', 'b']);
        expect(request.frames.map((f) => f.frameID).toSet(), {'a', 'b'});
        expect(request.frames.first.imageRelativePath, 'photos_depth/a.jpg');
        expect(
          request.frames.first.sourceImageRelativePath,
          'photos_highres/a.jpg',
        );
        expect(request.frames.first.inputWidth, 742);
        expect(request.frames.first.inputHeight, 476);
        expect(
          request.toJson()['inputSizePolicy'],
          containsPair('locked', true),
        );
        expect(request.toJson()['inputSizePolicy'], containsPair('width', 742));
        final runtimeContract =
            request.toJson()['runtimeContract'] as Map<String, Object?>;
        expect(runtimeContract['owner'], 'Flutter/Dart pipeline policy');
        expect(
          runtimeContract['outputs'],
          containsPair('predPoseDir', 'pred_pose'),
        );

        final depthIndex =
            jsonDecode(
                  File(
                    '${cap.path}/stages/depth/depth_index.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(depthIndex['status'], 'completed');
        expect(depthIndex['completed_count'], 2);
        expect(depthIndex['input_size_locked'], isTrue);
        expect(depthIndex['input_width'], 742);
        expect(depthIndex['input_height'], 476);
        expect(
          depthIndex['runtime_contract'],
          containsPair('schemaVersion', 'aether_da3_runtime_contract_v1'),
        );
        expect(
          depthIndex['visual_loop_retrieval'],
          containsPair('status', 'not_configured'),
        );
        expect(
          depthIndex['dense_sim3_verification'],
          containsPair(
            'method',
            'official_streaming_weighted_point_map_sim3_dart_v1',
          ),
        );
        expect(
          depthIndex['da3_real_device_audit_report_path'],
          'da3_real_device_audit.json',
        );
        expect(
          depthIndex['metric_depth_alignment_report_path'],
          'metric_depth_alignment_report.json',
        );
        expect(
          depthIndex['metric_depth_alignment'],
          containsPair(
            'schema_version',
            'aether_metric_depth_alignment_report_v1',
          ),
        );
        expect(
          depthIndex['da3_real_device_audit'],
          containsPair('schema_version', 'aether_da3_real_device_audit_v1'),
        );
        expect(
          depthIndex['k_window_graph']['bridge_graph'],
          isA<List<dynamic>>(),
        );
        expect(
          depthIndex['k_window_graph']['loop_candidates'],
          isA<List<dynamic>>(),
        );
        expect(
          depthIndex['frames'],
          everyElement(containsPair('status', 'completed')),
        );

        final metaLines = File(
          '${cap.path}/stages/depth/depth_meta.jsonl',
        ).readAsLinesSync();
        expect(metaLines, hasLength(2));
        expect(metaLines.first, contains('"relative_depth_path"'));
      },
    );

    test(
      'default depth stage MethodChannel ABI returns native adapter results',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));
        await _writePhotoBundleFixture(cap);

        final channel = const MethodChannel('pocketworld/da3_depth');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'runDa3DepthWindow');
          final args = (call.arguments as Map).cast<String, Object?>();
          expect(args['windowID'], 'window_000');
          expect(args['model'], containsPair('id', 'DA3-BASE'));
          expect(args['inputSizePolicy'], containsPair('locked', true));
          expect(args['inputSizePolicy'], containsPair('width', 742));
          expect(
            args['runtimeContract'],
            containsPair('schemaVersion', 'aether_da3_runtime_contract_v1'),
          );
          final frames = (args['frames'] as List).cast<Map<Object?, Object?>>();
          expect(frames, hasLength(35));
          expect(frames.first['imageRelativePath'], 'photos_depth/a.jpg');
          expect(
            frames.first['sourceImageRelativePath'],
            'photos_highres/a.jpg',
          );
          expect(frames.take(2).map((f) => f['frameID']), ['a', 'b']);
          expect(
            File(frames.first['imagePath']! as String).existsSync(),
            isTrue,
          );
          return <String, Object?>{
            'windowID': args['windowID'],
            'status': 'completed',
            'telemetry': {
              'loadMs': 10.0,
              'inferenceMs': 25.0,
              'rssPeakApproxMB': 128.0,
              'cpu': {'peakDeviceNormalizedPercent': 40.0},
            },
            'frames': [
              for (var i = 0; i < frames.length; i++)
                <String, Object?>{
                  'frameID': frames[i]['frameID'],
                  'windowID': args['windowID'],
                  'status': 'completed',
                  'relativeDepthPath': 'relative_depth/mock_$i.bin',
                  'confidencePath': 'confidence/mock_$i.bin',
                  'predExtrinsicsPath': 'pred_pose/mock_${i}_extrinsics.bin',
                  'predIntrinsicsPath': 'pred_pose/mock_${i}_intrinsics.bin',
                  'depthWidth': 0,
                  'depthHeight': 0,
                  'inferenceMs': 0.0,
                  'confMedian': 1.2,
                  'confMean': 1.2,
                  'confMin': 1.2,
                  'confMax': 1.2,
                },
            ],
          };
        });

        final runner = LocalPipelineRunner(
          captureDir: cap,
          stages: const [DepthStage(stubDelay: _fastDelay)],
        );
        addTearDown(runner.dispose);

        await runner.run();

        final depthIndex =
            jsonDecode(
                  File(
                    '${cap.path}/stages/depth/depth_index.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(depthIndex['status'], 'completed');
        expect(depthIndex['completed_count'], 2);
        expect(depthIndex['pending_count'], 0);
        expect(depthIndex['input_size_locked'], isTrue);
        expect(depthIndex['geometry_contract']['downstream_consumers'], [
          'pointcloud',
          'mesh',
          'texture',
          'highlight_specular',
        ]);
        expect(
          depthIndex['da3_real_device_audit']['windowTelemetry'],
          isNotEmpty,
        );
      },
    );

    test('a stage that throws → PipelineErrorEvent + run() returns', () async {
      final cap = await _makeCaptureDir();
      addTearDown(() => cap.delete(recursive: true));

      final runner = LocalPipelineRunner(
        captureDir: cap,
        stages: const [
          DepthStage(stubDelay: _fastDelay),
          _ExplodingStage(),
          MeshStage(stubDelay: _fastDelay),
          TextureStage(stubDelay: _fastDelay),
          CompressStage(stubDelay: _fastDelay),
        ],
      );
      addTearDown(runner.dispose);

      final events = <PipelineEvent>[];
      final sub = runner.stream.listen(events.add);
      await runner.run();
      await sub.cancel();

      final errors = events.whereType<PipelineErrorEvent>().toList();
      expect(errors.length, 1);
      expect(errors.single.error.stage, PipelineStage.pointcloud);
      expect(errors.single.error.code, 'stage_threw');
      expect(errors.single.error.isRetryable, isTrue);

      // No completion event — runner returned mid-pipeline.
      expect(events.whereType<PipelineCompletedEvent>(), isEmpty);

      // Depth stage did complete (its done.json exists), pointcloud
      // dir was created but has no done.json (so a retry resumes
      // there), and downstream stages were not touched.
      expect(File('${cap.path}/stages/depth/done.json').existsSync(), isTrue);
      expect(
        File('${cap.path}/stages/pointcloud/done.json').existsSync(),
        isFalse,
      );
      expect(
        Directory('${cap.path}/stages/mesh').existsSync(),
        isFalse,
        reason: 'mesh stage should not have started after pointcloud failed',
      );
    });
  });
}

Future<void> _writePhotoBundleFixture(Directory cap) async {
  final highres = Directory('${cap.path}/photos_highres')..createSync();
  final previews = Directory('${cap.path}/previews')..createSync();
  for (final id in ['a', 'b']) {
    final jpeg = _jpegFixture(id == 'a' ? 24 : 48);
    await File('${highres.path}/$id.jpg').writeAsBytes(jpeg);
    await File('${previews.path}/$id.jpg').writeAsBytes(jpeg);
  }
  await File('${cap.path}/photo_bundle.json').writeAsString(
    jsonEncode({
      'schemaVersion': 'aether_photo_bundle_v1',
      'photosHighresDir': 'photos_highres',
      'previewsDir': 'previews',
      'frames': [
        _photoBundleFrame('a', 0, 0, 0, 0),
        _photoBundleFrame('b', 0.14, 0, 0.12, 0.02),
      ],
    }),
  );
}

Map<String, Object?> _photoBundleFrame(
  String id,
  double azimuth,
  double elevation,
  double x,
  double z,
) {
  return {
    'id': id,
    'highresFilename': '$id.jpg',
    'previewFilename': '$id.jpg',
    'timestamp': id == 'a' ? 1.0 : 2.0,
    'azimuth': azimuth,
    'elevation': elevation,
    'cameraRadiusM': 1.0,
    'radiusShellID': 'r_1.00_1.25m',
    'imageWidth': 4032,
    'imageHeight': 3024,
    'quality': {'score': 0.9, 'laplacianVariance': 500.0},
    'cameraTransform': [
      1.0,
      0.0,
      0.0,
      0.0,
      0.0,
      1.0,
      0.0,
      0.0,
      0.0,
      0.0,
      1.0,
      0.0,
      x,
      0.0,
      z,
      1.0,
    ],
    'intrinsics': [2200.0, 2200.0, 2016.0, 1512.0],
  };
}

List<int> _jpegFixture(int seed) {
  final img = image.Image(width: 32, height: 24);
  for (var y = 0; y < img.height; y += 1) {
    for (var x = 0; x < img.width; x += 1) {
      img.setPixelRgb(x, y, (x * 3 + seed) % 255, (y * 5 + seed) % 255, 160);
    }
  }
  return image.encodeJpg(img, quality: 90);
}

/// Test seam: a stage that always throws on run(). Used by the error-
/// path test above to confirm the orchestrator surfaces failure as a
/// PipelineErrorEvent and short-circuits the remaining stages.
class _ExplodingStage extends PipelineStageRunner {
  const _ExplodingStage();

  @override
  PipelineStage get stage => PipelineStage.pointcloud;

  @override
  String get outputDirName => 'pointcloud';

  @override
  Future<void> run({
    required Directory inputDir,
    required Directory outputDir,
    required StreamSink<StageProgress> progressSink,
  }) async {
    throw StateError('synthetic failure for test');
  }
}

class _FakeDa3DepthRunner extends Da3DepthRunner {
  final requests = <Da3DepthWindowRequest>[];

  @override
  Future<Da3DepthWindowResult> runWindow(Da3DepthWindowRequest request) async {
    requests.add(request);
    final results = <Da3DepthFrameResult>[];
    for (final frame in request.frames) {
      final depthPath = 'depth_${frame.frameIndex}.bin';
      await File(
        '${request.outputDir.path}/$depthPath',
      ).writeAsBytes(<int>[frame.frameIndex]);
      results.add(
        Da3DepthFrameResult(
          frameID: frame.frameID,
          windowID: request.windowID,
          status: 'completed',
          relativeDepthPath: depthPath,
          confidencePath: 'conf_${frame.frameIndex}.bin',
          predExtrinsicsPath: 'pose_${frame.frameIndex}_extrinsics.bin',
          predIntrinsicsPath: 'pose_${frame.frameIndex}_intrinsics.bin',
          depthWidth: 0,
          depthHeight: 0,
          inferenceMs: 12.5,
          confStats: const DepthConfStats(
            median: 1.2,
            mean: 1.3,
            min: 1.1,
            max: 1.8,
          ),
        ),
      );
    }
    return Da3DepthWindowResult(windowID: request.windowID, frames: results);
  }
}
