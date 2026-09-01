import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'archive_audit_store.dart';
import 'archive_background_scheduler.dart';
import 'aux_archive_transaction.dart';
import 'database_archive_codec.dart';
import 'database_archive_policy.dart';
import 'database_archive_preprocessor.dart';
import 'database_archive_transaction.dart';
import 'database_recipe_transaction.dart';
import 'photo_archive_codec.dart';
import 'photo_archive_policy.dart';
import 'photo_archive_transaction.dart';
import 'pwva_master.dart';
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

/// Serializes cold photo archive work across official captures.
class PhotoArchiveCoordinator {
  PhotoArchiveCoordinator({
    required this.codec,
    this.codecsByName = const <String, PhotoArchiveCodec>{},
    this.databaseCodec,
    this.databasePreprocessor,
    this.auditStore,
    ArchiveBackgroundScheduler? backgroundScheduler,
  }) : backgroundScheduler =
           backgroundScheduler ?? const NoopArchiveBackgroundScheduler();

  final PhotoArchiveCodec codec;
  final Map<String, PhotoArchiveCodec> codecsByName;
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
    _requestPhotoCancellation();
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

  /// Pauses cold archive work for a production task that is not tied to an
  /// archive-eligible official capture directory (for example, resuming a
  /// legacy reconstruction draft).
  PhotoArchiveActivityLease beginProcessingActivity() =>
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
    _requestPhotoCancellation();
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
      // [2026-08-12] PWVA 转码在飞:让主本接管拿到第一手机会。
      // 采集结束→稀疏 PLY 落盘→本队列被触发,而收尾转码要几十秒。若此刻
      // 放行,PwvaMasterTransaction 会因"归档还没写完"放弃,紧接着 Lepton
      // 就把 JPEG 归档成 .lep —— 接管机会**永久**丢失(照片于是两份都存)。
      // 有界:归档收尾会写 archive-report(成功/失败都写),报告一出即放行;
      // 码流 10 分钟没动静(isolate 被杀)也放行,绝不把 capture 永久卡住。
      if (await _pwvaTranscodeInFlight(item.value)) {
        _pending[item.key] = item.value;
        _triggerByPath[item.key] = trigger;
        await _recordAudit(
          event: 'capture_not_ready',
          trigger: trigger,
          captureId: _captureId(item.value),
          details: const <String, Object?>{
            'reason': 'pwva_transcode_in_flight',
            'work_remaining': true,
          },
        );
        continue;
      }
      await removeTransientCapturePreviews(item.value);
      // PWVA 主本接管(P2 去 JPEG 化)先行:验证通过则删策展 JPEG 原件,
      // 后续 Lepton 事务对已接管帧按 skipped 处理;任何验证不过 = 不适用,
      // 一个字节不动,capture 照旧走 Lepton 线。
      final master = await PwvaMasterTransaction(
        canContinue: () =>
            !isProductionPipelineActive &&
            runGeneration == _interruptionGeneration,
      ).masterCapture(item.value);
      if (master.paused || master.failedNames.isNotEmpty) {
        _pending[item.key] = item.value;
        _triggerByPath[item.key] = trigger;
        await _recordAudit(
          event: master.paused ? 'capture_paused' : 'capture_retry_required',
          trigger: trigger,
          captureId: _captureId(item.value),
          details: <String, Object?>{
            'photos_pwva_mastered': master.masteredNames.length,
            'photos_pwva_failed': master.failedNames.length,
            'work_remaining': true,
          },
        );
        return;
      }
      final result = await PhotoArchiveTransaction(
        codec: codec,
        codecsByName: codecsByName,
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
      // B1 配方化(签决 2026-08-10)先于 ZPAQ:配方提交则 DB 字节按签决删除,
      // ZPAQ 事务对已配方化 capture 自行 skip;notApplicable 则一切照旧。
      // DatabaseRecipeTransaction.enabled=false 时恒 no-op(设备门未过)。
      final recipe = await DatabaseRecipeTransaction(
        canContinue: () =>
            !isProductionPipelineActive &&
            runGeneration == _interruptionGeneration,
      ).recipeCapture(item.value);
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
      // 附属物归档排在最后:侧车与诊断日志既不参与 PWVA/Lepton 事务,也不
      // 是 ZPAQ 的伴生文件,放在末尾就不会跟前面任何一条线抢文件。失败只
      // 影响这一项(源字节原样留着),不把整个 capture 打回重来。
      AuxArchiveRunResult? aux;
      final auxCodec = databaseCodec;
      if (auxCodec != null && !isProductionPipelineActive) {
        aux = await AuxArchiveTransaction(
          codec: auxCodec,
          canContinue: () =>
              !isProductionPipelineActive &&
              runGeneration == _interruptionGeneration,
        ).archiveCapture(item.value);
      }
      await _recordAudit(
        event: 'capture_completed',
        trigger: trigger,
        captureId: _captureId(item.value),
        details: <String, Object?>{
          'photos_archived': result.archivedNames.length,
          'photos_skipped': result.skippedNames.length,
          'photos_failed': result.failedNames.length,
          if (master.applicable)
            'photos_pwva_mastered': master.masteredNames.length,
          if (recipe.applicable) 'database_recipe_committed': recipe.committed,
          if (recipe.applicable)
            'database_recipe_deleted_bytes': recipe.deletedBytes,
          // 不适用时也记原因:今晚就因为没记而查了半天(诊断盲区)。
          if (!recipe.applicable && recipe.reason != null)
            'database_recipe_skip_reason': recipe.reason,
          if (databaseResult != null)
            'database_archived': databaseResult.archived,
          if (databaseResult != null)
            'database_skipped': databaseResult.skipped,
          if (aux != null && aux.committedBundles.isNotEmpty)
            'aux_bundles': aux.committedBundles,
          if (aux != null && aux.committedBundles.isNotEmpty)
            'aux_deleted_bytes': aux.deletedBytes,
          if (aux != null && aux.committedBundles.isNotEmpty)
            'aux_archive_bytes': aux.archiveBytes,
          if (aux != null && (aux.failed || !aux.applicable))
            'aux_skip_reason': aux.failed ? 'failed' : aux.reason,
          'work_remaining': _pending.isNotEmpty,
        },
      );
    }
  }

  void _requestPhotoCancellation() {
    final codecs = HashSet<PhotoArchiveCodec>.identity()
      ..add(codec)
      ..addAll(codecsByName.values);
    for (final photoCodec in codecs) {
      photoCodec.requestCancellation();
    }
  }

  /// 归档转码是否仍在进行(码流已开写、收尾报告未落、且近期仍有写入)。
  Future<bool> _pwvaTranscodeInFlight(Directory captureDirectory) async {
    try {
      final stream = File('${captureDirectory.path}/photos_hevc/photos.hevc');
      if (!await stream.exists()) return false;
      final report = File(
        '${captureDirectory.path}/photos_hevc/archive-report.json',
      );
      if (await report.exists()) return false;
      final age = DateTime.now().difference(await stream.lastModified());
      return age < const Duration(minutes: 10);
    } on FileSystemException {
      return false;
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
