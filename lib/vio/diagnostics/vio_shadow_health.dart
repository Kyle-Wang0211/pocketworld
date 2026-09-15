import 'vio_shadow_se3_comparison.dart';
import 'vio_shadow_downsample_contract.dart';
import '../ffi/xrslam_build_contract.dart';

class VioShadowRunIdentityExpectation {
  const VioShadowRunIdentityExpectation({
    required this.sessionId,
    required this.sessionEpoch,
    required this.effectiveConfigSha256,
    required this.inputIdentitySha256,
    required this.downsampleFactor,
    required this.downsampleFormula,
    required this.requestedCameraHz,
    required this.cameraTimeOffsetSeconds,
    required this.accelerationScale,
    required this.requestedAccelerometerHz,
    required this.requestedGyroscopeHz,
  });

  final String sessionId;
  final int sessionEpoch;
  final String effectiveConfigSha256;
  final String inputIdentitySha256;
  final int downsampleFactor;
  final String downsampleFormula;
  final double requestedCameraHz;
  final double cameraTimeOffsetSeconds;
  final double accelerationScale;
  final double requestedAccelerometerHz;
  final double requestedGyroscopeHz;
}

class VioShadowTimebaseEvidence {
  const VioShadowTimebaseEvidence({
    required this.schemaValid,
    required this.sessionId,
    required this.sessionEpoch,
    required this.nativeGeneration,
    required this.expectedNativeGeneration,
    required this.boundShadowGeneration,
    required this.accelerometerBase,
    required this.gyroscopeBase,
    required this.arFrameBase,
    required this.accelerometerSameBaseAsCamera,
    required this.gyroscopeSameBaseAsCamera,
    // [pw] 2026-09-14 为定案「transportValid 倒在哪一项」而补。
    // 上面的 `schemaValid` 存的是 **wireAccepted 的合取结果**,它同时吃
    // `snapshot.schemaValid` 与 `snapshot.transportLossFree`,一旦为 false
    // 就分不出是哪一个 —— 09-14 排查到这里卡住了。下面把两个输入各自摊开。
    // 纯观测,不进任何判据。
    this.wireSchemaValid,
    this.wireTransportLossFree,
    this.wireOutOfSessionStaleObservations,
    this.wireSourceLoss = const <String, Map<String, int>>{},
  });

  const VioShadowTimebaseEvidence.missing()
    : schemaValid = false,
      sessionId = '',
      sessionEpoch = -1,
      nativeGeneration = -1,
      expectedNativeGeneration = -1,
      boundShadowGeneration = -1,
      accelerometerBase = 'unavailable',
      gyroscopeBase = 'unavailable',
      arFrameBase = 'unavailable',
      accelerometerSameBaseAsCamera = null,
      gyroscopeSameBaseAsCamera = null,
      wireSchemaValid = null,
      wireTransportLossFree = null,
      wireOutOfSessionStaleObservations = null,
      wireSourceLoss = const <String, Map<String, int>>{};

  final bool schemaValid;
  final String sessionId;
  final int sessionEpoch;
  final int nativeGeneration;
  final int expectedNativeGeneration;
  final int boundShadowGeneration;
  final String accelerometerBase;
  final String gyroscopeBase;
  final String arFrameBase;
  final bool? accelerometerSameBaseAsCamera;
  final bool? gyroscopeSameBaseAsCamera;

  /// `snapshot.schemaValid` 本身(未与 transportLossFree 合取)。纯观测。
  final bool? wireSchemaValid;

  /// `snapshot.transportLossFree` 本身。纯观测。
  final bool? wireTransportLossFree;

  /// 快照自报的跨会话陈旧观测数;`transportLossFree` 要求它为 0。
  final int? wireOutOfSessionStaleObservations;

  /// 逐来源原始样本丢失:`{来源: {rejected, dropped, attempted, accepted}}`。
  /// `transportLossFree` 要求每个来源的 rejected 与 dropped **都为 0**。
  final Map<String, Map<String, int>> wireSourceLoss;

  /// The clock-domain receipt that must exist before creating the XRSLAM core.
  /// It intentionally does not require a shadow generation: that generation
  /// cannot exist until after the core has started.
  bool get preStartDomainAccepted =>
      schemaValid &&
      nativeGeneration > 0 &&
      nativeGeneration == expectedNativeGeneration &&
      accelerometerBase != 'unavailable' &&
      accelerometerBase != 'indeterminate' &&
      accelerometerBase != 'unknown' &&
      gyroscopeBase != 'unavailable' &&
      gyroscopeBase != 'indeterminate' &&
      gyroscopeBase != 'unknown' &&
      arFrameBase != 'unavailable' &&
      arFrameBase != 'indeterminate' &&
      arFrameBase != 'unknown' &&
      accelerometerSameBaseAsCamera == true &&
      gyroscopeSameBaseAsCamera == true;

  bool get domainAccepted =>
      preStartDomainAccepted && boundShadowGeneration > 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaValid': schemaValid,
    'sessionId': sessionId,
    'sessionEpoch': sessionEpoch,
    'nativeGeneration': nativeGeneration,
    'expectedNativeGeneration': expectedNativeGeneration,
    'boundShadowGeneration': boundShadowGeneration,
    'accelerometerBase': accelerometerBase,
    'gyroscopeBase': gyroscopeBase,
    'arFrameBase': arFrameBase,
    'accelerometerSameBaseAsCamera': accelerometerSameBaseAsCamera,
    'gyroscopeSameBaseAsCamera': gyroscopeSameBaseAsCamera,
    'preStartDomainAccepted': preStartDomainAccepted,
    'domainAccepted': domainAccepted,
    'wireSchemaValid': wireSchemaValid,
    'wireTransportLossFree': wireTransportLossFree,
    'wireOutOfSessionStaleObservations': wireOutOfSessionStaleObservations,
    'wireSourceLoss': wireSourceLoss,
  };
}

