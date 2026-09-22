// sfm_feed_queue.dart — 拍摄期喂帧队列的纯调度谓词(零 Flutter 依赖)。
//
// 背景(07-12 签决:快门彻底与后台解耦)= 三角约束:
//   ① 快门彻底不限流:无论多热、队列多深,快门永远立即可拍;
//   ② 队列不丢帧:每一张拍下的帧最终都进 finalize(一个不少);
//   ③ 不降质:不靠降分辨率/丢帧/降采样消化积压。
//
// 队列架构(实现在 SfmLiveRecon.offerFrame/_pump/_maybeSendFinalize):
//   - 每帧先 flush 到磁盘,worker 最多同时在途 [kSfmFeedMaxInFlight] 个;
//   - in-flight 项仍留在 durable queue；OK ack 原子移动 pending→fed，
//     内部 replay 文件直到最终点云成功落盘后才删除;
//   - slot 一空且 thermal scheduler 允许时,pump 按到达顺序喂队首;
//   - 读/worker/non-OK 失败保留队首并阻断 finalize;
//   - finalize 延后到队列**彻底排空**(spool 空 + 在途为 0)才下发,
//     所以每一个 offered 帧都先进了重建 → finalize 帧数 == 拍摄帧数。
//
// 快门永不因队列深度/热态被阻挡:背压只作用在**后台消费侧**(worker 何时
// 收下一帧),绝不回压到快门。这些谓词把上面的调度决策抽成纯函数,便于
// host 断言(tool/sfm_feed_queue_check.dart:狂喂 N 帧证明零丢帧、内存
// bounded、finalize==offered、顺序保持)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sfm_orphan_recovery.dart';

/// worker 同时在途 add_frame 的上限。超过即溢写磁盘排队(不阻塞、不丢帧)。
///
/// Keep exactly one command outstanding. The worker isolate is serial anyway,
/// so a second pre-sent command adds no native parallelism; it only prevents a
/// newly arriving shutter publication from taking priority before that second
/// command starts.
const int kSfmFeedMaxInFlight = 1;

/// 这一帧持久化后是否必须等待，而不能立即由 pump 送 worker。
/// 所有帧都会先落盘；true 仅表示 worker 已满或前面还有 FIFO 项。
bool sfmFeedShouldSpool({required int inFlight, required int spoolDepth}) {
  return inFlight >= kSfmFeedMaxInFlight || spoolDepth > 0;
}

/// pump 现在是否可以把队首的磁盘帧喂给 worker。
/// true = consumer 未暂停/阻断、worker 有空位且队列非空。
bool sfmFeedCanPumpNext({
  required int inFlight,
  required int spoolDepth,
  bool consumerPaused = false,
  bool queueBlocked = false,
}) {
  return !consumerPaused &&
      !queueBlocked &&
      inFlight < kSfmFeedMaxInFlight &&
      spoolDepth > 0;
}

/// What a durable queue owner may do after one native `add_frame` result.
/// Only an explicit OK acknowledgement commits consumption of the head.
enum SfmFeedAckDisposition { removeAfterSuccess, retainAndBlock }

SfmFeedAckDisposition sfmFeedAckDisposition({required bool nativeOk}) =>
    nativeOk
    ? SfmFeedAckDisposition.removeAfterSuccess
    : SfmFeedAckDisposition.retainAndBlock;

/// 是否可以下发延后的 finalize:必须已请求完成、尚未下发、且队列
/// **彻底排空**(spool 空 + 在途为 0)。这是 ②「一个不少」的强制点——
/// 队列没排空绝不 finalize,保证所有 offered 帧都已进重建。
bool sfmFeedCanSendFinalize({
  required bool finalizeRequested,
  required bool finalizeSent,
  required int spoolDepth,
  required int inFlight,
  bool queueBlocked = false,
}) {
  return finalizeRequested &&
      !finalizeSent &&
      !queueBlocked &&
      spoolDepth == 0 &&
      inFlight == 0;
}

// ---------------------------------------------------------------------------
// Durable FIFO
// ---------------------------------------------------------------------------

/// On-disk manifest shared by capture and reconstruction integration code.
///
/// Pending removal and the corresponding fed metadata are written to this
/// single document, then published with one same-directory rename. This is the
/// atomic ACK boundary. Replay payload cleanup is a later transaction that is
/// allowed only after the final point-cloud artifact is durably published.
const String kSfmFeedManifestFileName = 'sfm_feed_manifest.json';

const String _kSfmFeedLockFileName = '.sfm_feed_manifest.lock';
const String _kSfmFeedProcessOwnerFileName = '.sfm_feed_process_owner';
const int _kSfmFeedManifestSchemaVersion = 3;
const int _kOldestSupportedSfmFeedManifestSchemaVersion = 1;
const String _kSourceGrayPath = '_sourceGrayPath';
const String _kExpectedGrayBytes = '_expectedGrayBytes';
const String _kSfmGraySha256 = 'sfmGraySha256';
const String _kExcludedReplaySuffix = '.excluded.json';
const String _kOrphanRecoveryBlockPrefix =
    'committed capture orphan evidence is incomplete:\n';

enum SfmFeedBlockKind {
  nativeNonOk,
  grayReadFailed,
  grayWriteFailed,
  manifestWriteFailed,
  replayIncomplete,
  invalidAcknowledgement,
  workerDied,
}

/// Deterministic crash points used by host tests for the final-artifact purge
/// transaction. Production callers leave the injector unset.
enum SfmFeedQueueFaultPoint {
  beforeActiveSubsetManifestPersist,
  beforeFinalArtifactCommitPersist,
  afterFinalArtifactCommitPersist,
  afterReplayPayloadDelete,
  beforeReplayPurgeCompletePersist,
}

typedef SfmFeedQueueFaultInjector =
    FutureOr<void> Function(
      SfmFeedQueueFaultPoint point,
      int processedPayloads,
    );

/// A durable or fail-closed reason why the consumer may not advance.
class SfmFeedBlock {
  const SfmFeedBlock({required this.kind, required this.message, this.frameId});

  final SfmFeedBlockKind kind;
  final String message;
  final String? frameId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'message': message,
    if (frameId != null) 'frameId': frameId,
  };

  static SfmFeedBlock fromJson(Map<String, Object?> json) {
    final kindName = _requiredString(json, 'kind');
    final kind = SfmFeedBlockKind.values.where((value) {
      return value.name == kindName;
    }).firstOrNull;
    if (kind == null) {
      throw FormatException('unknown SFM feed block kind: $kindName');
    }
    return SfmFeedBlock(
      kind: kind,
      message: _requiredString(json, 'message'),
      frameId: _optionalString(json, 'frameId'),
    );
  }

  @override
  String toString() => 'SfmFeedBlock(${kind.name}, frame=$frameId, $message)';
}

/// One FIFO entry. The gray payload and descriptor are durable before the
/// entry is published in the manifest.
class SfmFeedDurableFrame {
  SfmFeedDurableFrame._({
    required this.id,
    required this.sequence,
    required this.grayFile,
    required this.descriptorFile,
    required Map<String, Object?> metadata,
  }) : metadata = Map<String, Object?>.unmodifiable(metadata);

  final String id;
  final int sequence;
  final File grayFile;
  final File descriptorFile;
  final Map<String, Object?> metadata;

  Map<String, Object?> _toJson() => <String, Object?>{
    'id': id,
    'sequence': sequence,
    'grayFile': _leafName(grayFile.path),
    'descriptorFile': _leafName(descriptorFile.path),
    'metadata': metadata,
  };

  static SfmFeedDurableFrame _fromJson(
    Directory directory,
    Map<String, Object?> json,
  ) {
    final id = _requiredString(json, 'id');
    final sequence = _requiredInt(json, 'sequence');
    final grayLeaf = _requiredSafeLeaf(json, 'grayFile');
    final descriptorLeaf = json.containsKey('descriptorFile')
        ? _requiredSafeLeaf(json, 'descriptorFile')
        : '$id.json';
    final rawMetadata = json['metadata'];
    if (rawMetadata is! Map) {
      throw const FormatException('frame metadata must be a JSON object');
    }
    return SfmFeedDurableFrame._(
      id: id,
      sequence: sequence,
      grayFile: File(_childPath(directory.path, grayLeaf)),
      descriptorFile: File(_childPath(directory.path, descriptorLeaf)),
      metadata: Map<String, Object?>.from(rawMetadata),
    );
  }
}

/// Bytes claimed for one native `add_frame` invocation. Claims are in-memory
/// leases only; after a process restart every pending manifest entry replays.
class SfmFeedClaim {
  const SfmFeedClaim({required this.frame, required this.grayBytes});

  final SfmFeedDurableFrame frame;
  final Uint8List grayBytes;
}

/// Metadata committed in the same manifest transaction as an OK ACK.
class SfmFeedFedRecord {
  SfmFeedFedRecord._({
    required this.id,
    required this.sequence,
    required Map<String, Object?> fedMeta,
  }) : fedMeta = Map<String, Object?>.unmodifiable(fedMeta);

  final String id;
  final int sequence;
  final Map<String, Object?> fedMeta;

  Map<String, Object?> _toJson() => <String, Object?>{
    'id': id,
    'sequence': sequence,
    'fedMeta': fedMeta,
  };

  static SfmFeedFedRecord _fromJson(Map<String, Object?> json) {
    final rawFedMeta = json['fedMeta'];
    if (rawFedMeta is! Map) {
      throw const FormatException('fedMeta must be a JSON object');
    }
    return SfmFeedFedRecord._(
      id: _requiredString(json, 'id'),
      sequence: _requiredInt(json, 'sequence'),
      fedMeta: Map<String, Object?>.from(rawFedMeta),
    );
  }
}

/// Immutable in-process visibility for code that must inspect a live queue
/// without opening the lock inode a second time.
class SfmFeedQueueReadSnapshot {
  const SfmFeedQueueReadSnapshot({
    required this.ownerOpening,
    required this.spoolDepth,
    required this.fedCount,
    required this.nextSequence,
    required this.nativeReplayRequired,
    required this.finalArtifactCommitted,
    required this.replayPurgePending,
    required this.block,
  });

