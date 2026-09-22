import 'dart:collection';

import 'manual_capture_ledger.dart';
import 'sfm_feed_queue.dart';
import 'sfm_live_recon.dart';

/// Why a finalized reconstruction is not yet safe to publish.
///
/// This gate never repairs, curates, or removes a frame. A failure keeps the
/// durable capture evidence intact so the reconstruction can be retried.
enum SfmRegistrationPublishFailureCode {
  noAcceptedFrames,
  durableQueueBlocked,
  durableQueueNotDrained,
  durableReplayRequired,
  durableAcceptedCountMismatch,
  durableSequenceMismatch,
  durableCaptureJobIdInvalid,
  durableCaptureJobIdDuplicate,
  durableJobMappingMismatch,
  durableNativeImageIdInvalid,
  durableNativeImageIdDuplicate,
  ledgerClosureIncomplete,
  ledgerAcceptedCountMismatch,
  ledgerNativeImageIdInvalid,
  snapshotNotRefined,
  snapshotPoseLayoutInvalid,
  snapshotPoseInvalid,
  snapshotNativeImageIdDuplicate,
  snapshotContainsUnregisteredFrame,
  snapshotRegisteredCountMismatch,
  nativeImageIdSetMismatch,
}

final class SfmRegistrationPublishFailure {
  const SfmRegistrationPublishFailure(this.code, this.message);

  final SfmRegistrationPublishFailureCode code;
  final String message;

  @override
  String toString() => '${code.name}: $message';
}

/// Immutable evidence returned by the fail-closed 100% registration gate.
final class SfmRegistrationPublishDecision {
  SfmRegistrationPublishDecision._({
    required this.acceptedCount,
    required this.durableAcceptedHighWatermark,
    required this.durableFedCount,
    required this.snapshotPoseCount,
    required this.snapshotRegisteredCount,
    required Set<int> ledgerNativeImageIds,
    required Set<int> durableNativeImageIds,
    required Set<int> snapshotNativeImageIds,
    required Map<String, int> durableJobToNativeImageId,
    required List<SfmRegistrationPublishFailure> failures,
    required this.ledgerClosure,
  }) : ledgerNativeImageIds = UnmodifiableSetView(
         SplayTreeSet<int>.of(ledgerNativeImageIds),
       ),
       durableNativeImageIds = UnmodifiableSetView(
         SplayTreeSet<int>.of(durableNativeImageIds),
       ),
       snapshotNativeImageIds = UnmodifiableSetView(
         SplayTreeSet<int>.of(snapshotNativeImageIds),
       ),
       durableJobToNativeImageId = UnmodifiableMapView(
         SplayTreeMap<String, int>.of(durableJobToNativeImageId),
       ),
       failures = List<SfmRegistrationPublishFailure>.unmodifiable(failures);

  /// Current-epoch active accepted jobs. User tombstones enter this denominator
  /// only after a clean rebuild proves a new epoch without them.
  final int acceptedCount;

  /// Historical queue sequence high-water mark. This is evidence, not the
  /// current denominator: user-authorized deletion never rewinds it.
  final int durableAcceptedHighWatermark;
  final int durableFedCount;
  final int snapshotPoseCount;
  final int snapshotRegisteredCount;
  final Set<int> ledgerNativeImageIds;
  final Set<int> durableNativeImageIds;
  final Set<int> snapshotNativeImageIds;
  final Map<String, int> durableJobToNativeImageId;
  final List<SfmRegistrationPublishFailure> failures;
  final ManualCaptureClosureReport ledgerClosure;

  bool get canPublish => failures.isEmpty;

  /// Throws before any persist/final-artifact commit side effect.
  void requireCanPublish() {
    if (!canPublish) throw SfmRegistrationPublishBlocked(this);
  }
}

final class SfmRegistrationPublishBlocked extends StateError {
  SfmRegistrationPublishBlocked(this.decision)
    : super(
        '100% registration publish gate refused the artifact: '
        '${decision.failures.join('; ')}',
      );

  final SfmRegistrationPublishDecision decision;
}

