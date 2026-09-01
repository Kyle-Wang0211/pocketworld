import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/capture_session.dart';
import 'package:pocketworld_flutter/official_dome/mock_pose_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorsMethodChannel = MethodChannel(
    'dev.fluttercommunity.plus/sensors/method',
  );

  test(
    'project manifest does not replace a full snapshot with missing rows',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sensorsMethodChannel, (_) async => null);
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'capture-session-manifest-',
      );
      final session = CaptureSession(
        poseProvider: MockARPoseProvider(),
        captureDirectoryFactory: () async =>
            Directory('${temporaryDirectory.path}/capture'),
      );
      addTearDown(() async {
        await session.dispose();
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(sensorsMethodChannel, null);
      });

      await session.start(autoLock: false, manualCapture: true);
      final manifest = File('${session.captureDir}/official_photo_bundle.json');
      const previousCompleteSnapshot = '{"frames":["kept"]}';
      await manifest.writeAsString(previousCompleteSnapshot);

      final result = await session.writeProjectPhotoBundleManifest(<String>[
        '${session.photosHighresDir}/missing.jpg',
        '${session.photosHighresDir}/also_missing.jpg',
      ]);

      expect(result, isNull);
      expect(await manifest.readAsString(), previousCompleteSnapshot);
    },
  );
}
