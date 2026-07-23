import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_dome/platform_pose_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pocketworld_official_arkit');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'official pose provider fails closed when its plugin is unavailable',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'isAvailable') return false;
            return null;
          });

      final provider = PlatformARPoseProvider();
      provider.start();

      await expectLater(
        provider.ensureStarted(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Official AR capture plugin is unavailable'),
          ),
        ),
      );

      expect(provider.lastPose, isNull);
      await provider.stop();
    },
  );
}
