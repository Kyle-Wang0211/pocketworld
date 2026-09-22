// The RECOVERY leg of the "a capture always ends up with a sparse cloud"
// guarantee.
//
// During capture, every keyframe's keypoints + matches are written into
// <captureDir>/sfm_live.db. The live finalize turns that into
// <captureDir>/sfm_sparse.ply. But finalize is minutes-scale and can be killed
// mid-flight — the user backgrounds the app, or a hot/large capture gets jetsam
// -ed under memory+thermal pressure — leaving a db but no PLY (the draft can't
// open its cloud). The in-session iOS-26 umbrella protects the FIRST attempt;
// this recovery helper is the safety net for when even that loses: an explicit
// user recovery action can find captures with a db but no PLY and re-run
// finalize STRAIGHT FROM THE DB
// (no frames needed — aether_sfm_create opens the existing db, RunIncremental
// reads keypoints/matches from it), on a now-cooler device, one at a time,
// under the umbrella. Idempotent + best-effort: a retry that still fails is left
// for the next launch, so output is guaranteed as long as the app runs again —
// it never depends on the user's capture timing or the device staying cool.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../dome/ar_pose.dart';
import '../dome/platform_pose_provider.dart';
import '../me/scan_record_store.dart';
import '../util/device_log.dart';
import 'colorize_pipeline.dart';
import 'capture_session.dart';
import 'floater_filter.dart';
import 'manual_capture_ledger.dart';
import 'representative_color.dart';
import 'sfm_feed_queue.dart';
import 'sfm_live_recon.dart';
import 'sfm_orphan_recovery.dart';
import 'sfm_registration_publish_gate.dart';
import 'sparse_ply.dart';
import 'telemetry_writer.dart';

const MethodChannel _arKitChannel = MethodChannel('aether_arkit');

bool _sweeping = false;
final Set<String> _detachedFinalizing = <String>{};
final Map<String, String> _captureReconstructionOwners = <String, String>{};

bool _claimCaptureReconstruction(String captureDir, String owner) {
  if (_captureReconstructionOwners.containsKey(captureDir)) return false;
  _captureReconstructionOwners[captureDir] = owner;
  return true;
}

void _releaseCaptureReconstruction(String captureDir, String owner) {
  if (_captureReconstructionOwners[captureDir] == owner) {
    _captureReconstructionOwners.remove(captureDir);
  }
}

/// 修2c【断点续跑入口】进行中的单 capture 恢复:captureDir → 完成 future。
/// 同卡重复点击/重进等待页时直接挂到同一个 future 上 —— 绝不为同一个
/// capture 起第二个 worker(与等待页重入契约同精神)。
final Map<String, Future<bool>> _resumeInFlight = <String, Future<bool>>{};

const String _finalCommitMarkerName = 'sfm_final_artifact_commit.json';
const String _finalCommitMarkerSchema = 'pw_sfm_final_artifact_commit_v1';

enum SfmFinalArtifactRecoveryState {
  complete,
  needsDurableCommit,
  needsRebuild,
}

class SfmFinalArtifactInspection {
  const SfmFinalArtifactInspection({
    required this.state,
    this.receipt,
    this.error,
  });

  final SfmFinalArtifactRecoveryState state;
  final SparsePersistReceipt? receipt;
  final Object? error;
}

/// Durable truth used by both the recovery sweep and the draft UI. A PLY path
/// alone is never completion: it must be a linked, refined sparse generation
/// and its replay-cleanup marker must name that exact generation.
Future<SfmFinalArtifactInspection> inspectSfmFinalArtifact(
  String captureDir,
) async {
  SparsePersistReceipt? receipt;
  try {
    receipt = await recoverSparsePublication(captureDir: captureDir);
  } catch (error) {
    return SfmFinalArtifactInspection(
      state: SfmFinalArtifactRecoveryState.needsRebuild,
      error: error,
    );
  }
  if (receipt == null || !receipt.refined) {
    return SfmFinalArtifactInspection(
      state: SfmFinalArtifactRecoveryState.needsRebuild,
      receipt: receipt,
    );
  }
  try {
    final persisted = await loadPersistedManualCaptureEvidence(captureDir);
    if (persisted.ledger.rebuildRequired) {
      return SfmFinalArtifactInspection(
        state: SfmFinalArtifactRecoveryState.needsRebuild,
        receipt: receipt,
      );
    }
  } catch (error) {
    return SfmFinalArtifactInspection(
      state: SfmFinalArtifactRecoveryState.needsRebuild,
      receipt: receipt,
      error: error,
    );
  }
  _FinalCommitMarker? marker;
  try {
    marker = await _readFinalCommitMarker(captureDir);
    if (marker != null &&
        marker.phase == 'committed' &&
        _markerMatchesReceipt(marker, receipt)) {
      return SfmFinalArtifactInspection(
        state: SfmFinalArtifactRecoveryState.complete,
        receipt: receipt,
      );
    }
  } catch (error) {
    return SfmFinalArtifactInspection(
      state: SfmFinalArtifactRecoveryState.needsRebuild,
      receipt: receipt,
      error: error,
    );
  }
  try {
    if (await _recoverVerifiedFinalArtifactCommit(
      captureDir,
      receipt,
      marker: marker,
    )) {
      return SfmFinalArtifactInspection(
        state: SfmFinalArtifactRecoveryState.complete,
        receipt: receipt,
      );
    }
  } catch (error) {
    _FinalCommitMarker? recoveredMarker;
    try {
      recoveredMarker = await _readFinalCommitMarker(captureDir);
    } catch (_) {}
    return SfmFinalArtifactInspection(
      state:
          recoveredMarker?.phase == 'prepared' &&
              _markerMatchesReceipt(recoveredMarker!, receipt)
          ? SfmFinalArtifactRecoveryState.needsDurableCommit
          : SfmFinalArtifactRecoveryState.needsRebuild,
      receipt: receipt,
      error: error,
    );
  }
  _FinalCommitMarker? recoveredMarker;
  try {
    recoveredMarker = await _readFinalCommitMarker(captureDir);
  } catch (_) {}
  return SfmFinalArtifactInspection(
    state:
        recoveredMarker?.phase == 'prepared' &&
            _markerMatchesReceipt(recoveredMarker!, receipt)
        ? SfmFinalArtifactRecoveryState.needsDurableCommit
        : SfmFinalArtifactRecoveryState.needsRebuild,
    receipt: receipt,
  );
}

/// Performs the mutation-safe preparation shared by normal continuation and
/// explicit regeneration. [forceRegenerate] deliberately does not bypass
/// integrity handling: a provably partial/corrupt sparse transaction is
/// discarded before the replacement solve, while user photos, DB and replay
/// gray remain untouched.
Future<SfmFinalArtifactInspection> prepareSfmFinalArtifactForResume(
  String captureDir, {
  required bool forceRegenerate,
}) async {
  final inspection = await inspectSfmFinalArtifact(captureDir);
  if (inspection.state == SfmFinalArtifactRecoveryState.needsRebuild &&
      inspection.error != null) {
    DeviceLog.log(
      'SfmResume',
      'discarding invalid sparse transaction before '
          '${forceRegenerate ? "forced" : "normal"} resume: '
          '${inspection.error}',
    );
    await discardInvalidSparsePublication(captureDir: captureDir);
    await _deleteFinalCommitMarkerBestEffort(captureDir);
    return inspectSfmFinalArtifact(captureDir);
  }
  return inspection;
}

/// Retries only durable cleanup for an already verified refined generation;
/// it never re-runs SfM and never rewrites the user's final cloud.
Future<bool> retryPersistedSfmFinalArtifactCommit({
  required String captureDir,
  required SfmLiveRecon recon,
}) async {
  final inspection = await inspectSfmFinalArtifact(captureDir);
  if (inspection.state == SfmFinalArtifactRecoveryState.complete) return true;
  final receipt = inspection.receipt;
  if (inspection.state != SfmFinalArtifactRecoveryState.needsDurableCommit ||
      receipt == null) {
    return false;
  }
  return commitPersistedSfmFinalArtifact(
    captureDir: captureDir,
    recon: recon,
    receipt: receipt,
  );
}