/// Provenance that can only be supplied by the Dart call site which directly
/// awaited `slamStop`. A map which merely looks terminal is not an acceptance
/// receipt: it may be a delayed/replayed generic snapshot.
class VioShadowTerminalReceiptEvidence {
  const VioShadowTerminalReceiptEvidence({
    required this.trustedDirectSlamStopCall,
    required this.consumedOnce,
    required this.runningGeneration,
    required this.receiptGeneration,
  });

  const VioShadowTerminalReceiptEvidence.missing()
    : trustedDirectSlamStopCall = false,
      consumedOnce = false,
      runningGeneration = -1,
      receiptGeneration = -1;

  final bool trustedDirectSlamStopCall;
  final bool consumedOnce;
  final int runningGeneration;
  final int receiptGeneration;

  bool get accepted =>
      trustedDirectSlamStopCall &&
      consumedOnce &&
      runningGeneration > 0 &&
      receiptGeneration == runningGeneration;

  Map<String, Object?> toJson() => <String, Object?>{
    'trustedDirectSlamStopCall': trustedDirectSlamStopCall,
    'consumedOnce': consumedOnce,
    'runningGeneration': runningGeneration,
    'receiptGeneration': receiptGeneration,
    'accepted': accepted,
  };
}

class VioShadowRunIdentitySummary {
  const VioShadowRunIdentitySummary({
    required this.schemaValid,
    required this.matchesExpected,
    required this.values,
  });

  final bool schemaValid;
  final bool matchesExpected;
  final Map<String, Object?> values;

  bool get valid => schemaValid && matchesExpected;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaValid': schemaValid,
    'matchesExpected': matchesExpected,
    'valid': valid,
    ...values,
  };
}

/// Privacy-safe, read-only interpretation of the native XRSLAM shadow snapshot.
///
/// This layer never exposes pose coordinates, image bytes, or raw IMU samples.
/// It also hard-codes the governance boundary: XRSLAM remains a shadow authority
/// with zero decision consumers regardless of malformed native input.
class VioSensorAccounting {
  const VioSensorAccounting({
    required this.schemaValid,
    required this.attempted,
    required this.accepted,
    required this.rejected,
    required this.terminal,
  });

  final bool schemaValid;
  final int attempted;
  final int accepted;
  final int rejected;
  final bool terminal;

  /// The frozen XRSLAM C ingress is void. `accepted` is retained only as the
  /// legacy wire spelling; it means submitted through the checked wrapper,
  /// not accepted by the algorithm core.
  int get submitted => accepted;

  int get unresolved => attempted - accepted - rejected;
  bool get conserved =>
      schemaValid && unresolved >= 0 && (!terminal || unresolved == 0);

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaValid': schemaValid,
    'attempted': attempted,
    'accepted': accepted,
    'submitted': submitted,
    'rejected': rejected,
    'unresolved': unresolved,
    'terminal': terminal,
    'conserved': conserved,
  };
}

class VioShadowQueueAccounting {
  const VioShadowQueueAccounting({
    required this.schemaValid,
    required this.accepted,
    required this.processed,
    required this.droppedOnStop,
    required this.terminalRejected,
    required this.backlog,
    required this.inFlight,
  });

  final bool schemaValid;
  final int accepted;
  final int processed;
  final int droppedOnStop;
  final int terminalRejected;
  final int backlog;
  final int inFlight;

  /// During a run backlog/inFlight are outstanding. Once stop completes they
  /// must both be zero, reducing this to the terminal conservation equation.
  bool get conserved =>
      schemaValid &&
      accepted ==
          processed + droppedOnStop + terminalRejected + backlog + inFlight;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaValid': schemaValid,
    'accepted': accepted,
    'processed': processed,
    'droppedOnStop': droppedOnStop,
    'terminalRejected': terminalRejected,
    'backlog': backlog,
    'inFlight': inFlight,
    'conserved': conserved,
  };
}

/// Cross-platform quality classification from raw native measurements.
/// Native code reports raw frame timestamps plus `lastFrameMs`; this Dart layer
/// computes the interval, comparison and streak so every platform executes the
/// same portable policy.
class VioShadowQualitySummary {
  const VioShadowQualitySummary({
    required this.schemaValid,
    required this.observationCount,
    required this.behindCount,
    required this.behindStreak,
    required this.behindMaxStreak,
    required this.invalidMeasurementCount,
    required this.lastFrameMs,
    required this.lastFrameIntervalMs,
  });

  const VioShadowQualitySummary.empty()
    : schemaValid = false,
      observationCount = 0,
      behindCount = 0,
      behindStreak = 0,
      behindMaxStreak = 0,
      invalidMeasurementCount = 0,
      lastFrameMs = -1,
      lastFrameIntervalMs = -1;

  final bool schemaValid;
  final int observationCount;
  final int behindCount;
  final int behindStreak;
  final int behindMaxStreak;
  final int invalidMeasurementCount;
  final double lastFrameMs;
  final double lastFrameIntervalMs;

  double get behindRate =>
      observationCount == 0 ? 0 : behindCount / observationCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaValid': schemaValid,
    'classification': 'lastFrameMs>lastFrameIntervalMs',
    'observationCount': observationCount,
    'behindCount': behindCount,
    'behindRate': behindRate,
    'behindStreak': behindStreak,
    'behindMaxStreak': behindMaxStreak,
    'invalidMeasurementCount': invalidMeasurementCount,
    'lastFrameMs': lastFrameMs,
    'lastFrameIntervalMs': lastFrameIntervalMs,
  };
}

