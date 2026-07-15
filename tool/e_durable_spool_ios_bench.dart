import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_thermal_scheduler.dart';

const _benchRun = 'e_durable_spool_v2_20260715';
const _frameCount = 12;
const _fedBeforeKill = 4;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BenchApp());
}

void _crashProbe(Object? _) {
  throw StateError('intentional E isolate-death probe');
}

class _BenchApp extends StatefulWidget {
  const _BenchApp();

  @override
  State<_BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<_BenchApp> {
  String _status = 'starting';
  SfmDurableFeedQueue? _heldQueue;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    Directory? root;
    try {
      final documents = await getApplicationDocumentsDirectory();
      root = Directory('${documents.path}/bench/$_benchRun');
      final phaseFile = File('${root.path}/phase.json');
      if (!await phaseFile.exists()) {
        await _prepareCrashPhase(root, phaseFile);
        return;
      }

      final phase = jsonDecode(await phaseFile.readAsString());
      if (phase is! Map) throw const FormatException('phase is not an object');
      switch (phase['phase']) {
        case 'ready_to_kill':
          await _verifyAfterRestart(root, phaseFile, phase);
        case 'pass':
          _publish('PASS (already completed)');
        default:
          throw StateError('unexpected prior phase: ${phase['phase']}');
      }
    } catch (error, stackTrace) {
      _publish('FAIL: $error');
      if (root != null) {
        await root.create(recursive: true);
        await _writeJsonAtomically(File('${root.path}/phase.json'), {
          'phase': 'fail',
          'error': '$error',
          'stack': '$stackTrace',
          'writtenAt': DateTime.now().toIso8601String(),
        });
      }
    }
  }

  Future<void> _prepareCrashPhase(Directory root, File phaseFile) async {
    if (await root.exists()) await root.delete(recursive: true);
    await root.create(recursive: true);
    final queueDirectory = Directory('${root.path}/sfm_live.db.sfm-feed');
    final queue = await SfmDurableFeedQueue.open(queueDirectory);
    _heldQueue = queue;

    for (var index = 0; index < _frameCount; index++) {
      final gray = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, index);
      await queue.enqueueGray(
        grayBytes: gray,
        metadata: {
          'captureJobId': 'bench-job-$index',
          'grayW': 1024,
          'grayH': 1024,
          'imageW': 1024,
          'imageH': 1024,
          'fx': 800.0,
          'fy': 800.0,
          'cx': 512.0,
          'cy': 512.0,
          'jpegPath': '${root.path}/bench-$index.jpg',
        },
      );
    }

    for (
      var nativeFrameId = 0;
      nativeFrameId < _fedBeforeKill;
      nativeFrameId++
    ) {
      final claim = await queue.claimNext();
      if (claim == null) throw StateError('claim $nativeFrameId failed');
      final disposition = await queue.acknowledge(
        frameId: claim.frame.id,
        nativeOk: true,
        fedMeta: {...claim.frame.metadata, 'nativeFrameId': nativeFrameId},
      );
      if (disposition != SfmFeedAckDisposition.removeAfterSuccess) {
        throw StateError('ACK $nativeFrameId was not committed');
      }
    }

    await File(
      '${root.path}/sfm_live.db',
    ).writeAsString('native-db-before-kill', flush: true);
    await File(
      '${root.path}/sfm_live.db-wal',
    ).writeAsString('native-wal-before-kill', flush: true);

    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final errorFuture = errorPort.first.timeout(const Duration(seconds: 5));
    final exitFuture = exitPort.first.timeout(const Duration(seconds: 5));
    await Isolate.spawn<Object?>(
      _crashProbe,
      null,
      errorsAreFatal: true,
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
      debugName: 'e_isolate_death_probe',
    );
    final isolateError = await errorFuture;
    await exitFuture;
    errorPort.close();
    exitPort.close();
    if (isolateError is! List || isolateError.isEmpty) {
      throw StateError('isolate onError port received no error payload');
    }

    await queue.retainAndBlock(
      const SfmFeedBlock(
        kind: SfmFeedBlockKind.workerDied,
        message: 'bench isolate exited before durable queue drain',
      ),
    );
    if (queue.fedCount != _fedBeforeKill ||
        queue.spoolDepth != _frameCount - _fedBeforeKill ||
        queue.blockReason?.kind != SfmFeedBlockKind.workerDied) {
      throw StateError('pre-kill queue state is inconsistent');
    }

