import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/capture_session.dart';
import 'package:pocketworld_flutter/capture/dome/captured_frame_sample.dart';
import 'package:pocketworld_flutter/capture/dome/dome_cell_state.dart';
import 'package:pocketworld_flutter/capture/dome/dome_target_points.dart';
import 'package:pocketworld_flutter/dome/ar_pose.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const sensorsMethodChannel = MethodChannel(
    'dev.fluttercommunity.plus/sensors/method',
  );

  late Directory documentsDirectory;

  setUp(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'capture-session-retention-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => documentsDirectory.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, (_) async => null);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  test('final curation never deletes photos the user captured', () async {
    final session = CaptureSession(poseProvider: _FakeARPoseProvider());
    addTearDown(session.dispose);
    await session.start(autoLock: false, manualCapture: true);

    final photosDirectory = Directory(session.photosDir!);
    final selectedJpeg = File('${photosDirectory.path}/selected.jpg');
    final selectedSidecar = File('${photosDirectory.path}/selected.json');
    final unselectedJpeg = File('${photosDirectory.path}/unselected.jpg');
    final unselectedSidecar = File('${photosDirectory.path}/unselected.json');
    await selectedJpeg.writeAsBytes(const [1]);
    await selectedSidecar.writeAsString('{}');
    await unselectedJpeg.writeAsBytes(const [2]);
    await unselectedSidecar.writeAsString('{}');

    final curated = <CuratedFrame>[
      CuratedFrame(
        sample: CapturedFrameSample(
          timestamp: 1,
          azimuth: 0,
          elevation: 0,
          sharpness: 1000,
          motionScore: 0,
          exposureScore: 1,
          frameId: 'selected',
          jpegPath: selectedJpeg.path,
        ),
        azBin: 0,
        elBin: 0,
        cellState: DomeCellState.ok,
        qualityScore: 1,
        cellRankInTopK: 0,
      ),
    ];
    expect(await selectedJpeg.exists(), isTrue);
    expect(await selectedSidecar.exists(), isTrue);
    expect(
      await unselectedJpeg.exists(),
      isTrue,
      reason: 'Only the user may delete a captured frame.',
    );
    expect(await unselectedSidecar.exists(), isTrue);
    expect(
      await session.reconcileCapturedPhotosFromDisk(),
      containsAll(<String>[selectedJpeg.path, unselectedJpeg.path]),
      reason: 'Draft/album truth comes from every local JPEG, not curation.',
    );

    final manifestFile = await session.writePhotoBundleManifest(curated);
    final manifest = jsonDecode(await manifestFile!.readAsString()) as Map;
    final frameNames = (manifest['frames'] as List)
        .cast<Map>()
        .map((frame) => frame['highresFilename'])
        .toSet();
    expect(
      frameNames,
      <Object?>{'selected.jpg', 'unselected.jpg'},
      reason: 'The local reconstruction bundle must include every photo.',
    );
    expect(await selectedJpeg.exists(), isTrue);
    expect(await unselectedJpeg.exists(), isTrue);
  });
}

class _FakeARPoseProvider implements ARPoseProvider {
  @override
  ARPose? get lastPose => null;

  @override
  Stream<ARPose> start() => const Stream<ARPose>.empty();

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async => null;

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async => false;

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async =>
      ARFrameSaveResult(spec: spec, status: 'unsupported');

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
  }) async => null;

  @override
  Future<void> stop() async {}
}
