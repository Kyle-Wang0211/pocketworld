import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketworld_flutter/capture/capture_session.dart';
import 'package:pocketworld_flutter/capture/pw_telemetry.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/capture/telemetry_writer.dart';
import 'package:pocketworld_flutter/dome/platform_pose_provider.dart';

const _arKitChannel = MethodChannel('aether_arkit');
const _benchName = 'e_foreground_critical_500ms_1000_v3';
const _captureInterval = Duration(milliseconds: 500);
const _totalCaptureCount = 1000;
const _maxNativeDrainDuration = Duration(minutes: 10);
const _maxArReadyWait = Duration(seconds: 60);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BenchApp());
}

class _BenchApp extends StatefulWidget {
  const _BenchApp();

  @override
  State<_BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<_BenchApp> {
  final PlatformARPoseProvider _provider = PlatformARPoseProvider();
  final Stopwatch _runClock = Stopwatch();
  final List<int> _reserveMs = <int>[];
  final List<int> _captureStartMs = <int>[];
  final List<int> _criticalCaptureStartMs = <int>[];
  final List<Map<String, Object?>> _thermalSamples = <Map<String, Object?>>[];
  final List<Future<void>> _completionFutures = <Future<void>>[];
  final List<double> _flutterTotalMs = <double>[];
  final List<double> _flutterBuildMs = <double>[];
  final List<double> _flutterRasterMs = <double>[];
  final List<double> _criticalFlutterTotalMs = <double>[];
  final List<double> _criticalFlutterBuildMs = <double>[];
  final List<double> _criticalFlutterRasterMs = <double>[];
  final List<String> _failures = <String>[];

  CaptureSession? _session;
  SfmLiveRecon? _recon;
  Directory? _runDirectory;
  String _status = 'starting';
  int _attempted = 0;
  int _accepted = 0;
  int _committed = 0;
  int _durable = 0;
  int _postCritical = 0;
  int? _criticalAtMs;
  int? _foregroundCompleteAtMs;
  int? _cameraStoppedAtMs;
  int? _nativeDrainCompleteAtMs;
  String? _foregroundVerdict;
  bool _finished = false;
  bool _nativeTelemetryActive = false;
  bool _showPreview = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    unawaited(_recon?.dispose());
    unawaited(_session?.dispose());
    unawaited(_provider.stop());
    super.dispose();
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!_runClock.isRunning) return;
    for (final timing in timings) {
      final totalMs = timing.totalSpan.inMicroseconds / 1000.0;
      final buildMs = timing.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000.0;
      _flutterTotalMs.add(totalMs);
      _flutterBuildMs.add(buildMs);
      _flutterRasterMs.add(rasterMs);
      if (_criticalAtMs != null && _cameraStoppedAtMs == null) {
        _criticalFlutterTotalMs.add(totalMs);
        _criticalFlutterBuildMs.add(buildMs);
        _criticalFlutterRasterMs.add(rasterMs);
      }
    }
  }

  Future<void> _run() async {
    try {
      if (!Platform.isIOS) {
        throw UnsupportedError(
          'This bench requires the physical iOS ARKit app.',
        );
      }
      final documents = await getApplicationDocumentsDirectory();
      await TelemetryWriter.instance.init(
        '${documents.path}/telemetry_dart.jsonl',
      );
      final benchRoot = Directory('${documents.path}/bench/$_benchName');
      await benchRoot.create(recursive: true);
      final pendingDrain = await _loadPendingDrain(benchRoot);
      final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        ':',
        '',
      );
      _runDirectory = Directory('${benchRoot.path}/$stamp');
      await _runDirectory!.create(recursive: true);

      await _arKitChannel.invokeMethod<void>('telemetryCaptureBegin');
      _nativeTelemetryActive = true;
      if (pendingDrain != null) {
        await _runPendingDrain(pendingDrain);
        return;
      }

      _setStatus('starting ARKit');
      _showPreview = true;
      if (mounted) setState(() {});
      await SchedulerBinding.instance.endOfFrame;
      final session = _session = CaptureSession(poseProvider: _provider);
      await session.attach();
      await session.start(autoLock: true, manualCapture: true);
      await _waitForArReady(session);

      final captureDir = session.captureDir;
      if (captureDir == null) {
        throw StateError('CaptureSession did not create a capture directory.');
      }
      final recon = _recon = await SfmLiveRecon.start(
        dbPath: '$captureDir/sfm_live.db',
      );
      if (recon == null) {
        throw StateError(
          'SfmLiveRecon failed to start on the physical device.',
        );
      }
      session.bindManualCaptureActivitySink(recon.setForegroundCaptureActive);
      session.bindManualSfmFrameSink(recon.offerFrame);

      _runClock.start();
      for (
        var captureIndex = 0;
        captureIndex < _totalCaptureCount;
        captureIndex += 1
      ) {
        final targetStart = _captureInterval * captureIndex;
        final untilNext = targetStart - _runClock.elapsed;
        if (untilNext > Duration.zero) {
          await Future<void>.delayed(untilNext);
        }
        final sample = PwTelemetry.sample();
        _recordThermal(sample);
        if (sample != null &&
            sample.thermalState >= 3 &&
            _criticalAtMs == null) {
          _criticalAtMs = _runClock.elapsedMilliseconds;
          _criticalFlutterTotalMs.clear();
          _criticalFlutterBuildMs.clear();
          _criticalFlutterRasterMs.clear();
        }
        await _captureOne(session, sample?.thermalState ?? -1);
      }

      // The 1000th reservation ends the foreground stress window. Stop ARKit
      // immediately; already-reserved native snapshots remain owned by their
      // jobs while publication and durable FIFO spooling finish camera-off.
      _setStatus('1000 shutters reserved; stopping camera');
      await session.stop();
      await _arKitChannel.invokeMethod<void>('stopSession');
      _cameraStoppedAtMs = _runClock.elapsedMilliseconds;
      _showPreview = false;
      if (mounted) setState(() {});

      _setStatus('camera off; publishing accepted photos to durable FIFO');
      await Future.wait(_completionFutures);
      await session.waitForPendingPhotoSaves();
      _foregroundCompleteAtMs = _runClock.elapsedMilliseconds;
      _foregroundVerdict = _foregroundOnlyVerdict();
      await _writeResult(terminal: false);

      // The foreground measurement is over. Release ARKit/camera/VIO so the
      // phone can cool, then require the exact retained FIFO to resume and
      // reach a native OK ACK for every accepted frame. No capture artifact is
      // deleted; the durable queue and all user JPEGs stay in the cap folder.
      _setStatus('foreground complete; camera-off FIFO drain');
      final drained = await _waitForNativeDrain(recon);
      if (!drained) {
        await _writeResult(
          terminal: true,
          verdictOverride: 'DRAIN_DEFERRED_THERMAL',
        );
        await recon.dispose();
        await session.dispose();
        _finished = true;
        _setStatus('foreground PASS; FIFO drain deferred until cool restart');
        return;
      }
      _nativeDrainCompleteAtMs = _runClock.elapsedMilliseconds;
      await _writeResult(terminal: true);
      await recon.dispose();
      await session.dispose();
      _finished = true;
      _setStatus(_verdict() == 'PASS' ? 'PASS' : 'FAIL: ${_verdict()}');
    } catch (error, stackTrace) {
      _failures.add('$error\n$stackTrace');
      try {
        await _session?.stop();
        await _arKitChannel.invokeMethod<void>('stopSession');
        await _recon?.dispose();
        await _session?.dispose();
      } catch (_) {}
      await _writeResult(terminal: true, fatalError: '$error');
      _finished = true;
      _setStatus('FAIL: $error');
    } finally {
      if (_nativeTelemetryActive) {
        try {
          await _arKitChannel.invokeMethod<void>('telemetryCaptureEnd');
        } catch (_) {}
        _nativeTelemetryActive = false;
      }
    }
  }

  Future<Map<String, Object?>?> _loadPendingDrain(Directory benchRoot) async {
    final latest = File('${benchRoot.path}/latest.json');
    if (!await latest.exists()) return null;
    try {
      final decoded = jsonDecode(await latest.readAsString());
      if (decoded is! Map) return null;
      final prior = decoded.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
      final captureDir = prior['capture_dir'];
      final accepted = (prior['accepted'] as num?)?.toInt() ?? 0;
      final remaining = (prior['recon_remaining'] as num?)?.toInt() ?? 0;
      if (captureDir is! String ||
          captureDir.isEmpty ||
          accepted <= 0 ||
          remaining <= 0 ||
          prior['foreground_verdict'] != 'PASS') {
        return null;
      }
      final manifest = File(
        '$captureDir/sfm_live.db.sfm-feed/sfm_feed_manifest.json',
      );
      return await manifest.exists() ? prior : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _runPendingDrain(Map<String, Object?> prior) async {
    final captureDir = prior['capture_dir'] as String;
    final expected = (prior['accepted'] as num).toInt();
    _runClock.start();
    final initialThermal = PwTelemetry.sample()?.thermalState;
    if (initialThermal != null && initialThermal >= 2) {
      await _writePendingDrainResult(
        prior,
        terminal: true,
        verdict: 'DRAIN_DEFERRED_THERMAL',
        fed: (prior['recon_fed'] as num?)?.toInt() ?? 0,
        remaining: (prior['recon_remaining'] as num?)?.toInt() ?? expected,
        thermal: initialThermal,
      );
      _finished = true;
      _setStatus(
        'foreground PASS; drain deferred at thermal=$initialThermal '
        '(camera never started)',
      );
      return;
    }

    _setStatus('drain-only recovery; camera remains off');
    final recon = _recon = await SfmLiveRecon.start(
      dbPath: '$captureDir/sfm_live.db',
    );
    if (recon == null) {
      await _writePendingDrainResult(
        prior,
        terminal: true,
        verdict: 'DRAIN_START_FAILED',
        fed: 0,
        remaining: expected,
        thermal: initialThermal,
        error: 'SfmLiveRecon failed to reopen the durable FIFO.',
      );
      _finished = true;
      _setStatus('FAIL: durable FIFO reopen failed');
      return;
    }

    final deadline = DateTime.now().add(_maxNativeDrainDuration);
    var nextCheckpoint = DateTime.now();
    String verdict = 'DRAIN_TIMEOUT';
    String? error;
    try {
      while (DateTime.now().isBefore(deadline)) {
        final fed = recon.fedCount;
        final remaining = recon.remainingCount;
        _setStatus(
          'drain-only ordered FIFO fed=$fed/$expected remaining=$remaining',
        );
        if (fed == expected && remaining == 0) {
          verdict = 'PASS';
          break;
        }
        final thermal = PwTelemetry.sample()?.thermalState;
        if (thermal != null && thermal >= 2) {
          verdict = 'DRAIN_DEFERRED_THERMAL';
          break;
        }
        if (!DateTime.now().isBefore(nextCheckpoint)) {
          await _writePendingDrainResult(
            prior,
            terminal: false,
            verdict: 'RUNNING',
            fed: fed,
            remaining: remaining,
            thermal: thermal,
          );
          nextCheckpoint = DateTime.now().add(const Duration(seconds: 5));
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (caught, stackTrace) {
      verdict = 'DRAIN_FAILURE';
      error = '$caught\n$stackTrace';
    }

    await _writePendingDrainResult(
      prior,
      terminal: true,
      verdict: verdict,
      fed: recon.fedCount,
      remaining: recon.remainingCount,
      thermal: PwTelemetry.sample()?.thermalState,
      error: error,
    );
    await recon.dispose();
    _finished = true;
    _setStatus(
      verdict == 'PASS'
          ? 'PASS: foreground + ordered native ACK drain'
          : '$verdict; camera remained off',
    );
  }

  Future<void> _writePendingDrainResult(
    Map<String, Object?> prior, {
    required bool terminal,
    required String verdict,
    required int fed,
    required int remaining,
    required int? thermal,
    String? error,
  }) async {
    final result = <String, Object?>{
      ...prior,
      'schema_version': 2,
      'terminal': terminal,
      'verdict': verdict,
      'recon_fed': fed,
      'recon_remaining': remaining,
      'native_drain_complete_at_ms': verdict == 'PASS'
          ? _runClock.elapsedMilliseconds
          : null,
      'drain_resume': <String, Object?>{
        'mode': 'camera_off_only',
        'elapsed_ms': _runClock.elapsedMilliseconds,
        'thermal': thermal,
        'error': error,
      },
      'written_at': DateTime.now().toUtc().toIso8601String(),
    };
    await _persistResultMap(result);
  }

  Future<bool> _waitForNativeDrain(SfmLiveRecon recon) async {
    final deadline = DateTime.now().add(_maxNativeDrainDuration);
    var nextCheckpoint = DateTime.now();
    while (DateTime.now().isBefore(deadline)) {
      final remaining = recon.remainingCount;
      final fed = recon.fedCount;
      _setStatus(
        'camera off; ordered FIFO drain '
        'fed=$fed/$_accepted remaining=$remaining',
      );
      if (remaining == 0 && fed == _accepted) return true;
      final thermal = PwTelemetry.sample()?.thermalState;
      if (thermal != null && thermal >= 2) return false;
      if (!DateTime.now().isBefore(nextCheckpoint)) {
        await _writeResult(terminal: false);
        nextCheckpoint = DateTime.now().add(const Duration(seconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException(
      'native FIFO did not drain in $_maxNativeDrainDuration '
      '(fed=${recon.fedCount}/$_accepted, remaining=${recon.remainingCount})',
    );
  }

  Future<void> _waitForArReady(CaptureSession session) async {
    final waitClock = Stopwatch()..start();
    while (mounted && waitClock.elapsed < _maxArReadyWait) {
      final pose = _provider.lastPose;
      if (pose != null && pose.isTracking && session.hasLockedOrigin) return;
      if (waitClock.elapsedMilliseconds % 5000 < 100) {
        _setStatus(
          'waiting for AR tracking + origin '
          '(${waitClock.elapsed.inSeconds}s)',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (mounted) {
      throw TimeoutException(
        'AR tracking + origin not ready in $_maxArReadyWait; '
        'camera will be stopped instead of heating indefinitely.',
      );
    }
    throw StateError('Bench disposed while waiting for AR tracking + origin.');
  }

  Future<void> _captureOne(CaptureSession session, int thermal) async {
    _attempted += 1;
    final captureStartMs = _runClock.elapsedMilliseconds;
    _captureStartMs.add(captureStartMs);
    if (_criticalAtMs != null || thermal >= 3) {
      _criticalCaptureStartMs.add(captureStartMs);
    }
    final stopwatch = Stopwatch()..start();
    ManualPhotoCapture? capture;
    try {
      capture = await session.captureSinglePhoto();
    } catch (error, stackTrace) {
      _failures.add('reserve attempt=$_attempted: $error\n$stackTrace');
    } finally {
      stopwatch.stop();
      _reserveMs.add(stopwatch.elapsedMilliseconds);
    }
    if (capture == null) {
      _failures.add('reserve attempt=$_attempted returned null');
      await _checkpoint();
      return;
    }

    _accepted += 1;
    if (_criticalAtMs != null || thermal >= 3) _postCritical += 1;
    capture.committed
        .then<void>((result) {
          if (result.committed) _committed += 1;
        })
        .catchError((Object error, StackTrace stackTrace) {
          _failures.add('commit ${capture!.captureJobID}: $error\n$stackTrace');
        });
    final tracked = capture.completion
        .then<void>((_) {
          _durable += 1;
        })
        .catchError((Object error, StackTrace stackTrace) {
          _failures.add(
            'durable ${capture!.captureJobID}: $error\n$stackTrace',
          );
        });
    _completionFutures.add(tracked);
    _setStatus(
      'thermal=$thermal accepted=$_accepted durable=$_durable '
      'total=$_attempted/$_totalCaptureCount post-critical=$_postCritical',
    );
    await _checkpoint();
  }

  void _recordThermal(PwTelemetrySample? sample) {
    _thermalSamples.add(<String, Object?>{
      'elapsed_ms': _runClock.elapsedMilliseconds,
      'state': sample?.thermalState ?? -1,
      'name': sample?.thermalName ?? 'unavailable',
      'footprint_mb': sample?.physFootprintMb,
      'peak_footprint_mb': sample?.peakFootprintMb,
    });
  }

  Future<void> _checkpoint() async {
    // Never let benchmark JSON encoding or fsync compete with the fixed 500 ms
    // foreground cadence. Capture artifacts and the SfM FIFO are independently
    // durable; the benchmark summary is written after the camera is stopped.
  }

  String _foregroundOnlyVerdict() {
    if (_criticalAtMs == null) return 'THERMAL_CRITICAL_NOT_REACHED';
    if (_attempted != _totalCaptureCount) {
      return 'CAPTURE_ATTEMPT_COUNT_INCOMPLETE';
    }
    if (_attempted != _accepted ||
        _accepted != _committed ||
        _accepted != _durable) {
      return 'CAPTURE_DENOMINATOR_MISMATCH';
    }
    if (_failures.isNotEmpty) return 'CAPTURE_FAILURE';
    if ((_percentile(_reserveMs, 0.95) ?? double.infinity) > 33.0) {
      return 'SHUTTER_RESERVE_P95_OVER_33MS';
    }
    if ((_maxInt(_reserveMs) ?? 0) > 100) {
      return 'SHUTTER_RESERVE_MAX_OVER_100MS';
    }
    final cadenceMs = _intervals(_captureStartMs);
    if ((_percentile(cadenceMs, 0.05) ?? 0) < 450.0) {
      return 'CAPTURE_CADENCE_P05_UNDER_450MS';
    }
    if ((_percentile(cadenceMs, 0.95) ?? double.infinity) > 550.0) {
      return 'CAPTURE_CADENCE_P95_OVER_550MS';
    }
    if ((_maxInt(cadenceMs) ?? 0) > 650) {
      return 'CAPTURE_CADENCE_MAX_OVER_650MS';
    }
    final criticalCadenceMs = _intervals(_criticalCaptureStartMs);
    if ((_percentile(criticalCadenceMs, 0.05) ?? 0) < 450.0) {
      return 'CRITICAL_CAPTURE_CADENCE_P05_UNDER_450MS';
    }
    if ((_percentile(criticalCadenceMs, 0.95) ?? double.infinity) > 550.0) {
      return 'CRITICAL_CAPTURE_CADENCE_P95_OVER_550MS';
    }
    if ((_maxInt(criticalCadenceMs) ?? 0) > 650) {
      return 'CRITICAL_CAPTURE_CADENCE_MAX_OVER_650MS';
    }
    if (_flutterTotalMs.isEmpty) return 'NO_FLUTTER_FRAME_SAMPLES';
    if ((_percentileDouble(_flutterTotalMs, 0.95) ?? double.infinity) > 16.7) {
      return 'FLUTTER_FRAME_P95_OVER_16_7MS';
    }
    if ((_maxDouble(_flutterTotalMs) ?? double.infinity) > 33.3) {
      return 'FLUTTER_FRAME_MAX_OVER_33_3MS';
    }
    if (_criticalFlutterTotalMs.isEmpty) {
      return 'NO_CRITICAL_FLUTTER_FRAME_SAMPLES';
    }
    if ((_percentileDouble(_criticalFlutterTotalMs, 0.95) ?? double.infinity) >
        16.7) {
      return 'CRITICAL_FLUTTER_FRAME_P95_OVER_16_7MS';
    }
    if ((_maxDouble(_criticalFlutterTotalMs) ?? double.infinity) > 33.3) {
      return 'CRITICAL_FLUTTER_FRAME_MAX_OVER_33_3MS';
    }
    return 'PASS';
  }

  String _verdict() {
    final foreground = _foregroundVerdict ?? _foregroundOnlyVerdict();
    if (foreground != 'PASS') return foreground;
    final recon = _recon;
    if (recon == null ||
        recon.fedCount != _accepted ||
        recon.remainingCount != 0) {
      return 'NATIVE_ACK_DENOMINATOR_MISMATCH';
    }
    return 'PASS';
  }

  Future<void> _writeResult({
    required bool terminal,
    String? fatalError,
    String? verdictOverride,
  }) async {
    final directory = _runDirectory;
    if (directory == null) return;
    final cadenceMs = _intervals(_captureStartMs);
    final criticalCadenceMs = _intervals(_criticalCaptureStartMs);
    final result = <String, Object?>{
      'schema_version': 1,
      'bench': _benchName,
      'terminal': terminal,
      'verdict': verdictOverride ?? (terminal ? _verdict() : 'RUNNING'),
      'fatal_error': fatalError,
      'capture_dir': _session?.captureDir,
      'elapsed_ms': _runClock.elapsedMilliseconds,
      'critical_at_ms': _criticalAtMs,
      'foreground_complete_at_ms': _foregroundCompleteAtMs,
      'camera_stopped_at_ms': _cameraStoppedAtMs,
      'native_drain_complete_at_ms': _nativeDrainCompleteAtMs,
      'foreground_verdict': _foregroundVerdict,
      'attempted': _attempted,
      'accepted': _accepted,
      'committed': _committed,
      'durable': _durable,
      'post_critical': _postCritical,
      'recon_fed': _recon?.fedCount,
      'recon_remaining': _recon?.remainingCount,
      'recon_offered': _recon?.offeredCount,
      'reserve_ms': <String, Object?>{
        'samples': _reserveMs,
        'p50': _percentile(_reserveMs, 0.50),
        'p95': _percentile(_reserveMs, 0.95),
        'max': _maxInt(_reserveMs),
      },
      'capture_cadence_ms': <String, Object?>{
        'target': _captureInterval.inMilliseconds,
        'samples': cadenceMs,
        'p50': _percentile(cadenceMs, 0.50),
        'p95': _percentile(cadenceMs, 0.95),
        'max': _maxInt(cadenceMs),
      },
      'critical_capture_cadence_ms': <String, Object?>{
        'target': _captureInterval.inMilliseconds,
        'samples': criticalCadenceMs,
        'p50': _percentile(criticalCadenceMs, 0.50),
        'p95': _percentile(criticalCadenceMs, 0.95),
        'max': _maxInt(criticalCadenceMs),
      },
      'flutter_frames': <String, Object?>{
        'count': _flutterTotalMs.length,
        'total_p95_ms': _percentileDouble(_flutterTotalMs, 0.95),
        'total_max_ms': _maxDouble(_flutterTotalMs),
        'build_p95_ms': _percentileDouble(_flutterBuildMs, 0.95),
        'raster_p95_ms': _percentileDouble(_flutterRasterMs, 0.95),
        'over_16_7ms': _flutterTotalMs.where((value) => value > 16.7).length,
        'over_33_3ms': _flutterTotalMs.where((value) => value > 33.3).length,
      },
      'critical_flutter_frames': <String, Object?>{
        'count': _criticalFlutterTotalMs.length,
        'total_p95_ms': _percentileDouble(_criticalFlutterTotalMs, 0.95),
        'total_max_ms': _maxDouble(_criticalFlutterTotalMs),
        'build_p95_ms': _percentileDouble(_criticalFlutterBuildMs, 0.95),
        'raster_p95_ms': _percentileDouble(_criticalFlutterRasterMs, 0.95),
        'over_16_7ms': _criticalFlutterTotalMs
            .where((value) => value > 16.7)
            .length,
        'over_33_3ms': _criticalFlutterTotalMs
            .where((value) => value > 33.3)
            .length,
      },
      'thermal_samples': _thermalSamples,
      'failures': _failures,
      'written_at': DateTime.now().toUtc().toIso8601String(),
    };
    await _persistResultMap(result);
  }

  Future<void> _persistResultMap(Map<String, Object?> result) async {
    final directory = _runDirectory;
    if (directory == null) return;
    final runFile = File('${directory.path}/result.json');
    await runFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
      flush: true,
    );
    final latest = File('${directory.parent.path}/latest.json');
    final temp = File('${latest.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
      flush: true,
    );
    if (await latest.exists()) await latest.delete();
    await temp.rename(latest.path);
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() => _status = value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (Platform.isIOS && _showPreview)
              const UiKitView(viewType: 'aether_arkit_preview'),
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'E foreground thermal bench\n$_status'
                    '${_finished ? '\nResult saved in Documents/bench' : ''}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double? _percentile(List<int> values, double fraction) {
  if (values.isEmpty) return null;
  final sorted = values.toList()..sort();
  final index = (fraction * (sorted.length - 1)).round();
  return sorted[index].toDouble();
}

List<int> _intervals(List<int> timestampsMs) {
  if (timestampsMs.length < 2) return const <int>[];
  return <int>[
    for (var i = 1; i < timestampsMs.length; i++)
      timestampsMs[i] - timestampsMs[i - 1],
  ];
}

double? _percentileDouble(List<double> values, double fraction) {
  if (values.isEmpty) return null;
  final sorted = values.toList()..sort();
  final index = (fraction * (sorted.length - 1)).round();
  return sorted[index];
}

int? _maxInt(List<int> values) {
  if (values.isEmpty) return null;
  return values.reduce((left, right) => left > right ? left : right);
}

double? _maxDouble(List<double> values) {
  if (values.isEmpty) return null;
  return values.reduce((left, right) => left > right ? left : right);
}
