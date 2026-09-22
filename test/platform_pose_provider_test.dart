import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dome/ar_pose.dart';
import 'package:pocketworld_flutter/dome/platform_pose_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aether_arkit');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'legacy save derives durable feed job identity from sealed Dart spec',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'stopSession') return null;
            expect(call.method, 'saveCurrentFrameAsJpeg');
            return <String, Object?>{
              'sfm_gray': Uint8List.fromList(const <int>[1, 2, 3, 4]),
              'sfm_gray_w': 2,
              'sfm_gray_h': 2,
              'image_w': 4,
              'image_h': 4,
              'intrinsics_fxfycxcy': const <double>[100, 100, 2, 2],
              'extrinsic': const <double>[
                1,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                1,
              ],
              't': 42.0,
            };
          });
      final provider = PlatformARPoseProvider();
      addTearDown(provider.stop);
      const spec = ARFrameSaveSpec(
        frameID: 'auto-frame-17',
        cellIndex: 1,
        slotIndex: 2,
        jpegPath: '/tmp/auto-frame-17.jpg',
        metadataPath: '/tmp/auto-frame-17.json',
      );

      final result = await provider.saveCurrentFrame(spec);

      expect(result.saved, isTrue);
      expect(result.sfmFrame, isNotNull);
      expect(result.sfmFrame!.captureJobId, 'auto-frame-17');
      expect(result.sfmFrame!.gray, const <int>[1, 2, 3, 4]);
    },
  );

  test('whole-discard validates exact native cleanup receipt', () async {
    const root = '/tmp/cap-discard-exact';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'stopSession') return null;
          expect(call.method, 'discardManualCaptureV2Jobs');
          expect(call.arguments, <String, Object?>{'captureDirectory': root});
          return <String, Object?>{
            'schema_version': 'aether_manual_capture_v2_discard_v1',
            'capture_directory': root,
            'discarded_job_ids': <String>['job-1'],
            'released_raw_bytes': 64,
            'backlog_metrics': <String, Object?>{
              'raw_bytes': 0,
              'job_count': 0,
            },
          };
        });
    final provider = PlatformARPoseProvider();
    addTearDown(provider.stop);

    final receipt = await provider.discardManualCaptureV2Jobs(root);

    expect(receipt.captureDirectory, root);
    expect(receipt.discardedJobIds, const <String>['job-1']);
    expect(receipt.releasedRawBytes, 64);
    expect(receipt.backlogMetrics['raw_bytes'], 0);
  });
}