class VioShadowQualityAccumulator {
  int? _sessionGeneration;
  int? _lastCoreFrameSequence;
  int _observationCount = 0;
  int _behindCount = 0;
  int _behindStreak = 0;
  int _behindMaxStreak = 0;
  int _invalidMeasurementCount = 0;
  double _lastFrameMs = -1;
  double _lastFrameIntervalMs = -1;

  void reset() {
    _sessionGeneration = null;
    _resetAggregates();
  }

  void _resetAggregates() {
    _lastCoreFrameSequence = null;
    _observationCount = 0;
    _behindCount = 0;
    _behindStreak = 0;
    _behindMaxStreak = 0;
    _invalidMeasurementCount = 0;
    _lastFrameMs = -1;
    _lastFrameIntervalMs = -1;
  }

  void consumeSnapshot(Map<String, Object?> wire) {
    final int? generation = _wireCounter(wire['sessionGeneration']);
    if (generation == null) return;
    if (_sessionGeneration != null && generation < _sessionGeneration!) {
      return;
    }
    if (_sessionGeneration == null || generation > _sessionGeneration!) {
      _resetAggregates();
    }
    _sessionGeneration = generation;

    final Object? raw = wire['poseObservations'];
    if (raw is! List) return;
    final List<Map<String, Object?>> observations =
        raw.map(_stringObjectMap).whereType<Map<String, Object?>>().toList()
          ..sort((Map<String, Object?> a, Map<String, Object?> b) {
            return (_wireCounter(a['seq']) ?? -1).compareTo(
              _wireCounter(b['seq']) ?? -1,
            );
          });
    for (final Map<String, Object?> observation in observations) {
      final int? sequence = _wireCounter(observation['seq']);
      if (sequence == null ||
          (_lastCoreFrameSequence != null &&
              sequence <= _lastCoreFrameSequence!)) {
        continue;
      }
      _lastCoreFrameSequence = sequence;
      final double? frameMs = _wireFiniteDouble(observation['lastFrameMs']);
      final double? sensorTimestamp = _wireFiniteDouble(
        observation['sensorTimestamp'],
      );
      final double? previousTimestamp = _wireFiniteDouble(
        observation['previousImageTimestamp'],
      );
      final double? intervalMs =
          sensorTimestamp == null || previousTimestamp == null
          ? null
          : (sensorTimestamp - previousTimestamp) * 1000;
      if (frameMs == null || intervalMs == null || intervalMs <= 0) {
        _invalidMeasurementCount++;
        continue;
      }
      _lastFrameMs = frameMs;
      _lastFrameIntervalMs = intervalMs;
      _observationCount++;
      if (frameMs > intervalMs) {
        _behindCount++;
        _behindStreak++;
        if (_behindStreak > _behindMaxStreak) {
          _behindMaxStreak = _behindStreak;
        }
      } else {
        _behindStreak = 0;
      }
    }
  }

  VioShadowQualitySummary get summary => VioShadowQualitySummary(
    schemaValid: _sessionGeneration != null && _observationCount > 0,
    observationCount: _observationCount,
    behindCount: _behindCount,
    behindStreak: _behindStreak,
    behindMaxStreak: _behindMaxStreak,
    invalidMeasurementCount: _invalidMeasurementCount,
    lastFrameMs: _lastFrameMs,
    lastFrameIntervalMs: _lastFrameIntervalMs,
  );

  /// Capture the immutable aggregate, then erase all per-run raw-derived
  /// counters and sequence state. Used immediately after terminal summary
  /// construction so a stopped session leaves no transient pose timing state.
  VioShadowQualitySummary takeSummaryAndReset() {
    final VioShadowQualitySummary result = summary;
    reset();
    return result;
  }
}

class VioShadowPoseAvailability {
  const VioShadowPoseAvailability({
    required this.schemaValid,
    required this.nativeOffered,
    required this.nativeDropped,
    required this.valid,
    required this.noNew,
    required this.degenerate,
    required this.errors,
    required this.initialized,
    required this.initializationLatencyMs,
    required this.validLatencyMeanMs,
    required this.validLatencyMaxMs,
    required this.poseEpochCount,
    required this.continuityBreakCount,
  });

  const VioShadowPoseAvailability.empty()
    : schemaValid = false,
      nativeOffered = 0,
      nativeDropped = 0,
      valid = 0,
      noNew = 0,
      degenerate = 0,
      errors = 0,
      initialized = false,
      initializationLatencyMs = -1,
      validLatencyMeanMs = -1,
      validLatencyMaxMs = -1,
      poseEpochCount = 0,
      continuityBreakCount = 0;

  final bool schemaValid;
  final int nativeOffered;
  final int nativeDropped;
  final int valid;
  final int noNew;
  final int degenerate;
  final int errors;
  final bool initialized;
  final double initializationLatencyMs;
  final double validLatencyMeanMs;
  final double validLatencyMaxMs;
  final int poseEpochCount;
  final int continuityBreakCount;

  int get totalAttempts => valid + noNew + degenerate + errors;
  double get validRate => totalAttempts == 0 ? 0 : valid / totalAttempts;
  bool get singleContinuousPoseEpoch =>
      poseEpochCount == 1 && continuityBreakCount == 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaValid': schemaValid,
    'nativeOffered': nativeOffered,
    'nativeDropped': nativeDropped,
    'validCount': valid,
    'noNewCount': noNew,
    'degenerateCount': degenerate,
    'errorCount': errors,
    'totalAttempts': totalAttempts,
    'validRate': validRate,
    'initialized': initialized,
    'initializationLatencyMs': initializationLatencyMs,
    'validLatencyMeanMs': validLatencyMeanMs,
    'validLatencyMaxMs': validLatencyMaxMs,
    'poseEpochCount': poseEpochCount,
    'continuityBreakCount': continuityBreakCount,
    'singleContinuousPoseEpoch': singleContinuousPoseEpoch,
  };
}