  final bool ownerOpening;
  final int spoolDepth;
  final int fedCount;
  final int nextSequence;
  final bool nativeReplayRequired;
  final bool finalArtifactCommitted;
  final bool replayPurgePending;
  final SfmFeedBlock? block;

  bool get blocked => block != null;
}

/// Durable, cross-process-replayable FIFO owner for gray frames.
///
/// Integration boundary:
///  * call [enqueueGray] before offering a frame to native code;
///  * call [claimNext] in pump order (at most [kSfmFeedMaxInFlight] claims);
///  * pass every native result to [acknowledge];
///  * an OK result is not consumed until the manifest atomically records both
///    pending removal and [fedMeta]; non-OK/read/write errors retain and block;
///  * derive finalize permission only through [canSendFinalize].
///
/// [open] takes an exclusive advisory lock for the owner's lifetime. A crashed
/// process releases the OS lock; the next owner replays the manifest and any
/// descriptor/payload published just before a manifest commit.
class SfmDurableFeedQueue {
  SfmDurableFeedQueue._(
    this._directory,
    this._manifestFile,
    this._lockHandle,
    this._state,
    this._faultInjector,
    this._ownershipKey,
    this._processOwnerFile,
    this._processOwnerToken,
  );

  static final Map<String, SfmDurableFeedQueue?> _processOwners =
      <String, SfmDurableFeedQueue?>{};

  final Directory _directory;
  final File _manifestFile;
  RandomAccessFile? _lockHandle;
  _SfmFeedManifestState _state;
  final SfmFeedQueueFaultInjector? _faultInjector;
  final String _ownershipKey;
  final File _processOwnerFile;
  final String _processOwnerToken;
  final Set<String> _claimed = <String>{};
  final Map<String, Uint8List> _volatileGray = <String, Uint8List>{};
  SfmFeedBlock? _runtimeBlock;
  Future<void> _operationTail = Future<void>.value();
  bool _closed = false;

  static Future<SfmDurableFeedQueue> open(
    Directory directory, {
    SfmFeedQueueFaultInjector? faultInjector,
  }) async {
    await directory.create(recursive: true);
    final ownershipKey = await directory.resolveSymbolicLinks();
    if (_processOwners.containsKey(ownershipKey)) {
      throw StateError(
        'SfmDurableFeedQueue already has a process owner: $ownershipKey',
      );
    }
    // Reserve synchronously before the first lock await so two same-isolate
    // opens cannot both reach fcntl/flock ownership.
    _processOwners[ownershipKey] = null;
    final lockFile = File(_childPath(ownershipKey, _kSfmFeedLockFileName));
    final processOwnerFile = File(
      _childPath(ownershipKey, _kSfmFeedProcessOwnerFileName),
    );
    final processOwnerToken =
        '$pid|${DateTime.now().microsecondsSinceEpoch}|'
        '${identityHashCode(processOwnerFile)}';
    RandomAccessFile? lock;
    var ownsProcessToken = false;
    try {
      String? priorToken;
      try {
        await _createProcessOwnerToken(processOwnerFile, processOwnerToken);
        ownsProcessToken = true;
      } on FileSystemException {
        priorToken = await _readProcessOwnerToken(processOwnerFile);
        if (_processOwnerPid(priorToken) == pid) {
          throw StateError(
            'SfmDurableFeedQueue already has a process owner: $ownershipKey',
          );
        }
      }

      lock = await lockFile.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      if (!ownsProcessToken) {
        final confirmedToken = await _readProcessOwnerToken(processOwnerFile);
        if (confirmedToken != priorToken) {
          throw StateError('queue process ownership changed during open');
        }
        await processOwnerFile.delete();
        await _createProcessOwnerToken(processOwnerFile, processOwnerToken);
        ownsProcessToken = true;
      }
      final manifest = File(_childPath(ownershipKey, kSfmFeedManifestFileName));
      final canonicalDirectory = Directory(ownershipKey);
      var state = await _loadManifest(canonicalDirectory, manifest);
      final replay = await _replayUncommittedFiles(canonicalDirectory, state);
      state = replay.state;
      if (replay.changed || !await manifest.exists()) {
        state = state.withGeneration(state.generation + 1);
        await _writeManifestAtomically(manifest, state);
      }
      final queue = SfmDurableFeedQueue._(
        canonicalDirectory,
        manifest,
        lock,
        state,
        faultInjector,
        ownershipKey,
        processOwnerFile,
        processOwnerToken,
      );
      _processOwners[ownershipKey] = queue;
      return queue;
    } catch (_) {
      await lock?.close();
      if (ownsProcessToken) {
        await _deleteProcessOwnerTokenIfMatching(
          processOwnerFile,
          processOwnerToken,
        );
      }
      if (_processOwners[ownershipKey] == null) {
        _processOwners.remove(ownershipKey);
      }
      rethrow;
    }
  }

  /// Returns a point-in-time view of an existing process owner. It never
  /// opens or closes the lock file and grants no mutation capability.
  static Future<SfmFeedQueueReadSnapshot?> processOwnerSnapshot(
    Directory directory,
  ) async {
    if (!await directory.exists()) return null;
    final key = await directory.resolveSymbolicLinks();
    if (!_processOwners.containsKey(key)) return null;
    final owner = _processOwners[key];
    if (owner == null) {
      return const SfmFeedQueueReadSnapshot(
        ownerOpening: true,
        spoolDepth: 0,
        fedCount: 0,
        nextSequence: 0,
        nativeReplayRequired: false,
        finalArtifactCommitted: false,
        replayPurgePending: false,
        block: null,
      );
    }
    return owner._readSnapshot();
  }

  SfmFeedQueueReadSnapshot _readSnapshot() => SfmFeedQueueReadSnapshot(
    ownerOpening: false,
    spoolDepth: spoolDepth,
    fedCount: fedCount,
    nextSequence: nextSequence,
    nativeReplayRequired: nativeReplayRequired,
    finalArtifactCommitted: finalArtifactCommitted,
    replayPurgePending: replayPurgePending,
    block: blockReason,
  );

  int get spoolDepth => _state.pending.length;
  int get fedCount => _state.fed.length;
  int get nextSequence => _state.nextSequence;
  bool get nativeReplayRequired => _state.nativeReplayRequired;
  bool get requiresLegacyFinalArtifactAdoption =>
      _state.persistedSchemaVersion < _kSfmFeedManifestSchemaVersion &&
      !_state.finalArtifactCommitted;
  bool get finalArtifactCommitted => _state.finalArtifactCommitted;
  bool get replayPurgePending => _state.replayPurgePending;
  bool get blocked => _runtimeBlock != null || _state.block != null;
  SfmFeedBlock? get blockReason => _runtimeBlock ?? _state.block;
  List<SfmFeedDurableFrame> get pendingFrames =>
      List<SfmFeedDurableFrame>.unmodifiable(_state.pending);
  List<SfmFeedFedRecord> get fedRecords =>
      List<SfmFeedFedRecord>.unmodifiable(_state.fed);

  /// Cold-recovery bridge for the crash window after native manual-v2 has
  /// committed JPEG/sidecar/gray but before [enqueueGrayFile] wrote a queue
  /// descriptor.
  ///
  /// This is deliberately *not* part of [open]. During a live capture the
  /// native serial writer can transiently expose sidecar, then gray, before
  /// its final JPEG commit marker; scanning that in-flight publication would
  /// create a false durable block. Resume code may call this only after the
  /// old process is gone (or writers are otherwise proven quiescent).
  Future<SfmOrphanRecoveryScan>
  recoverCommittedCaptureSourcesAfterWriterQuiescence(
    Directory sourceDirectory, {
    required bool writersQuiesced,
  }) async {
    if (!writersQuiesced) {
      throw StateError('orphan recovery requires quiesced native writers');
    }
    final ownedJobIds = <String>{};
    final ownedJpegPaths = <String>{};
    void collect(Map<String, Object?> metadata) {
      final jobId = metadata['captureJobId'];
      if (jobId is String && jobId.isNotEmpty) ownedJobIds.add(jobId);
      final jpegPath = metadata['jpegPath'];
      if (jpegPath is String && jpegPath.isNotEmpty) {
        ownedJpegPaths.add(File(jpegPath).absolute.path);
      }
    }

    for (final frame in _state.pending) {
      collect(frame.metadata);
    }
    for (final record in _state.fed) {
      collect(record.fedMeta);
    }
    final scan = await scanCommittedSfmOrphans(
      sourceDirectory,
      queueOwnedCaptureJobIds: ownedJobIds,
      queueOwnedJpegPaths: ownedJpegPaths,
    );
    if (scan.blocks.isNotEmpty) {
      final first = scan.blocks.first;
      final block = SfmFeedBlock(
        kind: SfmFeedBlockKind.replayIncomplete,
        frameId: first.captureJobId,
        message:
            '$_kOrphanRecoveryBlockPrefix${first.evidencePath}\n'
            '${first.kind.name}: ${first.message}',
      );
      if (_state.finalArtifactCommitted) {
        throw StateError(block.message);
      }
      final current = blockReason;
      if (current == null ||
          (current.kind == SfmFeedBlockKind.replayIncomplete &&
              current.message.startsWith(_kOrphanRecoveryBlockPrefix))) {
        await retainAndBlock(block);
      }
      return scan;
    }

    final existingBlock = blockReason;
    if (existingBlock?.kind == SfmFeedBlockKind.replayIncomplete &&
        existingBlock!.message.startsWith(_kOrphanRecoveryBlockPrefix)) {
      final remainder = existingBlock.message.substring(
        _kOrphanRecoveryBlockPrefix.length,
      );
      final newline = remainder.indexOf('\n');
      final evidencePath = newline < 0
          ? remainder
          : remainder.substring(0, newline);
      final evidenceRestored = scan.committedOrphans.any(
        (orphan) =>
            orphan.grayFile.absolute.path == evidencePath ||
            orphan.sidecarFile.absolute.path == evidencePath,
      );
      if (evidenceRestored && !await clearBlockForRetry()) {
        throw StateError('could not clear restored orphan evidence block');
      }
    }

    if (_state.finalArtifactCommitted && scan.committedOrphans.isNotEmpty) {
      throw StateError(
        'committed capture orphan appeared after final artifact receipt',
      );
    }
    for (final orphan in scan.committedOrphans) {
      await enqueueGrayFile(
        sourceGrayFile: orphan.grayFile,
        expectedByteLength: orphan.expectedGrayBytes,
        metadata: orphan.toDurableQueueMetadata(),
      );
    }
    return scan;
  }