/// Proves that every durable accepted frame is the same exact frame represented
/// by the ledger's current reconstruction epoch and by one registered final
/// pose row.
///
/// [finalRegistration] is deliberately required: callers must bind the final
/// artifact identity/evidence token and current epoch mapping instead of
/// deriving success from counts alone. Call [requireCanPublish] on the result
/// immediately before sparse artifact persistence/commit.
SfmRegistrationPublishDecision evaluateSfmRegistrationPublishGate({
  required SfmDurableFeedQueue durableQueue,
  required ManualCaptureLedger ledger,
  required FinalRegistrationObservation finalRegistration,
  required SfmLiveSnapshot snapshot,
}) {
  final failures = <SfmRegistrationPublishFailure>[];
  void fail(SfmRegistrationPublishFailureCode code, String message) {
    failures.add(SfmRegistrationPublishFailure(code, message));
  }

  final fedRecords = durableQueue.fedRecords;
  final ledgerClosure = ledger.closureReport(
    finalRegistration: finalRegistration,
  );
  final acceptedCount = ledgerClosure.expected.length;
  final durableAcceptedHighWatermark = durableQueue.nextSequence;

  if (acceptedCount == 0) {
    fail(
      SfmRegistrationPublishFailureCode.noAcceptedFrames,
      'an empty capture cannot establish a registration denominator',
    );
  }
  if (durableQueue.blocked) {
    fail(
      SfmRegistrationPublishFailureCode.durableQueueBlocked,
      'durable feed queue is blocked: ${durableQueue.blockReason}',
    );
  }
  if (durableQueue.spoolDepth != 0) {
    fail(
      SfmRegistrationPublishFailureCode.durableQueueNotDrained,
      '${durableQueue.spoolDepth} accepted frames remain pending',
    );
  }
  if (durableQueue.nativeReplayRequired) {
    fail(
      SfmRegistrationPublishFailureCode.durableReplayRequired,
      'native replay remains required',
    );
  }
  if (durableAcceptedHighWatermark < acceptedCount) {
    fail(
      SfmRegistrationPublishFailureCode.durableAcceptedCountMismatch,
      'durable accepted high-water mark=$durableAcceptedHighWatermark is '
      'smaller than current active denominator=$acceptedCount',
    );
  }
  if (fedRecords.length != acceptedCount) {
    fail(
      SfmRegistrationPublishFailureCode.durableAcceptedCountMismatch,
      'durable current-epoch fed rows=${fedRecords.length} but active '
      'denominator=$acceptedCount; historical/deleted rows are not '
      'publishable evidence',
    );
  }

  final ledgerJobToNativeId = <String, int>{};
  final ledgerNativeIds = <int>{};
  for (final entry in finalRegistration.jobToNativeImageId.entries) {
    final nativeId = _parseCanonicalNativeImageId(entry.value);
    if (nativeId == null) {
      fail(
        SfmRegistrationPublishFailureCode.ledgerNativeImageIdInvalid,
        'job ${entry.key} has unverifiable native image ID ${entry.value}',
      );
      continue;
    }
    // FinalRegistrationObservation already rejects aliases. Keep the set add
    // check here so the gate remains explicit if that type evolves.
    if (!ledgerNativeIds.add(nativeId)) {
      fail(
        SfmRegistrationPublishFailureCode.ledgerNativeImageIdInvalid,
        'native image ID ${entry.value} is not one-to-one',
      );
    }
    ledgerJobToNativeId[entry.key] = nativeId;
  }

  final seenSequences = <int>{};
  final durableRecordsByJob = <String, List<({int nativeId, int sequence})>>{};
  for (final record in fedRecords) {
    if (record.sequence < 0 ||
        record.sequence >= durableAcceptedHighWatermark ||
        !seenSequences.add(record.sequence)) {
      fail(
        SfmRegistrationPublishFailureCode.durableSequenceMismatch,
        'fed record ${record.id} has invalid/duplicate sequence '
        '${record.sequence} for historical high-water mark '
        '$durableAcceptedHighWatermark',
      );
    }
    final captureJobId = record.fedMeta['captureJobId'];
    if (captureJobId is! String || !_isNormalizedCaptureJobId(captureJobId)) {
      fail(
        SfmRegistrationPublishFailureCode.durableCaptureJobIdInvalid,
        'fed record ${record.id} has no normalized captureJobId',
      );
      continue;
    }
    if (!ledgerJobToNativeId.containsKey(captureJobId)) {
      fail(
        SfmRegistrationPublishFailureCode.durableJobMappingMismatch,
        'fed record ${record.id} belongs to non-active/historical job '
        '$captureJobId',
      );
    }
    final nativeId = record.fedMeta['nativeFrameId'];
    if (nativeId is! int || nativeId < 0) {
      fail(
        SfmRegistrationPublishFailureCode.durableNativeImageIdInvalid,
        'fed record ${record.id} has no non-negative integer nativeFrameId',
      );
      continue;
    }
    durableRecordsByJob
        .putIfAbsent(captureJobId, () => <({int nativeId, int sequence})>[])
        .add((nativeId: nativeId, sequence: record.sequence));
  }

  final durableJobToNativeId = <String, int>{};
  final durableNativeIds = <int>{};
  for (final entry in ledgerJobToNativeId.entries) {
    final records = durableRecordsByJob[entry.key] ?? const [];
    final exact = records
        .where((record) => record.nativeId == entry.value)
        .toList(growable: false);
    if (exact.isEmpty) {
      fail(
        SfmRegistrationPublishFailureCode.durableJobMappingMismatch,
        'active job ${entry.key} has no durable ACK mapping to '
        'nativeFrameId ${entry.value}',
      );
      continue;
    }
    if (records.length > 1) {
      fail(
        SfmRegistrationPublishFailureCode.durableCaptureJobIdDuplicate,
        'active job ${entry.key} has ${records.length} durable ACK records',
      );
      continue;
    }
    if (records.single.nativeId != entry.value) {
      fail(
        SfmRegistrationPublishFailureCode.durableJobMappingMismatch,
        'job ${entry.key} durable nativeFrameId '
        '${records.single.nativeId} != current epoch ${entry.value}',
      );
      continue;
    }
    durableJobToNativeId[entry.key] = entry.value;
    if (!durableNativeIds.add(entry.value)) {
      fail(
        SfmRegistrationPublishFailureCode.durableNativeImageIdDuplicate,
        'nativeFrameId ${entry.value} is owned by multiple active jobs',
      );
    }
  }

  if (!ledgerClosure.isComplete) {
    fail(
      SfmRegistrationPublishFailureCode.ledgerClosureIncomplete,
      _describeIncompleteClosure(ledgerClosure),
    );
  }
  if (ledgerClosure.expected.length != ledgerJobToNativeId.length) {
    fail(
      SfmRegistrationPublishFailureCode.ledgerAcceptedCountMismatch,
      'ledger expected=${ledgerClosure.expected.length} but current epoch '
      'mapping has ${ledgerJobToNativeId.length} jobs',
    );
  }

  if (!snapshot.refined) {
    fail(
      SfmRegistrationPublishFailureCode.snapshotNotRefined,
      'LOCAL_READY/preview snapshots cannot be published as final',
    );
  }
  if (snapshot.posesPacked.length % 9 != 0) {
    fail(
      SfmRegistrationPublishFailureCode.snapshotPoseLayoutInvalid,
      'posesPacked length ${snapshot.posesPacked.length} is not divisible by 9',
    );
  }

  final snapshotNativeIds = <int>{};
  final completePoseRows = snapshot.posesPacked.length ~/ 9;
  for (var row = 0; row < completePoseRows; row++) {
    final offset = row * 9;
    final rawId = snapshot.posesPacked[offset];
    final registered = snapshot.posesPacked[offset + 1];
    var finite = true;
    for (var field = 0; field < 9; field++) {
      if (!snapshot.posesPacked[offset + field].isFinite) {
        finite = false;
        break;
      }
    }
    if (!finite ||
        rawId < 0 ||
        rawId > 9007199254740991 ||
        rawId != rawId.truncateToDouble()) {
      fail(
        SfmRegistrationPublishFailureCode.snapshotPoseInvalid,
        'pose row $row has non-finite fields or an invalid frame ID',
      );
      continue;
    }
    final nativeId = rawId.toInt();
    if (!snapshotNativeIds.add(nativeId)) {
      fail(
        SfmRegistrationPublishFailureCode.snapshotNativeImageIdDuplicate,
        'native frame $nativeId appears in multiple final pose rows',
      );
    }
    if (registered != 1.0) {
      fail(
        SfmRegistrationPublishFailureCode.snapshotContainsUnregisteredFrame,
        'native frame $nativeId is not registered (flag=$registered)',
      );
    }
  }

  if (snapshot.unregisteredFrameIds.isNotEmpty) {
    fail(
      SfmRegistrationPublishFailureCode.snapshotContainsUnregisteredFrame,
      'unregistered final frame IDs: ${snapshot.unregisteredFrameIds}',
    );
  }
  if (snapshot.registeredCount != acceptedCount ||
      snapshot.poseCount != acceptedCount) {
    fail(
      SfmRegistrationPublishFailureCode.snapshotRegisteredCountMismatch,
      'accepted=$acceptedCount, poses=${snapshot.poseCount}, '
      'registered=${snapshot.registeredCount}',
    );
  }

  if (!_setEquals(ledgerNativeIds, durableNativeIds) ||
      !_setEquals(ledgerNativeIds, snapshotNativeIds)) {
    fail(
      SfmRegistrationPublishFailureCode.nativeImageIdSetMismatch,
      'ledger=${_sorted(ledgerNativeIds)}, '
      'durable=${_sorted(durableNativeIds)}, '
      'snapshot=${_sorted(snapshotNativeIds)}',
    );
  }

  return SfmRegistrationPublishDecision._(
    acceptedCount: acceptedCount,
    durableAcceptedHighWatermark: durableAcceptedHighWatermark,
    durableFedCount: fedRecords.length,
    snapshotPoseCount: snapshot.poseCount,
    snapshotRegisteredCount: snapshot.registeredCount,
    ledgerNativeImageIds: ledgerNativeIds,
    durableNativeImageIds: durableNativeIds,
    snapshotNativeImageIds: snapshotNativeIds,
    durableJobToNativeImageId: durableJobToNativeId,
    failures: failures,
    ledgerClosure: ledgerClosure,
  );
}

