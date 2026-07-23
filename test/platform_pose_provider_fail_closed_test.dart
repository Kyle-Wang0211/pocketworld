import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/capture_session.dart';
import 'package:pocketworld_flutter/dome/platform_pose_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aether_arkit');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'self pose provider propagates ar_camera_busy without mock fallback',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'isAvailable') return true;
            if (call.method == 'startSession') {
              throw PlatformException(
                code: 'ar_camera_busy',
                message: 'Another capture route owns the camera',
              );
            }
            return null;
          });

      final provider = PlatformARPoseProvider();
      final poses = <Object>[];
      final subscription = provider.start().listen(poses.add);

      await expectLater(
        provider.ensureStarted(),
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', 'ar_camera_busy')
              .having(
                (error) => error.message,
                'message',
                'Another capture route owns the camera',
              ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(provider.lastPose, isNull);
      expect(poses, isEmpty);
      await subscription.cancel();
      await provider.stop();
    },
  );

  test('self capture session attach surfaces native startup failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'startSession') {
            throw PlatformException(code: 'ar_camera_busy');
          }
          return null;
        });

    final session = CaptureSession(poseProvider: PlatformARPoseProvider());

    await expectLater(
      session.attach(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'ar_camera_busy',
        ),
      ),
    );
    expect(session.isAttached, isFalse);
    await session.dispose();
  });
}