  /// Writes gray bytes and a recovery descriptor before publishing the entry.
  /// Calls are serialized, so manifest sequence is capture/FIFO sequence.
  Future<SfmFeedDurableFrame> enqueueGray({
    required Uint8List grayBytes,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final stableBytes = Uint8List.fromList(grayBytes);
    final stableMetadata = _metadataWithGrayDigest(
      _normalizeJsonMap(<String, Object?>{
        ...metadata,
        _kExpectedGrayBytes: stableBytes.length,
      }, label: 'metadata'),
      sha256.convert(stableBytes).toString(),
    );
    return _serialized(() async {
      _ensureAcceptingFrames();
      final sequence = _state.nextSequence;
      final id = 'frame-${sequence.toString().padLeft(20, '0')}';
      final frame = SfmFeedDurableFrame._(
        id: id,
        sequence: sequence,
        grayFile: File(_childPath(_directory.path, '$id.gray')),
        descriptorFile: File(_childPath(_directory.path, '$id.json')),
        metadata: stableMetadata,
      );
      final pending = <SfmFeedDurableFrame>[..._state.pending, frame];
      var nextState = _state.copyWith(
        nextSequence: sequence + 1,
        pending: pending,
        block: blockReason,
      );

      try {
        await _writeBytesAtomically(frame.grayFile, stableBytes);
      } catch (error) {
        _volatileGray[id] = stableBytes;
        _state = nextState;
        _runtimeBlock = SfmFeedBlock(
          kind: SfmFeedBlockKind.grayWriteFailed,
          frameId: id,
          message: 'gray write failed: $error',
        );
        return frame;
      }

      try {
        await _writeJsonAtomically(frame.descriptorFile, frame._toJson());
      } catch (error) {
        _state = nextState;
        _runtimeBlock = SfmFeedBlock(
          kind: SfmFeedBlockKind.manifestWriteFailed,
          frameId: id,
          message: 'frame descriptor write failed: $error',
        );
        return frame;
      }

      nextState = nextState.copyWith(block: blockReason);
      final failure = await _tryCommit(nextState);
      if (failure != null) {
        // The descriptor makes this entry replayable after a crash. Keep the
        // same in-memory head as well, and fail closed until commit is retried.
        _state = nextState;
        _runtimeBlock = failure;
      }
      return frame;
    });
  }

  /// Publishes an already-fsynced gray file without copying its bytes.
  ///
  /// The recovery descriptor lands first and records the source path. The
  /// source is then atomically renamed into the queue directory (same app data
  /// volume), followed by the manifest transaction. A crash between any two
  /// steps is replayable: descriptor+source completes the move, while
  /// descriptor+destination restores the manifest entry. No pixel payload is
  /// deleted or downsampled; ownership changes from the capture bundle to the
  /// durable FIFO and exactly one full-resolution copy remains.
  Future<SfmFeedDurableFrame> enqueueGrayFile({
    required File sourceGrayFile,
    required int expectedByteLength,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    if (expectedByteLength <= 0) {
      throw ArgumentError.value(
        expectedByteLength,
        'expectedByteLength',
        'must be positive',
      );
    }
    final sourcePath = sourceGrayFile.absolute.path;
    final baseMetadata = _normalizeJsonMap(<String, Object?>{
      ...metadata,
      _kSourceGrayPath: sourcePath,
      _kExpectedGrayBytes: expectedByteLength,
    }, label: 'metadata');
    _declaredGrayDigest(baseMetadata);
    return _serialized(() async {
      _ensureAcceptingFrames();
      final sequence = _state.nextSequence;
      final id = 'frame-${sequence.toString().padLeft(20, '0')}';
      var frame = SfmFeedDurableFrame._(
        id: id,
        sequence: sequence,
        grayFile: File(_childPath(_directory.path, '$id.gray')),
        descriptorFile: File(_childPath(_directory.path, '$id.json')),
        metadata: baseMetadata,
      );
      var pending = <SfmFeedDurableFrame>[..._state.pending, frame];
      var nextState = _state.copyWith(
        nextSequence: sequence + 1,
        pending: pending,
        block: blockReason,
      );

      try {
        final actualBytes = await sourceGrayFile.length();
        if (actualBytes != expectedByteLength) {
          throw StateError(
            'source gray has $actualBytes bytes; expected $expectedByteLength',
          );
        }
        var stableMetadata = baseMetadata;
        if (_declaredGrayDigest(stableMetadata) == null) {
          stableMetadata = _metadataWithGrayDigest(
            stableMetadata,
            await _sha256File(sourceGrayFile),
          );
          frame = _copyFrameWithMetadata(frame, stableMetadata);
          pending = <SfmFeedDurableFrame>[..._state.pending, frame];
          nextState = _state.copyWith(
            nextSequence: sequence + 1,
            pending: pending,
            block: blockReason,
          );
        }
        // Descriptor first: if the process dies before the rename, reopen can
        // recover the source path and complete the exact same queue identity.
        await _writeJsonAtomically(frame.descriptorFile, frame._toJson());
        await sourceGrayFile.rename(frame.grayFile.path);
        await _verifyGrayFile(frame, migrateMissingDigest: false);
      } catch (error) {
        _state = nextState;
        _runtimeBlock = SfmFeedBlock(
          kind: SfmFeedBlockKind.grayWriteFailed,
          frameId: id,
          message: 'gray ownership move failed: $error',
        );
        return frame;
      }

      final failure = await _tryCommit(nextState);
      if (failure != null) {
        _state = nextState;
        _runtimeBlock = failure;
      }
      return frame;
    });
  }

  /// Claims the earliest not-already-in-flight frame. Read failures never
  /// consume the entry and persist a block when storage permits.
  Future<SfmFeedClaim?> claimNext() => _serialized(() async {
    if (blocked) return null;
    if (_claimed.length >= kSfmFeedMaxInFlight) return null;
    SfmFeedDurableFrame? frame;
    for (final candidate in _state.pending) {
      if (!_claimed.contains(candidate.id)) {
        frame = candidate;
        break;
      }
    }
    if (frame == null) return null;
    var claimedFrame = frame;
    try {
      final bytes = await claimedFrame.grayFile.readAsBytes();
      String? descriptorDigest;
      if (_declaredGrayDigest(claimedFrame.metadata) == null &&
          await claimedFrame.descriptorFile.exists()) {
        final decoded = jsonDecode(
          await claimedFrame.descriptorFile.readAsString(),
        );
        if (decoded is! Map) {
          throw const _GrayIntegrityError(
            'legacy frame descriptor is not a JSON object',
          );
        }
        final diskFrame = SfmFeedDurableFrame._fromJson(
          _directory,
          Map<String, Object?>.from(decoded),
        );
        if (diskFrame.id != claimedFrame.id ||
            diskFrame.sequence != claimedFrame.sequence) {
          throw const _GrayIntegrityError(
            'legacy frame descriptor identity mismatch',
          );
        }
        descriptorDigest = _declaredGrayDigest(diskFrame.metadata);
      }
      final digest = _verifyGrayBytes(
        claimedFrame,
        bytes,
        expectedDigest: descriptorDigest,
      );
      if (_declaredGrayDigest(claimedFrame.metadata) == null) {
        final migrated = _copyFrameWithMetadata(
          claimedFrame,
          _metadataWithGrayDigest(claimedFrame.metadata, digest),
        );
        await _writeJsonAtomically(migrated.descriptorFile, migrated._toJson());
        final pending = <SfmFeedDurableFrame>[
          for (final candidate in _state.pending)
            if (candidate.id == migrated.id) migrated else candidate,
        ];
        final failure = await _tryCommit(_state.copyWith(pending: pending));
        if (failure != null) {
          _runtimeBlock = failure;
          return null;
        }
        claimedFrame = migrated;
      }
      _claimed.add(claimedFrame.id);
      return SfmFeedClaim(frame: claimedFrame, grayBytes: bytes);
    } catch (error) {
      await _retainAndBlock(
        SfmFeedBlock(
          kind: SfmFeedBlockKind.grayReadFailed,
          frameId: claimedFrame.id,
          message: 'gray read failed: $error',
        ),
      );
      return null;
    }
  });

  /// Records one native result. Only [nativeOk] can remove a pending entry.
  /// The OK transaction also appends [fedMeta] to the same manifest generation.
  /// Payloads remain available for an unambiguous full replay until the final
  /// reconstruction artifact is durably published.
  Future<SfmFeedAckDisposition> acknowledge({
    required String frameId,
    required bool nativeOk,
    Map<String, Object?> fedMeta = const <String, Object?>{},
  }) {
    final stableFedMeta = _normalizeJsonMap(fedMeta, label: 'fedMeta');
    return _serialized(() async {
      final pendingIndex = _state.pending.indexWhere(
        (frame) => frame.id == frameId,
      );
      if (pendingIndex < 0) {
        final alreadyFed = _state.fed.any((record) => record.id == frameId);
        if (nativeOk && alreadyFed) {
          return SfmFeedAckDisposition.removeAfterSuccess;
        }
        await _retainAndBlock(
          SfmFeedBlock(
            kind: SfmFeedBlockKind.invalidAcknowledgement,
            frameId: frameId,
            message: 'native result does not match a pending frame',
          ),
        );
        return SfmFeedAckDisposition.retainAndBlock;
      }

      if (!_claimed.contains(frameId)) {
        await _retainAndBlock(
          SfmFeedBlock(
            kind: SfmFeedBlockKind.invalidAcknowledgement,
            frameId: frameId,
            message: 'native result arrived for a frame that was never claimed',
          ),
        );
        return SfmFeedAckDisposition.retainAndBlock;
      }

      final frame = _state.pending[pendingIndex];
      if (!nativeOk) {
        _claimed.remove(frameId);
        await _retainAndBlock(
          SfmFeedBlock(
            kind: SfmFeedBlockKind.nativeNonOk,
            frameId: frameId,
            message: 'native add_frame returned non-OK',
          ),
        );
        return SfmFeedAckDisposition.retainAndBlock;
      }

      late final Map<String, Object?> durableFedMeta;
      try {
        final frameDigest = _declaredGrayDigest(frame.metadata);
        if (frameDigest == null) {
          throw const _GrayIntegrityError(
            'claimed frame has no durable gray digest',
          );
        }
        final acknowledgedDigest = _declaredGrayDigest(stableFedMeta);
        if (acknowledgedDigest != null && acknowledgedDigest != frameDigest) {
          throw const _GrayIntegrityError(
            'ACK gray digest does not match claimed frame',
          );
        }
        durableFedMeta = <String, Object?>{
          ...stableFedMeta,
          _kSfmGraySha256: frameDigest,
        };
      } catch (error) {
        _claimed.remove(frameId);
        await _retainAndBlock(
          SfmFeedBlock(
            kind: SfmFeedBlockKind.invalidAcknowledgement,
            frameId: frameId,
            message: 'native OK ACK has invalid gray integrity: $error',
          ),
        );
        return SfmFeedAckDisposition.retainAndBlock;
      }

      final pending = <SfmFeedDurableFrame>[..._state.pending]
        ..removeAt(pendingIndex);
      final fed = <SfmFeedFedRecord>[
        ..._state.fed,
        SfmFeedFedRecord._(
          id: frame.id,
          sequence: frame.sequence,
          fedMeta: durableFedMeta,
        ),
      ]..sort((a, b) => a.sequence.compareTo(b.sequence));
      final currentBlock = blockReason;
      final nextBlock = currentBlock?.frameId == frameId ? null : currentBlock;
      final nextState = _state.copyWith(
        pending: pending,
        fed: fed,
        nativeReplayRequired: _state.nativeReplayRequired && pending.isNotEmpty,
        block: nextBlock,
        clearBlock: nextBlock == null,
      );
      final failure = await _tryCommit(nextState);
      if (failure != null) {
        // Do not install nextState and do not touch either payload file. The
        // durable/in-memory head therefore remains retryable after native OK.
        _runtimeBlock = failure;
        return SfmFeedAckDisposition.retainAndBlock;
      }

      _claimed.remove(frameId);
      _volatileGray.remove(frameId);
      // Keep the replay payload until a final reconstruction artifact is
      // durably published. If the process dies after native committed this
      // frame but before the Dart ACK, the next owner must be able to rebuild
      // a fresh DB from every accepted frame instead of guessing whether this
      // particular add_frame crossed the native commit boundary.
      return SfmFeedAckDisposition.removeAfterSuccess;
    });
  }

  /// Rewinds every acknowledged and pending frame into one ordered pending
  /// set for reconstruction into a fresh native DB.
  ///
  /// A queue opened with pending work belongs to a previous process. Appending
  /// that work to the old COLMAP DB is unsafe: native may already have written
  /// the pending image before the process died, while its OK ACK was not yet
  /// committed here. Full replay removes that ambiguity without dropping or
  /// duplicating a user-accepted frame.
  Future<bool> prepareAllForFreshNativeReplay() =>
      _serialized(() => _prepareAllForFreshNativeReplay(force: false));

  /// Forces a full replay even when every frame was already acknowledged.
  ///
  /// This is reserved for a native DB that the caller has independently found
  /// missing or corrupt. The fed-only manifest is rewound only when every
  /// descriptor and gray payload remains complete; otherwise the queue blocks
  /// durably and no frame identity is consumed.
  Future<bool> prepareAllForForcedFreshNativeReplay() =>
      _serialized(() => _prepareAllForFreshNativeReplay(force: true));

  /// Atomically replaces replay membership with exactly [activeJobIds].
  ///
  /// This is the user-deletion rebuild boundary. Every queue row must have one
  /// unambiguous captureJobId, and every requested active job must have one
  /// complete descriptor+gray payload before the manifest changes. Excluded
  /// rows receive durable per-frame tombstones first; these are harmless while
  /// the old manifest still references a row, but prevent descriptor replay
  /// from resurrecting it after the active-only manifest commits.
  Future<bool> prepareActiveJobsForFreshNativeReplay(
    Set<String> activeJobIds,
  ) => _serialized(() async {
    if (_state.finalArtifactCommitted ||
        activeJobIds.isEmpty ||
        _claimed.isNotEmpty) {
      return false;
    }
    if (activeJobIds.any(
      (jobId) =>
          jobId.isEmpty ||
          jobId.trim() != jobId ||
          !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(jobId),
    )) {
      return false;
    }

    final rows = <_SfmReplayMembershipRow>[];
    for (final frame in _state.pending) {
      final jobId = _captureJobIdFromMetadata(frame.metadata);
      if (jobId == null) return false;
      rows.add(_SfmReplayMembershipRow(frame: frame, captureJobId: jobId));
    }
    for (final record in _state.fed) {
      final descriptor = File(_childPath(_directory.path, '${record.id}.json'));
      SfmFeedDurableFrame? frame;
      if (await descriptor.exists()) {
        try {
          final decoded = jsonDecode(await descriptor.readAsString());
          if (decoded is! Map) return false;
          frame = SfmFeedDurableFrame._fromJson(
            _directory,
            Map<String, Object?>.from(decoded),
          );
          if (frame.id != record.id || frame.sequence != record.sequence) {
            return false;
          }
          final fedDigest = _declaredGrayDigest(record.fedMeta);
          final descriptorDigest = _declaredGrayDigest(frame.metadata);
          if (fedDigest != null &&
              descriptorDigest != null &&
              fedDigest != descriptorDigest) {
            throw const _GrayIntegrityError(
              'fed/descriptor gray digest mismatch',
            );
          }
          if (descriptorDigest == null && fedDigest != null) {
            frame = _copyFrameWithMetadata(
              frame,
              _metadataWithGrayDigest(frame.metadata, fedDigest),
            );
          }
        } on _GrayIntegrityError catch (error) {
          await _retainAndBlock(
            SfmFeedBlock(
              kind: SfmFeedBlockKind.replayIncomplete,
              frameId: record.id,
              message: 'active replay metadata integrity failed: $error',
            ),
          );
          return false;
        } catch (_) {
          return false;
        }
      }
      final descriptorJob = frame == null
          ? null
          : _captureJobIdFromMetadata(frame.metadata);
      final fedJob = _captureJobIdFromMetadata(record.fedMeta);
      if (descriptorJob != null && fedJob != null && descriptorJob != fedJob) {
        return false;
      }
      final jobId = descriptorJob ?? fedJob;
      if (jobId == null) return false;
      frame ??= SfmFeedDurableFrame._(
        id: record.id,
        sequence: record.sequence,
        grayFile: File(_childPath(_directory.path, '${record.id}.gray')),
        descriptorFile: descriptor,
        metadata: record.fedMeta,
      );
      rows.add(_SfmReplayMembershipRow(frame: frame, captureJobId: jobId));
    }

    final byJob = <String, _SfmReplayMembershipRow>{};
    for (final row in rows) {
      if (byJob.containsKey(row.captureJobId)) return false;
      byJob[row.captureJobId] = row;
    }
    if (!byJob.keys.toSet().containsAll(activeJobIds)) return false;
    final activeRows = <_SfmReplayMembershipRow>[];
    final excludedRows = <_SfmReplayMembershipRow>[];
    for (final row in rows) {
      (activeJobIds.contains(row.captureJobId) ? activeRows : excludedRows).add(
        row,
      );
    }
    if (activeRows.length != activeJobIds.length) return false;
    activeRows.sort(
      (left, right) => left.frame.sequence.compareTo(right.frame.sequence),
    );

    // Validate all active evidence before writing tombstones or manifest.
    for (var index = 0; index < activeRows.length; index++) {
      final row = activeRows[index];
      final frame = row.frame;
      if (!await frame.descriptorFile.exists() ||
          !await frame.grayFile.exists()) {
        return false;
      }
      try {
        final decoded = jsonDecode(await frame.descriptorFile.readAsString());
        if (decoded is! Map) return false;
        final diskFrame = SfmFeedDurableFrame._fromJson(
          _directory,
          Map<String, Object?>.from(decoded),
        );
        if (diskFrame.id != frame.id ||
            diskFrame.sequence != frame.sequence ||
            _captureJobIdFromMetadata(diskFrame.metadata) != row.captureJobId) {
          return false;
        }
        final manifestDigest = _declaredGrayDigest(frame.metadata);
        final descriptorDigest = _declaredGrayDigest(diskFrame.metadata);
        if (manifestDigest != null &&
            descriptorDigest != null &&
            manifestDigest != descriptorDigest) {
          throw _GrayIntegrityError('manifest/descriptor gray digest mismatch');
        }
        final verified = await _verifyGrayFile(
          diskFrame,
          migrateMissingDigest: true,
          expectedDigest: manifestDigest,
        );
        if (!identical(verified, diskFrame)) {
          await _writeJsonAtomically(
            verified.descriptorFile,
            verified._toJson(),
          );
        }
        activeRows[index] = _SfmReplayMembershipRow(
          frame: verified,
          captureJobId: row.captureJobId,
        );
      } on _GrayIntegrityError catch (error) {
        await _retainAndBlock(
          SfmFeedBlock(
            kind: SfmFeedBlockKind.replayIncomplete,
            frameId: frame.id,
            message: 'active replay gray integrity failed: $error',
          ),
        );
        return false;
      } catch (_) {
        return false;
      }
    }

    // Tombstones land first. If the manifest commit fails, the old manifest
    // still owns every row, so these markers have no effect on replay.
    for (final row in excludedRows) {
      try {
        await _writeJsonAtomically(
          _excludedReplayMarker(_directory, row.frame.id),
          <String, Object?>{
            'schemaVersion': 1,
            'id': row.frame.id,
            'sequence': row.frame.sequence,
            'captureJobId': row.captureJobId,
          },
        );
      } catch (_) {
        return false;
      }
    }

    final nextState = _state.copyWith(
      pending: activeRows.map((row) => row.frame).toList(growable: false),
      fed: const <SfmFeedFedRecord>[],
      nativeReplayRequired: true,
      clearBlock: true,
    );
    try {
      await _injectFault(
        SfmFeedQueueFaultPoint.beforeActiveSubsetManifestPersist,
        excludedRows.length,
      );
    } catch (_) {
      return false;
    }
    final failure = await _tryCommit(nextState);
    if (failure != null) return false;
    _claimed.clear();
    for (final row in excludedRows) {
      _volatileGray.remove(row.frame.id);
    }
    _runtimeBlock = null;
    return true;
  });

  Future<bool> _prepareAllForFreshNativeReplay({required bool force}) async {
    if (_state.finalArtifactCommitted) return false;
    if (_state.pending.isEmpty && !force) return true;
    if (_state.pending.isEmpty && _state.fed.isEmpty) return true;

    final bySequence = <int, SfmFeedDurableFrame>{
      for (final frame in _state.pending) frame.sequence: frame,
    };
    for (final record in _state.fed) {
      if (bySequence.containsKey(record.sequence)) continue;
      final descriptor = File(_childPath(_directory.path, '${record.id}.json'));
      final gray = File(_childPath(_directory.path, '${record.id}.gray'));
      SfmFeedDurableFrame frame;
      try {
        if (await descriptor.exists()) {
          final decoded = jsonDecode(await descriptor.readAsString());
          if (decoded is! Map) {
            throw const FormatException('descriptor must be a JSON object');
          }
          frame = SfmFeedDurableFrame._fromJson(
            _directory,
            Map<String, Object?>.from(decoded),
          );
          if (frame.id != record.id || frame.sequence != record.sequence) {
            throw const FormatException(
              'descriptor identity does not match acknowledged frame',
            );
          }
          final fedDigest = _declaredGrayDigest(record.fedMeta);
          final descriptorDigest = _declaredGrayDigest(frame.metadata);
          if (fedDigest != null &&
              descriptorDigest != null &&
              fedDigest != descriptorDigest) {
            throw _GrayIntegrityError('fed/descriptor gray digest mismatch');
          }
          if (descriptorDigest == null && fedDigest != null) {
            frame = _copyFrameWithMetadata(
              frame,
              _metadataWithGrayDigest(frame.metadata, fedDigest),
            );
          }
        } else {
          final recoveredMetadata = Map<String, Object?>.from(record.fedMeta)
            ..remove('nativeFrameId');
          frame = SfmFeedDurableFrame._(
            id: record.id,
            sequence: record.sequence,
            grayFile: gray,
            descriptorFile: descriptor,
            metadata: recoveredMetadata,
          );
          await _writeJsonAtomically(descriptor, frame._toJson());
        }
      } catch (error) {
        await _retainAndBlock(
          SfmFeedBlock(
            kind: SfmFeedBlockKind.replayIncomplete,
            frameId: record.id,
            message: 'cannot rewind acknowledged frame for replay: $error',
          ),
        );
        return false;
      }
      bySequence[record.sequence] = frame;
    }

    final pending = bySequence.values.toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    for (var index = 0; index < pending.length; index++) {
      var frame = pending[index];
      try {
        final descriptorExists = await frame.descriptorFile.exists();
        String? descriptorDigest;
        if (descriptorExists) {
          final decoded = jsonDecode(await frame.descriptorFile.readAsString());
          if (decoded is! Map) {
            throw const _GrayIntegrityError(
              'pending descriptor is not a JSON object',
            );
          }
          final diskFrame = SfmFeedDurableFrame._fromJson(
            _directory,
            Map<String, Object?>.from(decoded),
          );
          if (diskFrame.id != frame.id ||
              diskFrame.sequence != frame.sequence) {
            throw const _GrayIntegrityError(
              'pending descriptor identity mismatch',
            );
          }
          descriptorDigest = _declaredGrayDigest(diskFrame.metadata);
        }
        final manifestDigest = _declaredGrayDigest(frame.metadata);
        if (manifestDigest != null &&
            descriptorDigest != null &&
            manifestDigest != descriptorDigest) {
          throw const _GrayIntegrityError(
            'pending manifest/descriptor gray digest mismatch',
          );
        }
        if (manifestDigest == null && descriptorDigest != null) {
          frame = _copyFrameWithMetadata(
            frame,
            _metadataWithGrayDigest(frame.metadata, descriptorDigest),
          );
        }
        final verified = await _verifyGrayFile(
          frame,
          migrateMissingDigest: true,
        );
        if (!descriptorExists ||
            descriptorDigest == null ||
            !identical(verified, frame)) {
          await _writeJsonAtomically(
            verified.descriptorFile,
            verified._toJson(),
          );
        }
        pending[index] = verified;
      } catch (error) {
        await _retainAndBlock(
          SfmFeedBlock(
            kind: SfmFeedBlockKind.replayIncomplete,
            frameId: frame.id,
            message: 'cannot prepare gray payload for replay: $error',
          ),
        );
        return false;
      }
    }
    _validateUniqueIdsAndSequences(pending, const <SfmFeedFedRecord>[]);
    final nextState = _state.copyWith(
      pending: pending,
      fed: const <SfmFeedFedRecord>[],
      nativeReplayRequired: true,
      clearBlock: true,
    );
    final failure = await _tryCommit(nextState);
    if (failure != null) {
      _runtimeBlock = failure;
      return false;
    }
    _claimed.clear();
    _runtimeBlock = null;
    return true;
  }

  /// Verifies every acknowledged replay payload immediately before a final
  /// sparse artifact is prepared/committed and the queue-owned evidence is
  /// purged. Existence and byte length alone are insufficient: a same-length
  /// corruption must not be published and then deleted as if it were valid.
  ///
  /// Legacy rows that genuinely have neither a manifest nor descriptor digest
  /// are migrated only after their current payload is read successfully. If
  /// either durable source already has a digest, that value remains the truth
  /// and can never be replaced by hashing corrupted bytes.
  Future<bool> verifyFedReplayPayloadsForFinalCommit() => _serialized(() async {
    if (_state.finalArtifactCommitted ||
        _state.pending.isNotEmpty ||
        _state.nativeReplayRequired ||
        _claimed.isNotEmpty ||
        blocked ||
        _state.fed.isEmpty) {
      return false;
    }

    final verifiedRecords = <SfmFeedFedRecord>[];
    var manifestChanged = false;
    for (final record in _state.fed) {
      final descriptor = File(_childPath(_directory.path, '${record.id}.json'));
      final gray = File(_childPath(_directory.path, '${record.id}.gray'));
      try {
        if (!await descriptor.exists()) {
          throw const _GrayIntegrityError(
            'acknowledged frame descriptor is missing',
          );
        }
        final decoded = jsonDecode(await descriptor.readAsString());
        if (decoded is! Map) {
          throw const _GrayIntegrityError(
            'acknowledged frame descriptor is not a JSON object',
          );
        }
        var frame = SfmFeedDurableFrame._fromJson(
          _directory,
          Map<String, Object?>.from(decoded),
        );
        if (frame.id != record.id || frame.sequence != record.sequence) {
          throw const _GrayIntegrityError(
            'acknowledged frame descriptor identity mismatch',
          );
        }

        final fedDigest = _declaredGrayDigest(record.fedMeta);
        final descriptorDigest = _declaredGrayDigest(frame.metadata);
        if (fedDigest != null &&
            descriptorDigest != null &&
            fedDigest != descriptorDigest) {
          throw const _GrayIntegrityError(
            'fed/descriptor gray digest mismatch',
          );
        }
        final fedExpectedBytes = _expectedGrayByteLength(record.fedMeta);
        final descriptorExpectedBytes = _expectedGrayByteLength(frame.metadata);
        if (fedExpectedBytes != null &&
            descriptorExpectedBytes != null &&
            fedExpectedBytes != descriptorExpectedBytes) {
          throw const _GrayIntegrityError(
            'fed/descriptor gray byte length mismatch',
          );
        }

        frame = await _verifyGrayFile(
          frame,
          migrateMissingDigest: true,
          expectedDigest: fedDigest,
        );
        final actualBytes = await gray.length();
        final requiredBytes = fedExpectedBytes ?? descriptorExpectedBytes;
        if (requiredBytes != null && requiredBytes != actualBytes) {
          throw _GrayIntegrityError(
            'gray byte length $actualBytes does not match $requiredBytes',
          );
        }
        final verifiedDigest = _declaredGrayDigest(frame.metadata)!;
        final descriptorNeedsMigration =
            descriptorDigest == null || descriptorExpectedBytes == null;
        if (descriptorNeedsMigration) {
          frame = _copyFrameWithMetadata(frame, <String, Object?>{
            ...frame.metadata,
            _kExpectedGrayBytes: actualBytes,
            _kSfmGraySha256: verifiedDigest,
          });
          await _writeJsonAtomically(descriptor, frame._toJson());
        }

        final fedNeedsMigration = fedDigest == null || fedExpectedBytes == null;
        final fedMeta = fedNeedsMigration
            ? <String, Object?>{
                ...record.fedMeta,
                _kExpectedGrayBytes: actualBytes,
                _kSfmGraySha256: verifiedDigest,
              }
            : record.fedMeta;
        verifiedRecords.add(
          SfmFeedFedRecord._(
            id: record.id,
            sequence: record.sequence,
            fedMeta: fedMeta,
          ),
        );
        manifestChanged = manifestChanged || fedNeedsMigration;
      } catch (error) {
        await _retainAndBlock(
          SfmFeedBlock(
            kind: SfmFeedBlockKind.replayIncomplete,
            frameId: record.id,
            message: 'final gray integrity verification failed: $error',
          ),
        );
        return false;
      }
    }

    if (!manifestChanged) return true;
    final failure = await _tryCommit(_state.copyWith(fed: verifiedRecords));
    if (failure != null) {
      _runtimeBlock = failure;
      return false;
    }
    return true;
  });

  /// Commits the final-artifact receipt before deleting any internal replay
  /// payload, then durably completes the cleanup transaction.
  ///
  /// A crash after the first manifest commit leaves [replayPurgePending] true.
  /// Reopening and calling this method again resumes deletion idempotently. A
  /// crash after every payload is gone but before the completion commit is the
  /// same safe state: all deletes are no-ops and the final marker is retried.
  /// User JPEGs and AR sidecars are outside this queue and are never touched.
  Future<bool> purgeReplayPayloadsAfterFinalArtifact() => _serialized(() async {
    if (requiresLegacyFinalArtifactAdoption) return false;
    return _purgeReplayPayloadsAfterFinalArtifact();
  });

  /// Adopts a final artifact that the caller has independently verified for a
  /// schema-1/2 queue whose old cleanup protocol had no durable receipt.
  ///
  /// Legacy cleanup may already have deleted any subset of exact queue-owned
  /// gray/descriptor files before crashing because schema 1/2 had no receipt.
  /// The caller's exact artifact verification authorizes adopting that progress.
  /// Once admitted, the normal schema-3 receipt-before-delete transaction takes
  /// over and removes only the remaining exact queue-owned paths.
  Future<bool> adoptLegacyFinalArtifact() => _serialized(() async {
    if (_state.finalArtifactCommitted) {
      return _purgeReplayPayloadsAfterFinalArtifact();
    }
    if (!requiresLegacyFinalArtifactAdoption ||
        _state.pending.isNotEmpty ||
        _state.nativeReplayRequired ||
        blocked ||
        _state.fed.isEmpty) {
      return false;
    }
    if (!await _legacyReplayPayloadsAreAdoptable()) return false;
    return _purgeReplayPayloadsAfterFinalArtifact();
  });

  Future<bool> _purgeReplayPayloadsAfterFinalArtifact() async {
    if (_state.finalArtifactCommitted && !_state.replayPurgePending) {
      return true;
    }
    if (!_state.finalArtifactCommitted &&
        (_state.pending.isNotEmpty || _state.nativeReplayRequired || blocked)) {
      return false;
    }

    if (!_state.finalArtifactCommitted) {
      await _injectFault(
        SfmFeedQueueFaultPoint.beforeFinalArtifactCommitPersist,
        0,
      );
      final receiptState = _state.copyWith(
        finalArtifactCommitted: true,
        replayPurgePending: true,
      );
      final receiptFailure = await _tryCommit(receiptState);
      if (receiptFailure != null) return false;
      await _injectFault(
        SfmFeedQueueFaultPoint.afterFinalArtifactCommitPersist,
        0,
      );
    }

    var processedPayloads = 0;
    for (final record in _state.fed) {
      for (final suffix in const <String>['gray', 'json']) {
        final deleted = await _deleteReplayPayloadIfPresent(
          File(_childPath(_directory.path, '${record.id}.$suffix')),
        );
        if (!deleted) return false;
        processedPayloads++;
        await _injectFault(
          SfmFeedQueueFaultPoint.afterReplayPayloadDelete,
          processedPayloads,
        );
      }
    }
    final exclusionMarkers = await _directory
        .list(followLinks: false)
        .where(
          (entry) =>
              entry is File &&
              RegExp(
                r'^frame-\d+\.excluded\.json$',
              ).hasMatch(_leafName(entry.path)),
        )
        .cast<File>()
        .toList();
    exclusionMarkers.sort((left, right) => left.path.compareTo(right.path));
    for (final marker in exclusionMarkers) {
      String id;
      try {
        final decoded = jsonDecode(await marker.readAsString());
        if (decoded is! Map) return false;
        final value = Map<String, Object?>.from(decoded);
        id = _requiredString(value, 'id');
        if (_leafName(marker.path) != '$id$_kExcludedReplaySuffix') {
          return false;
        }
      } catch (_) {
        return false;
      }
      for (final file in <File>[
        File(_childPath(_directory.path, '$id.gray')),
        File(_childPath(_directory.path, '$id.json')),
        marker,
      ]) {
        if (!await _deleteReplayPayloadIfPresent(file)) return false;
        processedPayloads++;
        await _injectFault(
          SfmFeedQueueFaultPoint.afterReplayPayloadDelete,
          processedPayloads,
        );
      }
    }
    await _injectFault(
      SfmFeedQueueFaultPoint.beforeReplayPurgeCompletePersist,
      processedPayloads,
    );
    final completionFailure = await _tryCommit(
      _state.copyWith(replayPurgePending: false),
    );
    return completionFailure == null;
  }

  /// Retries any failed durable writes, then atomically clears the queue block.
  /// A later read/native failure will establish a new block on the same head.
  Future<bool> clearBlockForRetry() => _serialized(() async {
    if (!blocked) return true;
    for (final frame in _state.pending) {
      final volatileBytes = _volatileGray[frame.id];
      if (volatileBytes != null) {
        try {
          await _writeBytesAtomically(frame.grayFile, volatileBytes);
          await _writeJsonAtomically(frame.descriptorFile, frame._toJson());
          _volatileGray.remove(frame.id);
        } catch (error) {
          _runtimeBlock = SfmFeedBlock(
            kind: SfmFeedBlockKind.grayWriteFailed,
            frameId: frame.id,
            message: 'gray retry failed: $error',
          );
          return false;
        }
      } else if (!await frame.grayFile.exists() &&
          !await _recoverGrayOwnershipMove(frame)) {
        _runtimeBlock = SfmFeedBlock(
          kind: SfmFeedBlockKind.grayReadFailed,
          frameId: frame.id,
          message: 'cannot retry: gray payload is still missing',
        );
        return false;
      } else if (!await frame.descriptorFile.exists()) {
        try {
          await _writeJsonAtomically(frame.descriptorFile, frame._toJson());
        } catch (error) {
          _runtimeBlock = SfmFeedBlock(
            kind: SfmFeedBlockKind.manifestWriteFailed,
            frameId: frame.id,
            message: 'descriptor retry failed: $error',
          );
          return false;
        }
      }
    }

    final nextState = _state.copyWith(clearBlock: true);
    final failure = await _tryCommit(nextState);
    if (failure != null) {
      _runtimeBlock = failure;
      return false;
    }
    _runtimeBlock = null;
    return true;
  });

  /// Persists a fail-closed condition that is not tied to one native ACK,
  /// such as an isolate error or unexpected worker exit.
  Future<void> retainAndBlock(SfmFeedBlock block) => _serialized(() {
    if (_state.finalArtifactCommitted) {
      throw StateError(
        'cannot block a queue after its final artifact was committed',
      );
    }
    return _retainAndBlock(block);
  });

  bool canSendFinalize({
    required bool finalizeRequested,
    required bool finalizeSent,
    required int inFlight,
  }) => sfmFeedCanSendFinalize(
    finalizeRequested: finalizeRequested,
    finalizeSent: finalizeSent,
    spoolDepth: spoolDepth,
    inFlight: inFlight,
    queueBlocked: blocked,
  );

  Future<void> close() {
    final previous = _operationTail;
    final released = Completer<void>();
    _operationTail = previous.then((_) => released.future);
    return (() async {
      await previous;
      try {
        if (_closed) return;
        _closed = true;
        final lock = _lockHandle;
        _lockHandle = null;
        try {
          if (lock != null) {
            try {
              await lock.unlock();
            } finally {
              await lock.close();
            }
          }
        } finally {
          await _deleteProcessOwnerTokenIfMatching(
            _processOwnerFile,
            _processOwnerToken,
          );
        }
      } finally {
        if (identical(_processOwners[_ownershipKey], this)) {
          _processOwners.remove(_ownershipKey);
        }
        released.complete();
      }
    })();
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final previous = _operationTail;
    final released = Completer<void>();
    _operationTail = previous.then((_) => released.future);
    return (() async {
      await previous;
      try {
        if (_closed) throw StateError('SfmDurableFeedQueue is closed');
        return await action();
      } finally {
        released.complete();
      }
    })();
  }

  Future<SfmFeedBlock?> _tryCommit(_SfmFeedManifestState candidate) async {
    final published = candidate.withGeneration(_state.generation + 1);
    try {
      published.validateForPersist();
      await _writeManifestAtomically(_manifestFile, published);
      _state = published;
      _runtimeBlock = null;
      return null;
    } catch (error) {
      return SfmFeedBlock(
        kind: SfmFeedBlockKind.manifestWriteFailed,
        message: 'manifest commit failed: $error',
      );
    }
  }

  Future<void> _retainAndBlock(SfmFeedBlock block) async {
    final failure = await _tryCommit(_state.copyWith(block: block));
    if (failure != null) _runtimeBlock = failure;
  }

  Future<void> _injectFault(
    SfmFeedQueueFaultPoint point,
    int processedPayloads,
  ) async {
    final injector = _faultInjector;
    if (injector != null) await injector(point, processedPayloads);
  }

  Future<bool> _legacyReplayPayloadsAreAdoptable() async {
    for (final record in _state.fed) {
      for (final suffix in const <String>['gray', 'json']) {
        final path = _childPath(_directory.path, '${record.id}.$suffix');
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file) {
          return false;
        }
      }
    }
    return true;
  }

  void _ensureAcceptingFrames() {
    if (_state.finalArtifactCommitted) {
      throw StateError(
        'cannot enqueue after the final reconstruction artifact was committed',
      );
    }
  }
}

class _SfmReplayMembershipRow {
  const _SfmReplayMembershipRow({
    required this.frame,
    required this.captureJobId,
  });

