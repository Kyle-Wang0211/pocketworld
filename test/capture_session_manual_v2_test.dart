import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/capture_session.dart';
import 'package:pocketworld_flutter/dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const sensorsMethodChannel = MethodChannel(
    'dev.fluttercommunity.plus/sensors/method',
  );

  late Directory documentsDirectory;
  late _ManualV2PoseProvider provider;
  late CaptureSession session;

  setUp(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'capture-session-manual-v2-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => documentsDirectory.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, (_) async => null);

    provider = _ManualV2PoseProvider();
    session = CaptureSession(poseProvider: provider);
    await session.start(autoLock: false, manualCapture: true);
    provider.emitPose();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await session.dispose();
    await provider.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  test(
    'reserve returns before commit and a late durable sink loses no frame',
    () async {
      final capture = await session.captureSinglePhoto();

      expect(capture, isNotNull);
      expect(provider.terminal.isCompleted, isFalse);
      expect(capture!.reservation.status, 'snapshot_reserved');
      expect(
        session.targetPoints.retainedJpegPaths,
        isEmpty,
        reason: 'A reservation must not publish an album/curation entry.',
      );
      expect(session.capturedPhotoPaths, isEmpty);

      await provider.completeCommitted();
      final committed = await capture.committed;
      expect(committed.committed, isTrue);
      expect(File(committed.jpegPath).existsSync(), isTrue);
      expect(
        session.targetPoints.retainedJpegPaths,
        contains(committed.jpegPath),
        reason: 'The admitted slot must publish its JPEG after native commit.',
      );
      expect(
        session.capturedPhotoPaths,
        contains(committed.jpegPath),
        reason: 'The user-owned inventory publishes only after native commit.',
      );
      expect(
        await session.reconcileCapturedPhotosFromDisk(),
        contains(committed.jpegPath),
      );

      var completionFinished = false;
      capture.completion.whenComplete(() => completionFinished = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        completionFinished,
        isFalse,
        reason: 'A committed frame must wait until a durable sink is bound.',
      );

      final offered = <SfmFrameFeed>[];
      session.bindManualSfmFrameSink((feed) {
        offered.add(feed);
        return true;
      });
      await capture.completion;

      expect(offered, hasLength(1));
      expect(offered.single.jpegPath, committed.jpegPath);
      expect(offered.single.gray, hasLength(4));
    },
  );

  test(
    'pending barrier has no timeout escape before accepted job completes',
    () async {
      session.bindManualSfmFrameSink((_) => true);
      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);

      var barrierFinished = false;
      final barrier = session
          .waitForPendingPhotoSaves(timeout: Duration.zero)
          .whenComplete(() => barrierFinished = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(barrierFinished, isFalse);

      await provider.completeCommitted();
      await barrier;
      expect(barrierFinished, isTrue);
    },
  );

  test(
    'missing gray and durable queue rejection are explicit failures',
    () async {
      session.bindManualSfmFrameSink((_) => false);
      final rejected = await session.captureSinglePhoto();
      expect(rejected, isNotNull);
      final rejectedCompletion = expectLater(
        rejected!.completion,
        throwsA(isA<ManualPhotoCaptureException>()),
      );
      await provider.completeCommitted();
      expect((await rejected.committed).committed, isTrue);
      await rejectedCompletion;
      await expectLater(
        session.waitForPendingPhotoSaves(),
        throwsA(isA<CapturePhotoSaveBarrierException>()),
      );

      await session.dispose();
      await provider.close();

      provider = _ManualV2PoseProvider();
      session = CaptureSession(poseProvider: provider);
      await session.start(autoLock: false, manualCapture: true);
      provider.emitPose();
      await Future<void>.delayed(Duration.zero);
      session.bindManualSfmFrameSink((_) => true);

      final missingGray = await session.captureSinglePhoto();
      expect(missingGray, isNotNull);
      final missingGrayCompletion = expectLater(
        missingGray!.completion,
        throwsA(isA<ManualPhotoCaptureException>()),
      );
      await provider.completeCommitted(writeGray: false);
      await missingGrayCompletion;
      await expectLater(
        session.waitForPendingPhotoSaves(),
        throwsA(isA<CapturePhotoSaveBarrierException>()),
      );
    },
  );

  test(
    'overlapping taps keep isolated jobs through out-of-order commits',
    () async {
      await session.dispose();
      await provider.close();

      final concurrentProvider = _ConcurrentManualV2PoseProvider();
      addTearDown(concurrentProvider.close);
      session = CaptureSession(poseProvider: concurrentProvider);
      await session.start(autoLock: false, manualCapture: true);
      concurrentProvider.emitPose();
      await Future<void>.delayed(Duration.zero);

      final offered = <SfmFrameFeed>[];
      session.bindManualSfmFrameSink((feed) {
        offered.add(feed);
        return true;
      });

      final captures = (await Future.wait(<Future<ManualPhotoCapture?>>[
        session.captureSinglePhoto(),
        session.captureSinglePhoto(),
        session.captureSinglePhoto(),
      ])).whereType<ManualPhotoCapture>().toList(growable: false);

      expect(captures, hasLength(3));
      final jobIDs = captures
          .map((capture) => capture.reservation.captureJobID)
          .toList(growable: false);
      expect(jobIDs.toSet(), hasLength(3));

      await concurrentProvider.completeCommitted(jobIDs[2]);
      await concurrentProvider.completeCommitted(jobIDs[0]);
      await concurrentProvider.completeCommitted(jobIDs[1]);
      await Future.wait(captures.map((capture) => capture.completion));
      await session.waitForPendingPhotoSaves();

      expect(offered, hasLength(3));
      expect(offered.map((feed) => feed.jpegPath).toSet(), hasLength(3));
      expect(session.capturedPhotoPaths.toSet(), hasLength(3));
      expect(
        offered.map((feed) => feed.jpegPath).toSet(),
        session.capturedPhotoPaths.toSet(),
      );
    },
  );
}