/// Dart-owned interpretation of bounded raw native pose-status observations.
class VioShadowPoseAccumulator {
  int? _generation;
  int? _lastSequence;
  int _nativeOffered = 0;
  int _nativeDropped = 0;
  int _delivered = 0;
  bool _ledgerSeen = false;
  bool _ledgerConsistent = true;
  int _valid = 0;
  int _noNew = 0;
  int _degenerate = 0;
  int _errors = 0;
  double? _firstValidObservedAt;
  double? _sessionStartedAt;
  double _validLatencySumMs = 0;
  double _validLatencyMaxMs = 0;
  RawXrslamPoseClassification _latestClassification =
      RawXrslamPoseClassification.malformed;
  int _poseEpochCount = 0;
  int _continuityBreakCount = 0;
  bool _validPoseSegmentOpen = false;

  RawXrslamPoseClassification get latestClassification => _latestClassification;

  void reset() {
    _generation = null;
    _resetAggregates();
  }

  void _resetAggregates() {
    _lastSequence = null;
    _nativeOffered = 0;
    _nativeDropped = 0;
    _delivered = 0;
    _ledgerSeen = false;
    _ledgerConsistent = true;
    _valid = 0;
    _noNew = 0;
    _degenerate = 0;
    _errors = 0;
    _firstValidObservedAt = null;
    _sessionStartedAt = null;
    _validLatencySumMs = 0;
    _validLatencyMaxMs = 0;
    _latestClassification = RawXrslamPoseClassification.malformed;
    _poseEpochCount = 0;
    _continuityBreakCount = 0;
    _validPoseSegmentOpen = false;
  }

  void consumeSnapshot(Map<String, Object?> wire) {
    final int? generation = _wireCounter(wire['sessionGeneration']);
    if (generation == null) return;
    if (_generation != null && generation < _generation!) return;
    if (_generation == null || generation > _generation!) _resetAggregates();
    _generation = generation;

    final int? offered = _wireCounter(wire['poseObservationsOffered']);
    final int? dropped = _wireCounter(wire['poseObservationsDropped']);
    if (offered == null ||
        dropped == null ||
        offered < _nativeOffered ||
        dropped < _nativeDropped ||
        dropped > offered) {
      _ledgerConsistent = false;
    } else {
      _ledgerSeen = true;
      _nativeOffered = offered;
      _nativeDropped = dropped;
    }

    final Object? raw = wire['poseObservations'];
    if (raw is! List) {
      _ledgerConsistent = false;
      return;
    }
    final List<Map<String, Object?>> observations =
        raw.map(_stringObjectMap).whereType<Map<String, Object?>>().toList()
          ..sort((Map<String, Object?> a, Map<String, Object?> b) {
            return (_wireCounter(a['seq']) ?? -1).compareTo(
              _wireCounter(b['seq']) ?? -1,
            );
          });
    for (final Map<String, Object?> observation in observations) {
      final int? sequence = _wireCounter(observation['seq']);
      if (sequence == null ||
          (_lastSequence != null && sequence <= _lastSequence!)) {
        continue;
      }
      _lastSequence = sequence;
      _delivered++;
      final RawXrslamPoseClassification poseClass = classifyRawXrslamPose(
        observation,
      );
      _latestClassification = poseClass;
      if (poseClass == RawXrslamPoseClassification.valid) {
        if (!_validPoseSegmentOpen) {
          _validPoseSegmentOpen = true;
          _poseEpochCount++;
        }
        _valid++;
        final double? observed = _wireFiniteDouble(
          observation['observedAtUptimeSeconds'],
        );
        final double? enqueued = _wireFiniteDouble(
          observation['enqueuedAtUptimeSeconds'],
        );
        final double? started = _wireFiniteDouble(
          observation['sessionStartedAtUptimeSeconds'],
        );
        if (observed == null ||
            enqueued == null ||
            started == null ||
            observed < enqueued ||
            observed < started) {
          _ledgerConsistent = false;
          continue;
        }
        _firstValidObservedAt ??= observed;
        _sessionStartedAt ??= started;
        final double latency = (observed - enqueued) * 1000;
        _validLatencySumMs += latency;
        if (latency > _validLatencyMaxMs) _validLatencyMaxMs = latency;
      } else {
        if (_validPoseSegmentOpen) {
          _validPoseSegmentOpen = false;
          _continuityBreakCount++;
        }
        switch (poseClass) {
          case RawXrslamPoseClassification.initializing:
            _noNew++;
            break;
          case RawXrslamPoseClassification.degenerate:
            _degenerate++;
            break;
          case RawXrslamPoseClassification.trackingFailed:
          case RawXrslamPoseClassification.malformed:
            _errors++;
            break;
          case RawXrslamPoseClassification.valid:
            break;
        }
      }
    }
  }

