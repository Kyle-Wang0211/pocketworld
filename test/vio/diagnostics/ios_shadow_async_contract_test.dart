import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final File feeder = File('ios/Runner/PwVioSlamFeeder.swift');
  final File plugin = File('ios/Runner/OfficialAetherARKitPlugin.swift');
  final File timebase = File('ios/Runner/PwVioTimebase.swift');
  final File channel = File('lib/vio/timebase/ios_timebase_channel.dart');
  final File recorder = File(
    'lib/vio/diagnostics/vio_diagnostics_recorder.dart',
  );

  test('ARSession retains only a fully reserved permit across its queue', () {
    final String source = plugin.readAsStringSync();
    final RegExpMatch? callback = RegExp(
      r'func session\(_ session: ARSession, didUpdate frame: ARFrame\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);

    expect(callback, isNotNull);
    final String body = callback!.group(1)!;
    expect(
      body,
      contains(
        'let shadowFeeder = PwVioSlamFeeder.shared\n'
        '    if let permit = shadowFeeder.tryOfferFrame(frame: frame) {\n'
        '      PwVioTimebase.shared.noteARFrame(frame)\n'
        '      PwVioSensorIngress.dispatchQueue.async {\n'
        '        _ = shadowFeeder.consume(permit: permit)\n'
        '      }\n'
        '    }',
      ),
      reason:
          'a rejected O(1) offer must not create an escaping ARFrame closure',
    );
    expect(body, isNot(contains('XRSLAMRunOneFrame')));
    expect(body, isNot(contains('downsampleBox')));
    final int offer = body.indexOf('shadowFeeder.tryOfferFrame(frame: frame)');
    final int timebaseNote = body.indexOf(
      'PwVioTimebase.shared.noteARFrame(frame)',
    );
    final int escapingClosure = body.indexOf(
      'PwVioSensorIngress.dispatchQueue.async {',
    );
    final int consume = body.indexOf('shadowFeeder.consume(permit: permit)');
    final int productionBroadcast = body.indexOf('onFrame?(frame)');
    expect(offer, greaterThanOrEqualTo(0));
    expect(offer, lessThan(timebaseNote));
    expect(timebaseNote, lessThan(escapingClosure));
    expect(escapingClosure, lessThan(consume));
    final int closureEnd = body.indexOf('\n      }', escapingClosure);
    expect(closureEnd, greaterThan(escapingClosure));
    expect(
      body.substring(escapingClosure, closureEnd),
      isNot(contains('frame')),
      reason: 'the escaping closure may retain only the fully reserved permit',
    );
    expect(
      consume,
      lessThan(productionBroadcast),
      reason:
          'production broadcast remains outside the rejectable shadow branch',
    );
  });

  test(
    'camera shadow and IMU share one serial queue without moving production state off main',
    () {
      final String pluginSource = plugin.readAsStringSync();
      final String timebaseSource = timebase.readAsStringSync();
      expect(
        pluginSource,
        contains(
          'session.delegateQueue = .main\n'
          '    session.delegate = sessionDelegate',
        ),
        reason:
            'production ARKit state must stay on its proven main-thread owner',
      );
      expect(
        timebaseSource,
        contains('private let motionQueue = PwVioSensorIngress.operationQueue'),
        reason: 'IMU transport must share the XRSLAM sensor ingress queue',
      );
      expect(timebaseSource, contains('queue.maxConcurrentOperationCount = 1'));
      expect(timebaseSource, contains('queue.underlyingQueue = dispatchQueue'));
      expect(
        pluginSource,
        contains('PwVioSensorIngress.dispatchQueue.async {'),
        reason:
            'only the shadow camera copy belongs on the XRSLAM ingress queue',
      );
      final int offer = pluginSource.indexOf(
        'shadowFeeder.tryOfferFrame(frame: frame)',
      );
      final int timebaseNote = pluginSource.indexOf(
        'PwVioTimebase.shared.noteARFrame(frame)',
        offer,
      );
      final int cameraQueue = pluginSource.indexOf(
        'PwVioSensorIngress.dispatchQueue.async {',
        timebaseNote,
      );
      final int consume = pluginSource.indexOf(
        'shadowFeeder.consume(permit: permit)',
        cameraQueue,
      );
      final int productionBroadcast = pluginSource.indexOf(
        'onFrame?(frame)',
        consume,
      );
      expect(offer, greaterThanOrEqualTo(0));
      expect(offer, lessThan(timebaseNote));
      expect(timebaseNote, lessThan(cameraQueue));
      expect(cameraQueue, lessThan(consume));
      expect(consume, lessThan(productionBroadcast));
      expect(
        'dispatchPrecondition(condition: .onQueue(.main))'.allMatches(
          pluginSource,
        ),
        hasLength(greaterThanOrEqualTo(2)),
        reason: 'snapshot selection and production broadcast must fail closed',
      );
      expect(
        pluginSource,
        isNot(
          contains('session.delegateQueue = PwVioSensorIngress.dispatchQueue'),
        ),
      );
      expect(
        timebaseSource,
        isNot(contains('motionQueue: OperationQueue = .main')),
      );
    },
  );

  test(
    'shadow feeder is fixed-bounded and pressure never paces production',
    () {
      final String source = feeder.readAsStringSync();
      expect(source, contains('private static let maxQueuedWork = 256'));
      expect(source, contains('private static let maxRetainedImages = 30'));
      expect(source, contains('private final class GrayFramePool'));
      expect(source, contains('PWXrslamTransportPrepareGrayBoxNxN('));
      expect(source, contains('fileprivate let pixelBuffer: CVPixelBuffer'));
      expect(source, contains('private let workSlotLimiter = AtomicLimiter('));
      expect(
        source,
        matches(
          RegExp(
            r'Array<PendingWork\?>\(\s*repeating: nil,\s*'
            r'count: (?:Self|PwVioSlamFeeder)\.maxQueuedWork\s*\)',
          ),
        ),
      );
      expect(source, isNot(contains('pendingWork.append(work)')));
      expect(source, isNot(contains('guard lock.try() else')));
      expect(source, contains('pendingCount < Self.maxQueuedWork'));
      expect(source, contains('grayFramePool.tryAcquire()'));
      expect(source, contains('private var inFlightImageCount = 0'));
      expect(source, contains('"retainedImageCount"'));
      expect(source, contains('"maxRetainedImageCount"'));
      expect(source, contains('"queueCapacity": Self.maxQueuedWork'));
      expect(source, contains('"cameraCapacity": Self.maxRetainedImages'));
      expect(source, contains('"dropPolicy": "invalidate-on-overflow"'));
      expect(source, contains('shadowOverflowDrops'));
      expect(source, contains('"transportValid"'));
      expect(source, contains('"runInvalidationReasons"'));
      expect(source, contains('coreQueue.async'));
      expect(source, isNot(contains('DispatchGroup')));
      expect(source, isNot(contains('.wait()')));

      // A deterministic model of the source contract: even if a producer
      // offers far more than a realistic session, resident work never grows.
      const int offered = 10001;
      var pending = 0;
      var retainedImages = 0;
      var rejected = 0;
      var invalid = false;
      for (var i = 0; i < offered; i += 1) {
        final bool image = i.isEven;
        if (pending >= 256 || (image && retainedImages >= 30)) {
          rejected += 1;
          invalid = true;
          continue;
        }
        pending += 1;
        if (image) retainedImages += 1;
      }
      expect(pending, lessThanOrEqualTo(256));
      expect(retainedImages, lessThanOrEqualTo(30));
      expect(rejected, greaterThan(0));
      expect(invalid, isTrue);
    },
  );

  test('production admission is O(1) and every sensor carries generation order', () {
    final String source = feeder.readAsStringSync();
    final RegExpMatch? frameOffer = RegExp(
      r'public func tryOfferFrame\(frame: ARFrame\) -> FrameIngressPermit\? \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(frameOffer, isNotNull);
    final String frameOfferBody = frameOffer!.group(1)!;
    expect(frameOfferBody, contains('admissionGate.enter()'));
    expect(frameOfferBody, contains('cameraIngressLimiter.tryAcquire()'));
    expect(frameOfferBody, contains('workSlotLimiter.tryAcquire()'));
    expect(frameOfferBody, contains('grayFramePool.tryAcquire()'));
    expect(frameOfferBody, contains('ingressSequence.incrementAndValue('));
    expect(frameOfferBody, contains('generation: lease.generation'));
    expect(frameOfferBody, contains('return FrameIngressPermit('));
    expect(frameOfferBody, isNot(contains('lock.lock()')));
    expect(frameOfferBody, contains('let pixelBuffer = frame.capturedImage'));
    expect(frameOfferBody, isNot(contains('.sync')));
    expect(frameOfferBody, isNot(contains('.wait()')));

    final RegExpMatch? frameConsume = RegExp(
      r'public func consume\(permit: FrameIngressPermit\) -> Bool \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(frameConsume, isNotNull);
    expect(frameConsume!.group(1), contains('guard permit.claim()'));
    expect(frameConsume.group(1), contains('permit.timestamp.isFinite'));
    expect(frameConsume.group(1), contains('ingressSequence: permit.sequence'));

    for (final RegExp callbackPattern in <RegExp>[
      RegExp(
        r'public func enqueue\(\s*acceleration sample: CMAccelerometerData,\s*expectedGeneration: Int\? = nil\s*\) -> Bool \{([\s\S]*?)\n  \}',
      ),
      RegExp(
        r'public func enqueue\(\s*gyroscope sample: CMGyroData,\s*expectedGeneration: Int\? = nil\s*\) -> Bool \{([\s\S]*?)\n  \}',
      ),
    ]) {
      final RegExpMatch? callback = callbackPattern.firstMatch(source);
      expect(callback, isNotNull);
      final String body = callback!.group(1)!;
      expect(body, contains('admissionGate.enter('));
      expect(body, contains('expectedGeneration: expectedGeneration'));
      expect(body, contains('ingressSequence.incrementAndValue('));
      expect(body, contains('generation: lease.generation'));
      expect(body, contains('admit('));
      expect(body, isNot(contains('lock.lock()')));
      expect(body, isNot(contains('.sync')));
      expect(body, isNot(contains('.wait()')));
    }
  });

  test(
    'offered sensors resolve as submitted only after checked wrapper call',
    () {
      final String source = feeder.readAsStringSync();
      for (final String prefix in <String>['images', 'acc', 'gyro']) {
        expect(source, contains('"${prefix}Attempted"'));
        expect(source, contains('"${prefix}Submitted"'));
        expect(source, contains('"${prefix}Accepted"'));
        expect(source, contains('"${prefix}Rejected"'));
      }
      expect(
        source,
        contains(
          'out["acceptedCompatibilitySemantics"] = '
          '"submitted_to_void_c_api"',
        ),
      );
      expect(source, contains('rejectionReasons'));
      expect(source, contains('lastImageRc'));
      expect(source, contains('lastAccRc'));
      expect(source, contains('lastGyroRc'));
      expect(source, contains('private struct SensorFacts'));
      expect(source, contains('mutating func offer()'));
      expect(source, contains('mutating func submit()'));
      expect(source, contains('mutating func reject('));
      expect(source, isNot(contains('recordSensorAdmission(work')));
      final RegExpMatch? frameProcessor = RegExp(
        r'private func processFrameOnCore\([\s\S]*?\n  \}',
      ).firstMatch(source);
      expect(frameProcessor, isNotNull);
      expect(
        frameProcessor!
            .group(0)!
            .indexOf('PWXrslamTransportPushCameraAndRunRaw('),
        lessThan(frameProcessor.group(0)!.indexOf('imageFacts.submit()')),
      );
      expect(source, contains('accFacts.submit()'));
      expect(source, contains('gyroFacts.submit()'));
    },
  );

  test(
    'queue success excludes invalid native stale and stopped terminal work',
    () {
      final String source = feeder.readAsStringSync();
      expect(source, contains('queueProcessedSuccess'));
      expect(source, contains('terminalRejected += 1'));
      expect(
        source,
        matches(
          RegExp(
            r'queueAccepted\s*==\s*queueProcessedSuccess\s*\+\s*'
            r'droppedOnStop\s*\+\s*terminalRejected\s*\+\s*'
            r'pendingCount\s*\+\s*inFlightCount',
          ),
        ),
      );
      expect(source, isNot(contains('rejectPendingOnStopLocked()')));
      expect(source, isNot(contains('droppedOnStop += 1')));
      expect(
        source,
        contains('state == .running || state == .stopping'),
        reason: 'sealed stop must drain every already-admitted item',
      );
      expect(source, contains('private func processFrameOnCore'));
      expect(source, contains('private func processAccelerationOnCore'));
      expect(source, contains('private func processGyroscopeOnCore'));
      expect(source, isNot(contains('private func processMotionOnCore')));
      expect(source, isNot(contains('queueProcessed += 1')));
    },
  );

  test('slamStop completion carries the immutable old-generation terminal receipt', () {
    final String channelSource = timebase.readAsStringSync();
    final String pluginSource = plugin.readAsStringSync();
    final String feederSource = feeder.readAsStringSync();
    expect(channelSource, contains('public func shutdownShadowPipeline('));
    expect(channelSource, contains('stopRawCoreMotionFeedLocked()'));
    expect(channelSource, contains('PwVioSlamFeeder.shared.stop { receipt in'));
    expect(channelSource, contains('join.receive(receipt: receipt)'));
    expect(
      channelSource,
      contains(
        'case "slamStop":\n'
        '        PwVioTimebase.shared.shutdownShadowPipeline { receipt in\n'
        '          result(receipt)',
      ),
    );
    final RegExpMatch? finishStop = RegExp(
      r'private func finishSealedStopOnCoreQueue\(generation: Int\) \{([\s\S]*?)\n  \}',
    ).firstMatch(feederSource);
    expect(finishStop, isNotNull);
    final String finishBody = finishStop!.group(1)!;
    expect(
      finishBody,
      contains('PWXrslamTransportDestroyWithReceipt(&destroyReceipt)'),
    );
    expect(finishBody, contains('var terminalReceipt'));
    expect(finishBody, contains('makeWireSnapshotLocked'));
    expect(
      finishBody,
      contains('assert(pendingCount == 0 && inFlightCount == 0)'),
    );
    expect(
      finishBody,
      contains('assert(pendingImageCount == 0 && inFlightImageCount == 0)'),
    );
    expect(feederSource, contains('"terminalReceiptComplete"'));
    expect(feederSource, contains('"workConserved"'));
    expect(finishBody, contains('completion(terminalReceipt)'));
    expect(
      finishBody.indexOf('terminalReceipt = makeWireSnapshotLocked'),
      lessThan(finishBody.indexOf('beginStartLocked')),
      reason: 'restart must not reset the generation before receipt freeze',
    );
    expect(
      finishBody,
      contains('if pendingRestart == nil { lastStartRequest = nil }'),
      reason: 'explicit shutdown must not retain a restartable old config',
    );
    expect(
      finishBody.indexOf('terminalReceipt = makeWireSnapshotLocked'),
      lessThan(
        finishBody.indexOf(
          'if pendingRestart == nil { lastStartRequest = nil }',
        ),
      ),
      reason: 'clear only after the immutable receipt has captured identity',
    );
    expect(finishBody, contains('DispatchQueue.main.async'));
    expect(
      finishBody.indexOf('PWXrslamTransportDestroyWithReceipt('),
      lessThan(finishBody.indexOf('DispatchQueue.main.async')),
    );
    final RegExpMatch? closeMarker = RegExp(
      r'private func closeIngressForStop\(generation: Int\) \{([\s\S]*?)\n  \}',
    ).firstMatch(feederSource);
    expect(closeMarker, isNotNull);
    final String closeBody = closeMarker!.group(1)!;
    expect(
      closeBody,
      contains('admissionGate.sealWhenQuiescent(generation: generation)'),
    );
    expect(closeBody, contains('self.coreQueue.async'));
    expect(closeBody, contains('self.ingressClosed = true'));
    expect(closeBody, contains('self.terminalIngressSequence = UInt64('));
    expect(closeBody, contains('self.terminalIngressCompleted = UInt64('));
    expect(
      closeBody.indexOf('self.terminalIngressSequence = UInt64('),
      lessThan(closeBody.indexOf('self.drain(epoch: generation)')),
      reason: 'the close marker must freeze the admitted tail before drain',
    );
    expect(
      finishBody,
      contains('guard sessionGeneration == generation, state == .stopping,'),
    );
    expect(finishBody, contains('ingressClosed else'));
    expect(finishBody, contains('"receiptAvailable": shouldDestroy'));
    expect(
      finishBody,
      contains(
        'destroyReceipt.lifecycle_generation != nativeStartLifecycleGeneration',
      ),
    );
    final RegExpMatch? frameCallback = RegExp(
      r'func session\(_ session: ARSession, didUpdate frame: ARFrame\) \{([\s\S]*?)\n  \}',
    ).firstMatch(pluginSource);
    expect(frameCallback, isNotNull);
    expect(
      frameCallback!.group(1),
      isNot(contains('shutdownShadowPipeline')),
      reason: 'production frame delivery must not own shadow teardown',
    );
    expect(feederSource, contains('pendingRestart'));
    expect(feederSource, contains('startCompletions'));
    expect(channelSource, contains('shadowLifecycleGeneration'));
    expect(channelSource, contains('shadowMotionDesired'));
    expect(
      feederSource,
      contains('"schema": "pw.vio.shadow-terminal-unavailable/1"'),
      reason: 'a second stop may be idempotent but cannot redeliver evidence',
    );
    expect(feederSource, contains('stopCompletions.removeAll'));
  });

  test('slamStart returns a direct immutable generation receipt', () {
    final String feederSource = feeder.readAsStringSync();
    final String timebaseSource = timebase.readAsStringSync();
    expect(
      feederSource,
      contains('directRunningReceipt(expectedGeneration: Int)'),
    );
    expect(
      feederSource,
      contains('completion(1, epoch)'),
      reason: 'the direct Create completion must carry its exact feeder epoch',
    );
    expect(
      timebaseSource,
      contains('"schema": "pw.vio.shadow-start-receipt/1"'),
    );
    expect(timebaseSource, contains('"generation": feederGeneration'));
    expect(timebaseSource, contains('"snapshot": directSnapshot'));
    expect(timebaseSource, contains('case "slamStart":'));
    expect(timebaseSource, contains('result(receipt)'));
    final RegExpMatch? handler = RegExp(
      r'case "slamStart":([\s\S]*?)case "slamStop":',
    ).firstMatch(timebaseSource);
    expect(handler, isNotNull);
    expect(handler!.group(1), isNot(contains('result(Int(rc))')));
  });

  test(
    'camera offset is applied once by shared transport and stop has native receipt',
    () {
      final String source = feeder.readAsStringSync();
      expect(source, contains('let cameraTimeOffsetSeconds: Double'));
      expect(
        source,
        contains('cameraTimeOffsetSeconds == other.cameraTimeOffsetSeconds'),
      );
      expect(source, contains('PWXrslamTransportCreateWithCameraTimeOffset('));
      expect(source, contains('request.cameraTimeOffsetSeconds'));
      expect(source, isNot(contains('PWXrslamTransportCreate(slam, device)')));
      expect(source, contains('PWXrslamTransportDestroyWithReceipt('));
      for (final String field in <String>[
        'nativeDestroyRc',
        'nativeDestroyAcknowledged',
        'nativeLifecycleGeneration',
        'nativeCameraSubmitted',
        'nativeCameraRunCalls',
        'nativeAccelerationSubmitted',
        'nativeGyroscopeSubmitted',
        'nativeRejectedInvalidArgument',
        'nativeRejectedNonMonotonic',
        'nativeRejectedNotRunning',
      ]) {
        expect(source, contains('"$field"'));
      }
      expect(source, contains('PWXrslamTransportGetCounters(&counters)'));
      expect(source, contains('"coreHealthSource": "transport_core_counters"'));
    },
  );

  test('raw CoreMotion stop and async failure accounting are lifecycle-safe', () {
    final String source = timebase.readAsStringSync();
    final RegExpMatch? stop = RegExp(
      r'private func stopRawCoreMotionFeedLocked\(\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(stop, isNotNull);
    expect(stop!.group(1), contains('motion.stopAccelerometerUpdates()'));
    expect(stop.group(1), contains('motion.stopGyroUpdates()'));
    expect(stop.group(1), isNot(contains('isAccelerometerActive')));
    expect(stop.group(1), isNot(contains('isGyroActive')));

    final RegExpMatch? failure = RegExp(
      r'private func scheduleRawMotionFailure\(generation: Int\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(failure, isNotNull);
    expect(
      failure!.group(1),
      contains('generation == self.shadowLifecycleGeneration'),
    );
    expect(failure.group(1), contains('self.shadowMotionDesired'));
    expect(
      failure.group(1),
      contains('self.rawMotionFailureScheduledGeneration != generation'),
    );
    expect(source, isNot(contains('rawMotionFailureScheduled: Int32')));

    final RegExpMatch? standaloneStart = RegExp(
      r'public func startRawCoreMotionFeed\(accelerometerHz: Double, gyroscopeHz: Double\) -> Bool \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(standaloneStart, isNotNull);
    final String startBody = standaloneStart!.group(1)!;
    expect(startBody, contains('shadowMotionDesired = true'));
    expect(
      startBody.indexOf('shadowMotionDesired = true'),
      lessThan(startBody.indexOf('startRawCoreMotionFeedLocked(')),
    );
    expect(startBody, contains('if !result {'));
    expect(startBody, contains('rollbackShadowStartIntentLocked()'));
  });

  test('a stale callback from an old session cannot poison every future run', () {
    final String source = timebase.readAsStringSync();
    final RegExpMatch? counter = RegExp(
      r'private final class PwVioAtomicCounter \{([\s\S]*?)\n\}',
    ).firstMatch(source);
    expect(counter, isNotNull);
    expect(counter!.group(1), contains('func reset()'));

    final RegExpMatch? begin = RegExp(
      r'public func beginSession\(sessionId: String, sessionEpoch: Int\) -> Bool \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(begin, isNotNull);
    final String body = begin!.group(1)!;
    expect(body, contains('outOfSessionStaleObservations.reset()'));
    expect(
      body.indexOf('timebaseIngress.prepare(generation: generation)'),
      lessThan(body.indexOf('outOfSessionStaleObservations.reset()')),
      reason: 'reset is only safe after the previous ingress is sealed/drained',
    );
    expect(
      body.indexOf('outOfSessionStaleObservations.reset()'),
      lessThan(body.indexOf('timebaseIngress.open(generation: generation)')),
      reason: 'new callbacks must not race the per-session reset',
    );
  });

  test('duplicate stop waits for the same terminal boundary', () {
    final String source = feeder.readAsStringSync();
    final RegExpMatch? stoppingBranch = RegExp(
      r'if state == \.stopping \{([\s\S]*?)\n    \}',
    ).firstMatch(source);
    expect(stoppingBranch, isNotNull);
    expect(
      stoppingBranch!.group(1),
      contains('stopCompletions.append(completion)'),
    );
    expect(stoppingBranch.group(1), isNot(contains('completion(receipt)')));
    expect(
      source,
      contains(
        'for completion in completedStops { completion(terminalReceipt) }',
      ),
    );
  });

  test('stop sealing is edge-triggered and never busy polls coreQueue', () {
    final String source = feeder.readAsStringSync();
    expect(source, contains('func sealWhenQuiescent('));
    expect(source, contains('completeSealIfReady()'));
    expect(source, contains('guard sealLock.try() else { return }'));
    expect(source, contains('finishSealedStopOnCoreQueue(generation:'));
    final RegExpMatch? closeMarker = RegExp(
      r'private func closeIngressForStop\(generation: Int\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(closeMarker, isNotNull);
    final String closeBody = closeMarker!.group(1)!;
    expect(
      'self.coreQueue.async'.allMatches(closeBody),
      hasLength(1),
      reason: 'one sealed marker enters coreQueue; it never polls or resubmits',
    );
    expect(closeBody, isNot(contains('asyncAfter')));
    expect(closeBody, contains('self.drain(epoch: generation)'));
    expect(
      source,
      contains('bitPattern: Phase.sealed.rawValue << Self.phaseShift'),
      reason: 'generation zero must reject pre-start callbacks',
    );
  });

  test(
    'terminal sensor receipt is sealed and built from one coherent ledger',
    () {
      final String source = feeder.readAsStringSync();
      expect(source, contains('seal(generation:'));
      expect(source, contains('sealedImageLockContention'));
      expect(source, contains('sealedAccelerationLockContention'));
      expect(source, contains('sealedGyroscopeLockContention'));
      expect(source, contains('struct SensorFacts'));
      expect(
        source,
        contains(
          'func wire(\n'
          '      lockContention: Int,\n'
          '      stopRejections: Int,\n'
          '      queueFullRejections: Int = 0',
        ),
      );
      expect(
        source,
        isNot(contains('private final class SensorAdmissionLedger')),
      );
      expect(
        source,
        isNot(contains('private final class SensorRejectionLedger')),
      );
      expect(
        source,
        contains('attempted + lockContention'),
        reason: 'one atomic contention event must contribute to both sides',
      );
      expect(
        source,
        contains(
          'attempted + lockContention + stopRejections + '
          'queueFullRejections',
        ),
        reason: 'pre-ring capacity rejection remains an unaccepted offer',
      );
      expect(source, contains('rejected + lockContention'));
    },
  );

  test(
    'Swift exports raw tracking and timing facts but owns no quality policy',
    () {
      final String source = feeder.readAsStringSync();
      expect(source, contains('"referenceTrackingState"'));
      expect(source, contains('"referenceTrackingReason"'));
      expect(source, contains('"previousImageTimestamp"'));
      expect(source, contains('"lastFrameMs"'));
      expect(source, isNot(contains('referenceTrackingUsable')));
      expect(source, isNot(contains('arkitTrackingNormal')));
      expect(source, isNot(contains('behindStreak')));
      expect(source, isNot(contains('behindMax')));
      expect(source, isNot(contains('frameIntervalEma')));
      expect(source, isNot(contains('lastRunSeconds')));
      expect(source, isNot(contains('1.0 / runHz')));
      expect(source, isNot(contains('healthPeriodSeconds')));
      expect(source, isNot(contains('comparisonExportPeriodSeconds')));
      expect(source, isNot(contains('"runValid"')));
      expect(source, isNot(contains('runInvalidations')));
      expect(source, isNot(contains('"authority": "shadow"')));
      expect(source, isNot(contains('"decisionConsumers": 0')));
      expect(source, isNot(contains('runHz')));
      for (final String portableReduction in <String>[
        'lastFrameIntervalMs',
        'lastRunSpanMs',
        'workerFrameMeanMs',
        'workerFrameMaxMs',
        'enqueueLatencyMeanUs',
        'enqueueLatencyMaxUs',
        'dutyCycle',
        'accMean',
      ]) {
        expect(
          source,
          isNot(contains(portableReduction)),
          reason: '$portableReduction belongs in Dart',
        );
      }
      expect(source, contains('"accSumX"'));
      expect(source, contains('"accNativeAcceptedCount"'));
      expect(source, contains('"workerFrameMsSum"'));
      expect(source, contains('"enqueueLatencyUsSum"'));
      expect(source, contains('"solveWallSecondsSum"'));
    },
  );

  test(
    'Swift timebase is raw platform glue and Dart owns estimation policy',
    () {
      final String source = timebase.readAsStringSync();
      expect(source, contains('rawSamples'));
      expect(source, contains('sourceSeconds'));
      expect(source, contains('uptimeRawBeforeSeconds'));
      expect(source, contains('monotonicSeconds'));
      expect(source, contains('uptimeRawAfterSeconds'));
      expect(source, contains('pw.vio.timebase-raw/5'));
      expect(source, isNot(contains('"schema": "pw.vio.timebase-raw/4"')));
      expect(source, contains('pw.vio.timebase-remeasure-raw/1'));
      expect(source, isNot(contains('"uptimeRawSeconds"')));
      expect(source, isNot(contains('"readCostSeconds"')));
      expect(source, isNot(contains('"clockPairReadCostSeconds"')));
      expect(source, isNot(contains('(a + c) * 0.5')));
      expect(source, isNot(contains('max(0.0, c - a)')));
      expect(source, contains('referenceTrackingState'));
      expect(source, contains('referenceTrackingReason'));
      expect(source, isNot(contains('PwVioMinFilter')));
      expect(source, isNot(contains('driftIsSignificant')));
      expect(source, isNot(contains('offsetToUptimeRaw')));
      expect(source, isNot(contains('pwVioIsNormal')));
      expect(source, isNot(contains('capturedAtSeconds')));
    },
  );

  test('timebase hot callbacks are O(1) nonblocking and fully accounted', () {
    final String source = timebase.readAsStringSync();
    final RegExpMatch? intrinsics = RegExp(
      r'private func noteIntrinsics\(_ camera: ARCamera, generation: Int\) \{([\s\S]*?)\n    \}',
    ).firstMatch(source);
    expect(intrinsics, isNotNull);
    expect(source, contains('guard let entry = timebaseIngress.enter()'));
    expect(source, contains('defer { timebaseIngress.leave(entry) }'));
    expect(source, contains('guard lock.try() else'));
    expect(intrinsics!.group(1), contains('lock.try()'));
    expect(intrinsics.group(1), isNot(contains('lock.lock()')));
    expect(intrinsics.group(1), isNot(contains('latestIntrinsics = [')));
    expect(source, contains('private struct PwVioRawIntrinsics'));
    expect(source, contains('"rawSamplesAttempted"'));
    expect(source, contains('"rawSamplesAccepted"'));
    expect(source, contains('"rawSamplesRejected"'));
    expect(source, contains('"rejectionReasons"'));
    expect(source, contains('"intrinsicsOverwritten"'));
  });

  test(
    'Swift intrinsics path transports only a small raw matrix and raw dimensions',
    () {
      final String source = timebase.readAsStringSync();
      final RegExpMatch? rawDto = RegExp(
        r'private struct PwVioRawIntrinsics \{([\s\S]*?)\n\}',
      ).firstMatch(source);
      final RegExpMatch? note = RegExp(
        r'private func noteIntrinsics\(_ camera: ARCamera, generation: Int\) \{([\s\S]*?)\n    \}',
      ).firstMatch(source);
      expect(rawDto, isNotNull);
      expect(note, isNotNull);

      expect(source, contains('pw.vio.ios.intrinsics-raw/1'));
      expect(source, contains('"intrinsicMatrixColumnMajor"'));
      expect(source, contains('"imageResolutionWidth"'));
      expect(source, contains('"imageResolutionHeight"'));
      expect(rawDto!.group(1), contains('matrix_float3x3'));
      expect(rawDto.group(1), isNot(contains('CVPixelBuffer')));
      expect(rawDto.group(1), isNot(contains('[UInt8]')));
      expect(rawDto.group(1), isNot(contains('Data')));

      final String body = note!.group(1)!;
      expect(body, isNot(contains('let fx')));
      expect(body, isNot(contains('let fy')));
      expect(body, isNot(contains('let cx')));
      expect(body, isNot(contains('let cy')));
      expect(body, isNot(contains('.isFinite')));
      expect(body, isNot(contains('res.width > 0')));
      expect(body, isNot(contains('res.height > 0')));
      expect(body, isNot(contains('Int(res.width)')));
      expect(body, isNot(contains('Int(res.height)')));
      expect(body, contains('intrinsicMatrix: camera.intrinsics'));
      expect(body, contains('imageResolutionWidth: Double(res.width)'));
      expect(body, contains('imageResolutionHeight: Double(res.height)'));
    },
  );

  test('stop clears raw pose observations only after core drain', () {
    final String source = feeder.readAsStringSync();
    final RegExpMatch? stop = RegExp(
      r'public func stop\([\s\S]*?\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(stop, isNotNull);
    expect(stop!.group(1), isNot(contains('poseObservations.removeAll')));
    final RegExpMatch? finish = RegExp(
      r'private func finishSealedStopOnCoreQueue\(generation: Int\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(finish, isNotNull);
    expect(finish!.group(1), contains('poseObservations.removeAll'));
    expect(source, contains('"poseObservationsOffered"'));
    expect(source, contains('"poseObservationsDropped"'));
    expect(source, contains('state == .running'));
    expect(source, contains('private final class GrayFramePool'));
    expect(source, isNot(contains('private var scratch:')));
    expect(finish.group(1), contains('vioWidth = 0'));
    expect(finish.group(1), contains('vioHeight = 0'));
  });

  test(
    'Dart owns restart authority and failed start clears retained motion policy',
    () {
      final String source = timebase.readAsStringSync();
      expect(source, contains('shadowResumeAuthorized'));
      expect(source, contains('revokeShadowAuthorization'));
      final RegExpMatch? revoke = RegExp(
        r'private func revokeShadowAuthorization\(\) \{([\s\S]*?)\n  \}',
      ).firstMatch(source);
      expect(revoke, isNotNull);
      expect(revoke!.group(1), contains('rollbackShadowStartIntentLocked()'));
      final RegExpMatch? resume = RegExp(
        r'public func resumeShadowPipeline\(\) \{([\s\S]*?)\n  \}',
      ).firstMatch(source);
      expect(resume, isNotNull);
      expect(resume!.group(1), contains('guard shadowResumeAuthorized'));
      expect(
        resume.group(1)!.indexOf('submitAuthorizedResumeLocked('),
        equals(-1),
        reason: 'native AR lifecycle may resume delivery, never create a run',
      );
      expect(
        resume.group(1),
        contains(
          'guard let feederGeneration = '
          'PwVioSlamFeeder.shared.runningGeneration else',
        ),
      );
      expect(resume.group(1), contains('feederGeneration: feederGeneration'));
      expect(
        source,
        contains(
          'case "slamStop":\n        '
          'PwVioTimebase.shared.shutdownShadowPipeline',
        ),
      );
      expect(source, isNot(contains('submitAuthorizedResumeLocked')));
      expect(source, isNot(contains('restartLastConfiguration')));
      expect(source, contains('rollbackShadowStartIntentLocked'));
      final RegExpMatch? rollback = RegExp(
        r'private func rollbackShadowStartIntentLocked[\s\S]*?\n  \}',
      ).firstMatch(source);
      expect(rollback, isNotNull);
      expect(rollback!.group(0), contains('shadowMotionDesired = false'));
      expect(rollback.group(0), contains('shadowResumeAuthorized = false'));
      expect(rollback.group(0), contains('shadowAccelerometerHz = nil'));
      expect(rollback.group(0), contains('shadowGyroscopeHz = nil'));
      expect(rollback.group(0), contains('stopRawCoreMotionFeedLocked()'));
    },
  );

  test(
    'Dart selects downsampling while requested camera rate is evidence only',
    () {
      final String dartSource = channel.readAsStringSync();
      final String feederSource = feeder.readAsStringSync();
      final String timebaseSource = timebase.readAsStringSync();
      final String recorderSource = recorder.readAsStringSync();

      expect(dartSource, contains('required int downsampleFactor'));
      expect(dartSource, contains('required String downsampleFormula'));
      expect(dartSource, contains('required double requestedCameraHz'));
      expect(dartSource, contains("'requestedCameraHz': requestedCameraHz"));
      expect(dartSource, contains("'downsampleFactor': downsampleFactor"));
      expect(dartSource, contains("'downsampleFormula': downsampleFormula"));
      expect(dartSource, isNot(contains('vioDownsampleFactor()')));
      expect(
        timebaseSource,
        contains('let downsampleFactor = args["downsampleFactor"] as? Int'),
      );
      expect(
        timebaseSource,
        contains(
          'let downsampleFormula = args["downsampleFormula"] as? String',
        ),
      );
      expect(
        timebaseSource,
        contains(
          'let requestedCameraHz = args["requestedCameraHz"] as? Double',
        ),
      );
      expect(timebaseSource, contains('downsampleFactor > 0'));
      expect(timebaseSource, isNot(contains('case "vioDownsampleFactor"')));
      expect(feederSource, contains('let downsampleFactor: Int'));
      expect(feederSource, contains('let downsampleFormula: String'));
      expect(feederSource, contains('let requestedCameraHz: Double'));
      expect(
        feederSource,
        contains('downsampleFactor == other.downsampleFactor'),
      );
      expect(
        feederSource,
        contains('downsampleFormula == other.downsampleFormula'),
      );
      expect(
        feederSource,
        contains('requestedCameraHz == other.requestedCameraHz'),
      );
      expect(feederSource, contains('downsampleFactor: downsampleFactor'));
      expect(feederSource, contains('downsampleFormula: downsampleFormula'));
      expect(feederSource, contains('PWXrslamTransportPrepareGrayBoxNxN('));
      expect(feederSource, contains('"vioDownsampleFactor":'));
      expect(feederSource, contains('"downsampleFactor":'));
      expect(feederSource, contains('"downsampleFormula":'));
      expect(feederSource, contains('"requestedCameraHz":'));
      final RegExpMatch? frameIngress = RegExp(
        r'public func consume\(permit: FrameIngressPermit\) -> Bool \{([\s\S]*?)\n  \}',
      ).firstMatch(feederSource);
      expect(frameIngress, isNotNull);
      expect(frameIngress!.group(1), isNot(contains('requestedCameraHz')));
      expect(frameIngress.group(1), isNot(contains('cameraPeriod')));
      expect(
        feederSource,
        isNot(contains('lastAdmittedCameraTimestamp')),
        reason:
            'every capacity-admitted ARFrame must reach FIFO ingress without native cadence sampling',
      );
      expect(feederSource, isNot(contains('cameraRateSampledOut')));
      expect(
        feederSource,
        contains(
          '"cameraAdmissionPolicy": '
          '"bounded-permit-no-cadence-sampling"',
        ),
      );
      expect(
        feederSource,
        contains('box-nxn-half-up-v1'),
        reason:
            'native may mechanically dispatch only the Dart-selected formula',
      );
      expect(feederSource, isNot(contains('kVioDownsampleFactor')));
      expect(feederSource, isNot(contains('vioDownsampleFactorForDart')));
      expect(
        recorderSource,
        contains(
          "const String kVioShadowDownsampleFormula =\n"
          "    kVioShadowDownsampleFormulaBoxNxnHalfUpV1;",
        ),
      );
      expect(
        recorderSource,
        contains("'downsampleFormula': kVioShadowDownsampleFormula"),
      );
      expect(
        recorderSource,
        contains("'schema': 'pw.vio.shadow-run-input-descriptor/4'"),
      );
    },
  );

  test('camera timestamps fail closed before pixel work or the XRSLAM C ABI', () {
    final String source = feeder.readAsStringSync();
    final RegExpMatch? frameOffer = RegExp(
      r'public func tryOfferFrame\(frame: ARFrame\) -> FrameIngressPermit\? \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    final RegExpMatch? frameIngress = RegExp(
      r'public func consume\(permit: FrameIngressPermit\) -> Bool \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(frameOffer, isNotNull);
    expect(frameIngress, isNotNull);
    final String offerBody = frameOffer!.group(0)!;
    final String ingressBody = frameIngress!.group(0)!;
    final int offerFiniteGuard = offerBody.indexOf(
      'guard frame.timestamp.isFinite else',
    );
    final int admission = offerBody.indexOf('admissionGate.enter()');
    final int finiteGuard = ingressBody.indexOf(
      'guard permit.timestamp.isFinite',
    );
    final int pixelLock = ingressBody.indexOf('CVPixelBufferLockBaseAddress');
    final int nativePush = source.indexOf(
      'PWXrslamTransportPushCameraAndRunRaw(',
    );
    expect(offerFiniteGuard, greaterThanOrEqualTo(0));
    expect(offerFiniteGuard, lessThan(admission));
    expect(
      offerBody.indexOf('grayFramePool.tryAcquire()'),
      lessThan(offerBody.indexOf('let pixelBuffer = frame.capturedImage')),
    );
    expect(finiteGuard, greaterThanOrEqualTo(0));
    expect(finiteGuard, lessThan(pixelLock));
    expect(
      source.indexOf('guard frame.timestamp.isFinite else'),
      lessThan(nativePush),
    );
    expect(
      ingressBody.substring(finiteGuard, pixelLock),
      allOf(
        contains('rejectPreparedImage(reason: .invalidInput)'),
        contains('return false'),
      ),
    );
    expect(source, contains('pending.timestamp,'));
    expect(source, contains('lastImageT = pending.timestamp'));
    expect(source, isNot(contains('pending.timestamp > lastImageT')));
    expect(source, isNot(contains('pending.timestamp > lastAccT')));
    expect(source, isNot(contains('pending.timestamp > lastGyroT')));
    expect(
      source,
      contains('rc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue)'),
    );
    expect(
      source,
      contains('accRc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue)'),
    );
    expect(
      source,
      contains('gyroRc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue)'),
    );
    expect(source, contains('case nonMonotonic = "non_monotonic"'));
  });

  test('pixel-buffer lock failure rejects without reading or unlocking', () {
    final String source = feeder.readAsStringSync();
    final RegExpMatch? frameIngress = RegExp(
      r'public func consume\(permit: FrameIngressPermit\) -> Bool \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(frameIngress, isNotNull);
    final String body = frameIngress!.group(0)!;
    final int lockCall = body.indexOf(
      'let pixelLockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)',
    );
    final int lockGuard = body.indexOf(
      'guard pixelLockStatus == kCVReturnSuccess else',
    );
    final int unlock = body.indexOf(
      'defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }',
    );
    final int baseRead = body.indexOf('CVPixelBufferGetBaseAddressOfPlane');
    expect(lockCall, greaterThanOrEqualTo(0));
    expect(lockGuard, greaterThan(lockCall));
    expect(unlock, greaterThan(lockGuard));
    expect(baseRead, greaterThan(unlock));
    expect(
      body.substring(lockGuard, unlock),
      allOf(
        contains('rejectPreparedImage(reason: .invalidInput)'),
        contains('return false'),
      ),
    );
  });

  test(
    'failed XRSLAMCreate closes and seals its admission generation before rc0',
    () {
      final String source = feeder.readAsStringSync();
      expect(source, contains('private func closeFailedCreateGeneration'));
      expect(
        source,
        contains('admissionGate.beginRejecting(generation: epoch)'),
      );
      expect(source, contains('closeIngressForStop(generation: epoch)'));
      expect(
        source,
        contains('finishSealedStopOnCoreQueue(generation: epoch)'),
      );
      expect(
        source,
        contains('shouldCloseFailedCreate = self.closeFailedCreateGeneration('),
      );
      expect(
        source,
        contains(
          'if shouldCloseFailedCreate {\n'
          '        self.closeIngressForStop(generation: epoch)',
        ),
      );
      expect(source, isNot(contains('completionRc')));
      final RegExpMatch? gate = RegExp(
        r'private final class AdmissionGate \{([\s\S]*?)\n  \}\n\n  private let admissionGate',
      ).firstMatch(source);
      expect(gate, isNotNull);
      expect(gate!.group(1), contains('guard old & Self.activeMask == 0,'));
      expect(
        gate.group(1),
        contains('Phase.sealed.rawValue else'),
        reason: 'start may prepare only after the old generation is sealed',
      );
      expect(
        gate.group(1),
        isNot(contains('Self.replace(&packed, with: token)')),
        reason: 'a new generation must never overwrite active callback leases',
      );

      final RegExpMatch? closure = RegExp(
        r'private func closeFailedCreateGeneration[\s\S]*?\n  \}',
      ).firstMatch(source);
      expect(closure, isNotNull);
      expect(closure!.group(0), contains('transitionLocked(to: .stopping)'));
      expect(
        closure.group(0),
        isNot(contains('transitionLocked(to: .stopped)')),
        reason: 'only the sealed terminal path may expose stopped',
      );
      final RegExpMatch? closeMarker = RegExp(
        r'private func closeIngressForStop\(generation: Int\) \{([\s\S]*?)\n  \}',
      ).firstMatch(source);
      expect(closeMarker, isNotNull);
      expect(
        closeMarker!.group(1),
        contains('admissionGate.sealWhenQuiescent(generation: generation)'),
      );
      expect(closeMarker.group(1), contains('self.coreQueue.async'));
      expect(closeMarker.group(1), contains('self.ingressClosed = true'));
    },
  );

  test(
    'snapshot exports health attribution lifecycle pose and transient pair fields',
    () {
      final String source = feeder.readAsStringSync();
      for (final String field in <String>[
        'coreHealthAvailable',
        'shadowOverflowDrops',
        'queueBacklog',
        'stateTransitions',
        'poseObservations',
        'rawStateCallCompleted',
        'rawCameraPoseCallCompleted',
        'rawXrslamState',
        'observedAtUptimeSeconds',
        'enqueuedAtUptimeSeconds',
        'sessionStartedAtUptimeSeconds',
        'sensorTimestamp',
        'xrslamPoseTimestamp',
        'referenceTrackingState',
        'referenceTrackingReason',
        'referenceWorldFromCamera',
        'xrslamWorldFromCamera',
        'qx',
        'qy',
        'qz',
        'qw',
        'tx',
        'ty',
        'tz',
        'PWXrslamSHA256',
        'UNSTAMPED',
      ]) {
        expect(source, contains('"$field"'), reason: 'missing $field');
      }
      expect(source, isNot(contains('"poseValidCount"')));
      expect(source, isNot(contains('"poseNoNewCount"')));
      expect(source, isNot(contains('"poseDegenerateCount"')));
      expect(source, isNot(contains('"initialized"')));
      expect(source, isNot(contains('exportedPoseTimestamp')));
      expect(source, isNot(contains('arkitAbsolutePose')));
      expect(source, isNot(contains('xrslamAbsolutePose')));
      expect(source, isNot(contains('arkitFromXrslam')));
      expect(source, isNot(contains('alignedTranslationSquaredSum')));
      expect(source, isNot(contains('alignedRotationSquaredSumDeg')));
      expect(source, isNot(contains('"alignedTranslationRmseM"')));
      expect(source, isNot(contains('"alignedRotationRmseDeg"')));
      expect(source, isNot(contains('simd_distance')));
      expect(source, isNot(contains('simd_inverse')));
      expect(source, contains('"schema": "pw.vio.shadow-native/6"'));
      for (final String identityField in <String>[
        'sessionId',
        'epoch',
        'queueCapacity',
        'cameraCapacity',
        'dropPolicy',
        'appVersion',
        'appBuild',
        'diagnosticBuildId',
        'productSourceManifestSha256',
        'dartAotSha256',
        'nativeHostUuid',
        'nativeFrameworkSha256',
        'xrslamUpstreamRevision',
        'xrslamBuildPatchSha256',
        'xrslamDestroyLifecyclePatchSha256',
        'xrslamZeroInlierMaskPatchSha256',
        'xrslamAlgorithmBranch',
        'xrslamIosEnabled',
        'xrslamThreadingEnabled',
        'xrslamCompileFlags',
        'opencvUpstreamRevision',
        'opencvBuildPatchSha256',
        'opencvSha256',
        'ceresUpstreamRevision',
        'ceresSha256',
        'spdlogCompatibilityPatchSha256',
        'effectiveConfigSha256',
        'inputIdentitySha256',
        'requestedCameraHz',
        'requestedAccelerometerHz',
        'requestedGyroscopeHz',
      ]) {
        expect(source, contains('"$identityField"'));
      }
    },
  );

  test(
    'Swift exposes independent raw IMU transport and no Apple fusion policy',
    () {
      final String source = timebase.readAsStringSync();
      final String feederSource = feeder.readAsStringSync();
      expect(
        source,
        contains(
          'startRawCoreMotionFeed(accelerometerHz: Double, gyroscopeHz: Double)',
        ),
      );
      expect(source, contains('shadowAccelerometerHz'));
      expect(source, contains('shadowGyroscopeHz'));
      expect(
        source,
        isNot(
          contains(
            'if motion.isAccelerometerActive && motion.isGyroActive { return true }',
          ),
        ),
      );
      expect(source, contains('startGyroUpdates(to: motionQueue)'));
      expect(source, contains('startAccelerometerUpdates(to: motionQueue)'));
      expect(
        source,
        isNot(contains('motion.isAccelerometerActive && motion.isGyroActive')),
      );
      expect(source, contains('return true'));
      expect(source, contains('scheduleRawMotionFailure(generation:'));
      expect(
        source,
        contains('if !started { rollbackShadowStartIntentLocked() }'),
      );
      expect(
        source.indexOf('startGyroUpdates(to: motionQueue)'),
        lessThan(source.indexOf('startAccelerometerUpdates(to: motionQueue)')),
      );
      expect(source, contains('noteCoreMotionAccelerometer'));
      expect(source, contains('noteCoreMotionGyroscope'));
      expect(source, isNot(contains('startDeviceMotionUpdates')));
      expect(source, isNot(contains('CMDeviceMotion')));
      expect(source, isNot(contains('userAcceleration')));
      expect(source, isNot(contains('.gravity')));
      expect(feederSource, contains('CMAccelerometerData'));
      expect(feederSource, contains('CMGyroData'));
      expect(feederSource, contains('accelerationScale: Double'));
      expect(feederSource, isNot(contains('-9.80665')));
      expect(feederSource, isNot(contains('CMDeviceMotion')));
      expect(feederSource, isNot(contains('userAcceleration')));
      expect(feederSource, isNot(contains('.gravity')));
      expect(source, isNot(contains('hz: Double = 100.0')));
      expect(source, isNot(contains('?? 100.0')));
      expect(source, isNot(contains('?? 10.0')));
      expect(source, isNot(contains('max(hz, 1.0)')));
      expect(source, isNot(contains('runHz')));
      expect(source, isNot(contains('accumulatedSleepSeconds')));
      expect(source, isNot(contains('sessionSleepDeltaSeconds')));
    },
  );

  test(
    'shadow start receipt distinguishes raw IMU startup failure from stale intent',
    () {
      final String source = timebase.readAsStringSync();
      expect(source, contains('raw-imu-start-failed'));
      expect(source, contains('stale-start-receipt'));
      expect(source, contains('direct-running-receipt-unavailable'));
      expect(
        source,
        contains('intentResult.failureReason'),
        reason: 'the wire reason must come from the exact failed boundary',
      );
    },
  );

  test(
    'raw timebase windows are drained per poll instead of inevitably overflowing',
    () {
      final String source = timebase.readAsStringSync();
      expect(source, contains('func drain() -> [PwVioRawTimestampSample]'));
      expect(source, contains('let samples = window.drain()'));
      expect(
        source,
        isNot(contains('func snapshot() -> [PwVioRawTimestampSample]')),
      );
      expect(source, contains('"rawSamplesDelivered"'));
      expect(source, contains('"rawSamplesBatchCount"'));
    },
  );

  test('slamStop seals raw timebase ingress before terminal delivery', () {
    final String source = timebase.readAsStringSync();
    expect(source, contains('private final class PwVioTimebaseIngressGate'));
    expect(source, contains('func closeWhenQuiescent('));
    expect(
      source,
      contains('let join = PwVioShadowStopJoin(completion: completion)'),
    );
    expect(source, contains('timebaseIngress.closeWhenQuiescent('));
    expect(source, contains('join.markTimebaseClosed()'));
    expect(source, isNot(contains('publishedTimebaseGeneration')));
  });
}
