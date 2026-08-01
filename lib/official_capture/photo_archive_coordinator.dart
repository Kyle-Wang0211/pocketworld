import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'archive_audit_store.dart';
import 'archive_background_scheduler.dart';
import 'database_archive_codec.dart';
import 'database_archive_policy.dart';
import 'database_archive_preprocessor.dart';
import 'database_archive_transaction.dart';
import 'photo_archive_codec.dart';
import 'photo_archive_policy.dart';
import 'photo_archive_transaction.dart';
import 'transient_preview_cleanup.dart';

class PhotoArchiveActivityLease {
  PhotoArchiveActivityLease(this._onClose);

  final Future<void> Function() _onClose;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
  }
}

/// Serializes cold JPEG XL archive work across official captures.
class PhotoArchiveCoordinator {
  PhotoArchiveCoordinator({
    required this.codec,
    this.databaseCodec,
    this.databasePreprocessor,
    this.auditStore,
    ArchiveBackgroundScheduler? backgroundScheduler,
  }) : backgroundScheduler =
           backgroundScheduler ?? const NoopArchiveBackgroundScheduler();

  final PhotoArchiveCodec codec;
  final DatabaseArchiveCodec? databaseCodec;
  final DatabaseArchivePreprocessor? databasePreprocessor;
  final OfficialArchiveAuditStore? auditStore;
  final ArchiveBackgroundScheduler backgroundScheduler;
  final LinkedHashMap<String, Directory> _pending =
      LinkedHashMap<String, Directory>();
  final Map<String, String> _triggerByPath = <String, String>{};
  final Set<String> _reconstructionOwners = <String>{};
  int _activeProductionPipelineCount = 0;
  int _interruptionGeneration = 0;
  Future<void>? _pumpFuture;

  bool get hasPendingWork => _pending.isNotEmpty;
  bool get isProductionPipelineActive => _activeProductionPipelineCount != 0;
  int get activeProductionPipelineCount => _activeProductionPipelineCount;

  void requestSystemInterruption() {
    _interruptionGeneration++;
    databaseCodec?.requestCancellation();
    databasePreprocessor?.requestCancellation();
    unawaited(
      _recordAudit(
        event: 'system_interrupted',
        trigger: 'bg_processing',
        details: const <String, Object?>{'work_remaining': true},
      ),
    );
  }

  PhotoArchiveActivityLease beginCaptureActivity() =>
      _beginProductionActivity();

  PhotoArchiveActivityLease beginReconstructionActivity(
    Directory captureDirectory,
  ) => _beginProductionActivity(reconstructionDirectory: captureDirectory);

  PhotoArchiveActivityLease _beginProductionActivity({
    Directory? reconstructionDirectory,
  }) {
    _activeProductionPipelineCount++;
    if (reconstructionDirectory != null) {
      _reconstructionOwners.add(_canonicalKey(reconstructionDirectory));
    }
    databaseCodec?.requestCancellation();
    databasePreprocessor?.requestCancellation();
    return PhotoArchiveActivityLease(
      () => _releaseProductionActivity(
        reconstructionDirectory: reconstructionDirectory,
      ),
    );
  }

  Future<void> _releaseProductionActivity({
    Directory? reconstructionDirectory,
  }) async {
    if (_activeProductionPipelineCount > 0) {
      _activeProductionPipelineCount--;
    }
    if (reconstructionDirectory != null) {
      final path = _canonicalKey(reconstructionDirectory);
      _reconstructionOwners.remove(path);
      _pending[path] = reconstructionDirectory.absolute;
    }
    if (isProductionPipelineActive) return;

    // A production lease can close before an interruptible database codec has
    // observed its cancellation request. Wait for that transaction to reach
    // its source-safe boundary, then restart anything it requeued.
    final active = _pumpFuture;
    if (active != null) await active;
    if (_pending.isNotEmpty) await _pumpQueue();
  }