/// Commits the exact generation just returned by [persistSparseSnapshot]. This
/// is the live-finalize entry point: it verifies receipt identity/count/hash,
/// publishes the prepared marker, performs the idempotent queue purge, then
/// publishes the committed marker. Failures are observable as `false` and keep
/// photos/replay recovery state intact.
Future<bool> commitPersistedSfmFinalArtifact({
  required String captureDir,
  required SfmLiveRecon recon,
  required SparsePersistReceipt receipt,
}) async {
  try {
    await _commitPersistedFinalArtifact(captureDir, recon, receipt);
    return true;
  } catch (error) {
    DeviceLog.log('SfmResume', 'durable artifact commit failed: $error');
    return false;
  }
}

/// [resumeSingleCapture] 是否正在为 [captureDir] 跑。
bool isResumeInFlight(String captureDir) =>
    _resumeInFlight.containsKey(captureDir);

/// Resolves a capture directory across app-container UUID changes without
/// requiring recovery inputs. This keeps historical, already-built PLY-only
/// captures viewable even after their SfM db was intentionally compacted.
Future<String?> resolveExistingCaptureDir(String recordCaptureDir) async {
  if (recordCaptureDir.isEmpty) return null;
  if (Directory(recordCaptureDir).existsSync()) return recordCaptureDir;
  try {
    final docs = (await getApplicationDocumentsDirectory()).path;
    final rebuilt = '$docs/captures/${recordCaptureDir.split('/').last}';
    if (Directory(rebuilt).existsSync()) return rebuilt;
  } catch (_) {}
  return null;
}

/// Structured recovery-input truth consumed by the draft UI and resume entry.
///
/// With no DB, this may bridge a fully committed manual-v2 native bundle into
/// the durable queue. It is therefore only called on cold/explicit recovery,
/// after the previous process and native writers are known to be gone. Bare
/// gray, missing pose/K/JPEG, invalid byte counts and malformed manifests are
/// durable state but never resumable evidence.
class SfmRecoveryInputInspection {
  const SfmRecoveryInputInspection({
    required this.hasDurableState,
    required this.canExplicitlyResume,
    required this.reason,
  });

  final bool hasDurableState;
  final bool canExplicitlyResume;
  final String reason;
}

Future<SfmRecoveryInputInspection> inspectSfmRecoveryInputs(
  String captureDir,
) async {
  if (!_claimCaptureReconstruction(captureDir, 'inspection')) {
    return SfmRecoveryInputInspection(
      hasDurableState: true,
      canExplicitlyResume: false,
      reason:
          'capture_reconstruction_owned:'
          '${_captureReconstructionOwners[captureDir]}',
    );
  }
  try {
    return await _inspectSfmRecoveryInputsOwned(captureDir);
  } finally {
    _releaseCaptureReconstruction(captureDir, 'inspection');
  }
}

Future<SfmRecoveryInputInspection> _inspectSfmRecoveryInputsOwned(
  String captureDir,
) async {
  final capture = Directory(captureDir);
  if (!await capture.exists()) {
    return const SfmRecoveryInputInspection(
      hasDurableState: false,
      canExplicitlyResume: false,
      reason: 'capture_directory_missing',
    );
  }
  final hasDb = File('$captureDir/sfm_live.db').existsSync();
  final photos = Directory('$captureDir/photos_highres');
  final queueDirectory = Directory('$captureDir/sfm_live.db.sfm-feed');
  final processOwner = await SfmDurableFeedQueue.processOwnerSnapshot(
    queueDirectory,
  );
  if (processOwner != null) {
    return SfmRecoveryInputInspection(
      hasDurableState: true,
      canExplicitlyResume: false,
      reason: processOwner.ownerOpening
          ? 'durable_queue_process_owned:opening'
          : 'durable_queue_process_owned:'
                'spool=${processOwner.spoolDepth}:'
                'fed=${processOwner.fedCount}',
    );
  }

  late PersistedManualCaptureEvidence persistedManualEvidence;
  try {
    persistedManualEvidence = await loadPersistedManualCaptureEvidence(
      captureDir,
    );
  } catch (error) {
    return SfmRecoveryInputInspection(
      hasDurableState: true,
      canExplicitlyResume: false,
      reason: 'manual_capture_evidence_failed:$error',
    );
  }
  try {
    await _completePersistedUserDeletedSourceCleanup(
      captureDir: captureDir,
      persisted: persistedManualEvidence,
    );
  } catch (error) {
    return SfmRecoveryInputInspection(
      hasDurableState: true,
      canExplicitlyResume: false,
      reason: 'user_deleted_source_cleanup_failed:$error',
    );
  }

  // Enumerate exact native commit receipts before orphan adoption moves any
  // *active* source `.sfm-gray` into the queue. Persisted user-deletion
  // tombstones are completed first so a crash halfway through explicit source
  // cleanup cannot make Swift enumeration or the orphan scanner poison the
  // remaining active replay. MissingPlugin is normalized to an empty list by
  // the provider; malformed/native platform failures remain fail-closed here.
  late final List<ManualCaptureV2RecoveryJob> nativeJobs;
  try {
    nativeJobs = await listPlatformManualCaptureV2Jobs(captureDir);
  } catch (error) {
    return SfmRecoveryInputInspection(
      hasDurableState: true,
      canExplicitlyResume: false,
      reason: 'native_commit_evidence_failed:$error',
    );
  }
  if (nativeJobs.any((job) => job.status == 'failed')) {
    try {
      persistedManualEvidence = await persistNativeManualCaptureFailures(
        captureDir: captureDir,
        nativeJobs: nativeJobs,
      );
    } catch (error) {
      return SfmRecoveryInputInspection(
        hasDurableState: true,
        canExplicitlyResume: false,
        reason: 'native_failure_evidence_persist_failed:$error',
      );
    }
  }
  try {
    persistedManualEvidence =
        await completePersistedManualDeletionRequestsAfterColdNativeReconciliation(
          captureDir: captureDir,
          nativeJobs: nativeJobs,
        );
    await _completePersistedUserDeletedSourceCleanup(
      captureDir: captureDir,
      persisted: persistedManualEvidence,
    );
  } catch (error) {
    return SfmRecoveryInputInspection(
      hasDurableState: true,
      canExplicitlyResume: false,
      reason: 'pending_user_deletion_reconciliation_failed:$error',
    );
  }
  final nativeJobBlock = _nativeManualRecoveryBlock(
    nativeJobs,
    persistedLedger: persistedManualEvidence.ledger,
  );

  final manifest = File('${queueDirectory.path}/$kSfmFeedManifestFileName');
  var hasQueueDiskState = await manifest.exists();
  if (!hasQueueDiskState && await queueDirectory.exists()) {
    try {
      await for (final _ in queueDirectory.list(followLinks: false)) {
        hasQueueDiskState = true;
        break;
      }
    } catch (error) {
      return SfmRecoveryInputInspection(
        hasDurableState: true,
        canExplicitlyResume: false,
        reason: 'queue_directory_unreadable:$error',
      );
    }
  }

  if (!hasQueueDiskState) {
    final scan = await scanCommittedSfmOrphans(photos);
    if (scan.committedOrphans.isEmpty && scan.blocks.isEmpty) {
      if (nativeJobs.isNotEmpty) {
        return SfmRecoveryInputInspection(
          hasDurableState: true,
          canExplicitlyResume: false,
          reason: nativeJobBlock ?? 'native_manual_commit_missing_replay_input',
        );
      }
      if (hasDb) {
        return const SfmRecoveryInputInspection(
          hasDurableState: true,
          canExplicitlyResume: true,
          reason: 'retained_native_db',
        );
      }
      if (persistedManualEvidence.ledger.jobs.isNotEmpty) {
        return SfmRecoveryInputInspection(
          hasDurableState: true,
          canExplicitlyResume: false,
          reason: _manualLedgerWithoutReplayReason(
            persistedManualEvidence.ledger,
          ),
        );
      }
      return const SfmRecoveryInputInspection(
        hasDurableState: false,
        canExplicitlyResume: false,
        reason: 'no_verified_recovery_inputs',
      );
    }
  }

  SfmDurableFeedQueue? queue;
  try {
    queue = await SfmDurableFeedQueue.open(queueDirectory);
    final scan = await queue
        .recoverCommittedCaptureSourcesAfterWriterQuiescence(
          photos,
          writersQuiesced: true,
        );
    await reconcilePersistedManualCaptureJobsFromNative(
      captureDir: captureDir,
      durableQueue: queue,
      nativeJobs: nativeJobs,
    );
    if (nativeJobBlock != null) {
      return SfmRecoveryInputInspection(
        hasDurableState: true,
        canExplicitlyResume: false,
        reason: nativeJobBlock,
      );
    }
    if (scan.blocked || queue.blocked) {
      return SfmRecoveryInputInspection(
        hasDurableState: true,
        canExplicitlyResume: false,
        reason:
            'recovery_evidence_blocked:'
            '${queue.blockReason ?? scan.blocks.firstOrNull?.message}',
      );
    }
    if (queue.finalArtifactCommitted) {
      return const SfmRecoveryInputInspection(
        hasDurableState: true,
        canExplicitlyResume: false,
        reason: 'final_artifact_already_committed',
      );
    }
    if (queue.spoolDepth > 0 || queue.fedCount > 0) {
      return SfmRecoveryInputInspection(
        hasDurableState: true,
        canExplicitlyResume: true,
        reason: scan.committedOrphans.isEmpty
            ? 'verified_durable_queue'
            : 'recovered_committed_manual_v2_bundle',
      );
    }
    return hasDb
        ? const SfmRecoveryInputInspection(
            hasDurableState: true,
            canExplicitlyResume: true,
            reason: 'retained_native_db',
          )
        : const SfmRecoveryInputInspection(
            hasDurableState: true,
            canExplicitlyResume: false,
            reason: 'durable_queue_has_no_replayable_frames',
          );
  } catch (error) {
    return SfmRecoveryInputInspection(
      hasDurableState: true,
      canExplicitlyResume: false,
      reason: 'recovery_input_validation_failed:$error',
    );
  } finally {
    await queue?.close();
  }
}