  VioShadowPoseAvailability get summary {
    final bool initialized =
        _firstValidObservedAt != null && _sessionStartedAt != null;
    return VioShadowPoseAvailability(
      schemaValid:
          _generation != null &&
          _ledgerSeen &&
          _ledgerConsistent &&
          _nativeOffered == _delivered + _nativeDropped,
      nativeOffered: _nativeOffered,
      nativeDropped: _nativeDropped,
      valid: _valid,
      noNew: _noNew,
      degenerate: _degenerate,
      errors: _errors,
      initialized: initialized,
      initializationLatencyMs: initialized
          ? (_firstValidObservedAt! - _sessionStartedAt!) * 1000
          : -1,
      validLatencyMeanMs: _valid == 0 ? -1 : _validLatencySumMs / _valid,
      validLatencyMaxMs: _valid == 0 ? -1 : _validLatencyMaxMs,
      poseEpochCount: _poseEpochCount,
      continuityBreakCount: _continuityBreakCount,
    );
  }

  /// Return the immutable terminal aggregate and erase sequence, latency, and
  /// initialization timestamps retained while the run was active.
  VioShadowPoseAvailability takeSummaryAndReset() {
    final VioShadowPoseAvailability result = summary;
    reset();
    return result;
  }
}

class VioShadowHealthSummary {
  const VioShadowHealthSummary._({
    required this.schemaValid,
    required this.sessionGeneration,
    required this.state,
    required this.transportValid,
    required this.qualityGatePassed,
    required this.coreHealthAvailable,
    required this.coreImuSamples,
    required this.shadowOverflowDrops,
    required this.stateTransitions,
    required this.images,
    required this.acc,
    required this.gyro,
    required this.queue,
    required this.rejectionReasons,
    required this.pose,
    required this.comparison,
    required this.quality,
    required this.identity,
    required this.timebase,
    required this.terminalReceipt,
  });

  final bool schemaValid;
  final int sessionGeneration;
  final String state;

  /// Transport/lifecycle/accounting validity only. It is deliberately
  /// independent of pose and comparison quality evidence.
  final bool transportValid;

  /// Minimum complete S1 diagnostic evidence. This is not an accuracy verdict
  /// and never grants production authority.
  final bool qualityGatePassed;

  /// Backwards-compatible name for callers that only recorded transport
  /// validity before the quality split.
  bool get runValid => transportValid;

  /// S1 is observation-only even when every diagnostic evidence gate passes.
  bool get productionAuthorityEligible => false;
  final bool coreHealthAvailable;
  final int coreImuSamples;
  final int shadowOverflowDrops;
  final List<String> stateTransitions;
  final VioSensorAccounting images;
  final VioSensorAccounting acc;
  final VioSensorAccounting gyro;
  final VioShadowQueueAccounting queue;
  final Map<String, Map<String, int>> rejectionReasons;
  final VioShadowPoseAvailability pose;
  final VioShadowComparisonSummary comparison;
  final VioShadowQualitySummary quality;
  final VioShadowRunIdentitySummary identity;
  final VioShadowTimebaseEvidence timebase;
  final VioShadowTerminalReceiptEvidence terminalReceipt;

  String get xrslamSha256 =>
      identity.values['xrslamSha256'] as String? ?? 'UNSTAMPED';

  bool get allAccountingConserved =>
      schemaValid &&
      images.conserved &&
      acc.conserved &&
      gyro.conserved &&
      queue.conserved;

  static int _i(Map<String, Object?> m, String key) {
    final Object? value = m[key];
    return value is num ? value.toInt() : 0;
  }

  static int? _requiredCounter(Map<String, Object?> m, String key) =>
      _wireCounter(m[key]);

  static bool _b(Map<String, Object?> m, String key) {
    final Object? value = m[key];
    return value == true || (value is num && value.toInt() == 1);
  }