  final SfmFeedDurableFrame frame;
  final String captureJobId;
}

String? _captureJobIdFromMetadata(Map<String, Object?> metadata) {
  final value = metadata['captureJobId'];
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
    return null;
  }
  return value;
}

int? _expectedGrayByteLength(Map<String, Object?> metadata) {
  final direct = metadata[_kExpectedGrayBytes];
  if (direct is int && direct > 0) return direct;
  final width = metadata['grayW'];
  final height = metadata['grayH'];
  if (width is int && width > 0 && height is int && height > 0) {
    return width * height;
  }
  return null;
}

class _GrayIntegrityError implements Exception {
  const _GrayIntegrityError(this.message);

  final String message;

  @override
  String toString() => message;
}

String? _declaredGrayDigest(Map<String, Object?> metadata) {
  if (!metadata.containsKey(_kSfmGraySha256)) return null;
  final value = metadata[_kSfmGraySha256];
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const _GrayIntegrityError(
      'sfmGraySha256 must be canonical lowercase SHA-256',
    );
  }
  return value;
}

Map<String, Object?> _metadataWithGrayDigest(
  Map<String, Object?> metadata,
  String digest,
) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const _GrayIntegrityError('computed gray digest is not canonical');
  }
  final declared = _declaredGrayDigest(metadata);
  if (declared != null && declared != digest) {
    throw const _GrayIntegrityError(
      'declared gray digest does not match payload',
    );
  }
  return <String, Object?>{...metadata, _kSfmGraySha256: digest};
}

