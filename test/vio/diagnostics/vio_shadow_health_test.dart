import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/diagnostics/vio_shadow_health.dart';
import 'package:pocketworld_flutter/vio/diagnostics/vio_shadow_se3_comparison.dart';

Map<String, Object?> sensorReasons({int nativeReject = 0}) => <String, Object?>{
  'not_running': 0,
  'lock_contention': 0,
  'queue_full': 0,
  'camera_full': 0,
  'late_after_seal': 0,
  'dropped_on_stop': 0,
  'stale_epoch': 0,
  'invalid_input': 0,
  'non_monotonic': 0,
  'native_reject': nativeReject,
};

Map<String, Object?> workTerminalReasons({
  int stale = 0,
  int invalid = 0,
  int nonMonotonic = 0,
  int nativeReject = 0,
  int internal = 0,
}) => <String, Object?>{
  'stale_epoch': stale,
  'invalid_input': invalid,
  'non_monotonic': nonMonotonic,
  'native_reject': nativeReject,
  'internal': internal,
};

Map<String, Object?> qualityWire({
  int? generation,
  required int seq,
  required double frameMs,
  required double intervalMs,
}) => <String, Object?>{
  'sessionGeneration': ?generation,
  'poseObservations': <Object?>[
    <String, Object?>{
      'seq': seq,
      'lastFrameMs': frameMs,
      'sensorTimestamp': 10.0 + seq,
      'previousImageTimestamp': 10.0 + seq - intervalMs / 1000,
    },
  ],
};

