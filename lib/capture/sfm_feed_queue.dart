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
const int _kSfmFeedManifestSchemaVersion = 2;
const int _kOldestSupportedSfmFeedManifestSchemaVersion = 1;

enum SfmFeedBlockKind {
  nativeNonOk,
  grayReadFailed,
  grayWriteFailed,
  manifestWriteFailed,
  replayIncomplete,
  invalidAcknowledgement,
  workerDied,
}

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
  );

  final Directory _directory;
  final File _manifestFile;
  RandomAccessFile? _lockHandle;
  _SfmFeedManifestState _state;
  final Set<String> _claimed = <String>{};
  final Map<String, Uint8List> _volatileGray = <String, Uint8List>{};
  SfmFeedBlock? _runtimeBlock;
  Future<void> _operationTail = Future<void>.value();
  bool _closed = false;

  static Future<SfmDurableFeedQueue> open(Directory directory) async {
    await directory.create(recursive: true);
    final lockFile = File(_childPath(directory.path, _kSfmFeedLockFileName));
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
      final manifest = File(
        _childPath(directory.path, kSfmFeedManifestFileName),
      );
      var state = await _loadManifest(directory, manifest);
      final replay = await _replayUncommittedFiles(directory, state);
      state = replay.state;
      if (replay.changed || !await manifest.exists()) {
        state = state.withGeneration(state.generation + 1);
        await _writeManifestAtomically(manifest, state);
      }
      return SfmDurableFeedQueue._(directory, manifest, lock, state);
    } catch (_) {
      await lock.close();
      rethrow;
    }
  }

  int get spoolDepth => _state.pending.length;
  int get fedCount => _state.fed.length;
  int get nextSequence => _state.nextSequence;
  bool get nativeReplayRequired => _state.nativeReplayRequired;
  bool get blocked => _runtimeBlock != null || _state.block != null;
  SfmFeedBlock? get blockReason => _runtimeBlock ?? _state.block;
  List<SfmFeedDurableFrame> get pendingFrames =>
      List<SfmFeedDurableFrame>.unmodifiable(_state.pending);
  List<SfmFeedFedRecord> get fedRecords =>
      List<SfmFeedFedRecord>.unmodifiable(_state.fed);

  /// Writes gray bytes and a recovery descriptor before publishing the entry.
  /// Calls are serialized, so manifest sequence is capture/FIFO sequence.
  Future<SfmFeedDurableFrame> enqueueGray({
    required Uint8List grayBytes,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final stableBytes = Uint8List.fromList(grayBytes);
    final stableMetadata = _normalizeJsonMap(metadata, label: 'metadata');
    return _serialized(() async {
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
    try {
      final bytes = await frame.grayFile.readAsBytes();
      _claimed.add(frame.id);
      return SfmFeedClaim(frame: frame, grayBytes: bytes);
    } catch (error) {
      await _retainAndBlock(
        SfmFeedBlock(
          kind: SfmFeedBlockKind.grayReadFailed,
          frameId: frame.id,
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

      final pending = <SfmFeedDurableFrame>[..._state.pending]
        ..removeAt(pendingIndex);
      final fed = <SfmFeedFedRecord>[
        ..._state.fed,
        SfmFeedFedRecord._(
          id: frame.id,
          sequence: frame.sequence,
          fedMeta: stableFedMeta,
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
  Future<bool> prepareAllForFreshNativeReplay() => _serialized(() async {
    if (_state.pending.isEmpty) return true;

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
        if (!await frame.grayFile.exists()) {
          throw StateError('replay gray payload is missing');
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
  });

  /// Deletes internal gray/descriptor replay payloads only after the final
  /// point-cloud artifact is known to be on disk. User JPEGs and sidecars are
  /// outside this queue and are never touched.
  Future<bool> purgeReplayPayloadsAfterFinalArtifact() => _serialized(() async {
    if (_state.pending.isNotEmpty || _state.nativeReplayRequired || blocked) {
      return false;
    }
    for (final record in _state.fed) {
      await _deleteIfPresent(
        File(_childPath(_directory.path, '${record.id}.gray')),
      );
      await _deleteIfPresent(
        File(_childPath(_directory.path, '${record.id}.json')),
      );
    }
    return true;
  });

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
      } else if (!await frame.grayFile.exists()) {
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
  Future<void> retainAndBlock(SfmFeedBlock block) =>
      _serialized(() => _retainAndBlock(block));

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
        if (lock != null) {
          await lock.unlock();
          await lock.close();
        }
      } finally {
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
}

class _SfmFeedManifestState {
  const _SfmFeedManifestState({
    required this.generation,
    required this.nextSequence,
    required this.pending,
    required this.fed,
    required this.block,
    required this.nativeReplayRequired,
  });

  factory _SfmFeedManifestState.empty() => const _SfmFeedManifestState(
    generation: 0,
    nextSequence: 0,
    pending: <SfmFeedDurableFrame>[],
    fed: <SfmFeedFedRecord>[],
    block: null,
    nativeReplayRequired: false,
  );

  final int generation;
  final int nextSequence;
  final List<SfmFeedDurableFrame> pending;
  final List<SfmFeedFedRecord> fed;
  final SfmFeedBlock? block;
  final bool nativeReplayRequired;

  _SfmFeedManifestState copyWith({
    int? nextSequence,
    List<SfmFeedDurableFrame>? pending,
    List<SfmFeedFedRecord>? fed,
    SfmFeedBlock? block,
    bool clearBlock = false,
    bool? nativeReplayRequired,
  }) => _SfmFeedManifestState(
    generation: generation,
    nextSequence: nextSequence ?? this.nextSequence,
    pending: List<SfmFeedDurableFrame>.unmodifiable(pending ?? this.pending),
    fed: List<SfmFeedFedRecord>.unmodifiable(fed ?? this.fed),
    block: clearBlock ? null : (block ?? this.block),
    nativeReplayRequired: nativeReplayRequired ?? this.nativeReplayRequired,
  );

  _SfmFeedManifestState withGeneration(int value) => _SfmFeedManifestState(
    generation: value,
    nextSequence: nextSequence,
    pending: pending,
    fed: fed,
    block: block,
    nativeReplayRequired: nativeReplayRequired,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': _kSfmFeedManifestSchemaVersion,
    'generation': generation,
    'nextSequence': nextSequence,
    'pending': pending.map((frame) => frame._toJson()).toList(),
    'fed': fed.map((record) => record._toJson()).toList(),
    'nativeReplayRequired': nativeReplayRequired,
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
    return _SfmFeedManifestState(
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
    );
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

  for (final descriptor in files.where((file) {
    return RegExp(r'^frame-\d+\.json$').hasMatch(_leafName(file.path));
  })) {
    final decoded = jsonDecode(await descriptor.readAsString());
    if (decoded is! Map) {
      throw FormatException('invalid frame descriptor: ${descriptor.path}');
    }
    final frame = SfmFeedDurableFrame._fromJson(
      directory,
      Map<String, Object?>.from(decoded),
    );
    if (fedIds.contains(frame.id)) continue;
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
      generation: original.generation,
      nextSequence: nextSequence,
      pending: List<SfmFeedDurableFrame>.unmodifiable(pending),
      fed: original.fed,
      block: block,
      nativeReplayRequired: original.nativeReplayRequired,
    ),
    changed,
  );
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
) => _writeJsonAtomically(manifest, state.toJson());

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