SfmFeedDurableFrame _copyFrameWithMetadata(
  SfmFeedDurableFrame frame,
  Map<String, Object?> metadata,
) => SfmFeedDurableFrame._(
  id: frame.id,
  sequence: frame.sequence,
  grayFile: frame.grayFile,
  descriptorFile: frame.descriptorFile,
  metadata: metadata,
);

String _verifyGrayBytes(
  SfmFeedDurableFrame frame,
  List<int> bytes, {
  String? expectedDigest,
}) {
  final expectedBytes = _expectedGrayByteLength(frame.metadata);
  if (bytes.isEmpty ||
      (expectedBytes != null && bytes.length != expectedBytes)) {
    throw _GrayIntegrityError(
      'gray byte length ${bytes.length} does not match '
      '${expectedBytes ?? 'a positive payload'}',
    );
  }
  final actualDigest = sha256.convert(bytes).toString();
  final declaredDigest = _declaredGrayDigest(frame.metadata);
  if (expectedDigest != null &&
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedDigest)) {
    throw const _GrayIntegrityError(
      'expected gray digest is not canonical lowercase SHA-256',
    );
  }
  if (declaredDigest != null &&
      expectedDigest != null &&
      declaredDigest != expectedDigest) {
    throw const _GrayIntegrityError(
      'gray digest disagrees across durable metadata',
    );
  }
  final requiredDigest = declaredDigest ?? expectedDigest;
  if (requiredDigest != null && requiredDigest != actualDigest) {
    throw const _GrayIntegrityError(
      'gray payload SHA-256 does not match durable metadata',
    );
  }
  return actualDigest;
}