int? _parseCanonicalNativeImageId(String value) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) return null;
  final parsed = int.tryParse(value);
  return parsed != null && parsed >= 0 ? parsed : null;
}

bool _isNormalizedCaptureJobId(String value) =>
    value.isNotEmpty &&
    value == value.trim() &&
    !value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

String _describeIncompleteClosure(ManualCaptureClosureReport report) {
  final pieces = <String>[];
  if (report.rebuildRequired) pieces.add('rebuild required');
  if (!report.finalRegistrationArtifactMatchesRebuild) {
    pieces.add('artifact does not match rebuild evidence');
  }
  if (!report.finalRegistrationEpochMatches) pieces.add('stale epoch');
  if (!report.finalRegistrationMappingMatchesCurrentEpoch) {
    pieces.add('job/native mapping differs from current epoch');
  }
  if (report.blockingJobIds.isNotEmpty) {
    pieces.add('blocking jobs=${report.blockingJobIds.toList()}');
  }
  for (final entry in report.missing.entries) {
    if (entry.value.isNotEmpty) {
      pieces.add('missing ${entry.key}=${entry.value.toList()}');
    }
  }
  for (final entry in report.extra.entries) {
    if (entry.value.isNotEmpty) {
      pieces.add('extra ${entry.key}=${entry.value.toList()}');
    }
  }
  return pieces.isEmpty ? 'ledger closure is incomplete' : pieces.join(', ');
}

bool _setEquals(Set<int> left, Set<int> right) =>
    left.length == right.length && left.containsAll(right);

List<int> _sorted(Set<int> values) => values.toList()..sort();
