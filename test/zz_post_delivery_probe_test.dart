import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_record_store.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_transaction.dart';
import 'package:pocketworld_flutter/official_capture/capture_archive_service.dart';
import 'package:pocketworld_flutter/official_capture/capture_session.dart';
import 'package:pocketworld_flutter/official_capture/official_highres_reconstruction_input.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorsMethodChannel = MethodChannel(
    'dev.fluttercommunity.plus/sensors/method',
  );

  late Directory temporaryDirectory;
  late _ControlledPoseProvider provider;
  late CaptureSession session;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, (_) async => null);
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'capture-session-transaction-',
    );
    provider = _ControlledPoseProvider();
    session = CaptureSession(
      poseProvider: provider,
      captureDirectoryFactory: () async =>
          Directory('${temporaryDirectory.path}/capture'),
    );
    await session.start(autoLock: false, manualCapture: true);
    provider.emitPose();
  });

  tearDown(() async {
    await session.dispose();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, null);
  });

  test('POST_DELIVERY_HOST_COST', () async {
    final gray = Uint8List(128 * 128);
    for (var i = 0; i < gray.length; i++) {
      gray[i] = (i ~/ 8).isEven ? 32 : 224;
    }
    final capture = await session.captureSinglePhoto(automaticSelection: true);
    final receipt = capture!;
    await provider.writeHighResolutionArtifacts();
    await provider.writePreviewArtifacts();
    provider.completePreview(saved: true);

    final sw = Stopwatch()..start();
    provider.completeHighResolution(provider.validStill(gray128: gray));
    await receipt.nativeDeliveryCompletion;
    final releaseUs = sw.elapsedMicroseconds;
    await receipt.highResolutionCompletion.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final totalUs = sw.elapsedMicroseconds;
    // ignore: avoid_print
    print('POST_DELIVERY 送达→释放=${releaseUs / 1000}ms  '
        '送达→事务终结=${totalUs / 1000}ms  '
        '(真机同一段实测中位 663ms)');
  });
}

class _ControlledPoseProvider
    implements ARPoseProvider, ARPoseTransportLifecycle {
  final StreamController<ARPose> _poses = StreamController<ARPose>.broadcast(
    sync: true,
  );
  final Completer<HighResolutionStillCapture?> _highResolution =
      Completer<HighResolutionStillCapture?>();
  final Completer<ARFrameSaveResult> _preview = Completer<ARFrameSaveResult>();

  ARPose? _lastPose;
  ARFrameSaveSpec? previewSpec;
  String? highResolutionPath;
  String? highResolutionPreviewPath;
  String? transactionId;
  String? cardTexturePath;
  int highResolutionRequestCount = 0;
  int suspendCount = 0;
  int resumeCount = 0;
  int stopCount = 0;
  final List<String> requestOrder = <String>[];

  @override
  ARPose? get lastPose => _lastPose;

  Iterable<String> get allArtifactPaths sync* {
    if (highResolutionPath case final path?) yield path;
    if (highResolutionPreviewPath case final path?) yield path;
    if (previewSpec case final spec?) {
      yield spec.jpegPath;
      yield spec.metadataPath;
    }
    final metadataPath = previewSpec?.metadataPath.replaceFirst(
      RegExp(r'/previews/'),
      '/photos_highres/',
    );
    if (metadataPath != null) yield metadataPath;
  }

  void emitPose() {
    _lastPose = ARPose(
      position: Vector3(0, 0, 1),
      orientation: Quaternion.identity(),
      azimuth: 0,
      elevation: 0,
      isTracking: true,
      timestamp: 10,
      hasOrigin: true,
      worldOrigin: Vector3.zero(),
      worldYaw: 0,
      extrinsic4x4: const <double>[
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
      intrinsicFxFyCxCy: const <double>[2000, 2000, 2016, 1512],
      trackingStateName: 'normal',
    );
    _poses.add(_lastPose!);
  }

  HighResolutionStillCapture validStill({
    Uint8List? gray128,
  }) => HighResolutionStillCapture(
    transactionId: transactionId,
    highresPath: highResolutionPath!,
    previewPath: highResolutionPreviewPath!,
    requestTimestamp: 10,
    timestamp: 10.1,
    timestampDelta: 0.1,
    imageWidth: 4032,
    imageHeight: 3024,
    requestPose: const <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1],
    evidencePose: const <double>[
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
      2,
      0,
      0,
      1,
    ],
    cardPose: const <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 0, 1],
    intrinsics: const <double>[2000, 2000, 2016, 1512],
    gray128: gray128 ?? Uint8List(128 * 128),
  );

  Future<void> writeHighResolutionArtifacts() async {
    await File(highResolutionPath!).writeAsBytes(<int>[1, 2, 3]);
    await File(highResolutionPreviewPath!).writeAsBytes(<int>[4, 5, 6]);
    final metadataPath = previewSpec!.metadataPath.replaceFirst(
      RegExp(r'/previews/'),
      '/photos_highres/',
    );
    await File(metadataPath).writeAsString('{}');
  }

  Future<void> writePreviewArtifacts() async {
    await File(previewSpec!.jpegPath).writeAsBytes(<int>[7, 8, 9]);
    await File(previewSpec!.metadataPath).writeAsString('{}');
  }

  void completeHighResolution(HighResolutionStillCapture? still) {
    _highResolution.complete(still);
  }

  void completePreview({required bool saved}) {
    _preview.complete(
      ARFrameSaveResult(
        spec: previewSpec!,
        status: saved ? 'saved' : 'unsupported',
      ),
    );
  }

  @override
  Stream<ARPose> start() => _poses.stream;

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
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) {
    requestOrder.add('preview');
    previewSpec = spec;
    return _preview.future;
  }

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
    bool feedSfm = false,
    bool deriveAuxiliary = true,
    bool stagePhotoFeedback = false,
    String? transactionId,
    String? cardTexturePath,
    double? maxTimestampDelta,
  }) {
    requestOrder.add('highres');
    highResolutionRequestCount++;
    highResolutionPath = highresPath;
    highResolutionPreviewPath = previewPath;
    this.transactionId = transactionId;
    this.cardTexturePath = cardTexturePath;
    return _highResolution.future;
  }

  @override
  Future<void> suspendTransport() async => suspendCount++;

  @override
  Future<void> resumeTransport() async => resumeCount++;

  @override
  Future<void> stop() async => stopCount++;
}