Future<SfmFeedDurableFrame> _verifyGrayFile(
  SfmFeedDurableFrame frame, {
  required bool migrateMissingDigest,
  String? expectedDigest,
}) async {
  if (!await frame.grayFile.exists()) {
    throw const _GrayIntegrityError('gray payload is missing');
  }
  final actualBytes = await frame.grayFile.length();
  final expectedBytes = _expectedGrayByteLength(frame.metadata);
  if (actualBytes <= 0 ||
      (expectedBytes != null && actualBytes != expectedBytes)) {
    throw _GrayIntegrityError(
      'gray byte length $actualBytes does not match '
      '${expectedBytes ?? 'a positive payload'}',
    );
  }
  if (expectedDigest != null &&
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedDigest)) {
    throw const _GrayIntegrityError(
      'expected gray digest is not canonical lowercase SHA-256',
    );
  }
  final declaredDigest = _declaredGrayDigest(frame.metadata);
  if (declaredDigest != null &&
      expectedDigest != null &&
      declaredDigest != expectedDigest) {
    throw const _GrayIntegrityError(
      'gray digest disagrees across durable metadata',
    );
  }
  final actualDigest = await _sha256File(frame.grayFile);
  final requiredDigest = declaredDigest ?? expectedDigest;
  if (requiredDigest != null && requiredDigest != actualDigest) {
    throw const _GrayIntegrityError(
      'gray payload SHA-256 does not match durable metadata',
    );
  }
  if (declaredDigest != null) return frame;
  if (!migrateMissingDigest) {
    throw const _GrayIntegrityError('gray payload has no durable SHA-256');
  }
  return _copyFrameWithMetadata(
    frame,
    _metadataWithGrayDigest(frame.metadata, actualDigest),
  );
}

