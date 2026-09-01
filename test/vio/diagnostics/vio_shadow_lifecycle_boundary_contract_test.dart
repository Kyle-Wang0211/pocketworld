import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final File feeder = File('ios/Runner/PwVioSlamFeeder.swift');
  final File recorder = File(
    'lib/vio/diagnostics/vio_diagnostics_recorder.dart',
  );

  test(
    'frame permit reserves every cross-queue capacity before pixel retention',
    () {
      final String source = feeder.readAsStringSync();
      expect(source, contains('public final class FrameIngressPermit'));
      expect(
        source,
        contains('private static let maxOutstandingCameraIngress = 2'),
      );
      expect(
        source,
        contains(
          'public func tryOfferFrame(frame: ARFrame) -> FrameIngressPermit?',
        ),
      );
      expect(
        source,
        contains('public func consume(permit: FrameIngressPermit) -> Bool'),
      );
      final RegExpMatch? offer = RegExp(
        r'public func tryOfferFrame\(frame: ARFrame\) -> FrameIngressPermit\? \{([\s\S]*?)\n  \}',
      ).firstMatch(source);
      expect(offer, isNotNull);
      final String body = offer!.group(1)!;
      final int generation = body.indexOf('admissionGate.enter()');
      final int fullFrame = body.indexOf('cameraIngressLimiter.tryAcquire()');
      final int ringWork = body.indexOf('workSlotLimiter.tryAcquire()');
      final int graySlot = body.indexOf('grayFramePool.tryAcquire()');
      final int sequence = body.indexOf('ingressSequence.incrementAndValue(');
      final int pixelRetention = body.indexOf(
        'let pixelBuffer = frame.capturedImage',
      );
      expect(generation, greaterThanOrEqualTo(0));
      expect(generation, lessThan(fullFrame));
      expect(fullFrame, lessThan(ringWork));
      expect(ringWork, lessThan(graySlot));
      expect(graySlot, lessThan(sequence));
      expect(sequence, lessThan(pixelRetention));
      expect(body, contains('graySlot: grayReservation.slot'));
      expect(body, contains('grayBuffer: grayReservation.buffer'));
      expect(body, contains('pixelBuffer: pixelBuffer'));
      expect(body, isNot(contains('lock.lock()')));
      expect(body, isNot(contains('PWXrslamTransportPrepareGrayBoxNxN')));
      expect(body, isNot(contains('grayFramePool.prepare()')));
      expect(body, isNot(contains('UnsafeMutablePointer<UInt8>.allocate')));
      expect(body, isNot(contains('DispatchQueue')));
    },
  );

  test(
    'every capacity failure rolls back before sequence and has an exact reason',
    () {
      final String source = feeder.readAsStringSync();
      final RegExpMatch? offer = RegExp(
        r'public func tryOfferFrame\(frame: ARFrame\) -> FrameIngressPermit\? \{([\s\S]*?)\n  \}',
      ).firstMatch(source);
      final RegExpMatch? consume = RegExp(
        r'public func consume\(permit: FrameIngressPermit\) -> Bool \{([\s\S]*?)\n  \}',
      ).firstMatch(source);
      expect(offer, isNotNull);
      expect(consume, isNotNull);

      final String offerBody = offer!.group(1)!;
      final int acceptedSequence = offerBody.indexOf(
        'ingressSequence.incrementAndValue(',
      );
      for (final String reason in <String>[
        '.fullFrame',
        '.workRing',
        '.grayPool',
      ]) {
        final int rejection = offerBody.indexOf(
          'recordCameraCapacityRejection($reason, generation: lease.generation)',
        );
        expect(rejection, greaterThanOrEqualTo(0));
        expect(rejection, lessThan(acceptedSequence));
      }
      expect(source, contains('"full_frame": cameraFullFrame'));
      expect(source, contains('"work_ring": cameraWorkRing'));
      expect(source, contains('"gray_pool": cameraGrayPool'));

      final int fullFrameGuard = offerBody.indexOf(
        'guard cameraIngressLimiter.tryAcquire() else',
      );
      final int workGuard = offerBody.indexOf(
        'guard workSlotLimiter.tryAcquire() else',
      );
      final int grayGuard = offerBody.indexOf(
        'guard let grayReservation = grayFramePool.tryAcquire() else',
      );
      final int pixelRetention = offerBody.indexOf(
        'let pixelBuffer = frame.capturedImage',
      );
      final String fullFrameFailure = offerBody.substring(
        fullFrameGuard,
        workGuard,
      );
      final String workFailure = offerBody.substring(workGuard, grayGuard);
      final String grayFailure = offerBody.substring(
        grayGuard,
        acceptedSequence,
      );
      final String sequenceFailure = offerBody.substring(
        acceptedSequence,
        pixelRetention,
      );
      expect(fullFrameFailure, contains('admissionGate.leave(lease)'));
      expect(workFailure, contains('cameraIngressLimiter.release()'));
      expect(workFailure, contains('admissionGate.leave(lease)'));
      expect(grayFailure, contains('workSlotLimiter.release()'));
      expect(grayFailure, contains('cameraIngressLimiter.release()'));
      expect(grayFailure, contains('admissionGate.leave(lease)'));
      expect(
        sequenceFailure,
        contains('grayFramePool.release(grayReservation.slot)'),
      );
      expect(sequenceFailure, contains('workSlotLimiter.release()'));
      expect(sequenceFailure, contains('cameraIngressLimiter.release()'));
      expect(sequenceFailure, contains('admissionGate.leave(lease)'));

      final String consumeBody = consume!.group(1)!;
      expect(consumeBody, isNot(contains('requestedCameraHz')));
      expect(consumeBody, isNot(contains('cameraPeriod')));
      expect(consumeBody, isNot(contains('cameraRateSampledOut')));
      expect(consumeBody, isNot(contains('lastAdmittedCameraTimestamp')));
      expect(source, isNot(contains('cameraRateSampledOut')));
      expect(source, isNot(contains('lastAdmittedCameraTimestamp')));
      expect(
        source,
        contains(
          '"cameraAdmissionPolicy": '
          '"bounded-permit-no-cadence-sampling"',
        ),
      );
      expect(
        source,
        contains('out["cameraIngressCapacityRejections"] = cameraIngressFull'),
      );
    },
  );

  test('accepted camera timestamps remain unchanged in the FIFO work ring', () {
    final String source = feeder.readAsStringSync();
    final RegExpMatch? consume = RegExp(
      r'public func consume\(permit: FrameIngressPermit\) -> Bool \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(consume, isNotNull);
    final String body = consume!.group(1)!;
    expect(body, contains('permit.timestamp.isFinite'));
    expect(body, contains('timestamp: permit.timestamp'));
    expect(body, contains('ingressSequence: permit.sequence'));
    expect(
      body.indexOf('timestamp: permit.timestamp'),
      lessThan(body.indexOf('let admitted = admit(')),
    );
    expect(source, contains('pendingWork[pendingTail] = work'));
    expect(source, contains('pendingWork[pendingHead] = nil'));
    expect(source, isNot(contains('pendingWork.sort')));
    expect(source, isNot(contains('pendingWork.removeLast')));
  });

  test(
    'slow consumer bounds hundreds of retained frames and drains every lease',
    () {
      final String source = feeder.readAsStringSync();
      int capacity(String name) => int.parse(
        RegExp(
          'private static let $name = ([0-9]+)',
        ).firstMatch(source)!.group(1)!,
      );

      final int fullFrameCapacity = capacity('maxOutstandingCameraIngress');
      final int grayCapacity = capacity('maxRetainedImages');
      final int workCapacity = capacity('maxQueuedWork');
      var retainedPixelBuffers = 0;
      var retainedGraySlots = 0;
      var retainedWorkSlots = 0;
      var maxPixelBuffers = 0;
      var maxGraySlots = 0;
      var maxWorkSlots = 0;
      var accepted = 0;
      var grayRejected = 0;

      // Ingress consumes each two-frame callback burst, but the algorithm is
      // deliberately stalled. Transferred gray/work leases remain resident.
      for (var offered = 0; offered < 500; offered += fullFrameCapacity) {
        var burstAccepted = 0;
        for (var i = 0; i < fullFrameCapacity && offered + i < 500; i += 1) {
          if (retainedPixelBuffers >= fullFrameCapacity ||
              retainedWorkSlots >= workCapacity ||
              retainedGraySlots >= grayCapacity) {
            if (retainedGraySlots >= grayCapacity) grayRejected += 1;
            continue;
          }
          retainedPixelBuffers += 1;
          retainedWorkSlots += 1;
          retainedGraySlots += 1;
          burstAccepted += 1;
          accepted += 1;
          maxPixelBuffers = retainedPixelBuffers > maxPixelBuffers
              ? retainedPixelBuffers
              : maxPixelBuffers;
          maxGraySlots = retainedGraySlots > maxGraySlots
              ? retainedGraySlots
              : maxGraySlots;
          maxWorkSlots = retainedWorkSlots > maxWorkSlots
              ? retainedWorkSlots
              : maxWorkSlots;
        }
        // Successful consumer transfers gray/work ownership to FIFO and releases
        // only the full-resolution pixel-buffer lease.
        retainedPixelBuffers -= burstAccepted;
      }

      expect(accepted, grayCapacity);
      expect(grayRejected, 500 - grayCapacity);
      expect(maxPixelBuffers, fullFrameCapacity);
      expect(maxGraySlots, grayCapacity);
      expect(maxWorkSlots, grayCapacity);
      retainedGraySlots -= accepted;
      retainedWorkSlots -= accepted;
      expect(retainedPixelBuffers, 0);
      expect(retainedGraySlots, 0);
      expect(retainedWorkSlots, 0);
    },
  );

  test('permit and transferred work each have exactly one release owner', () {
    final String source = feeder.readAsStringSync();
    final RegExpMatch? permit = RegExp(
      r'public final class FrameIngressPermit \{([\s\S]*?)\n  \}\n\n  private enum ShadowState',
    ).firstMatch(source);
    final RegExpMatch? consume = RegExp(
      r'public func consume\(permit: FrameIngressPermit\) -> Bool \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(permit, isNotNull);
    expect(consume, isNotNull);
    expect(permit!.group(1), contains('finish(reservationsTransferred: Bool)'));
    expect(
      permit.group(1),
      contains('releaseBody(false, reservationsTransferred)'),
    );
    expect(permit.group(1), contains('releaseBody(true, false)'));
    expect(consume!.group(1), contains('var reservationsTransferred = false'));
    expect(
      consume.group(1),
      contains(
        'defer {\n'
        '      permit.finish(\n'
        '        reservationsTransferred: reservationsTransferred\n'
        '      )\n'
        '    }',
      ),
    );
    expect(consume.group(1), contains('reservationsTransferred = admitted'));
    expect(consume.group(1), isNot(contains('grayFramePool.release(')));
    expect(consume.group(1), isNot(contains('workSlotLimiter.release()')));
    expect(
      source,
      contains(
        'if !reservationsTransferred {\n'
        '        grayPool.release(grayReservation.slot)\n'
        '        workLimiter.release()\n'
        '      }',
      ),
    );
    expect(source, contains('workSlotLimiter.release()'));
    expect(
      source,
      contains('defer { grayFramePool.release(pending.graySlot) }'),
    );
    final RegExpMatch? drain = RegExp(
      r'private func drain\(epoch: Int\) \{([\s\S]*?)\n  \}\n\n  /// The close marker',
    ).firstMatch(source);
    expect(drain, isNotNull);
    expect(
      'workSlotLimiter.release()'.allMatches(drain!.group(1)!),
      hasLength(3),
      reason:
          'empty-slot defense, stale work, and processed work each release one transferred slot',
    );
  });

  test('Create publishes admission only after native success', () {
    final String source = feeder.readAsStringSync();
    final RegExpMatch? begin = RegExp(
      r'private func beginStartLocked\([\s\S]*?\n  \}',
    ).firstMatch(source);
    final RegExpMatch? create = RegExp(
      r'private func scheduleCreate\([\s\S]*?\n  \}',
    ).firstMatch(source);
    expect(begin, isNotNull);
    expect(create, isNotNull);
    expect(
      begin!.group(0),
      contains('admissionGate.prepare(generation: epoch)'),
    );
    expect(begin.group(0), isNot(contains('admissionGate.open(')));
    expect(
      create!.group(0),
      contains('if self.state == .starting, self.created'),
    );
    expect(create.group(0), contains('startCountersRc == 0'));
    expect(create.group(0), contains('startCounters.lifecycle_generation > 0'));
    expect(create.group(0), contains('self.grayFramePool.prepare()'));
    expect(create.group(0), contains('admissionGate.open(generation: epoch)'));
    expect(
      create.group(0)!.indexOf('self.grayFramePool.prepare()'),
      lessThan(
        create.group(0)!.indexOf('admissionGate.open(generation: epoch)'),
      ),
      reason:
          'gray storage must be ready before ARSession can acquire a permit',
    );
  });

  test('offer sequence is evidence and never reorders serial ingress', () {
    final String source = feeder.readAsStringSync();
    expect(source, contains('ingressSequence: permit.sequence'));
    expect(source, contains('ingressSequence: sequence'));
    expect(
      source,
      isNot(
        contains('unscopedWork.ingressSequence > lastAdmittedIngressSequence'),
      ),
    );
  });

  test('stop seals accepted ingress before drain and terminal receipt', () {
    final String source = feeder.readAsStringSync();
    expect(source, contains('private var ingressClosed = false'));
    expect(source, contains('private var terminalIngressSequence: UInt64 = 0'));
    expect(source, contains('closeIngressForStop(generation: epoch)'));
    expect(source, contains('guard ingressClosed else'));
    expect(source, contains('"terminalIngressSequence"'));
    expect(source, contains('"ingressClosed"'));
    final int close = source.indexOf('closeIngressForStop(generation: epoch)');
    final int destroy = source.indexOf(
      'PWXrslamTransportDestroyWithReceipt(&destroyReceipt)',
    );
    expect(close, greaterThanOrEqualTo(0));
    expect(close, lessThan(destroy));
    final RegExpMatch? finish = RegExp(
      r'private func finishSealedStopOnCoreQueue\(generation: Int\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(finish, isNotNull);
    final String finishBody = finish!.group(1)!;
    final int workEmpty = finishBody.indexOf('workSlotLimiter.value == 0');
    final int grayEmpty = finishBody.indexOf('grayFramePool.activeCount == 0');
    final int nativeDestroy = finishBody.indexOf(
      'PWXrslamTransportDestroyWithReceipt(&destroyReceipt)',
    );
    expect(workEmpty, greaterThanOrEqualTo(0));
    expect(grayEmpty, greaterThanOrEqualTo(0));
    expect(workEmpty, lessThan(nativeDestroy));
    expect(grayEmpty, lessThan(nativeDestroy));
    expect(
      source,
      contains(
        'terminalIngressSequence == terminalIngressCompleted &&\n'
        '      cameraIngressLimiter.value == 0 &&\n'
        '      workSlotLimiter.value == 0 &&\n'
        '      grayFramePool.activeCount == 0',
      ),
      reason:
          'a stop racing offered/consuming permits cannot freeze a receipt early',
    );
    expect(source, contains('"outstandingWorkReservations"'));
    expect(source, contains('"reservedGrayFrameSlots"'));
    expect(
      source,
      contains(
        'workSlotLimiter.value == 0 && grayFramePool.activeCount == 0 &&',
      ),
      reason:
          'terminalComplete freezes only after every transferred lease drains',
    );
  });

  test(
    'pose observation carrier is fixed-capacity and invalidates overflow',
    () {
      final String source = feeder.readAsStringSync();
      expect(source, contains('private static let maxPoseObservations = 128'));
      expect(source, contains('private struct PoseObservationRing'));
      expect(source, contains('capacity: PwVioSlamFeeder.maxPoseObservations'));
      expect(
        source,
        contains('guard poseObservations.append(observation) else'),
      );
      expect(
        source,
        contains('invalidateRunLocked(reason: "pose_observation_full")'),
      );
      expect(
        source,
        contains('"poseObservationCapacity": Self.maxPoseObservations'),
      );
      expect(source, isNot(contains('poseObservations: [[String: Any]] = []')));
    },
  );

  test('dispose-safe stop request remains serialized with the next start', () {
    final String source = recorder.readAsStringSync();
    expect(source, contains('void stopInBackground()'));
    final RegExpMatch? backgroundStop = RegExp(
      r'void stopInBackground\(\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(backgroundStop, isNotNull);
    expect(
      backgroundStop!.group(1),
      contains('_enqueueLifecycle(_stopSerialized)'),
    );
    expect(backgroundStop.group(1), contains('unawaited('));
  });
}