Future<void> _completePersistedUserDeletedSourceCleanup({
  required String captureDir,
  required PersistedManualCaptureEvidence persisted,
}) async {
  final captureRoot = _normalizedAbsolutePath(captureDir);
  final photosRoot = _normalizedAbsolutePath(
    '$captureRoot${Platform.pathSeparator}photos_highres',
  );
  final previewsRoot = _normalizedAbsolutePath(
    '$captureRoot${Platform.pathSeparator}previews',
  );
  for (final job in persisted.ledger.jobs.values) {
    if (!job.userDeleted) continue;
    if (!job.writersQuiesced) {
      throw StateError(
        'deleted job ${job.captureJobId} has no writer-quiescence evidence',
      );
    }
    final rawJpeg = persisted.jobToJpegPath[job.captureJobId];
    if (rawJpeg == null) {
      throw StateError('deleted job ${job.captureJobId} has no JPEG identity');
    }
    final jpegPath = _normalizedAbsolutePath(rawJpeg);
    if (_parentPath(jpegPath) != photosRoot) {
      throw StateError(
        'deleted job ${job.captureJobId} JPEG is outside photos_highres',
      );
    }
    final fileName = _fileName(jpegPath);
    if (fileName.isEmpty || fileName == '.' || fileName == '..') {
      throw StateError('deleted job ${job.captureJobId} JPEG is invalid');
    }
    final previewPath = '$previewsRoot${Platform.pathSeparator}$fileName';
    final stem = jpegPath.endsWith('.jpg')
        ? jpegPath.substring(0, jpegPath.length - 4)
        : jpegPath;
    final cleanupPaths = <String>[
      // Remove the commit marker first. If this cleanup itself is killed, a
      // durable-v2 sidecar/gray remainder is no longer a published orphan and
      // the next cold pass can idempotently finish the same tombstone.
      '$stem.manual-v2-committed.json',
      '$stem.sfm-gray',
      '$stem.json',
      previewPath,
      jpegPath,
    ];
    for (final path in cleanupPaths) {
      final expectedRoot = path == previewPath ? previewsRoot : photosRoot;
      if (_parentPath(path) != expectedRoot) {
        throw StateError(
          'deleted job ${job.captureJobId} cleanup path escaped capture root',
        );
      }
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
}

String _normalizedAbsolutePath(String path) =>
    File(path).absolute.uri.normalizePath().toFilePath();

String _parentPath(String path) {
  final separator = Platform.pathSeparator;
  final split = path.lastIndexOf(separator);
  return split <= 0 ? '' : path.substring(0, split);
}

String _fileName(String path) {
  final split = path.lastIndexOf(Platform.pathSeparator);
  return split < 0 ? path : path.substring(split + 1);
}

String _manualLedgerWithoutReplayReason(ManualCaptureLedger ledger) {
  final jobs = ledger.jobs.values.toList()
    ..sort((left, right) => left.captureJobId.compareTo(right.captureJobId));
  final details = <String>[];
  for (final job in jobs) {
    final codes = job.blockers.values.map((blocker) => blocker.code).toList()
      ..sort();
    final state = job.userDeleted ? 'user_deleted' : job.stage.name;
    details.add(
      <String>[
        job.captureJobId,
        state,
        if (codes.isNotEmpty) codes.join('+'),
      ].join(':'),
    );
  }
  return 'manual_capture_ledger_without_replay:${details.join(',')}';
}

String? _nativeManualRecoveryBlock(
  List<ManualCaptureV2RecoveryJob> nativeJobs, {
  required ManualCaptureLedger persistedLedger,
}) {
  // Native keeps a process-independent job registry after a user deletes that
  // job's JPEG/sidecar/gray bundle. The resulting native "failed" or
  // "pending" status is correct for the deleted job, but it must not poison
  // recovery of the remaining active jobs. Unknown jobs still fail closed: the
  // only jobs ignored here are those whose persisted ledger explicitly proves
  // a completed user deletion.
  final relevantNativeJobs = nativeJobs
      .where(
        (job) => persistedLedger.job(job.captureJobID)?.userDeleted != true,
      )
      .toList(growable: false);
  final seen = <String>{};
  final ambiguous = <String>{};
  for (final job in relevantNativeJobs) {
    if (!seen.add(job.captureJobID)) ambiguous.add(job.captureJobID);
  }
  if (ambiguous.isNotEmpty) {
    final ids = ambiguous.toList()..sort();
    return 'native_manual_jobs_ambiguous:${ids.join(',')}';
  }
  final failed =
      relevantNativeJobs.where((job) => job.status == 'failed').toList()..sort(
        (left, right) => left.captureJobID.compareTo(right.captureJobID),
      );
  if (failed.isNotEmpty) {
    return 'native_manual_jobs_failed:'
        '${failed.map((job) => '${job.captureJobID}:${job.errorCode}').join(',')}';
  }
  final pending =
      relevantNativeJobs
          .where((job) => !job.hasExactCommittedBundle)
          .map((job) => job.captureJobID)
          .toList()
        ..sort();
  if (pending.isNotEmpty) {
    return 'native_manual_jobs_pending:${pending.join(',')}';
  }
  return null;
}

/// Whether a capture still owns replay material or an unfinished replay
/// transaction. UI callers use this to distinguish a genuinely historical
/// PLY-only capture from a capture whose DB is missing while durable work is
/// still pending. Malformed state fails closed.
Future<bool> hasSfmDurableReplayState(String captureDir) async {
  var replay = await _inspectSfmReplayDiskState(captureDir);
  if (replay.isLegacyAdoptionCandidate) {
    try {
      final receipt = await recoverSparsePublication(captureDir: captureDir);
      if (receipt != null && receipt.refined) {
        final marker = await _readFinalCommitMarker(captureDir);
        await _recoverVerifiedFinalArtifactCommit(
          captureDir,
          receipt,
          marker: marker,
          replay: replay,
        );
        replay = await _inspectSfmReplayDiskState(captureDir);
      }
    } catch (_) {
      // Artifact or migration failure must keep legacy replay state visible.
    }
  }
  return replay.hasReplayState;
}

class _SfmReplayDiskState {
  const _SfmReplayDiskState({
    required this.directoryExists,
    required this.manifestExists,
    required this.malformed,
    required this.loosePayload,
    this.schemaVersion,
    this.pendingCount = 0,
    this.fedCount = 0,
    this.nativeReplayRequired = false,
    this.blocked = false,
    this.finalArtifactCommitted = false,
    this.replayPurgePending = false,
  });

  final bool directoryExists;
  final bool manifestExists;
  final bool malformed;
  final bool loosePayload;
  final int? schemaVersion;
  final int pendingCount;
  final int fedCount;
  final bool nativeReplayRequired;
  final bool blocked;
  final bool finalArtifactCommitted;
  final bool replayPurgePending;

  bool get cleanupComplete =>
      !malformed &&
      schemaVersion == 3 &&
      finalArtifactCommitted &&
      !replayPurgePending &&
      pendingCount == 0 &&
      !nativeReplayRequired &&
      !blocked &&
      !loosePayload;

  bool get hasNoReplayState =>
      !malformed && (!directoryExists || (!manifestExists && !loosePayload));

  bool get isLegacyAdoptionCandidate =>
      !malformed &&
      manifestExists &&
      schemaVersion != null &&
      schemaVersion! < 3 &&
      pendingCount == 0 &&
      fedCount > 0 &&
      !nativeReplayRequired &&
      !blocked;

  bool get hasReplayState {
    if (malformed) return true;
    if (!directoryExists) return false;
    if (!manifestExists) return loosePayload;
    if (cleanupComplete) return false;
    return pendingCount > 0 ||
        fedCount > 0 ||
        nativeReplayRequired ||
        blocked ||
        replayPurgePending ||
        loosePayload ||
        !finalArtifactCommitted;
  }
}

Future<_SfmReplayDiskState> _inspectSfmReplayDiskState(
  String captureDir,
) async {
  final directory = Directory('$captureDir/sfm_live.db.sfm-feed');
  if (!await directory.exists()) {
    return const _SfmReplayDiskState(
      directoryExists: false,
      manifestExists: false,
      malformed: false,
      loosePayload: false,
    );
  }

  Future<bool> hasLoosePayload() async {
    await for (final entry in directory.list(followLinks: false)) {
      final name = entry.path.split('/').last;
      if (name.endsWith('.gray') ||
          (name.startsWith('frame-') && name.endsWith('.json'))) {
        return true;
      }
    }
    return false;
  }

  final manifest = File('${directory.path}/$kSfmFeedManifestFileName');
  try {
    final loosePayload = await hasLoosePayload();
    if (!await manifest.exists()) {
      return _SfmReplayDiskState(
        directoryExists: true,
        manifestExists: false,
        malformed: false,
        loosePayload: loosePayload,
      );
    }
    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('SFM feed manifest must be a JSON object');
    }
    final schemaVersion = decoded['schemaVersion'];
    if (schemaVersion is! int || schemaVersion < 1 || schemaVersion > 3) {
      throw const FormatException('unsupported SFM feed manifest schema');
    }
    final pending = decoded['pending'];
    final fed = decoded['fed'];
    if (pending is! List || fed is! List) {
      throw const FormatException('manifest pending/fed must be arrays');
    }
    final nativeReplayRequired = decoded['nativeReplayRequired'] == true;
    final blocked = decoded['block'] != null;
    final replayPurgePending =
        schemaVersion >= 3 && decoded['replayPurgePending'] == true;
    final finalArtifactCommitted =
        schemaVersion >= 3 && decoded['finalArtifactCommitted'] == true;
    return _SfmReplayDiskState(
      directoryExists: true,
      manifestExists: true,
      malformed: false,
      loosePayload: loosePayload,
      schemaVersion: schemaVersion,
      pendingCount: pending.length,
      fedCount: fed.length,
      nativeReplayRequired: nativeReplayRequired,
      blocked: blocked,
      finalArtifactCommitted: finalArtifactCommitted,
      replayPurgePending: replayPurgePending,
    );
  } catch (_) {
    return const _SfmReplayDiskState(
      directoryExists: true,
      manifestExists: true,
      malformed: true,
      loosePayload: false,
    );
  }
}

/// 把 record 存的 captureDir 解析成**当前**磁盘上可恢复的目录:app 容器
/// UUID 在重装/迁移后会变,存的绝对路径可能已失效 —— 按目录名(= record
/// id)在当前 Documents/captures 下重建。DB 不存在时只接受已经严格验证
/// 并移交 durable queue 的 manual-v2 三件套；裸 gray/缺 pose/K/bytes 返回
/// null 且保留显式 block。与 [resumeIncompleteCaptures] 的 sweep 同一逻辑。
Future<String?> resolveRecoverableCaptureDir(String recordCaptureDir) async {
  final existing = await resolveExistingCaptureDir(recordCaptureDir);
  if (existing == null) return null;
  final inputs = await inspectSfmRecoveryInputs(existing);
  return inputs.canExplicitlyResume ? existing : null;
}

/// 用户显式确认后的单 capture 断点续跑(修2c:草稿卡 → "继续重建"):
/// 从保留的 sfm_live.db 重跑 finalize → 取色 → 持久化 PLY,全程灵动岛
/// umbrella 保护(用户主动触发,符合"不凭空创建"契约)。只有 linked
/// refined PLY/meta 与 durable replay commit 均完成才返回 true;单独存在
/// 一个 PLY 绝不算成功。[forceRegenerate] 仅供用户明确选择“重新重建”时
/// 绕过完成/commit-only 快路。幂等:同目录并发调用共享同一 future。
Future<bool> resumeSingleCapture(
  String captureDir, {
  bool forceRegenerate = false,
}) {
  final existing = _resumeInFlight[captureDir];
  if (existing != null) return existing;
  if (!_claimCaptureReconstruction(captureDir, 'single_resume')) {
    DeviceLog.log(
      'SfmResume',
      'single resume refused active owner for $captureDir: '
          '${_captureReconstructionOwners[captureDir]}',
    );
    return Future<bool>.value(false);
  }
  final completer = Completer<bool>();
  _resumeInFlight[captureDir] = completer.future;
  () async {
    var committed = false;
    try {
      final inspection = await prepareSfmFinalArtifactForResume(
        captureDir,
        forceRegenerate: forceRegenerate,
      );
      if (!forceRegenerate) {
        if (inspection.state == SfmFinalArtifactRecoveryState.complete) {
          committed = true;
          return;
        }
        if (inspection.state ==
            SfmFinalArtifactRecoveryState.needsDurableCommit) {
          committed = await _retryDurableCommitFromDisk(captureDir);
          if (committed) return;
        }
      }
      if (!File('$captureDir/sfm_live.db').existsSync()) {
        final inputs = await _inspectSfmRecoveryInputsOwned(captureDir);
        if (!inputs.canExplicitlyResume) {
          DeviceLog.log(
            'SfmResume',
            'resume refused without verified DB/replay inputs: '
                '${inputs.reason}',
          );
          return;
        }
      }
      // 等待页在场、用户盯着进度 —— 给完整 Cauchy phase2 留足余量,
      // 别沿用 sweep 的 8 分钟保守上限把 BA 中途掐死。
      committed = await _resumeOne(
        captureDir,
        timeout: const Duration(minutes: 25),
        forceRebuildFromRetainedDb: forceRegenerate,
      );
    } catch (e) {
      DeviceLog.log('SfmResume', 'single resume error $captureDir: $e');
    } finally {
      _resumeInFlight.remove(captureDir);
      _releaseCaptureReconstruction(captureDir, 'single_resume');
      completer.complete(committed);
    }
  }();
  return completer.future;
}

/// Continue a just-finished live capture after the capture page exits.
///
/// The UI contract is deliberately simple: saving the draft is the foreground
/// completion condition; SfM drains its queued frames and writes only the final
/// refined sparse cloud in the background. No LOCAL/preview cloud is persisted
/// as the user-visible result.
Future<bool> startDetachedSfmFinalize({
  required String captureDir,
  required SfmLiveRecon recon,
}) async {
  if (!_claimCaptureReconstruction(captureDir, 'detached_finalize')) {
    DeviceLog.log(
      'SfmResume',
      'detached refused active owner for $captureDir: '
          '${_captureReconstructionOwners[captureDir]}',
    );
    await recon.dispose();
    return false;
  }
  if (!_detachedFinalizing.add(captureDir)) {
    DeviceLog.log('SfmResume', 'detached already running for $captureDir');
    _releaseCaptureReconstruction(captureDir, 'detached_finalize');
    await recon.dispose();
    return false;
  }
  return _runDetachedFinalize(captureDir, recon);
}

/// Scans drafts with an SfM db and verifies exact final-artifact truth. A
/// complete linked pair missing only durable cleanup retries cleanup without a
/// solve; partial/corrupt/local-only output is rebuilt. This must only be called
/// from an explicit user recovery action. BGContinuedProcessingTaskRequest may
/// not be submitted just because the app launched; doing so creates
/// unsolicited Dynamic Island jobs.
Future<void> resumeIncompleteCaptures() async {
  if (_sweeping) return;
  _sweeping = true;
  final sweepClaims = <String>{};
  try {
    await ScanRecordStore.instance.ensureLoaded();
    final records = ScanRecordStore.instance.records;
    final docs = (await getApplicationDocumentsDirectory()).path;
    DeviceLog.log(
      'SfmResume',
      'sweep start: ${records.length} records | docs=$docs',
    );
    final pending = <({String dir, SfmFinalArtifactInspection inspection})>[];
    for (final r in records) {
      final recordDir = r.captureDir;
      if (recordDir == null || recordDir.isEmpty) continue;
      final dir = await resolveExistingCaptureDir(recordDir);
      if (dir == null) continue;
      if (!_claimCaptureReconstruction(dir, 'recovery_sweep')) continue;
      sweepClaims.add(dir);
      final hasDb = File('$dir/sfm_live.db').existsSync();
      final inputs = await _inspectSfmRecoveryInputsOwned(dir);
      final inspection = await inspectSfmFinalArtifact(dir);
      DeviceLog.log(
        'SfmResume',
        '  ${dir.split('/').last}: db=$hasDb '
            'inputs=${inputs.reason} artifact=${inspection.state.name}',
      );
      if (inputs.canExplicitlyResume &&
          inspection.state != SfmFinalArtifactRecoveryState.complete &&
          !_detachedFinalizing.contains(dir)) {
        pending.add((dir: dir, inspection: inspection));
      } else {
        _releaseCaptureReconstruction(dir, 'recovery_sweep');
        sweepClaims.remove(dir);
      }
    }
    DeviceLog.log(
      'SfmResume',
      'sweep: ${pending.length} capture(s) to recover',
    );
    for (final item in pending) {
      final dir = item.dir;
      try {
        if (item.inspection.state ==
            SfmFinalArtifactRecoveryState.needsDurableCommit) {
          final retried = await _retryDurableCommitFromDisk(dir);
          if (retried) continue;
          DeviceLog.log(
            'SfmResume',
            'durable-only retry refused; rebuilding from retained queue/db: '
                '$dir',
          );
        } else if (item.inspection.error != null) {
          try {
            await discardInvalidSparsePublication(captureDir: dir);
            await _deleteFinalCommitMarkerBestEffort(dir);
          } catch (error) {
            DeviceLog.log(
              'SfmResume',
              'invalid sparse artifact could not be prepared for retry: '
                  '$error',
            );
            continue;
          }
        }
        await _resumeOne(dir);
      } finally {
        _releaseCaptureReconstruction(dir, 'recovery_sweep');
        sweepClaims.remove(dir);
      }
    }
  } catch (e, st) {
    DeviceLog.log('SfmResume', 'sweep error: $e\n$st');
  } finally {
    for (final dir in sweepClaims) {
      _releaseCaptureReconstruction(dir, 'recovery_sweep');
    }
    _sweeping = false;
  }
}

Future<bool> _retryDurableCommitFromDisk(String captureDir) async {
  SfmLiveRecon? recon;
  try {
    await _umbrella('beginReconUmbrella', captureDir);
    recon = await SfmLiveRecon.start(dbPath: '$captureDir/sfm_live.db');
    if (recon == null) return false;
    return await retryPersistedSfmFinalArtifactCommit(
      captureDir: captureDir,
      recon: recon,
    );
  } catch (error) {
    DeviceLog.log('SfmResume', 'durable commit reopen failed: $error');
    return false;
  } finally {
    await recon?.dispose();
    await _umbrella('endReconUmbrella', captureDir);
  }
}

Future<void> _deleteFinalCommitMarkerBestEffort(String captureDir) async {
  try {
    final marker = File('$captureDir/$_finalCommitMarkerName');
    if (await marker.exists()) await marker.delete();
  } catch (error) {
    DeviceLog.log('SfmResume', 'stale final commit marker retained: $error');
  }
}

Future<bool> _runDetachedFinalize(String captureDir, SfmLiveRecon recon) async {
  StreamSubscription<SfmLiveEvent>? sub;
  final done = Completer<void>();
  var committed = false;
  var terminalClaimed = false;
  Future<void>? terminalWork;
  try {
    await _umbrella('beginReconUmbrella', captureDir);
    sub = recon.events.listen((e) {
      switch (e) {
        case SfmLiveLocalReady(:final snapshot):
          DeviceLog.log(
            'SfmResume',
            'detached local ignored: ${snapshot.pointCount} pts',
          );
        case SfmLiveRefined(:final snapshot):
          if (terminalClaimed) break;
          terminalClaimed = true;
          terminalWork = () async {
            try {
              await _requirePersistedRegistrationGate(
                captureDir: captureDir,
                recon: recon,
                snapshot: snapshot,
                artifactIdentity: _registrationArtifactIdentity(
                  captureDir,
                  snapshot,
                ),
                evidenceToken:
                    'prepersist-${snapshot.poseCount}-'
                    '${snapshot.registeredCount}',
              );
              final receipt = await _persistColored(captureDir, snapshot);
              await _requirePersistedRegistrationGate(
                captureDir: captureDir,
                recon: recon,
                snapshot: snapshot,
                artifactIdentity: _registrationArtifactIdentity(
                  captureDir,
                  snapshot,
                ),
                evidenceToken:
                    'receipt-${receipt.metaSha256}-${receipt.pointCount}',
                sparseReceipt: receipt,
              );
              await _commitPersistedFinalArtifact(captureDir, recon, receipt);
              committed = true;
            } catch (e) {
              DeviceLog.log('SfmResume', 'detached persist/commit failed: $e');
            } finally {
              if (!done.isCompleted) done.complete();
            }
          }();
          unawaited(terminalWork!);
        case SfmLiveFailed(:final stage, :final message):
          if (terminalClaimed) break;
          terminalClaimed = true;
          DeviceLog.log(
            'SfmResume',
            'detached failed for $captureDir: $stage $message',
          );
          if (!done.isCompleted) done.complete();
        default:
          break;
      }
    });
    DeviceLog.log('SfmResume', 'detached finalize start: $captureDir');
    recon.finalize();
    await done.future.timeout(
      const Duration(minutes: 12),
      onTimeout: () {
        DeviceLog.log('SfmResume', 'detached timed out for $captureDir');
      },
    );
    // Once a refined artifact starts writing, a timeout may no longer dispose
    // its recon underneath the commit. The timeout only bounds waiting for a
    // terminal native event; accepted persistence/commit is an exact barrier.
    await terminalWork;
  } catch (e) {
    DeviceLog.log('SfmResume', 'detached error $captureDir: $e');
  } finally {
    await terminalWork;
    await sub?.cancel();
    await recon.dispose();
    await _umbrella('endReconUmbrella', captureDir);
    _detachedFinalizing.remove(captureDir);
    _releaseCaptureReconstruction(captureDir, 'detached_finalize');
  }
  return committed;
}

Future<bool> _resumeOne(
  String captureDir, {
  Duration timeout = const Duration(minutes: 8),
  bool forceRebuildFromRetainedDb = false,
}) async {
  SfmLiveRecon? recon;
  StreamSubscription<SfmLiveEvent>? sub;
  final done = Completer<void>();
  var committed = false;
  var terminalClaimed = false;
  Future<void>? terminalWork;
  try {
    await _umbrella('beginReconUmbrella', captureDir);
    await _prepareActiveManualRebuildIfRequired(captureDir);
    recon = await SfmLiveRecon.start(
      dbPath: '$captureDir/sfm_live.db',
      forceRebuildFromRetainedDb: forceRebuildFromRetainedDb,
    );
    if (recon == null) {
      DeviceLog.log('SfmResume', 'start unavailable for $captureDir');
      return false;
    }
    final activeRecon = recon;
    // 与 live 主路径对齐【重力对齐】:resume 会话没喂过帧,facade 的
    // _fedMeta 为空 → _gravityAlign 会整段跳过(cnt<3),恢复出的点云
    // 歪着。先用拍摄期落盘的 sfm_fed_frames.jsonl(含每帧
    // arkitCamFromWorldQwxyz)回填,refined 快照就会走与 live 完全同一条
    // _gravityAlign 链。sidecar 缺失(极老草稿)时按时间戳序兜底,无
    // ARKit 四元数 → 对齐自然跳过(与今日行为一致,诚实降级)。
    final frameMeta = await _loadFrameMeta(captureDir);
    activeRecon.seedFedMeta(frameMeta);
    DeviceLog.log(
      'SfmResume',
      'fed-meta seeded: ${frameMeta.length} frames, '
          'arkitQuat=${frameMeta.values.where((m) => m.arkitQuatWxyz != null).length}',
    );
    sub = activeRecon.events.listen((e) {
      switch (e) {
        case SfmLiveLocalReady(:final snapshot):
          DeviceLog.log(
            'SfmResume',
            'resume local ignored: ${snapshot.pointCount} pts',
          );
        case SfmLiveRefined(:final snapshot):
          if (terminalClaimed) break;
          terminalClaimed = true;
          // 与 detached 腿同构:persist 完成(取色+孤点过滤+PLY 落盘)才算
          // 完成 —— 原先 refined 一到就 complete,等待页/调用方在 PLY 尚未
          // 写完时就检查 existsSync,会把成功误报成失败(竞态)。
          terminalWork = () async {
            try {
              await _requirePersistedRegistrationGate(
                captureDir: captureDir,
                recon: activeRecon,
                snapshot: snapshot,
                artifactIdentity: _registrationArtifactIdentity(
                  captureDir,
                  snapshot,
                ),
                evidenceToken:
                    'prepersist-${snapshot.poseCount}-'
                    '${snapshot.registeredCount}',
              );
              final receipt = await _persistColored(
                captureDir,
                snapshot,
                frameMeta: frameMeta,
                allowRefinedReplacement: true,
              );
              await _requirePersistedRegistrationGate(
                captureDir: captureDir,
                recon: activeRecon,
                snapshot: snapshot,
                artifactIdentity: _registrationArtifactIdentity(
                  captureDir,
                  snapshot,
                ),
                evidenceToken:
                    'receipt-${receipt.metaSha256}-${receipt.pointCount}',
                sparseReceipt: receipt,
              );
              await _commitPersistedFinalArtifact(
                captureDir,
                activeRecon,
                receipt,
              );
              committed = true;
            } catch (e) {
              DeviceLog.log('SfmResume', 'resume persist/commit failed: $e');
            } finally {
              if (!done.isCompleted) done.complete();
            }
          }();
          unawaited(terminalWork!);
        case SfmLiveFailed(:final stage, :final message):
          if (terminalClaimed) break;
          terminalClaimed = true;
          DeviceLog.log(
            'SfmResume',
            'resume $captureDir failed: $stage $message',
          );
          if (!done.isCompleted) done.complete();
        default:
          break;
      }
    });
    activeRecon.resumeFromDb();
    // Bound the wait so one stubborn capture can't stall the whole sweep. We do
    // not persist LOCAL as the final user-visible cloud; a failed refine leaves
    // the db for a later retry.
    await done.future.timeout(
      timeout,
      onTimeout: () {
        DeviceLog.log('SfmResume', '$captureDir timed out (kept partial/none)');
      },
    );
    await terminalWork;
    await sub.cancel();
    sub = null;
    DeviceLog.log(
      'SfmResume',
      'recovered $captureDir → artifactCommitted=$committed',
    );
    return committed;
  } catch (e) {
    DeviceLog.log('SfmResume', 'resume error $captureDir: $e');
    return false;
  } finally {
    await terminalWork;
    await sub?.cancel();
    if (recon != null) await recon.dispose();
    await _umbrella('endReconUmbrella', captureDir);
  }
}

/// Converts a deletion-tainted reconstruction into an exact active-job replay
/// before native opens its DB. Queue membership is committed first; the normal
/// live start then rotates the old SQLite set to `.pre-replay` and consumes
/// only these retained frames. A failed membership proof changes neither the
/// manifest nor the DB, and the old DB backup is kept until final publication.
Future<void> _prepareActiveManualRebuildIfRequired(String captureDir) async {
  final persisted = await loadPersistedManualCaptureEvidence(captureDir);
  final ledger = persisted.ledger;
  if (!ledger.rebuildRequired) return;
  final activeJobIds = ledger.jobs.values
      .where((job) => job.accepted && !job.userDeleted)
      .map((job) => job.captureJobId)
      .toSet();
  if (activeJobIds.isEmpty) {
    throw StateError(
      'clean reconstruction replay has no active accepted capture jobs',
    );
  }

  final queue = await SfmDurableFeedQueue.open(
    Directory('$captureDir/sfm_live.db.sfm-feed'),
  );
  try {
    final prepared = await queue.prepareActiveJobsForFreshNativeReplay(
      activeJobIds,
    );
    if (!prepared) {
      throw StateError(
        'durable queue refused active-only clean replay for '
        '${activeJobIds.length} jobs',
      );
    }
  } finally {
    await queue.close();
  }
  DeviceLog.log(
    'SfmResume',
    'clean replay prepared: active=${activeJobIds.length} '
        'deleted=${ledger.jobs.values.where((job) => job.userDeleted).length}',
  );
}

/// Reopens every durable identity source at the publication boundary. The
/// ledger reconciliation is exact job/JPEG/native-image mapping, not a count
/// approximation. A missing or corrupt ledger, pending/blocked queue, or any
/// unregistered pose throws before PLY persistence or replay purge.
Future<SfmRegistrationPublishDecision> _requirePersistedRegistrationGate({
  required String captureDir,
  required SfmLiveRecon recon,
  required SfmLiveSnapshot snapshot,
  required String artifactIdentity,
  required String evidenceToken,
  SparsePersistReceipt? sparseReceipt,
}) async {
  return recon.withDurableRegistrationEvidence((queue) async {
    final evidence = await reconcilePersistedManualFinalRegistration(
      captureDir: captureDir,
      durableQueue: queue,
      snapshot: snapshot,
      artifactIdentity: artifactIdentity,
      evidenceToken: evidenceToken,
    );
    final decision = evaluateSfmRegistrationPublishGate(
      durableQueue: queue,
      ledger: evidence.ledger,
      finalRegistration: evidence.finalRegistration,
      snapshot: snapshot,
    );
    decision.requireCanPublish();
    if (sparseReceipt != null) {
      await persistSfmRegistrationGateReceipt(
        captureDir: captureDir,
        sparseReceipt: sparseReceipt,
        decision: decision,
        ledger: evidence.ledger,
        durableQueue: queue,
      );
    }
    return decision;
  });
}

String _registrationArtifactIdentity(
  String captureDir,
  SfmLiveSnapshot snapshot,
) =>
    'prepersist-${captureDir.split(Platform.pathSeparator).last}-'
    '${snapshot.poseCount}-${snapshot.pointCount}';

/// Recovers completion truth without starting native SfM.
///
/// Legacy schema-1/2 queues could finish a refined artifact and delete every
/// replay payload without ever persisting a cleanup receipt. The verified
/// sparse receipt is bound to a prepared marker before the queue atomically
/// adopts that old state. A crash after queue adoption can therefore complete
/// only the same sparse generation, never a later replacement.
///
Future<bool> _recoverVerifiedFinalArtifactCommit(
  String captureDir,
  SparsePersistReceipt receipt, {
  required _FinalCommitMarker? marker,
  _SfmReplayDiskState? replay,
}) async {
  if (marker != null && !_markerMatchesReceipt(marker, receipt)) return false;
  if (marker?.phase == 'committed') return true;

  replay ??= await _inspectSfmReplayDiskState(captureDir);
  if (replay.malformed) return false;

  if (replay.cleanupComplete) {
    // Only a matching prepared marker can bind an already-completed queue
    // receipt to this exact sparse generation.
    if (marker?.phase != 'prepared') return false;
    await _writeFinalCommitMarker(captureDir, receipt, phase: 'committed');
    return true;
  }

  if (replay.isLegacyAdoptionCandidate) {
    if (marker == null) {
      await _writeFinalCommitMarker(captureDir, receipt, phase: 'prepared');
    } else if (marker.phase != 'prepared') {
      return false;
    }
    final queue = await SfmDurableFeedQueue.open(
      Directory('$captureDir/sfm_live.db.sfm-feed'),
    );
    try {
      if (!await queue.adoptLegacyFinalArtifact()) return false;
    } finally {
      await queue.close();
    }
    final migrated = await _inspectSfmReplayDiskState(captureDir);
    if (!migrated.cleanupComplete) return false;
    await _writeFinalCommitMarker(captureDir, receipt, phase: 'committed');
    return true;
  }

  // Sparse recovery assigns `legacy-*` only to the old PLY+meta format after
  // pinning its exact bytes into a modern sparse commit marker. If that
  // historical capture has already compacted both DB and replay state, there
  // is provably nothing left to purge. Modern markerless receipts never enter
  // this branch.
  if (marker == null &&
      receipt.artifactId.startsWith('legacy-') &&
      !File('$captureDir/sfm_live.db').existsSync() &&
      replay.hasNoReplayState) {
    await _writeFinalCommitMarker(captureDir, receipt, phase: 'prepared');
    await _writeFinalCommitMarker(captureDir, receipt, phase: 'committed');
    return true;
  }

  return false;
}

/// Makes final publication and replay-payload cleanup one observable commit.
///
/// Recovery verifies the exact receipt returned by [persistSparseSnapshot]
/// before queue-owned replay gray is released. A prepared marker makes purge
/// retries discoverable; a committed marker is published only after the queue
/// acknowledges its recoverable purge transaction. User JPEGs and their AR
/// sidecars are never addressed by this function.
Future<void> _commitPersistedFinalArtifact(
  String captureDir,
  SfmLiveRecon recon,
  SparsePersistReceipt receipt,
) async {
  await verifyPersistedSparseSnapshot(
    captureDir: captureDir,
    expectedReceipt: receipt,
  );
  // The sparse pair is only data, never authorization to release replay
  // inputs. Reopen the recon-owned queue handle and require the exact durable
  // post-persist registration decision before publishing `prepared` or
  // purging anything. This also makes crash-time commit-only retry fail closed
  // if the receipt, ledger or queue evidence has changed.
  await recon.withDurableRegistrationEvidence((queue) async {
    await requirePersistedSfmRegistrationGateReceipt(
      captureDir: captureDir,
      sparseReceipt: receipt,
      durableQueue: queue,
    );
  });
  await _writeFinalCommitMarker(captureDir, receipt, phase: 'prepared');
  final purged = await recon.markFinalArtifactCommitted();
  if (!purged) {
    TelemetryWriter.instance.event('sfm_final_artifact_commit', {
      'capture_dir': captureDir,
      'ok': false,
      'reason': 'durable_replay_purge_refused',
    });
    throw StateError(
      'final artifact exists but durable replay purge was refused',
    );
  }
  await _writeFinalCommitMarker(captureDir, receipt, phase: 'committed');
  TelemetryWriter.instance.event('sfm_final_artifact_commit', {
    'capture_dir': captureDir,
    'ok': true,
  });
}

class _FinalCommitMarker {
  const _FinalCommitMarker({
    required this.phase,
    required this.artifactId,
    required this.pointCount,
    required this.plySha256,
    required this.metaSha256,
  });

  final String phase;
  final String artifactId;
  final int pointCount;
  final String plySha256;
  final String metaSha256;
}

bool _markerMatchesReceipt(
  _FinalCommitMarker marker,
  SparsePersistReceipt receipt,
) =>
    marker.artifactId == receipt.artifactId &&
    marker.pointCount == receipt.pointCount &&
    marker.plySha256 == receipt.plySha256 &&
    marker.metaSha256 == receipt.metaSha256;

Future<_FinalCommitMarker?> _readFinalCommitMarker(String captureDir) async {
  final file = File('$captureDir/$_finalCommitMarkerName');
  if (!await file.exists()) return null;
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, dynamic> ||
      decoded['schema'] != _finalCommitMarkerSchema ||
      (decoded['phase'] != 'prepared' && decoded['phase'] != 'committed') ||
      decoded['artifact_id'] is! String ||
      decoded['point_count'] is! int ||
      decoded['ply_sha256'] is! String ||
      decoded['meta_sha256'] is! String) {
    throw const FormatException('invalid final artifact commit marker');
  }
  return _FinalCommitMarker(
    phase: decoded['phase'] as String,
    artifactId: decoded['artifact_id'] as String,
    pointCount: decoded['point_count'] as int,
    plySha256: decoded['ply_sha256'] as String,
    metaSha256: decoded['meta_sha256'] as String,
  );
}