    await _writeJsonAtomically(phaseFile, {
      'phase': 'ready_to_kill',
      'expected': _frameCount,
      'fed': queue.fedCount,
      'pending': queue.spoolDepth,
      'block': queue.blockReason?.kind.name,
      'isolateErrorPortObserved': true,
      'isolateExitPortObserved': true,
      'writtenAt': DateTime.now().toIso8601String(),
    });
    _publish('READY_TO_KILL fed=${queue.fedCount} pending=${queue.spoolDepth}');
    // Intentionally keep the queue lock and process alive. The host bench uses
    // devicectl SIGKILL so no Dart finally/dispose path can run.
  }

  Future<void> _verifyAfterRestart(
    Directory root,
    File phaseFile,
    Map<Object?, Object?> prior,
  ) async {
    final queueDirectory = Directory('${root.path}/sfm_live.db.sfm-feed');
    final queue = await SfmDurableFeedQueue.open(queueDirectory);
    _heldQueue = queue;
    final before = {
      'fed': queue.fedCount,
      'pending': queue.spoolDepth,
      'block': queue.blockReason?.kind.name,
    };
    if (queue.fedCount != _fedBeforeKill ||
        queue.spoolDepth != _frameCount - _fedBeforeKill ||
        queue.blockReason?.kind != SfmFeedBlockKind.workerDied) {
      throw StateError('durable state did not survive SIGKILL: $before');
    }

    if (!await queue.prepareAllForFreshNativeReplay()) {
      throw StateError('full replay preparation failed: ${queue.blockReason}');
    }
    await prepareSfmNativeDbForFreshReplay('${root.path}/sfm_live.db');
    if (!queue.nativeReplayRequired ||
        queue.fedCount != 0 ||
        queue.spoolDepth != _frameCount ||
        queue.blocked) {
      throw StateError('fresh replay state is inconsistent');
    }

    var nativeFrameId = 0;
    while (queue.spoolDepth > 0) {
      final claim = await queue.claimNext();
      if (claim == null) {
        throw StateError('replay claim failed: ${queue.blockReason}');
      }
      final disposition = await queue.acknowledge(
        frameId: claim.frame.id,
        nativeOk: true,
        fedMeta: {...claim.frame.metadata, 'nativeFrameId': nativeFrameId++},
      );
      if (disposition != SfmFeedAckDisposition.removeAfterSuccess) {
        throw StateError('replay ACK failed: ${queue.blockReason}');
      }
    }

    await File(
      '${root.path}/sfm_sparse.ply',
    ).writeAsString('ply\n', flush: true);
    final purged = await queue.purgeReplayPayloadsAfterFinalArtifact();
    await purgeSfmNativeReplayBackup('${root.path}/sfm_live.db');
    final replayPayloads = await queueDirectory
        .list(followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .where(
          (file) =>
              file.path.endsWith('.gray') ||
              RegExp(r'/frame-\d+\.json$').hasMatch(file.path),
        )
        .length;

    final thermal = <String, SfmBackgroundScheduleDecision>{
      'serious': _thermalDecision(2),
      'critical': _thermalDecision(3),
      'unknown': _thermalDecision(null),
      'fairRecovery': _thermalDecision(1),
    };
    final thermalPass =
        thermal['serious']!.pause &&
        thermal['critical']!.pause &&
        thermal['unknown']!.send &&
        thermal['fairRecovery']!.send;
    final pass =
        queue.fedCount == _frameCount &&
        queue.spoolDepth == 0 &&
        !queue.nativeReplayRequired &&
        !queue.blocked &&
        purged &&
        replayPayloads == 0 &&
        thermalPass;
    if (!pass) throw StateError('post-replay verification failed');

    await _writeJsonAtomically(phaseFile, {
      'phase': 'pass',
      'expected': _frameCount,
      'prior': prior,
      'afterSigkillOpen': before,
      'afterReplay': {
        'fed': queue.fedCount,
        'pending': queue.spoolDepth,
        'nativeReplayRequired': queue.nativeReplayRequired,
        'blocked': queue.blocked,
        'replayPayloadFiles': replayPayloads,
        'payloadPurgeAfterFinalArtifact': purged,
      },
      'thermal': {
        for (final entry in thermal.entries)
          entry.key: {
            'send': entry.value.send,
            'pause': entry.value.pause,
            'allowedInFlight': entry.value.allowedInFlight,
            'reason': entry.value.reason,
          },
      },
      'writtenAt': DateTime.now().toIso8601String(),
    });
    await queue.close();
    _heldQueue = null;
    _publish('PASS replayed=$_frameCount payloads=$replayPayloads');
  }

  SfmBackgroundScheduleDecision _thermalDecision(int? thermalState) {
    return decideSfmBackgroundSchedule(
      input: SfmBackgroundScheduleInput(
        thermalState: thermalState,
        recentGpuResultCode: null,
        consecutiveGpuFailures: 0,
        queueDepth: 1,
        inFlight: 0,
        cooldownRemaining: Duration.zero,
        finalizeRequested: false,
      ),
    );
  }

  void _publish(String value) {
    if (mounted) setState(() => _status = value);
  }

  @override
  void dispose() {
    final queue = _heldQueue;
    _heldQueue = null;
    if (queue != null) unawaited(queue.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xff101216),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'PocketWorld E durable bench\n\n$_status',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 22),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _writeJsonAtomically(
  File target,
  Map<String, Object?> value,
) async {
  await target.parent.create(recursive: true);
  final temporary = File('${target.path}.next');
  await temporary.writeAsString(jsonEncode(value), flush: true);
  await temporary.rename(target.path);
}