  Future<void> noteArtifactsPersisted(Directory captureDirectory) async {
    final key = _canonicalKey(captureDirectory);
    _pending[key] = captureDirectory.absolute;
    _triggerByPath[key] = 'artifacts_persisted';
    await _recordAudit(
      event: 'capture_enqueued',
      trigger: 'artifacts_persisted',
      captureId: _captureId(captureDirectory),
      details: const <String, Object?>{'work_remaining': true},
    );
    await _scheduleBackground();
    await _pumpQueue();
  }

  /// Restarts only work explicitly opted in by the creation-time marker.
  Future<void> discoverUnderDocuments(
    Directory documentsDirectory, {
    String trigger = 'startup',
  }) async {
    final captures = Directory('${documentsDirectory.path}/captures_official');
    await _recordAudit(
      event: 'scan_started',
      trigger: trigger,
      details: const <String, Object?>{'work_remaining': true},
    );
    try {
      if (!await captures.exists()) {
        await _recordAudit(
          event: 'scan_completed',
          trigger: trigger,
          details: const <String, Object?>{
            'candidates': 0,
            'work_remaining': false,
          },
        );
        return;
      }
      final directories = <Directory>[];
      await for (final entity in captures.list(followLinks: false)) {
        if (entity is Directory) directories.add(entity);
      }
      directories.sort((left, right) => left.path.compareTo(right.path));
      for (final capture in directories) {
        final photoEligible =
            await PhotoArchivePolicy.readCompatible(capture) != null;
        final databaseEligible =
            await DatabaseArchivePolicy.readCompatible(capture) != null;
        if (!photoEligible && !databaseEligible) {
          continue;
        }
        final key = _canonicalKey(capture);
        _pending[key] = capture.absolute;
        _triggerByPath[key] = trigger;
      }
      if (_pending.isNotEmpty) await _scheduleBackground();
      await _pumpQueue();
      await _recordAudit(
        event: 'scan_completed',
        trigger: trigger,
        details: <String, Object?>{
          'candidates': directories.length,
          'work_remaining': _pending.isNotEmpty,
        },
      );
    } on FileSystemException {
      // Startup recovery is best effort and always fails closed.
    }
  }

  Future<void> waitForIdle() async {
    final active = _pumpFuture;
    if (active != null) await active;
  }

  Future<void> _pumpQueue() {
    final existing = _pumpFuture;
    if (existing != null) return existing;
    late final Future<void> started;
    started = _runPump().whenComplete(() async {
      if (_pending.isEmpty) {
        await _recordAudit(
          event: 'queue_drained',
          trigger: 'coordinator',
          details: const <String, Object?>{'work_remaining': false},
        );
        await _cancelScheduledBackground();
      }
      if (identical(_pumpFuture, started)) _pumpFuture = null;
    });
    _pumpFuture = started;
    return started;
  }