  factory VioShadowHealthSummary.fromWire(
    Map<String, Object?> wire, {
    VioShadowComparisonSummary comparison =
        const VioShadowComparisonSummary.empty(),
    VioShadowQualitySummary quality = const VioShadowQualitySummary.empty(),
    VioShadowPoseAvailability pose = const VioShadowPoseAvailability.empty(),
    VioShadowRunIdentityExpectation? expectedIdentity,
    VioShadowTimebaseEvidence timebase =
        const VioShadowTimebaseEvidence.missing(),
    VioShadowTerminalReceiptEvidence terminalReceipt =
        const VioShadowTerminalReceiptEvidence.missing(),
  }) {
    const Set<String> sensorReasonKeys = <String>{
      'not_running',
      'lock_contention',
      'queue_full',
      'camera_full',
      'late_after_seal',
      'dropped_on_stop',
      'stale_epoch',
      'invalid_input',
      'non_monotonic',
      'native_reject',
    };
    const Set<String> workTerminalKeys = <String>{
      'stale_epoch',
      'invalid_input',
      'non_monotonic',
      'native_reject',
      'internal',
    };
    const Set<String> topReasonKeys = <String>{
      'images',
      'acc',
      'gyro',
      'workTerminal',
      'workDroppedOnStop',
    };
    Map<String, int>? parseReasonMap(Object? raw, Set<String> keys) {
      final Map<String, Object?>? map = _stringObjectMap(raw);
      if (map == null ||
          map.keys.toSet().difference(keys).isNotEmpty ||
          keys.difference(map.keys.toSet()).isNotEmpty) {
        return null;
      }
      final Map<String, int> parsed = <String, int>{};
      for (final String key in keys) {
        final int? value = _wireCounter(map[key]);
        if (value == null) return null;
        parsed[key] = value;
      }
      return parsed;
    }

    final Map<String, Object?>? rawReasons = _stringObjectMap(
      wire['rejectionReasons'],
    );
    final Map<String, int>? imageReasons = parseReasonMap(
      rawReasons?['images'],
      sensorReasonKeys,
    );
    final Map<String, int>? accReasons = parseReasonMap(
      rawReasons?['acc'],
      sensorReasonKeys,
    );
    final Map<String, int>? gyroReasons = parseReasonMap(
      rawReasons?['gyro'],
      sensorReasonKeys,
    );
    final Map<String, int>? workTerminalReasons = parseReasonMap(
      rawReasons?['workTerminal'],
      workTerminalKeys,
    );
    final Map<String, int>? workDropReasons = parseReasonMap(
      rawReasons?['workDroppedOnStop'],
      const <String>{'dropped_on_stop'},
    );
    final Map<String, Map<String, int>> reasons = <String, Map<String, int>>{
      'images': ?imageReasons,
      'acc': ?accReasons,
      'gyro': ?gyroReasons,
      'workTerminal': ?workTerminalReasons,
      'workDroppedOnStop': ?workDropReasons,
    };
    final List<String> transitions = <String>[];
    final Object? rawTransitions = wire['stateTransitions'];
    if (rawTransitions is List) {
      transitions.addAll(rawTransitions.whereType<String>());
    }
    final String state = wire['state'] is String
        ? wire['state']! as String
        : 'unknown';
    final bool terminal = state == 'stopped';

    VioSensorAccounting sensor(String prefix) {
      final int? attempted = _requiredCounter(wire, '${prefix}Attempted');
      final int? accepted = _requiredCounter(wire, '${prefix}Accepted');
      final int? rejected = _requiredCounter(wire, '${prefix}Rejected');
      return VioSensorAccounting(
        schemaValid: attempted != null && accepted != null && rejected != null,
        attempted: attempted ?? 0,
        accepted: accepted ?? 0,
        rejected: rejected ?? 0,
        terminal: terminal,
      );
    }

    final int? queueAccepted = _requiredCounter(wire, 'queueAccepted');
    final int? queueProcessed = _requiredCounter(wire, 'queueProcessedSuccess');
    final int? droppedOnStop = _requiredCounter(wire, 'droppedOnStop');
    final int? terminalRejected = _requiredCounter(wire, 'terminalRejected');
    final int? queueBacklog = _requiredCounter(wire, 'queueBacklog');
    final int? queueInFlight = _requiredCounter(wire, 'queueInFlight');
    final VioShadowQueueAccounting queue = VioShadowQueueAccounting(
      schemaValid:
          queueAccepted != null &&
          queueProcessed != null &&
          droppedOnStop != null &&
          terminalRejected != null &&
          queueBacklog != null &&
          queueInFlight != null,
      accepted: queueAccepted ?? 0,
      processed: queueProcessed ?? 0,
      droppedOnStop: droppedOnStop ?? 0,
      terminalRejected: terminalRejected ?? 0,
      backlog: queueBacklog ?? 0,
      inFlight: queueInFlight ?? 0,
    );
    final VioSensorAccounting images = sensor('images');
    final VioSensorAccounting acc = sensor('acc');
    final VioSensorAccounting gyro = sensor('gyro');
    final int? generation = _requiredCounter(wire, 'sessionGeneration');
    final int? overflow = _requiredCounter(wire, 'shadowOverflowDrops');
    final bool stateValid =
        state == 'stopped' ||
        state == 'starting' ||
        state == 'running' ||
        state == 'stopping';
    int sum(Map<String, int>? values) =>
        values?.values.fold<int>(0, (int a, int b) => a + b) ?? -1;
    final bool reasonsSchemaValid =
        rawReasons != null &&
        rawReasons.keys.toSet().containsAll(topReasonKeys) &&
        topReasonKeys.containsAll(rawReasons.keys) &&
        reasons.length == topReasonKeys.length;
    final bool reasonsConserved =
        reasonsSchemaValid &&
        sum(imageReasons) == images.rejected &&
        sum(accReasons) == acc.rejected &&
        sum(gyroReasons) == gyro.rejected &&
        sum(workTerminalReasons) == queue.terminalRejected &&
        sum(workDropReasons) == queue.droppedOnStop;
    final VioShadowRunIdentitySummary identity = _parseRunIdentity(
      wire['identity'],
      nativeGeneration: generation,
      expected: expectedIdentity,
    );
    final bool schemaValid =
        wire['schema'] == 'pw.vio.shadow-native/6' &&
        generation != null &&
        overflow != null &&
        stateValid &&
        images.schemaValid &&
        acc.schemaValid &&
        gyro.schemaValid &&
        queue.schemaValid &&
        identity.schemaValid &&
        wire['acceptedCompatibilitySemantics'] == 'submitted_to_void_c_api' &&
        reasonsConserved;
    final bool accountingConserved =
        images.conserved && acc.conserved && gyro.conserved && queue.conserved;
    const Set<String> invalidatingSensorReasons = <String>{
      // [pw] 2026-09-14 'lock_contention' 已移出。依据是本功能自己的 spec:
      // openspec/changes/add-xrslam-bounded-shadow-promotion-gates/specs/
      //   xrslam-shadow-promotion/spec.md:37
      //   "ordinary ledger-lock contention is **not** classified as an input drop"
      // 原生侧同步改了两处(PwVioSlamFeeder.swift 的 transportValid 与
      // shadowOverflowDrops)。计数仍在 rejectionReasons 里可见,只是不再致废。
      'queue_full',
      'camera_full',
      'late_after_seal',
      'stale_epoch',
      'invalid_input',
      'non_monotonic',
      'native_reject',
    };
    int invalidatingCount(Map<String, int>? values) => invalidatingSensorReasons
        .fold<int>(0, (int total, String key) => total + (values?[key] ?? 0));
    final bool transportValid =
        schemaValid &&
        accountingConserved &&
        terminal &&
        queue.backlog == 0 &&
        queue.inFlight == 0 &&
        identity.valid &&
        timebase.domainAccepted &&
        timebase.sessionId == identity.values['sessionId'] &&
        timebase.sessionEpoch == identity.values['sessionEpoch'] &&
        timebase.boundShadowGeneration == generation &&
        terminalReceipt.accepted &&
        terminalReceipt.receiptGeneration == generation &&
        images.accepted > 0 &&
        acc.accepted > 0 &&
        gyro.accepted > 0 &&
        overflow == 0 &&
        invalidatingCount(imageReasons) == 0 &&
        invalidatingCount(accReasons) == 0 &&
        invalidatingCount(gyroReasons) == 0 &&
        sum(workTerminalReasons) == 0;
    final bool qualityGatePassed =
        transportValid &&
        pose.schemaValid &&
        pose.initialized &&
        pose.valid > 0 &&
        pose.nativeDropped == 0 &&
        pose.degenerate == 0 &&
        pose.errors == 0 &&
        pose.singleContinuousPoseEpoch &&
        comparison.schemaValid &&
        comparison.alignmentInitialized &&
        comparison.acceptedPairCount >= 2 &&
        comparison.sampleCount >= 1 &&
        comparison.nativeDroppedCount == 0 &&
        comparison.referenceTrackingRejectedCount == 0 &&
        comparison.timestampInvalidCount == 0 &&
        comparison.timestampMismatchCount == 0 &&
        comparison.malformedPairCount == 0 &&
        comparison.singleContinuousPoseEpoch &&
        comparison.translationRmseM.isFinite &&
        comparison.translationRmseM >= 0 &&
        comparison.translationMaxM.isFinite &&
        comparison.translationMaxM >= 0 &&
        comparison.rotationRmseDeg.isFinite &&
        comparison.rotationRmseDeg >= 0 &&
        comparison.rotationMaxDeg.isFinite &&
        comparison.rotationMaxDeg >= 0 &&
        quality.schemaValid &&
        quality.observationCount > 0 &&
        quality.invalidMeasurementCount == 0 &&
        quality.behindCount == 0 &&
        quality.behindMaxStreak == 0;

    return VioShadowHealthSummary._(
      schemaValid: schemaValid,
      sessionGeneration: generation ?? 0,
      state: state,
      transportValid: transportValid,
      qualityGatePassed: qualityGatePassed,
      coreHealthAvailable: _b(wire, 'coreHealthAvailable'),
      coreImuSamples: _i(wire, 'coreImuSamples'),
      shadowOverflowDrops: overflow ?? 0,
      stateTransitions: List<String>.unmodifiable(transitions),
      images: images,
      acc: acc,
      gyro: gyro,
      queue: queue,
      rejectionReasons: Map<String, Map<String, int>>.unmodifiable(
        reasons.map(
          (String key, Map<String, int> value) =>
              MapEntry<String, Map<String, int>>(
                key,
                Map<String, int>.unmodifiable(value),
              ),
        ),
      ),
      pose: pose,
      comparison: comparison,
      quality: quality,
      identity: identity,
      timebase: timebase,
      terminalReceipt: terminalReceipt,
    );
  }