Future<String> _sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

File _excludedReplayMarker(Directory directory, String id) =>
    File(_childPath(directory.path, '$id$_kExcludedReplaySuffix'));

Future<void> _createProcessOwnerToken(File file, String token) async {
  await file.create(exclusive: true);
  RandomAccessFile? output;
  try {
    output = await file.open(mode: FileMode.write);
    await output.writeFrom(utf8.encode(token));
    await output.flush();
    await output.close();
    output = null;
  } catch (_) {
    await output?.close();
    await _deleteIfPresent(file);
    rethrow;
  }
}

Future<String> _readProcessOwnerToken(File file) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    try {
      final value = await file.readAsString();
      if (value.split('|').length == 3) return value;
    } on FileSystemException {
      if (attempt == 49) rethrow;
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw FormatException('invalid queue process-owner token: ${file.path}');
}

int? _processOwnerPid(String token) => int.tryParse(token.split('|').first);

Future<void> _deleteProcessOwnerTokenIfMatching(
  File file,
  String expected,
) async {
  try {
    if (!await file.exists()) return;
    if (await file.readAsString() != expected) return;
    await file.delete();
  } on FileSystemException {
    // Another owner may have atomically replaced a stale token. Never remove
    // a token whose identity cannot still be proven as ours.
  }
}

class _SfmFeedManifestState {
  const _SfmFeedManifestState({
    required this.persistedSchemaVersion,
    required this.generation,
    required this.nextSequence,
    required this.pending,
    required this.fed,
    required this.block,
    required this.nativeReplayRequired,
    required this.finalArtifactCommitted,
    required this.replayPurgePending,
  });

  factory _SfmFeedManifestState.empty() => const _SfmFeedManifestState(
    persistedSchemaVersion: _kSfmFeedManifestSchemaVersion,
    generation: 0,
    nextSequence: 0,
    pending: <SfmFeedDurableFrame>[],
    fed: <SfmFeedFedRecord>[],
    block: null,
    nativeReplayRequired: false,
    finalArtifactCommitted: false,
    replayPurgePending: false,
  );

  final int persistedSchemaVersion;
  final int generation;
  final int nextSequence;
  final List<SfmFeedDurableFrame> pending;
  final List<SfmFeedFedRecord> fed;
  final SfmFeedBlock? block;
  final bool nativeReplayRequired;
  final bool finalArtifactCommitted;
  final bool replayPurgePending;

  _SfmFeedManifestState copyWith({
    int? nextSequence,
    List<SfmFeedDurableFrame>? pending,
    List<SfmFeedFedRecord>? fed,
    SfmFeedBlock? block,
    bool clearBlock = false,
    bool? nativeReplayRequired,
    bool? finalArtifactCommitted,
    bool? replayPurgePending,
  }) => _SfmFeedManifestState(
    persistedSchemaVersion: persistedSchemaVersion,
    generation: generation,
    nextSequence: nextSequence ?? this.nextSequence,
    pending: List<SfmFeedDurableFrame>.unmodifiable(pending ?? this.pending),
    fed: List<SfmFeedFedRecord>.unmodifiable(fed ?? this.fed),
    block: clearBlock ? null : (block ?? this.block),
    nativeReplayRequired: nativeReplayRequired ?? this.nativeReplayRequired,
    finalArtifactCommitted:
        finalArtifactCommitted ?? this.finalArtifactCommitted,
    replayPurgePending: replayPurgePending ?? this.replayPurgePending,
  );

  _SfmFeedManifestState withGeneration(int value) => _SfmFeedManifestState(
    persistedSchemaVersion: _kSfmFeedManifestSchemaVersion,
    generation: value,
    nextSequence: nextSequence,
    pending: pending,
    fed: fed,
    block: block,
    nativeReplayRequired: nativeReplayRequired,
    finalArtifactCommitted: finalArtifactCommitted,
    replayPurgePending: replayPurgePending,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': _kSfmFeedManifestSchemaVersion,
    'generation': generation,
    'nextSequence': nextSequence,
    'pending': pending.map((frame) => frame._toJson()).toList(),
    'fed': fed.map((record) => record._toJson()).toList(),
    'nativeReplayRequired': nativeReplayRequired,
    'finalArtifactCommitted': finalArtifactCommitted,
    'replayPurgePending': replayPurgePending,
    if (block != null) 'block': block!.toJson(),
  };

  static _SfmFeedManifestState fromJson(
    Directory directory,
    Map<String, Object?> json,
  ) {
    final schema = _requiredInt(json, 'schemaVersion');
    if (schema < _kOldestSupportedSfmFeedManifestSchemaVersion ||
        schema > _kSfmFeedManifestSchemaVersion) {
      throw FormatException('unsupported SFM feed manifest schema: $schema');
    }
    final rawPending = json['pending'];
    final rawFed = json['fed'];
    if (rawPending is! List || rawFed is! List) {
      throw const FormatException('manifest pending/fed must be JSON arrays');
    }
    final pending = rawPending.map((value) {
      if (value is! Map) throw const FormatException('invalid pending entry');
      return SfmFeedDurableFrame._fromJson(
        directory,
        Map<String, Object?>.from(value),
      );
    }).toList();
    final fed = rawFed.map((value) {
      if (value is! Map) throw const FormatException('invalid fed entry');
      return SfmFeedFedRecord._fromJson(Map<String, Object?>.from(value));
    }).toList();
    _validateUniqueIdsAndSequences(pending, fed);
    final rawBlock = json['block'];
    final finalArtifactCommitted =
        schema >= 3 && json['finalArtifactCommitted'] == true;
    final replayPurgePending =
        schema >= 3 && json['replayPurgePending'] == true;
    if (replayPurgePending && !finalArtifactCommitted) {
      throw const FormatException(
        'replay purge cannot be pending before final artifact commit',
      );
    }
    if (finalArtifactCommitted &&
        (pending.isNotEmpty ||
            (schema >= 2 && json['nativeReplayRequired'] == true) ||
            rawBlock != null)) {
      throw const FormatException(
        'committed final artifact cannot retain pending/replay-blocked work',
      );
    }
    return _SfmFeedManifestState(
      persistedSchemaVersion: schema,
      generation: _requiredInt(json, 'generation'),
      nextSequence: _requiredInt(json, 'nextSequence'),
      pending: List<SfmFeedDurableFrame>.unmodifiable(pending),
      fed: List<SfmFeedFedRecord>.unmodifiable(fed),
      block: rawBlock == null
          ? null
          : SfmFeedBlock.fromJson(Map<String, Object?>.from(rawBlock as Map)),
      nativeReplayRequired: schema >= 2
          ? json['nativeReplayRequired'] == true
          : false,
      finalArtifactCommitted: finalArtifactCommitted,
      replayPurgePending: replayPurgePending,
    );
  }

  void validateForPersist() {
    if (replayPurgePending && !finalArtifactCommitted) {
      throw const FormatException(
        'replay purge cannot be pending before final artifact commit',
      );
    }
    if (finalArtifactCommitted &&
        (pending.isNotEmpty || nativeReplayRequired || block != null)) {
      throw const FormatException(
        'committed final artifact cannot retain pending/replay-blocked work',
      );
    }
  }
}