class _ManualV2PoseProvider implements ARPoseProvider, ManualCaptureV2Provider {
  final StreamController<ARPose> _poses = StreamController<ARPose>.broadcast();
  final Completer<ManualCaptureV2Result> terminal =
      Completer<ManualCaptureV2Result>();

  ManualCaptureV2Request? request;
  ARPose? _lastPose;

  void emitPose() {
    final pose = ARPose(
      position: Vector3(0, 0, 1),
      orientation: Quaternion.identity(),
      azimuth: 0,
      elevation: 0,
      isTracking: true,
      timestamp: 42,
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
        1,
        1,
      ],
      intrinsicFxFyCxCy: const <double>[100, 100, 2, 2],
      imageWidth: 4,
      imageHeight: 4,
      trackingStateName: 'normal',
    );
    _lastPose = pose;
    _poses.add(pose);
  }

  Future<void> completeCommitted({bool writeGray = true}) async {
    final active = request!;
    await File(active.saveSpec.jpegPath).writeAsBytes(const <int>[1, 2, 3]);
    await File(active.saveSpec.metadataPath).writeAsString('{}');
    if (writeGray) {
      await File(active.sfmGrayPath).writeAsBytes(const <int>[1, 2, 3, 4]);
    }
    terminal.complete(
      ManualCaptureV2Result(
        captureJobID: active.captureJobID,
        status: 'committed',
        jpegPath: active.saveSpec.jpegPath,
        metadataPath: active.saveSpec.metadataPath,
        sfmGrayPath: active.sfmGrayPath,
        sfmGrayWidth: 2,
        sfmGrayHeight: 2,
        timestamp: 42,
        imageWidth: 4,
        imageHeight: 4,
        intrinsicFxFyCxCy: const <double>[100, 100, 2, 2],
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
          1,
          1,
        ],
      ),
    );
  }

  Future<void> close() async {
    await _poses.close();
  }

  @override
  ARPose? get lastPose => _lastPose;

  @override
  Stream<ARPose> start() => _poses.stream;

  @override
  Future<ManualCaptureV2Ticket> reserveManualCaptureV2(
    ManualCaptureV2Request request,
  ) async {
    this.request = request;
    return ManualCaptureV2Ticket(
      captureJobID: request.captureJobID,
      status: 'snapshot_reserved',
      snapshotTimestamp: 42,
      jpegPath: request.saveSpec.jpegPath,
      metadataPath: request.saveSpec.metadataPath,
      sfmGrayPath: request.sfmGrayPath,
    );
  }

  @override
  Future<ManualCaptureV2Result> awaitManualCaptureV2(String captureJobID) =>
      terminal.future;

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