  /// Deliberately constructed field-by-field: unknown wire keys (including raw
  /// poses/images/IMU) cannot leak into persisted diagnostics.
  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 'pw.vio.shadow-health/2',
    'schemaValid': schemaValid,
    'authority': comparison.authority,
    'decisionConsumers': comparison.decisionConsumers,
    'xrslamSha256': xrslamSha256,
    'identity': identity.toJson(),
    'timebaseAcceptance': timebase.toJson(),
    'terminalReceipt': terminalReceipt.toJson(),
    'sessionGeneration': sessionGeneration,
    'state': state,
    'runValid': runValid,
    'transportValid': transportValid,
    'qualityGatePassed': qualityGatePassed,
    'productionAuthorityEligible': productionAuthorityEligible,
    'coreHealthAvailable': coreHealthAvailable,
    'coreImuSamples': coreImuSamples,
    'shadowOverflowDrops': shadowOverflowDrops,
    'stateTransitions': stateTransitions,
    'accountingConserved': allAccountingConserved,
    'sensors': <String, Object?>{
      'image': images.toJson(),
      'acc': acc.toJson(),
      'gyro': gyro.toJson(),
    },
    'queue': queue.toJson(),
    'rejectionReasons': rejectionReasons,
    'poseAvailability': pose.toJson(),
    'comparison': comparison.toJson(),
    'quality': quality.toJson(),
  };
}

int? _wireCounter(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  final int integer = value.toInt();
  return value.toDouble() == integer.toDouble() ? integer : null;
}

Map<String, Object?>? _stringObjectMap(Object? value) {
  if (value is! Map) return null;
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key! as String] = entry.value;
  }
  return result;
}

double? _wireFiniteDouble(Object? value) {
  if (value is! num) return null;
  final double result = value.toDouble();
  return result.isFinite ? result : null;
}