class _ReplayResult {
  const _ReplayResult(this.state, this.changed);
  final _SfmFeedManifestState state;
  final bool changed;
}

Future<_SfmFeedManifestState> _loadManifest(
  Directory directory,
  File manifest,
) async {
  if (!await manifest.exists()) return _SfmFeedManifestState.empty();
  final decoded = jsonDecode(await manifest.readAsString());
  if (decoded is! Map) {
    throw const FormatException('SFM feed manifest must be a JSON object');
  }
  return _SfmFeedManifestState.fromJson(
    directory,
    Map<String, Object?>.from(decoded),
  );
}

Future<_ReplayResult> _replayUncommittedFiles(
  Directory directory,
  _SfmFeedManifestState original,
) async {
  final pendingById = <String, SfmFeedDurableFrame>{
    for (final frame in original.pending) frame.id: frame,
  };
  final fedIds = <String>{for (final record in original.fed) record.id};
  var changed = false;
  var nextSequence = original.nextSequence;
  var block = original.block;
  final files = await directory
      .list(followLinks: false)
      .where((entry) => entry is File)
      .cast<File>()
      .toList();
  final exclusions =
      <String, ({int sequence, String captureJobId, File marker})>{};
  for (final marker in files.where((file) {
    return RegExp(
      r'^frame-\d+\.excluded\.json$',
    ).hasMatch(_leafName(file.path));
  })) {
    final decoded = jsonDecode(await marker.readAsString());
    if (decoded is! Map) {
      throw FormatException('invalid replay exclusion: ${marker.path}');
    }
    final value = Map<String, Object?>.from(decoded);
    if (_requiredInt(value, 'schemaVersion') != 1) {
      throw FormatException('unsupported replay exclusion: ${marker.path}');
    }
    final id = _requiredString(value, 'id');
    final expectedLeaf = '$id$_kExcludedReplaySuffix';
    final sequence = _requiredInt(value, 'sequence');
    final captureJobId = _captureJobIdFromMetadata(value);
    if (_leafName(marker.path) != expectedLeaf ||
        sequence < 0 ||
        !id.startsWith('frame-') ||
        int.tryParse(id.substring('frame-'.length)) != sequence ||
        captureJobId == null) {
      throw FormatException('mismatched replay exclusion: ${marker.path}');
    }
    if (exclusions.containsKey(id)) {
      throw FormatException('duplicate replay exclusion for $id');
    }
    exclusions[id] = (
      sequence: sequence,
      captureJobId: captureJobId,
      marker: marker,
    );
  }

  for (final descriptor in files.where((file) {
    return RegExp(r'^frame-\d+\.json$').hasMatch(_leafName(file.path));
  })) {
    final descriptorLeaf = _leafName(descriptor.path);
    final descriptorId = descriptorLeaf.substring(
      0,
      descriptorLeaf.length - '.json'.length,
    );
    if (fedIds.contains(descriptorId)) continue;
    final decoded = jsonDecode(await descriptor.readAsString());
    if (decoded is! Map) {
      throw FormatException('invalid frame descriptor: ${descriptor.path}');
    }
    final frame = SfmFeedDurableFrame._fromJson(
      directory,
      Map<String, Object?>.from(decoded),
    );
    final exclusion = exclusions[descriptorId];
    if (exclusion != null && !pendingById.containsKey(descriptorId)) {
      if (frame.id != descriptorId ||
          frame.sequence != exclusion.sequence ||
          _captureJobIdFromMetadata(frame.metadata) != exclusion.captureJobId) {
        throw FormatException(
          'replay exclusion conflicts with descriptor: ${descriptor.path}',
        );
      }
      continue;
    }
    if (!pendingById.containsKey(frame.id)) {
      pendingById[frame.id] = frame;
      nextSequence = nextSequence > frame.sequence + 1
          ? nextSequence
          : frame.sequence + 1;
      changed = true;
    }
  }

  for (final gray in files.where((file) {
    return RegExp(r'^frame-\d+\.gray$').hasMatch(_leafName(file.path));
  })) {
    final leaf = _leafName(gray.path);
    final id = leaf.substring(0, leaf.length - '.gray'.length);
    if (fedIds.contains(id)) continue;
    if (exclusions.containsKey(id) && !pendingById.containsKey(id)) continue;
    if (!pendingById.containsKey(id)) {
      final sequence = int.parse(id.substring('frame-'.length));
      final frame = SfmFeedDurableFrame._(
        id: id,
        sequence: sequence,
        grayFile: gray,
        descriptorFile: File(_childPath(directory.path, '$id.json')),
        metadata: const <String, Object?>{},
      );
      pendingById[id] = frame;
      nextSequence = nextSequence > sequence + 1 ? nextSequence : sequence + 1;
      block ??= SfmFeedBlock(
        kind: SfmFeedBlockKind.replayIncomplete,
        frameId: id,
        message: 'recovered gray payload without its descriptor',
      );
      changed = true;
    }
  }

  final pending = pendingById.values.toList()
    ..sort((a, b) => a.sequence.compareTo(b.sequence));
  for (final frame in pending) {
    if (!await frame.grayFile.exists() &&
        await _recoverGrayOwnershipMove(frame)) {
      changed = true;
    }
    if (!await frame.grayFile.exists()) {
      block ??= SfmFeedBlock(
        kind: SfmFeedBlockKind.grayReadFailed,
        frameId: frame.id,
        message: 'manifest references a missing gray payload',
      );
      changed = true;
      break;
    }
  }
  _validateUniqueIdsAndSequences(pending, original.fed);
  return _ReplayResult(
    _SfmFeedManifestState(
      persistedSchemaVersion: original.persistedSchemaVersion,
      generation: original.generation,
      nextSequence: nextSequence,
      pending: List<SfmFeedDurableFrame>.unmodifiable(pending),
      fed: original.fed,
      block: block,
      nativeReplayRequired: original.nativeReplayRequired,
      finalArtifactCommitted: original.finalArtifactCommitted,
      replayPurgePending: original.replayPurgePending,
    ),
    changed,
  );
}

Future<bool> _recoverGrayOwnershipMove(SfmFeedDurableFrame frame) async {
  final sourcePath = frame.metadata[_kSourceGrayPath];
  final expectedBytes = frame.metadata[_kExpectedGrayBytes];
  if (sourcePath is! String ||
      sourcePath.isEmpty ||
      expectedBytes is! int ||
      expectedBytes <= 0) {
    return false;
  }
  final source = File(sourcePath);
  try {
    if (!await source.exists()) return false;
    if (await source.length() != expectedBytes) return false;
    await source.rename(frame.grayFile.path);
    return await frame.grayFile.exists() &&
        await frame.grayFile.length() == expectedBytes;
  } on FileSystemException {
    return false;
  }
}

/// Atomically preserves the first pre-replay SQLite set and removes any later
/// partial replay DB so native always starts from an empty path.
Future<void> prepareSfmNativeDbForFreshReplay(String dbPath) async {
  for (final suffix in const <String>['', '-wal', '-shm', '-journal']) {
    final source = File('$dbPath$suffix');
    if (!await source.exists()) continue;
    final backup = File('$dbPath$suffix.pre-replay');
    if (await backup.exists()) {
      await source.delete();
    } else {
      await source.rename(backup.path);
    }
  }
}

Future<void> purgeSfmNativeReplayBackup(String dbPath) async {
  for (final suffix in const <String>['', '-wal', '-shm', '-journal']) {
    await _deleteIfPresent(File('$dbPath$suffix.pre-replay'));
  }
}

void _validateUniqueIdsAndSequences(
  List<SfmFeedDurableFrame> pending,
  List<SfmFeedFedRecord> fed,
) {
  final ids = <String>{};
  final sequences = <int>{};
  for (final frame in pending) {
    if (!ids.add(frame.id) || !sequences.add(frame.sequence)) {
      throw FormatException('duplicate pending frame ${frame.id}');
    }
  }
  for (final record in fed) {
    if (!ids.add(record.id) || !sequences.add(record.sequence)) {
      throw FormatException('duplicate fed frame ${record.id}');
    }
  }
}

Future<void> _writeManifestAtomically(
  File manifest,
  _SfmFeedManifestState state,
) async {
  state.validateForPersist();
  await _writeJsonAtomically(manifest, state.toJson());
}

Future<void> _writeJsonAtomically(File target, Map<String, Object?> value) =>
    _writeBytesAtomically(target, utf8.encode(jsonEncode(value)));

Future<void> _writeBytesAtomically(File target, List<int> bytes) async {
  final temporary = File('${target.path}.next');
  RandomAccessFile? output;
  try {
    output = await temporary.open(mode: FileMode.write);
    await output.writeFrom(bytes);
    await output.flush();
    await output.close();
    output = null;
    await temporary.rename(target.path);
  } catch (_) {
    if (output != null) await output.close();
    rethrow;
  }
}

Future<void> _deleteIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Cleanup is best-effort. Retaining an internal replay file costs space but
    // never invalidates the already-published final reconstruction artifact.
  }
}

/// Strict replay cleanup: completion is never published while a payload is
/// still present. A later call can retry any filesystem failure.
Future<bool> _deleteReplayPayloadIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
    return !await file.exists();
  } on FileSystemException {
    return false;
  }
}

Map<String, Object?> _normalizeJsonMap(
  Map<String, Object?> value, {
  required String label,
}) {
  try {
    final decoded = jsonDecode(jsonEncode(value));
    if (decoded is! Map) throw FormatException('$label is not a JSON object');
    return Map<String, Object?>.from(decoded);
  } catch (error) {
    throw ArgumentError.value(value, label, 'must be JSON encodable: $error');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value;
}

String _requiredSafeLeaf(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  if (_leafName(value) != value || value == '.' || value == '..') {
    throw FormatException('$key must be a safe leaf filename');
  }
  return value;
}

String _leafName(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf(r'\');
  final index = slash > backslash ? slash : backslash;
  return index < 0 ? path : path.substring(index + 1);
}

String _childPath(String parent, String leaf) =>
    '$parent${Platform.pathSeparator}$leaf';

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