void main() {
  const String shaA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const String shaB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const String shaC =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  const String sessionId = '123e4567-e89b-42d3-a456-426614174000';
  const VioShadowRunIdentityExpectation expectedIdentity =
      VioShadowRunIdentityExpectation(
        sessionId: sessionId,
        sessionEpoch: 11,
        effectiveConfigSha256: shaA,
        inputIdentitySha256: shaB,
        downsampleFactor: 3,
        downsampleFormula: 'box-nxn-half-up-v1',
        requestedCameraHz: 30.0,
        cameraTimeOffsetSeconds: 0.0,
        accelerationScale: -9.80665,
        requestedAccelerometerHz: 100.0,
        requestedGyroscopeHz: 100.0,
      );
  const VioShadowTimebaseEvidence validTimebase = VioShadowTimebaseEvidence(
    schemaValid: true,
    sessionId: sessionId,
    sessionEpoch: 11,
    nativeGeneration: 4,
    expectedNativeGeneration: 4,
    boundShadowGeneration: 7,
    accelerometerBase: 'uptimeRaw',
    gyroscopeBase: 'uptimeRaw',
    arFrameBase: 'uptimeRaw',
    accelerometerSameBaseAsCamera: true,
    gyroscopeSameBaseAsCamera: true,
  );
  const VioShadowTerminalReceiptEvidence trustedTerminal =
      VioShadowTerminalReceiptEvidence(
        trustedDirectSlamStopCall: true,
        consumedOnce: true,
        runningGeneration: 7,
        receiptGeneration: 7,
      );

  Map<String, Object?> healthyWire() => <String, Object?>{
    'sessionGeneration': 7,
    'state': 'running',
    'coreHealthAvailable': 1,
    'coreImuSamples': 12,
    'shadowOverflowDrops': 0,
    'queueBacklog': 2,
    'queueInFlight': 1,
    'queueAccepted': 10,
    'queueProcessedSuccess': 7,
    'droppedOnStop': 0,
    'terminalRejected': 0,
    'stateTransitions': <String>['stopped->starting', 'starting->running'],
    'imagesAttempted': 4,
    'imagesAccepted': 3,
    'imagesRejected': 1,
    'accAttempted': 8,
    'accAccepted': 8,
    'accRejected': 0,
    'gyroAttempted': 8,
    'gyroAccepted': 7,
    'gyroRejected': 1,
    'acceptedCompatibilitySemantics': 'submitted_to_void_c_api',
    'rejectionReasons': <String, Object?>{
      'images': sensorReasons(nativeReject: 1),
      'acc': sensorReasons(),
      'gyro': sensorReasons(nativeReject: 1),
      'workTerminal': workTerminalReasons(),
      'workDroppedOnStop': <String, Object?>{'dropped_on_stop': 0},
    },
    'authority': 'production', // Must never be allowed to elevate authority.
    'decisionConsumers': 99,
    'alignmentMethod': 'first-valid-pair-se3',
    'comparisonSampleCount': 4,
    'comparisonTimestampMismatchCount': 1,
    'alignedTranslationRmseM': 0.025,
    'alignedTranslationMaxM': 0.04,
    'alignedRotationRmseDeg': 1.5,
    'alignedRotationMaxDeg': 2.2,
    'identity': <String, Object?>{
      'sessionId': sessionId,
      'sessionEpoch': 11,
      'epoch': 7,
      'queueCapacity': 256,
      'cameraCapacity': 30,
      'fullFrameIngressCapacity': 2,
      'poseObservationCapacity': 128,
      'dropPolicy': 'invalidate-on-overflow',
      'appVersion': '1.2.3',
      'appBuild': '37',
      'diagnosticBuildId': 'vio-shadow-contract',
      'productSourceManifestSha256': shaC,
      'dartAotSha256': shaC,
      'nativeHostUuid': '123E4567-E89B-42D3-A456-426614174001',
      'nativeFrameworkSha256': shaC,
      'xrslamSha256': shaC,
      'xrslamUpstreamRevision': '4beb1a942f33da9afbfae2d70e2c641cfc2bb675',
      'xrslamBuildPatchSha256':
          'b98ed6aa689c9edaaac6da707d97592217d3f6caccc6df8c4d6961e2ee751de0',
      'xrslamDestroyLifecyclePatchSha256':
          '13592cb486f159217fa5ecf9ef2f9863be78cf599d42fb1757e34bd7d4bbb220',
      'xrslamZeroInlierMaskPatchSha256':
          '62b12204c647e445e88917859de6b29452df0e6cc65b447e7ea86005f98d1794',
      'xrslamAlgorithmBranch': 'generic',
      'xrslamIosEnabled': 'false',
      'xrslamThreadingEnabled': 'false',
      'xrslamCompileFlags':
          '-ffp-contract=off,-fno-fast-math,-fchar8_t,'
          '-Dceres=pw_xrslam_ceres_1_14',
      'opencvUpstreamRevision': 'c9ad5779f2803dcc91a9938142209128d30b22d1',
      'opencvBuildPatchSha256':
          '4041a1ac34b397679a04b733aa78bb1c37a25fcaf6a19c32e9563b0fd9159136',
      'opencvSha256': shaC,
      'ceresUpstreamRevision': 'e809cf0c2879f521078b4c9e6329390b42ecf722',
      'ceresSha256': shaC,
      'spdlogCompatibilityPatchSha256':
          '1afb69176857159ad29e69d0abf3359576ebc091104278fee5fdeeff08e21adb',
      'effectiveConfigSha256': shaA,
      'inputIdentitySha256': shaB,
      'downsampleFactor': 3,
      'downsampleFormula': 'box-nxn-half-up-v1',
      'requestedCameraHz': 30.0,
      'cameraTimeOffsetSeconds': 0.0,
      'accelerationScale': -9.80665,
      'requestedAccelerometerHz': 100.0,
      'requestedGyroscopeHz': 100.0,
    },
    'xrslamSha256': shaC,
    'schema': 'pw.vio.shadow-native/6',
    // Even if a buggy native producer adds raw evidence, the privacy-safe
    // summary must not retain or re-emit it.
    'pose': <double>[0, 0, 0, 1, 10, 20, 30],
    'rawImu': <double>[1, 2, 3],
    'image': <int>[1, 2, 3],
  };

  Map<String, Object?> cleanTerminalWire() {
    final Map<String, Object?> wire = healthyWire()
      ..['imagesAttempted'] = 3
      ..['imagesAccepted'] = 3
      ..['imagesRejected'] = 0
      ..['accAttempted'] = 8
      ..['accAccepted'] = 8
      ..['accRejected'] = 0
      ..['gyroAttempted'] = 7
      ..['gyroAccepted'] = 7
      ..['gyroRejected'] = 0
      ..['state'] = 'stopped'
      ..['queueProcessedSuccess'] = 10
      ..['queueBacklog'] = 0
      ..['queueInFlight'] = 0
      ..['receiptAvailable'] = true
      ..['nativeStartLifecycleGeneration'] = 17
      ..['nativeLifecycleGeneration'] = 17
      ..['nativeDestroyRc'] = 0
      ..['nativeDestroyAcknowledged'] = 1
      ..['terminalReceiptComplete'] = true
      ..['workConserved'] = true
      ..['ingressClosed'] = true
      ..['ingressOffered'] = 18
      ..['ingressCompleted'] = 18
      ..['terminalIngressSequence'] = 18
      ..['shadowRunInvalidated'] = false
      ..['transportValid'] = true
      ..['runCalls'] = 3
      ..['imagesSubmitted'] = 3
      ..['accSubmitted'] = 8
      ..['gyroSubmitted'] = 7
      ..['nativeCameraSubmitted'] = 3
      ..['nativeCameraRunCalls'] = 3
      ..['nativeAccelerationSubmitted'] = 8
      ..['nativeGyroscopeSubmitted'] = 7
      ..['nativeRejectedInvalidArgument'] = 0
      ..['nativeRejectedNonMonotonic'] = 0
      ..['nativeRejectedNotRunning'] = 0;
    wire['rejectionReasons'] = <String, Object?>{
      'images': sensorReasons(),
      'acc': sensorReasons(),
      'gyro': sensorReasons(),
      'workTerminal': workTerminalReasons(),
      'workDroppedOnStop': <String, Object?>{'dropped_on_stop': 0},
    };
    return wire;
  }

  test('both independent raw IMU clocks must match the camera clock', () {
    const VioShadowTimebaseEvidence acceptedBeforeCoreStart =
        VioShadowTimebaseEvidence(
          schemaValid: true,
          sessionId: sessionId,
          sessionEpoch: 11,
          nativeGeneration: 4,
          expectedNativeGeneration: 4,
          boundShadowGeneration: -1,
          accelerometerBase: 'uptimeRaw',
          gyroscopeBase: 'uptimeRaw',
          arFrameBase: 'uptimeRaw',
          accelerometerSameBaseAsCamera: true,
          gyroscopeSameBaseAsCamera: true,
        );
    expect(acceptedBeforeCoreStart.preStartDomainAccepted, isTrue);
    expect(acceptedBeforeCoreStart.domainAccepted, isFalse);
    expect(validTimebase.domainAccepted, isTrue);
    const VioShadowTimebaseEvidence gyroscopeMismatch =
        VioShadowTimebaseEvidence(
          schemaValid: true,
          sessionId: sessionId,
          sessionEpoch: 11,
          nativeGeneration: 4,
          expectedNativeGeneration: 4,
          boundShadowGeneration: 7,
          accelerometerBase: 'uptimeRaw',
          gyroscopeBase: 'monotonic',
          arFrameBase: 'uptimeRaw',
          accelerometerSameBaseAsCamera: true,
          gyroscopeSameBaseAsCamera: false,
        );
    expect(gyroscopeMismatch.preStartDomainAccepted, isFalse);
    expect(gyroscopeMismatch.domainAccepted, isFalse);
  });

  test(
    'parses all conservation ledgers and reports their truth independently',
    () {
      final VioShadowHealthSummary s = VioShadowHealthSummary.fromWire(
        healthyWire(),
      );

      expect(s.images.conserved, isTrue);
      expect(s.acc.conserved, isTrue);
      expect(s.gyro.conserved, isTrue);
      expect(s.queue.conserved, isTrue);
      expect(s.allAccountingConserved, isTrue);
      expect(s.queue.backlog, 2);
      expect(s.queue.inFlight, 1);
    },
  );

  test('detects a false success counter instead of normalizing it away', () {
    final Map<String, Object?> wire = healthyWire()..['accAccepted'] = 9;
    final VioShadowHealthSummary s = VioShadowHealthSummary.fromWire(wire);

    expect(s.acc.conserved, isFalse);
    expect(s.allAccountingConserved, isFalse);
    expect(s.toJson()['accountingConserved'], isFalse);
  });

  test(
    'downsample formula is mandatory, exact, and bound to Dart expectation',
    () {
      final Map<String, Object?> missing = healthyWire();
      final Map<String, Object?> missingIdentity =
          missing['identity']! as Map<String, Object?>;
      missingIdentity.remove('downsampleFormula');
      final VioShadowHealthSummary missingSummary =
          VioShadowHealthSummary.fromWire(
            missing,
            expectedIdentity: expectedIdentity,
          );
      expect(missingSummary.identity.schemaValid, isFalse);
      expect(missingSummary.identity.matchesExpected, isFalse);

      final Map<String, Object?> unknown = healthyWire();
      final Map<String, Object?> unknownIdentity =
          unknown['identity']! as Map<String, Object?>;
      unknownIdentity['downsampleFormula'] = 'nearest-neighbor-v0';
      final VioShadowHealthSummary unknownSummary =
          VioShadowHealthSummary.fromWire(
            unknown,
            expectedIdentity: expectedIdentity,
          );
      expect(unknownSummary.identity.schemaValid, isFalse);
      expect(unknownSummary.identity.matchesExpected, isFalse);
    },
  );

  test('missing accounting schema fails closed instead of becoming zero', () {
    final Map<String, Object?> wire = healthyWire()..remove('imagesAttempted');
    final VioShadowHealthSummary s = VioShadowHealthSummary.fromWire(wire);

    expect(s.schemaValid, isFalse);
    expect(s.images.schemaValid, isFalse);
    expect(s.images.conserved, isFalse);
    expect(s.allAccountingConserved, isFalse);
    expect(s.toJson()['schemaValid'], isFalse);
    expect(s.toJson()['accountingConserved'], isFalse);
  });

  test('negative or fractional counters invalidate the schema', () {
    final Map<String, Object?> negative = healthyWire()..['queueAccepted'] = -1;
    final Map<String, Object?> fractional = healthyWire()
      ..['gyroRejected'] = 0.5;
    final Map<String, Object?> fractionalReason = healthyWire();
    final Map<String, Object?> reasons =
        fractionalReason['rejectionReasons']! as Map<String, Object?>;
    final Map<String, Object?> gyro = reasons['gyro']! as Map<String, Object?>;
    gyro['native_reject'] = 0.5;

    expect(VioShadowHealthSummary.fromWire(negative).schemaValid, isFalse);
    expect(VioShadowHealthSummary.fromWire(fractional).schemaValid, isFalse);
    expect(
      VioShadowHealthSummary.fromWire(fractionalReason).schemaValid,
      isFalse,
    );
  });

  test('forces shadow authority and zero decision consumers', () {
    final VioShadowHealthSummary s = VioShadowHealthSummary.fromWire(
      healthyWire(),
    );

    expect(s.comparison.authority, 'shadow');
    expect(s.comparison.decisionConsumers, 0);
    expect(s.toJson()['authority'], 'shadow');
    expect(s.toJson()['decisionConsumers'], 0);
  });

  test(
    'privacy-safe JSON excludes absolute poses raw IMU and image payloads',
    () {
      final Map<String, Object?> json = VioShadowHealthSummary.fromWire(
        healthyWire(),
      ).toJson();

      expect(json.containsKey('pose'), isFalse);
      expect(json.containsKey('rawImu'), isFalse);
      expect(json.containsKey('image'), isFalse);
      expect(json.toString(), isNot(contains('10.0, 20.0, 30.0')));
    },
  );

  test('missing or UNSTAMPED required identity fails closed', () {
    final Map<String, Object?> missing = healthyWire();
    (missing['identity']! as Map<String, Object?>).remove('dartAotSha256');
    final Map<String, Object?> unstamped = healthyWire();
    (unstamped['identity']! as Map<String, Object?>)['nativeHostUuid'] =
        'UNSTAMPED';

    expect(
      VioShadowHealthSummary.fromWire(
        missing,
        expectedIdentity: expectedIdentity,
      ).identity.valid,
      isFalse,
    );
    expect(
      VioShadowHealthSummary.fromWire(
        unstamped,
        expectedIdentity: expectedIdentity,
      ).runValid,
      isFalse,
    );
  });

  test('dynamic identity cannot pass any bounded carrier schema', () {
    for (final String field in <String>[
      'queueCapacity',
      'cameraCapacity',
      'fullFrameIngressCapacity',
      'poseObservationCapacity',
    ]) {
      final Map<String, Object?> wire = healthyWire();
      (wire['identity']! as Map<String, Object?>)[field] =
          'loss-intolerant-dynamic';
      expect(
        VioShadowHealthSummary.fromWire(
          wire,
          expectedIdentity: expectedIdentity,
        ).identity.schemaValid,
        isFalse,
        reason: field,
      );
    }
  });

  test('non-monotonic and late-after-seal are explicit transport failures', () {
    for (final String reason in <String>['non_monotonic', 'late_after_seal']) {
      final Map<String, Object?> wire = cleanTerminalWire()
        ..['accAttempted'] = 9
        ..['accRejected'] = 1;
      final Map<String, Object?> reasons =
          wire['rejectionReasons']! as Map<String, Object?>;
      final Map<String, Object?> accReasons =
          reasons['acc']! as Map<String, Object?>;
      accReasons[reason] = 1;
      final VioShadowHealthSummary summary = VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
        timebase: validTimebase,
        terminalReceipt: trustedTerminal,
      );
      expect(summary.schemaValid, isTrue, reason: reason);
      expect(summary.allAccountingConserved, isTrue, reason: reason);
      expect(summary.transportValid, isFalse, reason: reason);
      expect(summary.qualityGatePassed, isFalse, reason: reason);
    }
  });

  test(
    'identity echoed by native must match the Dart-owned start contract',
    () {
      final Map<String, Object?> wire = healthyWire();
      (wire['identity']! as Map<String, Object?>)['effectiveConfigSha256'] =
          shaC;
      final VioShadowHealthSummary summary = VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
      );
      expect(summary.identity.schemaValid, isTrue);
      expect(summary.identity.matchesExpected, isFalse);
      expect(summary.runValid, isFalse);
    },
  );

  test('queued stop and terminal rejection are disjoint work outcomes', () {
    final Map<String, Object?> wire = healthyWire()
      ..['queueProcessedSuccess'] = 6
      ..['terminalRejected'] = 1
      ..['droppedOnStop'] = 1
      ..['queueInFlight'] = 0;
    final Map<String, Object?> reasons =
        wire['rejectionReasons']! as Map<String, Object?>;
    reasons['workTerminal'] = workTerminalReasons(nativeReject: 1);
    reasons['workDroppedOnStop'] = <String, Object?>{'dropped_on_stop': 1};
    final VioShadowHealthSummary s = VioShadowHealthSummary.fromWire(wire);

    expect(s.queue.conserved, isTrue);
    expect(s.queue.droppedOnStop, 1);
  });

  test(
    'rejection reason ledgers are required and must match all partitions',
    () {
      final Map<String, Object?> wire = healthyWire()
        ..remove('rejectionReasons');
      final VioShadowHealthSummary s = VioShadowHealthSummary.fromWire(wire);
      expect(s.schemaValid, isFalse);
      expect(s.allAccountingConserved, isFalse);
    },
  );

  test('reason sum mismatch fails closed', () {
    final Map<String, Object?> wire = healthyWire();
    final Map<String, Object?> reasons =
        wire['rejectionReasons']! as Map<String, Object?>;
    reasons['images'] = sensorReasons(nativeReject: 0);
    final VioShadowHealthSummary s = VioShadowHealthSummary.fromWire(wire);
    expect(s.schemaValid, isFalse);
    expect(s.runValid, isFalse);
  });

  test('unknown top-level rejection reason partition fails closed', () {
    final Map<String, Object?> wire = healthyWire();
    final Map<String, Object?> reasons =
        wire['rejectionReasons']! as Map<String, Object?>;
    reasons['futureUnknownPartition'] = <String, Object?>{'x': 0};
    expect(VioShadowHealthSummary.fromWire(wire).schemaValid, isFalse);
  });

  test('Dart computes runValid from raw accounting and reason facts', () {
    final VioShadowHealthSummary healthy = VioShadowHealthSummary.fromWire(
      healthyWire(),
    );
    expect(
      healthy.runValid,
      isFalse,
      reason: 'native reject is an operational invalidation',
    );

    final Map<String, Object?> clean = healthyWire()
      ..['imagesAttempted'] = 3
      ..['imagesRejected'] = 0
      ..['gyroAttempted'] = 7
      ..['gyroRejected'] = 0;
    clean['rejectionReasons'] = <String, Object?>{
      'images': sensorReasons(),
      'acc': sensorReasons(),
      'gyro': sensorReasons(),
      'workTerminal': workTerminalReasons(),
      'workDroppedOnStop': <String, Object?>{'dropped_on_stop': 0},
    };
    expect(
      VioShadowHealthSummary.fromWire(
        clean,
        expectedIdentity: expectedIdentity,
      ).runValid,
      isFalse,
      reason: 'a running/backlogged snapshot is never a final accepted run',
    );
    clean.addAll(cleanTerminalWire());
    final VioShadowHealthSummary transportOnly =
        VioShadowHealthSummary.fromWire(
          clean,
          expectedIdentity: expectedIdentity,
          timebase: validTimebase,
          terminalReceipt: trustedTerminal,
        );
    expect(transportOnly.transportValid, isTrue);
    expect(transportOnly.runValid, isTrue);
    expect(transportOnly.qualityGatePassed, isFalse);
    clean['runValid'] = true;
    expect(
      VioShadowHealthSummary.fromWire(
        clean,
        expectedIdentity: expectedIdentity,
        timebase: validTimebase,
        terminalReceipt: trustedTerminal,
      ).runValid,
      isTrue,
      reason: 'untrusted native verdict is ignored',
    );
  });

  test(
    'quality gate requires non-empty continuous pose and comparison evidence',
    () {
      final Map<String, Object?> clean = cleanTerminalWire();
      const VioShadowPoseAvailability pose = VioShadowPoseAvailability(
        schemaValid: true,
        nativeOffered: 3,
        nativeDropped: 0,
        valid: 3,
        noNew: 0,
        degenerate: 0,
        errors: 0,
        initialized: true,
        initializationLatencyMs: 20,
        validLatencyMeanMs: 2,
        validLatencyMaxMs: 3,
        poseEpochCount: 1,
        continuityBreakCount: 0,
      );
      const VioShadowComparisonSummary comparison = VioShadowComparisonSummary(
        schemaValid: true,
        nativeOfferedCount: 3,
        nativeDroppedCount: 0,
        alignmentInitialized: true,
        pairCount: 3,
        acceptedPairCount: 3,
        sampleCount: 2,
        referenceTrackingRejectedCount: 0,
        timestampInvalidCount: 0,
        timestampMismatchCount: 0,
        malformedPairCount: 0,
        translationRmseM: .1,
        translationMaxM: .2,
        rotationRmseDeg: 1,
        rotationMaxDeg: 2,
        poseEpochCount: 1,
        continuityBreakCount: 0,
      );
      const VioShadowQualitySummary quality = VioShadowQualitySummary(
        schemaValid: true,
        observationCount: 3,
        behindCount: 0,
        behindStreak: 0,
        behindMaxStreak: 0,
        invalidMeasurementCount: 0,
        lastFrameMs: 10,
        lastFrameIntervalMs: 33,
      );

      final VioShadowHealthSummary qualified = VioShadowHealthSummary.fromWire(
        clean,
        expectedIdentity: expectedIdentity,
        timebase: validTimebase,
        terminalReceipt: trustedTerminal,
        pose: pose,
        comparison: comparison,
        quality: quality,
      );
      expect(qualified.transportValid, isTrue);
      expect(qualified.qualityGatePassed, isTrue);
      expect(qualified.productionAuthorityEligible, isFalse);

      final outsideThreshold = VioShadowHealthSummary.fromWire(
        clean,
        expectedIdentity: expectedIdentity,
        timebase: validTimebase,
        terminalReceipt: trustedTerminal,
        pose: pose,
        comparison: const VioShadowComparisonSummary(
          schemaValid: true,
          nativeOfferedCount: 3,
          nativeDroppedCount: 0,
          alignmentInitialized: true,
          pairCount: 3,
          acceptedPairCount: 3,
          sampleCount: 2,
          referenceTrackingRejectedCount: 0,
          timestampInvalidCount: 0,
          timestampMismatchCount: 0,
          malformedPairCount: 0,
          translationRmseM: .100001,
          translationMaxM: .250001,
          rotationRmseDeg: 5.000001,
          rotationMaxDeg: 10.000001,
          poseEpochCount: 1,
          continuityBreakCount: 0,
        ),
        quality: quality,
      );
      expect(outsideThreshold.qualityGatePassed, isFalse);

      final VioShadowHealthSummary brokenContinuity =
          VioShadowHealthSummary.fromWire(
            clean,
            expectedIdentity: expectedIdentity,
            timebase: validTimebase,
            terminalReceipt: trustedTerminal,
            pose: const VioShadowPoseAvailability(
              schemaValid: true,
              nativeOffered: 3,
              nativeDropped: 0,
              valid: 2,
              noNew: 1,
              degenerate: 0,
              errors: 0,
              initialized: true,
              initializationLatencyMs: 20,
              validLatencyMeanMs: 2,
              validLatencyMaxMs: 3,
              poseEpochCount: 2,
              continuityBreakCount: 1,
            ),
            comparison: comparison,
            quality: quality,
          );
      expect(brokenContinuity.transportValid, isTrue);
      expect(brokenContinuity.qualityGatePassed, isFalse);
    },
  );

  test(
    'a conserved terminal receipt with any empty sensor stream is invalid',
    () {
      Map<String, Object?> cleanTerminal() {
        final Map<String, Object?> wire = healthyWire()
          ..['imagesAttempted'] = 3
          ..['imagesAccepted'] = 3
          ..['imagesRejected'] = 0
          ..['accAttempted'] = 8
          ..['accAccepted'] = 8
          ..['accRejected'] = 0
          ..['gyroAttempted'] = 7
          ..['gyroAccepted'] = 7
          ..['gyroRejected'] = 0
          ..['state'] = 'stopped'
          ..['queueProcessedSuccess'] = 10
          ..['queueBacklog'] = 0
          ..['queueInFlight'] = 0;
        wire['rejectionReasons'] = <String, Object?>{
          'images': sensorReasons(),
          'acc': sensorReasons(),
          'gyro': sensorReasons(),
          'workTerminal': workTerminalReasons(),
          'workDroppedOnStop': <String, Object?>{'dropped_on_stop': 0},
        };
        return wire;
      }

      for (final String stream in <String>['images', 'acc', 'gyro']) {
        final Map<String, Object?> wire = cleanTerminal()
          ..['${stream}Attempted'] = 0
          ..['${stream}Accepted'] = 0;
        final VioShadowHealthSummary summary = VioShadowHealthSummary.fromWire(
          wire,
          expectedIdentity: expectedIdentity,
          timebase: validTimebase,
          terminalReceipt: trustedTerminal,
        );
        expect(summary.allAccountingConserved, isTrue, reason: stream);
        expect(
          summary.runValid,
          isFalse,
          reason: '$stream accepted no samples',
        );
      }
    },
  );

  test('stopped-shaped generic snapshots never become valid receipts', () {
    final Map<String, Object?> clean = healthyWire()
      ..['imagesAttempted'] = 3
      ..['imagesRejected'] = 0
      ..['gyroAttempted'] = 7
      ..['gyroRejected'] = 0
      ..['state'] = 'stopped'
      ..['queueProcessedSuccess'] = 10
      ..['queueBacklog'] = 0
      ..['queueInFlight'] = 0;
    clean['rejectionReasons'] = <String, Object?>{
      'images': sensorReasons(),
      'acc': sensorReasons(),
      'gyro': sensorReasons(),
      'workTerminal': workTerminalReasons(),
      'workDroppedOnStop': <String, Object?>{'dropped_on_stop': 0},
    };

    expect(
      VioShadowHealthSummary.fromWire(
        clean,
        expectedIdentity: expectedIdentity,
        timebase: validTimebase,
      ).runValid,
      isFalse,
    );
    expect(
      VioShadowHealthSummary.fromWire(
        clean,
        expectedIdentity: expectedIdentity,
        timebase: validTimebase,
        terminalReceipt: const VioShadowTerminalReceiptEvidence(
          trustedDirectSlamStopCall: true,
          consumedOnce: true,
          runningGeneration: 6,
          receiptGeneration: 7,
        ),
      ).runValid,
      isFalse,
    );
  });

  test('direct native identity must echo Dart-selected downsample factor', () {
    final Map<String, Object?> wire = healthyWire();
    final Map<String, Object?> identity =
        wire['identity']! as Map<String, Object?>;

    expect(
      VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
      ).identity.valid,
      isTrue,
    );

    identity['downsampleFactor'] = 2;
    expect(
      VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
      ).identity.valid,
      isFalse,
    );
  });

  test('direct native identity must echo Dart-selected acceleration scale', () {
    final Map<String, Object?> wire = healthyWire();
    final Map<String, Object?> identity =
        wire['identity']! as Map<String, Object?>;

    expect(
      VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
      ).identity.valid,
      isTrue,
    );

    identity['accelerationScale'] = 9.80665;
    expect(
      VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
      ).identity.valid,
      isFalse,
    );
  });

  test('direct native identity must echo both Dart-selected raw IMU rates', () {
    final Map<String, Object?> wire = healthyWire();
    final Map<String, Object?> identity =
        wire['identity']! as Map<String, Object?>;

    expect(
      VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
      ).identity.valid,
      isTrue,
    );

    identity['requestedAccelerometerHz'] = 90.0;
    expect(
      VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
      ).identity.valid,
      isFalse,
    );
    identity['requestedAccelerometerHz'] = 100.0;
    identity['requestedGyroscopeHz'] = 200.0;
    expect(
      VioShadowHealthSummary.fromWire(
        wire,
        expectedIdentity: expectedIdentity,
      ).identity.valid,
      isFalse,
    );
  });

  test('final receipt rejects a timebase verdict from another generation', () {
    final Map<String, Object?> clean = healthyWire()
      ..['imagesAttempted'] = 3
      ..['imagesRejected'] = 0
      ..['gyroAttempted'] = 7
      ..['gyroRejected'] = 0
      ..['state'] = 'stopped'
      ..['queueProcessedSuccess'] = 10
      ..['queueBacklog'] = 0
      ..['queueInFlight'] = 0;
    clean['rejectionReasons'] = <String, Object?>{
      'images': sensorReasons(),
      'acc': sensorReasons(),
      'gyro': sensorReasons(),
      'workTerminal': workTerminalReasons(),
      'workDroppedOnStop': <String, Object?>{'dropped_on_stop': 0},
    };
    const VioShadowTimebaseEvidence stale = VioShadowTimebaseEvidence(
      schemaValid: true,
      sessionId: sessionId,
      sessionEpoch: 11,
      nativeGeneration: 3,
      expectedNativeGeneration: 4,
      boundShadowGeneration: 7,
      accelerometerBase: 'uptimeRaw',
      gyroscopeBase: 'uptimeRaw',
      arFrameBase: 'uptimeRaw',
      accelerometerSameBaseAsCamera: true,
      gyroscopeSameBaseAsCamera: true,
    );
    expect(
      VioShadowHealthSummary.fromWire(
        clean,
        expectedIdentity: expectedIdentity,
        timebase: stale,
        terminalReceipt: trustedTerminal,
      ).runValid,
      isFalse,
    );
  });

  test(
    'self-consistent clock generation cannot authorize another shadow run',
    () {
      final Map<String, Object?> clean = healthyWire()
        ..['imagesAttempted'] = 3
        ..['imagesRejected'] = 0
        ..['gyroAttempted'] = 7
        ..['gyroRejected'] = 0
        ..['state'] = 'stopped'
        ..['queueProcessedSuccess'] = 10
        ..['queueBacklog'] = 0
        ..['queueInFlight'] = 0;
      clean['rejectionReasons'] = <String, Object?>{
        'images': sensorReasons(),
        'acc': sensorReasons(),
        'gyro': sensorReasons(),
        'workTerminal': workTerminalReasons(),
        'workDroppedOnStop': <String, Object?>{'dropped_on_stop': 0},
      };
      const VioShadowTimebaseEvidence wrongShadowRun =
          VioShadowTimebaseEvidence(
            schemaValid: true,
            sessionId: sessionId,
            sessionEpoch: 11,
            nativeGeneration: 4,
            expectedNativeGeneration: 4,
            boundShadowGeneration: 6,
            accelerometerBase: 'uptimeRaw',
            gyroscopeBase: 'uptimeRaw',
            arFrameBase: 'uptimeRaw',
            accelerometerSameBaseAsCamera: true,
            gyroscopeSameBaseAsCamera: true,
          );

      expect(
        VioShadowHealthSummary.fromWire(
          clean,
          expectedIdentity: expectedIdentity,
          timebase: wrongShadowRun,
          terminalReceipt: trustedTerminal,
        ).runValid,
        isFalse,
      );
    },
  );

  test('Dart alone classifies raw pose status and first-valid timing', () {
    final VioShadowPoseAccumulator pose = VioShadowPoseAccumulator();
    Map<String, Object?> observation({
      required int seq,
      required int rc,
      int? cameraRc,
      int degenerate = 0,
      double observed = 10.5,
      double enqueued = 10.48,
    }) => <String, Object?>{
      'seq': seq,
      'rawStateCallCompleted': true,
      'rawCameraPoseCallCompleted': true,
      'rawXrslamState': degenerate == 1 ? 1 : (rc == 0 ? 1 : (rc == 2 ? 0 : 2)),
      'observedAtUptimeSeconds': observed,
      'enqueuedAtUptimeSeconds': enqueued,
      'sessionStartedAtUptimeSeconds': 10.0,
      'sensorTimestamp': 1.0,
      'xrslamPoseTimestamp': cameraRc == 0 ? 1.0 : null,
      'xrslamWorldFromCamera': <String, Object?>{
        'qx': 0.0,
        'qy': 0.0,
        'qz': 0.0,
        'qw': degenerate == 1 ? 0.0 : 1.0,
        'tx': 0.0,
        'ty': 0.0,
        'tz': 0.0,
      },
    };

    pose.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 3,
      'poseObservationsOffered': 4,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[
        observation(seq: 1, rc: 0, cameraRc: 0),
        observation(seq: 2, rc: 2),
        observation(seq: 3, rc: 2, degenerate: 1),
        observation(seq: 4, rc: -1),
      ],
    });
    final VioShadowPoseAvailability s = pose.summary;
    expect(s.schemaValid, isTrue);
    expect(s.valid, 1);
    expect(s.noNew, 1);
    expect(s.degenerate, 1);
    expect(s.errors, 1);
    expect(s.initialized, isTrue);
    expect(s.initializationLatencyMs, closeTo(500, 1e-9));
    expect(s.validLatencyMeanMs, closeTo(20, 1e-9));
  });

  test(
    'running may have unresolved offers, stopped must be terminally exact',
    () {
      final Map<String, Object?> running = healthyWire()
        ..['imagesAttempted'] = 5;
      expect(VioShadowHealthSummary.fromWire(running).images.conserved, isTrue);
      final Map<String, Object?> stopped = Map<String, Object?>.from(running)
        ..['state'] = 'stopped';
      expect(
        VioShadowHealthSummary.fromWire(stopped).images.conserved,
        isFalse,
      );
    },
  );

  test('Dart alone classifies raw frame timing and tracks behind streaks', () {
    final VioShadowQualityAccumulator quality = VioShadowQualityAccumulator();
    quality.consumeSnapshot(
      qualityWire(generation: 1, seq: 1, frameMs: 40, intervalMs: 33),
    );
    quality.consumeSnapshot(
      qualityWire(generation: 1, seq: 2, frameMs: 45, intervalMs: 33),
    );
    quality.consumeSnapshot(
      qualityWire(generation: 1, seq: 3, frameMs: 20, intervalMs: 33),
    );

    final VioShadowQualitySummary s = quality.summary;
    expect(s.schemaValid, isTrue);
    expect(s.observationCount, 3);
    expect(s.behindCount, 2);
    expect(s.behindMaxStreak, 2);
    expect(s.behindStreak, 0);
    expect(s.behindRate, closeTo(2 / 3, 1e-12));
  });

  test(
    'Dart quality state is isolated by generation and ignores old replies',
    () {
      final VioShadowQualityAccumulator quality = VioShadowQualityAccumulator();
      quality.consumeSnapshot(
        qualityWire(generation: 2, seq: 10, frameMs: 50, intervalMs: 25),
      );
      quality.consumeSnapshot(
        qualityWire(generation: 3, seq: 1, frameMs: 10, intervalMs: 25),
      );
      quality.consumeSnapshot(
        qualityWire(generation: 2, seq: 99, frameMs: 100, intervalMs: 1),
      );

      expect(quality.summary.observationCount, 1);
      expect(quality.summary.behindCount, 0);
    },
  );

  test(
    'quality ignores generation-less wire without contaminating next run',
    () {
      final VioShadowQualityAccumulator quality = VioShadowQualityAccumulator();
      quality.consumeSnapshot(
        qualityWire(seq: 99, frameMs: 100, intervalMs: 1),
      );
      quality.consumeSnapshot(
        qualityWire(generation: 1, seq: 1, frameMs: 10, intervalMs: 20),
      );

      expect(quality.summary.observationCount, 1);
      expect(quality.summary.behindCount, 0);
    },
  );

  test('terminal summary survives while quality and pose state is erased', () {
    final VioShadowQualityAccumulator quality = VioShadowQualityAccumulator();
    quality.consumeSnapshot(
      qualityWire(generation: 1, seq: 1, frameMs: 40, intervalMs: 20),
    );
    final VioShadowQualitySummary terminalQuality = quality
        .takeSummaryAndReset();
    expect(terminalQuality.observationCount, 1);
    expect(terminalQuality.behindCount, 1);
    expect(quality.summary.schemaValid, isFalse);
    expect(quality.summary.observationCount, 0);

    final VioShadowPoseAccumulator pose = VioShadowPoseAccumulator();
    pose.consumeSnapshot(<String, Object?>{
      'sessionGeneration': 1,
      'poseObservationsOffered': 1,
      'poseObservationsDropped': 0,
      'poseObservations': <Object?>[
        <String, Object?>{
          'seq': 1,
          'rawStateCallCompleted': true,
          'rawCameraPoseCallCompleted': true,
          'rawXrslamState': 1,
          'observedAtUptimeSeconds': 2.0,
          'enqueuedAtUptimeSeconds': 1.9,
          'sessionStartedAtUptimeSeconds': 1.0,
          'xrslamPoseTimestamp': 1.95,
          'xrslamWorldFromCamera': <String, Object?>{
            'qx': 0.0,
            'qy': 0.0,
            'qz': 0.0,
            'qw': 1.0,
            'tx': 0.0,
            'ty': 0.0,
            'tz': 0.0,
          },
        },
      ],
    });
    final VioShadowPoseAvailability terminalPose = pose.takeSummaryAndReset();
    expect(terminalPose.valid, 1);
    expect(terminalPose.initialized, isTrue);
    expect(pose.summary.schemaValid, isFalse);
    expect(pose.summary.totalAttempts, 0);
  });
}