VioShadowRunIdentitySummary _parseRunIdentity(
  Object? raw, {
  required int? nativeGeneration,
  required VioShadowRunIdentityExpectation? expected,
}) {
  const Set<String> keys = <String>{
    'sessionId',
    'sessionEpoch',
    'epoch',
    'queueCapacity',
    'cameraCapacity',
    'poseObservationCapacity',
    'dropPolicy',
    'appVersion',
    'appBuild',
    'diagnosticBuildId',
    'productSourceManifestSha256',
    'dartAotSha256',
    'nativeHostUuid',
    'nativeFrameworkSha256',
    'xrslamSha256',
    'xrslamUpstreamRevision',
    'xrslamBuildPatchSha256',
    'xrslamDestroyLifecyclePatchSha256',
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
    'downsampleFactor',
    'downsampleFormula',
    'requestedCameraHz',
    'cameraTimeOffsetSeconds',
    'accelerationScale',
    'requestedAccelerometerHz',
    'requestedGyroscopeHz',
  };
  final Map<String, Object?>? map = _stringObjectMap(raw);
  String value(String key) =>
      map?[key] is String ? (map![key]! as String).trim() : '';
  final int? epoch = _wireCounter(map?['epoch']);
  final int? sessionEpoch = _wireCounter(map?['sessionEpoch']);
  final int? queueCapacity = _wireCounter(map?['queueCapacity']);
  final int? cameraCapacity = _wireCounter(map?['cameraCapacity']);
  final int? downsampleFactor = _wireCounter(map?['downsampleFactor']);
  final String downsampleFormula = value('downsampleFormula');
  final double? requestedCameraHz = _wireFiniteDouble(
    map?['requestedCameraHz'],
  );
  final double? cameraTimeOffsetSeconds = _wireFiniteDouble(
    map?['cameraTimeOffsetSeconds'],
  );
  final double? accelerationScale = _wireFiniteDouble(
    map?['accelerationScale'],
  );
  final double? requestedAccelerometerHz = _wireFiniteDouble(
    map?['requestedAccelerometerHz'],
  );
  final double? requestedGyroscopeHz = _wireFiniteDouble(
    map?['requestedGyroscopeHz'],
  );
  final RegExp sha256 = RegExp(r'^[0-9a-f]{64}$');
  final RegExp uuid = RegExp(
    r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
    r'[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
  );
  final RegExp sessionUuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
    r'[0-9a-f]{12}$',
  );
  bool stamped(String key) {
    final String item = value(key);
    return item.isNotEmpty && item.toUpperCase() != 'UNSTAMPED';
  }

  final bool exactKeys =
      map != null &&
      map.keys.toSet().containsAll(keys) &&
      keys.containsAll(map.keys);
  final bool schemaValid =
      exactKeys &&
      nativeGeneration != null &&
      epoch == nativeGeneration &&
      sessionEpoch != null &&
      sessionUuid.hasMatch(value('sessionId')) &&
      queueCapacity == 256 &&
      cameraCapacity == 2 &&
      value('poseObservationCapacity') == 'loss-intolerant-dynamic' &&
      downsampleFactor != null &&
      downsampleFactor > 0 &&
      downsampleFormula == kVioShadowDownsampleFormulaBoxNxnHalfUpV1 &&
      requestedCameraHz != null &&
      requestedCameraHz > 0 &&
      cameraTimeOffsetSeconds != null &&
      accelerationScale != null &&
      accelerationScale != 0 &&
      requestedAccelerometerHz != null &&
      requestedAccelerometerHz > 0 &&
      requestedGyroscopeHz != null &&
      requestedGyroscopeHz > 0 &&
      value('dropPolicy') == 'invalidate-on-overflow' &&
      stamped('appVersion') &&
      stamped('appBuild') &&
      stamped('diagnosticBuildId') &&
      sha256.hasMatch(value('productSourceManifestSha256')) &&
      sha256.hasMatch(value('dartAotSha256')) &&
      uuid.hasMatch(value('nativeHostUuid')) &&
      sha256.hasMatch(value('nativeFrameworkSha256')) &&
      sha256.hasMatch(value('xrslamSha256')) &&
      value('xrslamUpstreamRevision') == XrslamBuildContract.xrslamRevision &&
      value('xrslamBuildPatchSha256') ==
          XrslamBuildContract.xrslamBuildPatchSha256 &&
      value('xrslamDestroyLifecyclePatchSha256') ==
          XrslamBuildContract.destroyLifecyclePatchSha256 &&
      value('xrslamAlgorithmBranch') == 'generic' &&
      value('xrslamIosEnabled') == 'false' &&
      value('xrslamThreadingEnabled') == 'false' &&
      value('xrslamCompileFlags') ==
          XrslamBuildContract.compileFlags.join(',') &&
      value('opencvUpstreamRevision') == XrslamBuildContract.opencvRevision &&
      value('opencvBuildPatchSha256') ==
          XrslamBuildContract.opencvBuildPatchSha256 &&
      sha256.hasMatch(value('opencvSha256')) &&
      value('ceresUpstreamRevision') == XrslamBuildContract.ceresRevision &&
      sha256.hasMatch(value('ceresSha256')) &&
      value('spdlogCompatibilityPatchSha256') ==
          XrslamBuildContract.spdlogCompatibilityPatchSha256 &&
      sha256.hasMatch(value('effectiveConfigSha256')) &&
      sha256.hasMatch(value('inputIdentitySha256'));
  final bool matchesExpected =
      expected != null &&
      value('sessionId') == expected.sessionId &&
      sessionEpoch == expected.sessionEpoch &&
      value('effectiveConfigSha256') == expected.effectiveConfigSha256 &&
      value('inputIdentitySha256') == expected.inputIdentitySha256 &&
      downsampleFactor == expected.downsampleFactor &&
      downsampleFormula == expected.downsampleFormula &&
      requestedCameraHz == expected.requestedCameraHz &&
      cameraTimeOffsetSeconds == expected.cameraTimeOffsetSeconds &&
      accelerationScale == expected.accelerationScale &&
      requestedAccelerometerHz == expected.requestedAccelerometerHz &&
      requestedGyroscopeHz == expected.requestedGyroscopeHz;
  final Map<String, Object?> safeValues = <String, Object?>{
    for (final String key in keys) key: map?[key],
  };
  return VioShadowRunIdentitySummary(
    schemaValid: schemaValid,
    matchesExpected: matchesExpected,
    values: Map<String, Object?>.unmodifiable(safeValues),
  );
}
