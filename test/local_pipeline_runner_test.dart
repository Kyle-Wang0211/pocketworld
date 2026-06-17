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
import 'dart:typed_data';

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
        expect(
          File(
            '${cap.path}/stages/capture_audit/arkit_sparse_anchors_world.ply',
          ).existsSync(),
          isTrue,
        );
        expect(
          File(
            '${cap.path}/stages/capture_audit/arkit_camera_path_world.ply',
          ).existsSync(),
          isTrue,
        );
        final arkitSparseAudit =
            jsonDecode(
                  File(
                    '${cap.path}/stages/capture_audit/arkit_sparse_pointcloud_audit.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(arkitSparseAudit['completeSidecarFrameCount'], 2);
        expect(arkitSparseAudit['exportedAnchorCount'], 6);
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
          'official_streaming_strict_sequential_coreml_padded_v1',
        );
        expect(request.window['bridgeRule'], 'root_window_no_parent');
        expect(request.window['officialSaveSlotIndices'], [0, 1]);
        expect(request.window['officialCoreFrameIDs'], ['a', 'b']);
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
          containsPair('status', 'awaiting_thin_executor'),
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
      'DA3 policy uses official sequential save slots without overlap duplicates',
      () {
        final policy = const PhotoBundlePipelinePolicyService();
        final manifest = {
          'schemaVersion': 'aether_photo_bundle_v1',
          'frames': [
            for (var i = 0; i < 11; i += 1)
              {
                'id': 'f${i.toString().padLeft(2, '0')}',
                'timestamp': i.toDouble(),
                'quality': {'score': 0.9},
              },
          ],
        };
        final plan = policy.buildKWindowPlan(
          manifest,
          const {'nodes': [], 'edges': []},
          windowSize: 5,
          targetBridgeOverlap: 2,
        );

        expect(
          plan['windowingPolicy'],
          containsPair('kind', 'official_streaming_strict_sequential_v1'),
        );
        expect(plan['windowCount'], 3);
        final windows = (plan['windows'] as List).cast<Map<String, Object?>>();
        expect(windows[0]['frameIDs'], ['f00', 'f01', 'f02', 'f03', 'f04']);
        expect(windows[1]['frameIDs'], ['f03', 'f04', 'f05', 'f06', 'f07']);
        expect(windows[2]['frameIDs'], ['f06', 'f07', 'f08', 'f09', 'f10']);
        expect(windows[0]['officialSaveSlotIndices'], [0, 1, 2]);
        expect(windows[1]['officialSaveSlotIndices'], [0, 1, 2]);
        expect(windows[2]['officialSaveSlotIndices'], [0, 1, 2, 3, 4]);

        final saved = [
          for (final window in windows)
            ...(window['officialCoreFrameIDs'] as List).cast<String>(),
        ];
        expect(saved, [
          'f00',
          'f01',
          'f02',
          'f03',
          'f04',
          'f05',
          'f06',
          'f07',
          'f08',
          'f09',
          'f10',
        ]);
        expect(saved.toSet(), hasLength(saved.length));
        expect(
          plan['windowingPolicy'],
          containsPair('officialSavedDuplicateFrameCount', 0),
        );
      },
    );

    test('pointcloud preflight contract stays on official npz baseline', () {
      final policy = const PhotoBundlePipelinePolicyService();
      final plan = policy.buildPreflightPlan(
        const {
          'schemaVersion': 'aether_photo_bundle_v1',
          'frames': [
            {'id': 'f00'},
            {'id': 'f01'},
          ],
        },
        const {'edgeCount': 0, 'nodes': [], 'edges': []},
      );

      final nativeKernels = (plan['nativeKernels'] as List).cast<String>();
      final outputs = (plan['outputs'] as List).cast<String>();
      final policyJson = (plan['policy'] as Map).cast<String, Object?>();
      expect(
        policyJson['mode'],
        'official_da3_streaming_npz_downstream_baseline',
      );
      expect(
        policyJson['officialReference'],
        contains('results_output/frame_*.npz'),
      );
      expect(
        policyJson['confidenceMode'],
        'official_da3_streaming_conf_minus_one',
      );
      expect(policyJson['confThresholdCoef'], 0.5);
      expect(
        policyJson['confThresholdCoefSource'],
        contains('npz_output_process.py CLI default'),
      );
      expect(policyJson['sampleRatio'], 0.015);
      expect(policyJson['depthInputMode'], 'relativeDepthPath_only');
      expect(
        policyJson['productCleanupPolicy'],
        contains('disabled_until_official_parity_is_proven'),
      );
      expect(nativeKernels, contains('official_reservoir_sample'));
      expect(nativeKernels, isNot(contains('voxel_downsample')));
      expect(nativeKernels, isNot(contains('statistical_outlier_prune')));
      expect(nativeKernels, isNot(contains('normal_estimation')));
      expect(outputs, contains('stages/pointcloud/pointcloud.ply'));
      expect(
        outputs,
        contains('stages/pointcloud/official_pointcloud_report.json'),
      );
    });

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
                  'confidenceMode': 'official_da3_streaming_conf_minus_one',
                  'confidenceOffsetApplied': -1.0,
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
        final frames = (depthIndex['frames'] as List).cast<Map>();
        expect(
          frames.first['confidenceMode'],
          'official_da3_streaming_conf_minus_one',
        );
        expect(frames.first['confidenceOffsetApplied'], -1.0);
      },
    );

    test(
      'pointcloud stage exports official core frames without overlap duplicates',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));
        await _writePhotoBundleFixture(cap);

        final runner = LocalPipelineRunner(
          captureDir: cap,
          stages: const [
            DepthStage(
              stubDelay: _fastDelay,
              depthRunner: _TensorDa3DepthRunner(),
            ),
            PointCloudStage(stubDelay: Duration.zero),
          ],
        );
        addTearDown(runner.dispose);

        await runner.run();

        final report =
            jsonDecode(
                  File(
                    '${cap.path}/stages/pointcloud/official_pointcloud_report.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(report['status'], 'completed');
        expect(report['selected_frame_count'], 2);
        expect(report['selected_duplicate_frame_count'], 0);
        expect(report['point_count'], 3);
        expect(report['valid_point_count_before_sampling'], 200);
        expect(
          report['confidence_scope'],
          'global_selected_official_core_frames',
        );
        expect(report['confidence_input_modes'], [
          'official_da3_streaming_conf_minus_one',
        ]);
        expect(report['confidence_offset_applied_values'], [-1.0]);
        expect(
          report['sampling_scope'],
          'global_selected_official_core_frames',
        );
        expect(
          report['color_mode'],
          'source_rgb_nearest_with_confidence_grayscale_fallback',
        );
        expect(report['source_rgb_frame_count'], 2);
        expect(report['color_fallback_frame_count'], 0);
        expect(report['ply_format'], 'binary_little_endian_1.0');
        expect(
          report['official_output_path_mode'],
          'results_output_npz_process_core_frames_downstream',
        );
        expect(
          report['official_downstream_overlap_policy'],
          contains('non-overlap/core'),
        );
        expect(
          report['official_cli_combined_pcd_path'],
          'pcd/combined_pcd.ply',
        );
        expect(
          report['official_cli_combined_pcd_overlap_policy'],
          contains('overlap slots are not removed'),
        );
        expect(
          report['sampling'],
          'official_reservoir_sampling_seeded_product_reproducible',
        );
        expect(
          _plyHeader(File('${cap.path}/stages/pointcloud/pointcloud.ply')),
          contains('format binary_little_endian 1.0'),
        );
        expect(
          _plyHeader(File('${cap.path}/stages/pointcloud/pointcloud.ply')),
          contains('element vertex 3'),
        );
      },
    );

    test(
      'pointcloud stage uses one global official confidence threshold and sample',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));
        final frameIDs = [
          for (var i = 0; i < 40; i += 1) 'f${i.toString().padLeft(2, '0')}',
        ];
        await _writePhotoBundleFixture(cap, frameIDs: frameIDs);

        final runner = LocalPipelineRunner(
          captureDir: cap,
          stages: [
            DepthStage(
              stubDelay: _fastDelay,
              depthRunner: _TensorDa3DepthRunner(
                width: 16,
                height: 16,
                confidenceByFrameID: {
                  for (final id in frameIDs.take(17)) id: 1.0,
                  for (final id in frameIDs.skip(17)) id: 3.0,
                },
              ),
            ),
            const PointCloudStage(stubDelay: Duration.zero),
          ],
        );
        addTearDown(runner.dispose);

        await runner.run();

        final report =
            jsonDecode(
                  File(
                    '${cap.path}/stages/pointcloud/official_pointcloud_report.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(report['status'], 'completed');
        expect(report['selected_frame_count'], 40);
        expect(report['selected_duplicate_frame_count'], 0);
        expect(report['confidence_threshold'], closeTo(1.075, 1e-9));
        expect(report['confidence_input_modes'], [
          'official_da3_streaming_conf_minus_one',
        ]);
        expect(report['confidence_offset_applied_values'], [-1.0]);
        expect(report['valid_point_count_before_sampling'], 5888);
        expect(report['point_count'], 88);
        expect(report['source_rgb_frame_count'], 40);
        expect(report['color_fallback_frame_count'], 0);
        expect(
          _plyHeader(File('${cap.path}/stages/pointcloud/pointcloud.ply')),
          contains('format binary_little_endian 1.0'),
        );
        expect(
          _plyHeader(File('${cap.path}/stages/pointcloud/pointcloud.ply')),
          contains('element vertex 88'),
        );
      },
    );

    test(
      'pointcloud stage writes official camera poses and intrinsics for core frames',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));
        final depthDir = Directory('${cap.path}/stages/depth')
          ..createSync(recursive: true);
        final outputDir = Directory('${cap.path}/stages/pointcloud')
          ..createSync(recursive: true);
        final photosDepth = Directory('${cap.path}/photos_depth')
          ..createSync(recursive: true);
        await File('${photosDepth.path}/a.jpg').writeAsBytes(_jpegFixture(24));
        await File('${cap.path}/da3_k_windows.json').writeAsString(
          jsonEncode({
            'windows': [
              {
                'id': 'window_000',
                'frameIDs': ['a'],
                'officialCoreFrameIDs': ['a'],
                'officialSaveSlotIndices': [0],
              },
            ],
          }),
        );
        await Directory('${depthDir.path}/relative_depth').create();
        await Directory('${depthDir.path}/metric_depth').create();
        await Directory('${depthDir.path}/confidence').create();
        await Directory('${depthDir.path}/pred_pose').create();
        await File(
          '${depthDir.path}/relative_depth/a.bin',
        ).writeAsBytes(_float32Bytes([for (var i = 0; i < 100; i += 1) 1.0]));
        await File(
          '${depthDir.path}/metric_depth/a.bin',
        ).writeAsBytes(_float32Bytes([for (var i = 0; i < 100; i += 1) 10.0]));
        await File(
          '${depthDir.path}/confidence/a.bin',
        ).writeAsBytes(_float32Bytes([for (var i = 0; i < 100; i += 1) 2.0]));
        await File('${depthDir.path}/pred_pose/a_extrinsics.bin').writeAsBytes(
          _float32Bytes(const [
            1.0,
            0.0,
            0.0,
            1.0,
            0.0,
            1.0,
            0.0,
            2.0,
            0.0,
            0.0,
            1.0,
            3.0,
          ]),
        );
        await File('${depthDir.path}/pred_pose/a_intrinsics.bin').writeAsBytes(
          _float32Bytes(const [4.0, 0.0, 5.0, 0.0, 6.0, 7.0, 0.0, 0.0, 1.0]),
        );
        await File('${depthDir.path}/depth_index.json').writeAsString(
          jsonEncode({
            'frames': [
              {
                'frameID': 'a',
                'windowID': 'window_000',
                'imageRelativePath': 'photos_depth/a.jpg',
                'relativeDepthPath': 'relative_depth/a.bin',
                'metricDepthPath': 'metric_depth/a.bin',
                'confidencePath': 'confidence/a.bin',
                'predExtrinsicsPath': 'pred_pose/a_extrinsics.bin',
                'predIntrinsicsPath': 'pred_pose/a_intrinsics.bin',
                'depthWidth': 100,
                'depthHeight': 1,
                'windowToRootSim3': {
                  'scale': 2.0,
                  'rotationRowMajor3x3': [
                    1.0,
                    0.0,
                    0.0,
                    0.0,
                    1.0,
                    0.0,
                    0.0,
                    0.0,
                    1.0,
                  ],
                  'translation': [10.0, 20.0, 30.0],
                },
              },
            ],
          }),
        );

        final progress = StreamController<StageProgress>.broadcast();
        addTearDown(progress.close);
        await const PointCloudStage(stubDelay: Duration.zero).run(
          inputDir: depthDir,
          outputDir: outputDir,
          progressSink: progress.sink,
        );

        final report =
            jsonDecode(
                  File(
                    '${outputDir.path}/official_pointcloud_report.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(report['camera_pose_count'], 1);
        expect(report['intrinsic_count'], 1);
        expect(report['point_count'], 1);
        expect(report['official_depth_input_mode'], 'relativeDepthPath_only');
        expect(
          report['metric_depth_path_policy'],
          contains('ignored by the official baseline exporter'),
        );
        expect(
          report['official_downstream_projection_mode'],
          'scaled_relative_depth_reprojected_with_saved_c2w_camera_pose',
        );
        expect(
          report['camera_pose_mode'],
          'official_save_camera_poses_c2w_normalized_sim3_left_multiply',
        );
        expect(
          report['camera_pose_ply_format'],
          'ascii_1.0_official_camera_center_visualization',
        );
        final firstPoint = _firstPlyVertexXYZ(
          File('${outputDir.path}/pointcloud.ply'),
        );
        expect(firstPoint[2], closeTo(26.0, 1e-6));

        final poseRows = _matrixRows(
          File('${outputDir.path}/camera_poses.txt').readAsStringSync(),
        );
        expect(poseRows, hasLength(1));
        expect(poseRows.single, hasLength(16));
        expect(poseRows.single[0], closeTo(1.0, 1e-9));
        expect(poseRows.single[5], closeTo(1.0, 1e-9));
        expect(poseRows.single[10], closeTo(1.0, 1e-9));
        expect(poseRows.single[3], closeTo(8.0, 1e-9));
        expect(poseRows.single[7], closeTo(16.0, 1e-9));
        expect(poseRows.single[11], closeTo(24.0, 1e-9));
        final posePly = File(
          '${outputDir.path}/camera_poses.ply',
        ).readAsStringSync();
        expect(posePly, contains('format ascii 1.0'));
        expect(posePly, contains('element vertex 1'));
        expect(posePly, contains('8.0 16.0 24.0 255 0 0'));

        final intrinsicRows = _matrixRows(
          File('${outputDir.path}/intrinsic.txt').readAsStringSync(),
        );
        expect(intrinsicRows.single, [4.0, 6.0, 5.0, 7.0]);

        final depthScales =
            jsonDecode(
                  File(
                    '${outputDir.path}/camera_pose_depth_scales.json',
                  ).readAsStringSync(),
                )
                as List;
        expect((depthScales.single as Map)['depthScale'], 2.0);
      },
    );

    test(
      'pointcloud stage blocks when dense Sim3 alignment is incomplete',
      () async {
        final cap = await _makeCaptureDir();
        addTearDown(() => cap.delete(recursive: true));
        final depthDir = Directory('${cap.path}/stages/depth')
          ..createSync(recursive: true);
        final outputDir = Directory('${cap.path}/stages/pointcloud')
          ..createSync(recursive: true);
        await File('${cap.path}/da3_k_windows.json').writeAsString(
          jsonEncode({
            'windows': [
              {
                'id': 'window_000',
                'frameIDs': ['a'],
                'officialCoreFrameIDs': ['a'],
                'officialSaveSlotIndices': [0],
              },
            ],
          }),
        );
        await File('${depthDir.path}/depth_index.json').writeAsString(
          jsonEncode({
            'geometry_gate_status': 'inconclusive',
            'geometry_gate_blocks_downstream': true,
            'streaming_alignment': {
              'status': 'incomplete',
              'unalignedWindowIDs': ['window_001'],
            },
            'frames': const <Map<String, Object?>>[],
          }),
        );

        final progress = StreamController<StageProgress>.broadcast();
        addTearDown(progress.close);
        await const PointCloudStage(stubDelay: Duration.zero).run(
          inputDir: depthDir,
          outputDir: outputDir,
          progressSink: progress.sink,
        );

        final report =
            jsonDecode(
                  File(
                    '${outputDir.path}/official_pointcloud_report.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(report['status'], 'blocked_by_dense_sim3_alignment');
        expect(report['point_count'], 0);
        expect(report['blocker']['geometry_gate_status'], 'inconclusive');
        expect(report['blocker']['streaming_alignment_status'], 'incomplete');
        expect(report['blocker']['unaligned_window_ids'], ['window_001']);
        expect(
          _plyHeader(File('${outputDir.path}/pointcloud.ply')),
          contains('element vertex 0'),
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

Future<void> _writePhotoBundleFixture(
  Directory cap, {
  List<String> frameIDs = const ['a', 'b'],
}) async {
  final highres = Directory('${cap.path}/photos_highres')..createSync();
  final previews = Directory('${cap.path}/previews')..createSync();
  for (var i = 0; i < frameIDs.length; i += 1) {
    final id = frameIDs[i];
    final jpeg = _jpegFixture(24 + i);
    await File('${highres.path}/$id.jpg').writeAsBytes(jpeg);
    await File(
      '${highres.path}/$id.json',
    ).writeAsString(jsonEncode(_arkitSidecar(i * 0.12)));
    await File('${previews.path}/$id.jpg').writeAsBytes(jpeg);
  }
  await File('${cap.path}/photo_bundle.json').writeAsString(
    jsonEncode({
      'schemaVersion': 'aether_photo_bundle_v1',
      'photosHighresDir': 'photos_highres',
      'previewsDir': 'previews',
      'frames': [
        for (var i = 0; i < frameIDs.length; i += 1)
          _photoBundleFrame(
            frameIDs[i],
            i * 0.14,
            0,
            i * 0.12,
            i * 0.02,
            timestamp: i + 1.0,
          ),
      ],
    }),
  );
}

Map<String, Object?> _photoBundleFrame(
  String id,
  double azimuth,
  double elevation,
  double x,
  double z, {
  double? timestamp,
}) {
  return {
    'id': id,
    'highresFilename': '$id.jpg',
    'previewFilename': '$id.jpg',
    'timestamp': timestamp ?? (id == 'a' ? 1.0 : 2.0),
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

Map<String, Object?> _arkitSidecar(double xOffset) {
  return {
    'version': 1,
    'native_role': 'thin_arkit_frame_executor',
    't': 1167754.045757208 + xOffset,
    'image_w': 4032,
    'image_h': 3024,
    'extrinsic': [
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
      xOffset,
      0.0,
      0.0,
      1.0,
    ],
    'intrinsics_fxfycxcy': [2200.0, 2200.0, 2016.0, 1512.0],
    'trackingStateName': 'normal',
    'tracking_state': 'normal',
    'is_tracking': true,
    'anchors_world': [
      [xOffset + 0.0, 0.0, -0.3],
      [xOffset + 0.1, 0.0, -0.4],
      [xOffset + 0.0, 0.1, -0.5],
    ],
    'anchor_ids': [1, 2, 3],
    'scale_align_premetrics': {
      'anchor_depth_count': 3,
      'anchor_depth_min_m': 0.3,
      'anchor_depth_max_m': 0.5,
      'anchor_depth_span_m': 0.2,
      'reliability_prior': 0.8,
    },
    'save_dt': 0.012,
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
          confidenceMode: 'official_da3_streaming_conf_minus_one',
          confidenceOffsetApplied: -1.0,
        ),
      );
    }
    return Da3DepthWindowResult(windowID: request.windowID, frames: results);
  }
}

class _TensorDa3DepthRunner extends Da3DepthRunner {
  const _TensorDa3DepthRunner({
    this.width = 100,
    this.height = 1,
    this.confidenceByFrameID = const {},
  });

  final int width;
  final int height;
  final Map<String, double> confidenceByFrameID;

  @override
  Future<Da3DepthWindowResult> runWindow(Da3DepthWindowRequest request) async {
    final results = <Da3DepthFrameResult>[];
    final written = <String>{};
    for (final frame in request.frames) {
      final depthPath = 'relative_depth/${frame.frameID}.bin';
      final confPath = 'confidence/${frame.frameID}.bin';
      final extrinsicsPath = 'pred_pose/${frame.frameID}_extrinsics.bin';
      final intrinsicsPath = 'pred_pose/${frame.frameID}_intrinsics.bin';
      if (written.add(frame.frameID)) {
        final depthValues = [for (var i = 0; i < width * height; i += 1) 1.0];
        final confidence = confidenceByFrameID[frame.frameID] ?? 2.0;
        final confValues = [
          for (var i = 0; i < width * height; i += 1) confidence,
        ];
        await File(
          '${request.outputDir.path}/$depthPath',
        ).create(recursive: true);
        await File(
          '${request.outputDir.path}/$depthPath',
        ).writeAsBytes(_float32Bytes(depthValues));
        await File(
          '${request.outputDir.path}/$confPath',
        ).create(recursive: true);
        await File(
          '${request.outputDir.path}/$confPath',
        ).writeAsBytes(_float32Bytes(confValues));
        await File(
          '${request.outputDir.path}/$extrinsicsPath',
        ).create(recursive: true);
        await File('${request.outputDir.path}/$extrinsicsPath').writeAsBytes(
          _float32Bytes(const [
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
          ]),
        );
        await File(
          '${request.outputDir.path}/$intrinsicsPath',
        ).create(recursive: true);
        await File('${request.outputDir.path}/$intrinsicsPath').writeAsBytes(
          _float32Bytes(const [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]),
        );
      }
      results.add(
        Da3DepthFrameResult(
          frameID: frame.frameID,
          windowID: request.windowID,
          status: 'completed',
          relativeDepthPath: depthPath,
          confidencePath: confPath,
          predExtrinsicsPath: extrinsicsPath,
          predIntrinsicsPath: intrinsicsPath,
          depthWidth: width,
          depthHeight: height,
          inferenceMs: 1,
          confStats: const DepthConfStats(median: 2, mean: 2, min: 2, max: 2),
          confidenceMode: 'official_da3_streaming_conf_minus_one',
          confidenceOffsetApplied: -1.0,
        ),
      );
    }
    return Da3DepthWindowResult(windowID: request.windowID, frames: results);
  }
}

List<int> _float32Bytes(List<double> values) {
  final bytes = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i += 1) {
    bytes.setFloat32(i * 4, values[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

List<List<double>> _matrixRows(String text) {
  return [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty)
        [
          for (final item in line.trim().split(RegExp(r'\s+')))
            double.parse(item),
        ],
  ];
}

String _plyHeader(File file) {
  final bytes = file.readAsBytesSync();
  final marker = ascii.encode('end_header\n');
  for (var i = 0; i <= bytes.length - marker.length; i += 1) {
    var matched = true;
    for (var j = 0; j < marker.length; j += 1) {
      if (bytes[i + j] != marker[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return ascii.decode(bytes.sublist(0, i + marker.length));
    }
  }
  return ascii.decode(bytes, allowInvalid: true);
}

List<double> _firstPlyVertexXYZ(File file) {
  final bytes = file.readAsBytesSync();
  final marker = ascii.encode('end_header\n');
  for (var i = 0; i <= bytes.length - marker.length; i += 1) {
    var matched = true;
    for (var j = 0; j < marker.length; j += 1) {
      if (bytes[i + j] != marker[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      final offset = i + marker.length;
      final data = ByteData.sublistView(bytes, offset, offset + 12);
      return [
        data.getFloat32(0, Endian.little),
        data.getFloat32(4, Endian.little),
        data.getFloat32(8, Endian.little),
      ];
    }
  }
  throw StateError('PLY header marker not found');
}