Future<void> _writeFinalCommitMarker(
  String captureDir,
  SparsePersistReceipt receipt, {
  required String phase,
}) async {
  if (phase != 'prepared' && phase != 'committed') {
    throw ArgumentError.value(phase, 'phase');
  }
  final finalFile = File('$captureDir/$_finalCommitMarkerName');
  final temporary = File(
    '$captureDir/.$_finalCommitMarkerName.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp',
  );
  try {
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{
        'schema': _finalCommitMarkerSchema,
        'phase': phase,
        'artifact_id': receipt.artifactId,
        'point_count': receipt.pointCount,
        'ply_sha256': receipt.plySha256,
        'meta_sha256': receipt.metaSha256,
        'written_at': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
    await temporary.rename(finalFile.path);
  } catch (_) {
    try {
      if (await temporary.exists()) await temporary.delete();
    } catch (_) {}
    rethrow;
  }
  final written = await _readFinalCommitMarker(captureDir);
  if (written == null ||
      written.phase != phase ||
      !_markerMatchesReceipt(written, receipt)) {
    throw StateError('final artifact commit marker verification failed');
  }
}

/// Colorize a recovered cloud to FULL FIDELITY — the same track-observation
/// sampling the live colorizer uses (each point sampled only in the frames of
/// its own track, full-res bilinear at xy-0.5, 归约取亮度中位的真实观测代表色
/// ——不算术平均,见 representative_color.dart), then persist. True color is a baseline of the
/// sparse cloud, not an enhancement; a recovered draft looks identical to one
/// finalized live.
Future<SparsePersistReceipt> _persistColored(
  String captureDir,
  SfmLiveSnapshot snap, {
  Map<int, SfmFedFrameMeta>? frameMeta,
  bool allowRefinedReplacement = false,
}) async {
  final n = snap.pointCount;
  if (n == 0) throw StateError('cannot persist an empty refined snapshot');
  frameMeta ??= await _loadFrameMeta(captureDir);
  final offs = snap.obsOffsets;
  final fids = snap.obsFrameIds;
  final oxy = snap.obsXY;
  final rgb = Uint8List(n * 3);

  if (frameMeta.isEmpty || fids.isEmpty || offs.length != n + 1) {
    // No color source found (photos missing). Never leave a recovered cloud
    // unpersisted — neutral gray so at least the structure is viewable.
    for (var i = 0; i < n; i++) {
      rgb[i * 3] = 185;
      rgb[i * 3 + 1] = 185;
      rgb[i * 3 + 2] = 190;
    }
    DeviceLog.log(
      'SfmResume',
      'colorize: no photo source for $captureDir → gray',
    );
    return _filterAndPersist(
      captureDir,
      snap,
      rgb,
      allowRefinedReplacement: allowRefinedReplacement,
    );
  }

  // Group observations by frame so every JPEG decodes exactly once.
  // obsCap 顺带统计每点有效观测数,作为样本池的预分配容量。
  final byFrame = <int, List<double>>{};
  final obsCap = Int32List(n);
  for (var i = 0; i < n; i++) {
    for (var j = offs[i]; j < offs[i + 1]; j++) {
      final f = fids[j];
      if (!frameMeta.containsKey(f)) continue;
      obsCap[i]++;
      (byFrame[f] ??= <double>[])
        ..add(i.toDouble())
        ..add(oxy[j * 2])
        ..add(oxy[j * 2 + 1]);
    }
  }

  // 代表色样本池:与 live 侧 _colorizeSnapshot 完全同构(共享
  // representative_color.dart + colorize_pipeline.dart),保证冷恢复与
  // 现场取色逐点一致。07-12 并行两刀(jpegPath 去重 + 有界并行 3)随
  // 共享 pipeline 一并生效,输出逐位不变(顺序=byFrame 插入序)。
  final samples = RepresentativeColorSamples(obsCap);
  final jobs = <ColorizeFrameJob>[];
  for (final entry in byFrame.entries) {
    final meta = frameMeta[entry.key]!;
    jobs.add(
      ColorizeFrameJob(
        jpegPath: meta.jpegPath,
        grayW: meta.grayW,
        grayH: meta.grayH,
        tri: entry.value,
      ),
    );
  }
  await sampleColorsPipelined(
    jobs: jobs,
    samples: samples,
    decode: _decodeJpegNative,
    maxInFlight: 3,
  );

  var colored = 0;
  for (var i = 0; i < n; i++) {
    // 代表色归约:选亮度中位的真实观测样本,不合成新颜色。
    if (samples.selectInto(i, rgb)) {
      colored++;
    } else {
      rgb[i * 3] = 185;
      rgb[i * 3 + 1] = 185;
      rgb[i * 3 + 2] = 190;
    }
  }
  DeviceLog.log(
    'SfmResume',
    'colorized ${snap.refined ? "refined" : "local"}: $colored/$n pts '
        'from ${byFrame.length} frames (${frameMeta.length} mapped)',
  );
  return _filterAndPersist(
    captureDir,
    snap,
    rgb,
    allowRefinedReplacement: allowRefinedReplacement,
  );
}

/// 与 live 主路径对齐【孤点过滤】:live 在 _colorizeSnapshot 尾部对交付
/// 点云跑保守 orphan filter(零近邻孤点删除,99 分位半径 ×1.2,≥3 观测
/// track 保护)后才持久化;resume 原先直接 persist,浮点全数落盘。这里
/// 用同一共享实现(floater_filter.dart)+ 同参数补齐:过滤 → 紧凑拷贝 →
/// persist(与 live 相同,持久化快照不再携带 obs 数组 —— 观测已被取色
/// 消费,过滤后的索引也不再对应)。
Future<SparsePersistReceipt> _filterAndPersist(
  String captureDir,
  SfmLiveSnapshot snap,
  Uint8List rgb, {
  required bool allowRefinedReplacement,
}) async {
  final n = snap.pointCount;
  final flt = floaterKeepIndices(snap.xyz, obsOffsets: snap.obsOffsets);
  final keepIdx = flt.keep;
  final m = keepIdx.length;
  final removedF = n - m;
  final Float32List fxyz;
  final Uint8List frgb;
  if (removedF <= 0) {
    fxyz = snap.xyz;
    frgb = rgb;
  } else {
    final compact = compactXyzRgbByIndices(snap.xyz, rgb, keepIdx);
    fxyz = compact.xyz;
    frgb = compact.rgb;
  }
  DeviceLog.log(
    'Floater',
    'orphan-filter(resume): kept $m/$n removed=$removedF '
        '(${n == 0 ? "0.0" : (100 * removedF / n).toStringAsFixed(1)}%) | '
        'radius=${flt.radius.toStringAsExponential(2)} kMin=1 '
        'protectedStable=${flt.protectedStable} | ${flt.ms}ms',
  );
  TelemetryWriter.instance.event('floater', {
    'kept': m,
    'removed': removedF,
    'protected_stable': flt.protectedStable,
    'ms': flt.ms,
    'leg': 'resume',
  });
  final fsnap = SfmLiveSnapshot(
    xyz: fxyz,
    rgb: frgb,
    posesPacked: snap.posesPacked,
    summary: snap.summary,
    refined: snap.refined,
    obsOffsets: Int32List(0),
    obsFrameIds: Int32List(0),
    obsXY: Float32List(0),
  );
  return persistSparseSnapshot(
    captureDir: captureDir,
    snapshot: fsnap,
    rgb: frgb,
    allowRefinedReplacement: allowRefinedReplacement,
  );
}

/// Maps each SfM frame-id → its color photo + the gray dims its keypoints live
/// in, PLUS(重力对齐)该帧的 ARKit CamFromWorld 四元数/平移(拍摄期
/// _persistFedMeta 落盘的 arkitCamFromWorldQwxyz/Txyz)。返回值直接是
/// [SfmFedFrameMeta],可原样回填 recon 的 fed-meta(seedFedMeta)——
/// resume 的取色与重力对齐由此与 live 共享同一数据形状。
/// 注意:sidecar 不含喂入内参(imageW/fx…),这些字段以 gray 尺寸/0 占位;
/// resume 链只消费 jpegPath/grayW/grayH/arkitQuatWxyz,占位字段无人读。
/// Prefers the exact `sfm_fed_frames.jsonl` sidecar written during capture;
/// falls back (for captures made before that existed, e.g. legacy drafts) to
/// the identity "SfM frame-id N == Nth shutter photo by capture timestamp",
/// which holds because frames are fed to SfM in tap order. Paths are rebuilt
/// under the CURRENT captureDir so a changed app-container UUID can't stale them.
Future<Map<int, SfmFedFrameMeta>> _loadFrameMeta(String captureDir) async {
  final photosDir = '$captureDir/photos_highres';
  final map = <int, SfmFedFrameMeta>{};

  List<double>? doubles(Object? v) => v is List
      ? v.map((e) => (e as num).toDouble()).toList(growable: false)
      : null;

  final sidecar = File('$captureDir/sfm_fed_frames.jsonl');
  if (sidecar.existsSync()) {
    try {
      for (final line in await sidecar.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final m = jsonDecode(line) as Map<String, Object?>;
        final fid = m['frameId'] as int;
        final jpeg = '$photosDir/${(m['jpegPath'] as String).split('/').last}';
        final grayW = (m['grayW'] as num).toInt();
        final grayH = (m['grayH'] as num).toInt();
        map[fid] = SfmFedFrameMeta(
          jpegPath: jpeg,
          imageW: grayW, // 占位(sidecar 不含全分辨率;resume 链不读)
          imageH: grayH,
          grayW: grayW,
          grayH: grayH,
          fx: 0,
          fy: 0,
          cx: 0,
          cy: 0,
          arkitQuatWxyz: doubles(m['arkitCamFromWorldQwxyz']),
          arkitTransTxyz: doubles(m['arkitCamFromWorldTxyz']),
          arkitCameraCenterWorld: doubles(m['arkitCameraCenterWorld']),
        );
      }
    } catch (_) {}
    if (map.isNotEmpty) return map;
  }

  // Legacy fallback: order the per-frame JSONs by capture timestamp.
  // 无 ARKit 四元数 → 重力对齐自然跳过(cnt<3 门),行为与旧版一致。
  final dir = Directory(photosDir);
  if (!dir.existsSync()) return map;
  final rows = <({double t, String jpeg, int w, int h})>[];
  for (final f in dir.listSync()) {
    if (!f.path.endsWith('.json')) continue;
    try {
      final j =
          jsonDecode(await File(f.path).readAsString()) as Map<String, Object?>;
      final t =
          (j['t'] as num?)?.toDouble() ??
          (j['save_target_t'] as num?)?.toDouble() ??
          0;
      final w = (j['image_w'] as num?)?.toInt() ?? 3840;
      final h = (j['image_h'] as num?)?.toInt() ?? 2160;
      final jpeg = f.path.replaceAll(RegExp(r'\.json$'), '.jpg');
      if (File(jpeg).existsSync()) rows.add((t: t, jpeg: jpeg, w: w, h: h));
    } catch (_) {}
  }
  rows.sort((a, b) => a.t.compareTo(b.t));
  for (var i = 0; i < rows.length; i++) {
    map[i] = SfmFedFrameMeta(
      jpegPath: rows[i].jpeg,
      imageW: rows[i].w,
      imageH: rows[i].h,
      grayW: rows[i].w,
      grayH: rows[i].h,
      fx: 0,
      fy: 0,
      cx: 0,
      cy: 0,
    );
  }
  return map;
}

/// Fast native JPEG decode (ImageIO downscale to 1280px, raw sensor
/// orientation) — the same channel the live colorizer uses.
Future<({Uint8List rgb, int w, int h})?> _decodeJpegNative(
  String jpegPath,
) async {
  try {
    final res = await _arKitChannel.invokeMethod<Map<Object?, Object?>>(
      'decodeJpegForColor',
      {'jpegPath': jpegPath, 'maxPx': 1280},
    );
    if (res == null) return null;
    final w = res['w'] as int?, h = res['h'] as int?;
    final rgb = res['rgb'] as Uint8List?;
    if (w == null || h == null || rgb == null || w <= 0 || h <= 0) return null;
    if (rgb.length < w * h * 3) return null;
    return (rgb: rgb, w: w, h: h);
  } catch (_) {
    return null;
  }
}

Future<void> _umbrella(String method, String captureDir) async {
  try {
    await _arKitChannel.invokeMethod<void>(method, <String, Object?>{
      'jobId': captureDir,
    });
  } catch (_) {}
}