class _ConcurrentManualV2PoseProvider
    implements ARPoseProvider, ManualCaptureV2Provider {
  final StreamController<ARPose> _poses = StreamController<ARPose>.broadcast();
  final Map<String, ManualCaptureV2Request> _requests =
      <String, ManualCaptureV2Request>{};
  final Map<String, Completer<ManualCaptureV2Result>> _terminals =
      <String, Completer<ManualCaptureV2Result>>{};
  ARPose? _lastPose;

  void emitPose() {
    final pose = ARPose(
      position: Vector3(0, 0, 1),
      orientation: Quaternion.identity(),
      azimuth: 0,
      elevation: 0,
      isTracking: true,
      timestamp: 42,
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
        1,
        1,
      ],
      intrinsicFxFyCxCy: const <double>[100, 100, 2, 2],
      imageWidth: 4,
      imageHeight: 4,
      trackingStateName: 'normal',
    );
    _lastPose = pose;
    _poses.add(pose);
  }

  Future<void> completeCommitted(String captureJobID) async {
    final request = _requests[captureJobID]!;
    await File(request.saveSpec.jpegPath).writeAsBytes(const <int>[1, 2, 3]);
    await File(request.saveSpec.metadataPath).writeAsString('{}');
    await File(request.sfmGrayPath).writeAsBytes(const <int>[1, 2, 3, 4]);
    _terminals[captureJobID]!.complete(
      ManualCaptureV2Result(
        captureJobID: captureJobID,
        status: 'committed',
        jpegPath: request.saveSpec.jpegPath,
        metadataPath: request.saveSpec.metadataPath,
        sfmGrayPath: request.sfmGrayPath,
        sfmGrayWidth: 2,
        sfmGrayHeight: 2,
        timestamp: 42,
        imageWidth: 4,
        imageHeight: 4,
        intrinsicFxFyCxCy: const <double>[100, 100, 2, 2],
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
          1,
          1,
        ],
      ),
    );
  }

  Future<void> close() => _poses.close();

  @override
  ARPose? get lastPose => _lastPose;

  @override
  Stream<ARPose> start() => _poses.stream;

  @override
  Future<ManualCaptureV2Ticket> reserveManualCaptureV2(
    ManualCaptureV2Request request,
  ) async {
    if (_requests.containsKey(request.captureJobID)) {
      throw StateError('duplicate capture job ${request.captureJobID}');
    }
    _requests[request.captureJobID] = request;
    _terminals[request.captureJobID] = Completer<ManualCaptureV2Result>();
    return ManualCaptureV2Ticket(
      captureJobID: request.captureJobID,
      status: 'snapshot_reserved',
      snapshotTimestamp: 42,
      jpegPath: request.saveSpec.jpegPath,
      metadataPath: request.saveSpec.metadataPath,
      sfmGrayPath: request.sfmGrayPath,
    );
  }

  @override
  Future<ManualCaptureV2Result> awaitManualCaptureV2(String captureJobID) {
    final terminal = _terminals[captureJobID];
    if (terminal == null) throw StateError('unknown capture job $captureJobID');
    return terminal.future;
  }

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
