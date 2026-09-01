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

  test(
    'CaptureSession exclusively owns camera transport transitions',
    () async {
      await session.suspendCameraTransport();
      expect(provider.suspendCount, 1);
      expect(session.manualCaptureTransactionsSuspended, isTrue);

      await session.resumeCameraTransport();
      expect(provider.resumeCount, 1);
      expect(session.manualCaptureTransactionsSuspended, isFalse);

      await session.stopCameraTransport();
      await session.stopCameraTransport();
      expect(
        provider.stopCount,
        1,
        reason: 'terminal camera stop is idempotent',
      );
    },
  );

  test(
    'sealCaptureAdmission synchronously closes every Dart ingest path',
    () async {
      final publishedPoses = <ARPose>[];
      final poseSubscription = session.poseStream.listen(publishedPoses.add);
      final beforeSeal = publishedPoses.length;
      session.suspendManualCaptureTransactions();
      final parkedCapture = session.captureSinglePhoto();
      await Future<void>.delayed(Duration.zero);

      session.sealCaptureAdmission();
      provider.emitPose();

      expect(session.isRunning, isTrue);
      expect(provider.stopCount, 0, reason: 'sealing must not stop the camera');
      expect(publishedPoses, hasLength(beforeSeal));
      expect(await parkedCapture, isNull);
      expect(await session.captureSinglePhoto(), isNull);
      expect(session.canonicalPhotoSnapshot, isEmpty);
      await poseSubscription.cancel();
    },
  );

  test(
    'one shutter issues exactly one native high-resolution request',
    () async {
      final failures = <OfficialHighResCaptureFailureEvent>[];
      final failureSubscription = session.highResFailureStream.listen(
        failures.add,
      );
      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);
      expect(
        session.activePhotoTransaction?.transaction,
        same(capture!.transaction),
      );
      expect(
        session.activePhotoTransaction?.evidenceJpegPath,
        capture.evidenceJpegPath,
      );

      provider.completePreview(saved: false);
      provider.completeHighResolution(null);

      await expectLater(
        capture.highResolutionCompletion,
        throwsA(isA<OfficialHighResCaptureException>()),
      );
      await capture.previewCompletion;

      expect(provider.highResolutionRequestCount, 1);
      expect(provider.requestOrder, <String>['highres', 'preview']);
      expect(provider.transactionId, capture.transactionId);
      expect(provider.cardTexturePath, capture.previewJpegPath);
      await Future<void>.delayed(Duration.zero);
      expect(failures, hasLength(1));
      expect(failures.single.transactionId, capture.transactionId);
      expect(
        capture.transaction.dataOutcome,
        AcceptedPhotoDataOutcome.rejected,
      );
      await failureSubscription.cancel();
    },
  );

  test(
    'stop seals the generation and cleanup waits for a late preview writer',
    () async {
      final sfmInputs = <OfficialHighResReconstructionInput>[];
      final subscription = session.sfmFrameStream.listen(sfmInputs.add);
      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);
      final receipt = capture!;

      await session.stop();
      await provider.writeHighResolutionArtifacts();
      provider.completeHighResolution(provider.validStill());

      var highResolutionTerminated = false;
      unawaited(
        receipt.highResolutionCompletion.then<void>(
          (_) => highResolutionTerminated = true,
          onError: (_) => highResolutionTerminated = true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(highResolutionTerminated, isFalse);
      expect(
        receipt.transaction.dataOutcome,
        AcceptedPhotoDataOutcome.cancelled,
      );

      await provider.writePreviewArtifacts();
      provider.completePreview(saved: true);

      await expectLater(
        receipt.highResolutionCompletion,
        throwsA(isA<OfficialHighResCaptureException>()),
      );
      await receipt.previewCompletion;

      for (final path in provider.allArtifactPaths) {
        expect(File(path).existsSync(), isFalse, reason: path);
      }
      expect(sfmInputs, isEmpty);
      expect(session.targetPoints.validFrameCount, 0);
      expect(
        await session.writeProjectPhotoBundleManifest(<String>[
          receipt.evidenceJpegPath,
        ]),
        isNull,
      );
      await subscription.cancel();
    },
  );

  test(
    'Finish seal rejects new admission but lets the active 12MP commit',
    () async {
      final canonicalRecords = <AcceptedPhotoRecord>[];
      final canonicalSubscription = session.canonicalPhotoCommitStream.listen(
        canonicalRecords.add,
      );
      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);

      session.sealCaptureAdmission();
      expect(await session.captureSinglePhoto(), isNull);

      await provider.writeHighResolutionArtifacts();
      await provider.writePreviewArtifacts();
      provider.completePreview(saved: true);
      provider.completeHighResolution(provider.validStill());

      final input = await capture!.highResolutionCompletion;
      await capture.previewCompletion;

      expect(input.jpegPath, capture.evidenceJpegPath);
      expect(
        capture.transaction.dataOutcome,
        AcceptedPhotoDataOutcome.accepted,
      );
      expect(session.canonicalPhotoSnapshot, hasLength(1));
      expect(
        session.canonicalPhotoSnapshot.single.transactionId,
        capture.transactionId,
      );
      await Future<void>.delayed(Duration.zero);
      expect(canonicalRecords, hasLength(1));
      expect(session.targetPoints.validFrameCount, 1);
      expect(
        session.canonicalPhotoReplayDebtSnapshot.map((debt) => debt.projection),
        <AcceptedPhotoProjection>[AcceptedPhotoProjection.controller],
        reason:
            'Finish sealing and absent live SfM must not block durable/internal '
            'projections; only the unattached page controller may owe replay',
      );
      await canonicalSubscription.cancel();
    },
  );

  test(
    'automatic data commits once and is not reversed by presentation failure',
    () async {
      final sfmInputs = <OfficialHighResReconstructionInput>[];
      final canonicalRecords = <AcceptedPhotoRecord>[];
      final subscription = session.sfmFrameStream.listen(sfmInputs.add);
      final canonicalSubscription = session.canonicalPhotoCommitStream.listen(
        canonicalRecords.add,
      );
      final capture = await session.captureSinglePhoto(
        automaticSelection: true,
      );
      expect(capture, isNotNull);
      final receipt = capture!;
      final gray = Uint8List(128 * 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          gray[y * 128 + x] = (x ~/ 8).isEven ? 32 : 224;
        }
      }

      await provider.writeHighResolutionArtifacts();
      await provider.writePreviewArtifacts();
      provider.completePreview(saved: true);
      provider.completeHighResolution(provider.validStill(gray128: gray));

      final input = await receipt.highResolutionCompletion;
      await receipt.previewCompletion;
      await Future<void>.delayed(Duration.zero);
      expect(
        receipt.transaction.dataOutcome,
        AcceptedPhotoDataOutcome.accepted,
      );
      expect(session.canonicalPhotoSnapshot, hasLength(1));
      expect(canonicalRecords, hasLength(1));
      expect(canonicalRecords.single.transactionId, receipt.transactionId);
      expect(canonicalRecords.single.jpegPath, input.jpegPath);
      expect(canonicalRecords.single.requestPose[12], 1);
      expect(canonicalRecords.single.evidencePose[12], 2);
      expect(canonicalRecords.single.cardPose[12], 3);
      expect(input.transactionId, receipt.transactionId);
      expect(input.requestPose, canonicalRecords.single.requestPose);
      expect(input.evidencePose, canonicalRecords.single.evidencePose);
      expect(input.cardPose, canonicalRecords.single.cardPose);
      expect(sfmInputs, hasLength(1));
      expect(session.targetPoints.validFrameCount, 1);

      expect(session.commitAutomaticActualPhoto(input), isTrue);
      expect(
        session.commitAutomaticActualPhoto(input),
        isTrue,
        reason: 'compatibility receipt is idempotent and does not fan out',
      );
      expect(
        receipt.transaction.dataOutcome,
        AcceptedPhotoDataOutcome.accepted,
      );
      expect(sfmInputs, hasLength(1));
      expect(session.targetPoints.validFrameCount, 1);
      expect(
        session.canonicalPhotoReplayDebtSnapshot,
        contains(
          isA<AcceptedPhotoReplayDebt>().having(
            (debt) => debt.projection,
            'projection',
            AcceptedPhotoProjection.controller,
          ),
        ),
      );
      var controllerProjectionCalls = 0;
      final controllerProjection = await session.projectCanonicalPhoto(
        transactionId: receipt.transactionId,
        projection: AcceptedPhotoProjection.controller,
        apply: (_) => controllerProjectionCalls++,
      );
      final controllerProjectionAgain = await session.projectCanonicalPhoto(
        transactionId: receipt.transactionId,
        projection: AcceptedPhotoProjection.controller,
        apply: (_) => controllerProjectionCalls++,
      );
      expect(
        controllerProjection.status,
        AcceptedPhotoProjectionStatus.applied,
      );
      expect(
        controllerProjectionAgain.status,
        AcceptedPhotoProjectionStatus.alreadyApplied,
      );
      expect(controllerProjectionCalls, 1);
      expect(session.canonicalPhotoReplayDebtSnapshot, isEmpty);

      expect(
        session.resolvePhotoPresentation(
          receipt.transaction,
          AcceptedPhotoPresentationOutcome.failed,
        ),
        isTrue,
      );
      expect(
        receipt.transaction.dataOutcome,
        AcceptedPhotoDataOutcome.accepted,
      );
      expect(session.activePhotoTransaction, isNull);
      expect(File(input.jpegPath).existsSync(), isTrue);

      final archiveWasEnabled = CaptureArchiveService.enabled;
      CaptureArchiveService.enabled = false;
      addTearDown(() => CaptureArchiveService.enabled = archiveWasEnabled);
      session.sealCaptureAdmission();
      expect(
        await session.writeProjectPhotoBundleManifest(const <String>[]),
        isNull,
        reason: 'the page cannot shrink durable canonical membership',
      );
      final manifest = await session.writeProjectPhotoBundleManifest(<String>[
        input.jpegPath,
      ]);
      expect(manifest, isNotNull);
      final decoded = jsonDecode(await manifest!.readAsString()) as Map;
      expect(
        decoded['frames'],
        isA<List>().having((value) => value.length, 'length', 1),
      );
      await canonicalSubscription.cancel();
      await subscription.cancel();
    },
  );

  test(
    'manual and automatic captures share the durable canonical owner',
    () async {
      final sfmInputs = <OfficialHighResReconstructionInput>[];
      final subscription = session.sfmFrameStream.listen(sfmInputs.add);
      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);

      await provider.writeHighResolutionArtifacts();
      provider.completeHighResolution(provider.validStill());
      provider.completePreview(saved: false);

      final input = await capture!.highResolutionCompletion;
      await capture.previewCompletion;

      expect(
        capture.transaction.dataOutcome,
        AcceptedPhotoDataOutcome.accepted,
      );
      expect(session.canonicalPhotoSnapshot, hasLength(1));
      expect(session.canonicalPhotoSnapshot.single.jpegPath, input.jpegPath);
      expect(
        File(
          '${session.captureDir}/accepted_photo_ledger/records',
        ).existsSync(),
        isFalse,
        reason: 'the ledger path is a directory, not a fake aggregate file',
      );
      expect(
        Directory('${session.captureDir}/accepted_photo_ledger/records')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.json')),
        hasLength(1),
      );
      expect(sfmInputs, hasLength(1));
      await subscription.cancel();
    },
  );

  test(
    'photo deletion tombstones membership before removing artifacts',
    () async {
      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);
      await provider.writeHighResolutionArtifacts();
      provider.completeHighResolution(provider.validStill());
      provider.completePreview(saved: false);
      final input = await capture!.highResolutionCompletion;
      await capture.previewCompletion;

      final deleted = await session.tombstoneCanonicalPhoto(input.jpegPath);

      expect(deleted?.transactionId, capture.transactionId);
      expect(session.canonicalPhotoSnapshot, isEmpty);
      expect(session.targetPoints.validFrameCount, 0);
      expect(File(input.jpegPath).existsSync(), isFalse);
      expect(
        Directory(
          '${session.captureDir}/accepted_photo_ledger/tombstones',
        ).listSync().whereType<File>(),
        hasLength(1),
      );
    },
  );
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