  Future<void> _runPump() async {
    final runGeneration = _interruptionGeneration;
    while (_pending.isNotEmpty &&
        !isProductionPipelineActive &&
        runGeneration == _interruptionGeneration) {
      final item = _pending.entries.first;
      _pending.remove(item.key);
      final trigger = _triggerByPath.remove(item.key) ?? 'coordinator';
      if (_reconstructionOwners.contains(item.key)) {
        _pending[item.key] = item.value;
        _triggerByPath[item.key] = trigger;
        return;
      }
      if (!await _isDurablyReady(item.value)) {
        await _recordAudit(
          event: 'capture_not_ready',
          trigger: trigger,
          captureId: _captureId(item.value),
          details: const <String, Object?>{'work_remaining': false},
        );
        continue;
      }
      await _recordAudit(
        event: 'capture_started',
        trigger: trigger,
        captureId: _captureId(item.value),
        details: const <String, Object?>{'work_remaining': true},
      );
      await removeTransientCapturePreviews(item.value);
      final result = await PhotoArchiveTransaction(
        codec: codec,
        canStartNext: () =>
            !isProductionPipelineActive &&
            runGeneration == _interruptionGeneration,
      ).archiveCapture(item.value);
      if (result.paused || result.failedNames.isNotEmpty) {
        _pending[item.key] = item.value;
        _triggerByPath[item.key] = trigger;
        await _recordAudit(
          event: result.paused ? 'capture_paused' : 'capture_retry_required',
          trigger: trigger,
          captureId: _captureId(item.value),
          details: <String, Object?>{
            'photos_archived': result.archivedNames.length,
            'photos_failed': result.failedNames.length,
            'work_remaining': true,
          },
        );
        return;
      }
      final database = databaseCodec;
      DatabaseArchiveRunResult? databaseResult;
      if (database != null && !isProductionPipelineActive) {
        databaseResult = await DatabaseArchiveTransaction(
          codec: database,
          preprocessor: databasePreprocessor,
          canContinue: () =>
              !isProductionPipelineActive &&
              runGeneration == _interruptionGeneration,
        ).archiveCapture(item.value);
        if (databaseResult.interrupted ||
            databaseResult.failed ||
            isProductionPipelineActive ||
            runGeneration != _interruptionGeneration) {
          _pending[item.key] = item.value;
          _triggerByPath[item.key] = trigger;
          await _recordAudit(
            event: databaseResult.interrupted
                ? 'capture_paused'
                : 'capture_retry_required',
            trigger: trigger,
            captureId: _captureId(item.value),
            details: <String, Object?>{
              'photos_archived': result.archivedNames.length,
              'database_interrupted': databaseResult.interrupted,
              'database_failed': databaseResult.failed,
              'work_remaining': true,
            },
          );
          return;
        }
      }
      await _recordAudit(
        event: 'capture_completed',
        trigger: trigger,
        captureId: _captureId(item.value),
        details: <String, Object?>{
          'photos_archived': result.archivedNames.length,
          'photos_skipped': result.skippedNames.length,
          'photos_failed': result.failedNames.length,
          if (databaseResult != null)
            'database_archived': databaseResult.archived,
          if (databaseResult != null)
            'database_skipped': databaseResult.skipped,
          'work_remaining': _pending.isNotEmpty,
        },
      );
    }
  }

  Future<bool> _isDurablyReady(Directory captureDirectory) async {
    final photoEligible =
        await PhotoArchivePolicy.readCompatible(captureDirectory) != null;
    final databaseEligible =
        await DatabaseArchivePolicy.readCompatible(captureDirectory) != null;
    if (!photoEligible && !databaseEligible) {
      return false;
    }
    for (final relativePath in const <String>[
      'official_photo_bundle.json',
      'official_sfm_sparse.ply',
      'official_sfm_sparse_meta.json',
    ]) {
      final file = File('${captureDirectory.path}/$relativePath');
      try {
        if (!await file.exists() || await file.length() == 0) return false;
      } on FileSystemException {
        return false;
      }
    }
    return true;
  }

  String _canonicalKey(Directory directory) => directory.absolute.path;

  String _captureId(Directory directory) =>
      directory.path.split(Platform.pathSeparator).last;

  Future<void> _scheduleBackground() async {
    try {
      await backgroundScheduler.schedule();
    } catch (_) {
      // Scheduling is an execution opportunity, never a source-safety gate.
    }
  }

  Future<void> _cancelScheduledBackground() async {
    try {
      await backgroundScheduler.cancelScheduled();
    } catch (_) {
      // A stale system request only causes a later idempotent disk rescan.
    }
  }

  Future<void> _recordAudit({
    required String event,
    required String trigger,
    String? captureId,
    Map<String, Object?> details = const <String, Object?>{},
  }) async {
    final store = auditStore;
    if (store == null) return;
    try {
      await store.record(
        ArchiveAuditEvent(
          timestamp: DateTime.now().toUtc(),
          event: event,
          trigger: trigger,
          captureId: captureId,
          details: details,
        ),
      );
    } catch (_) {
      // Audit is observable evidence, never part of deletion authorization.
    }
  }
}
