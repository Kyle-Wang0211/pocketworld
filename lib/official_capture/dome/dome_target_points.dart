// Discrete target-point coverage tracker for the capture dome.
//
// v6 architecture: 1:1 visual = data. Each visible target point owns
// its own [RingBufferCell] (8-frame ring buffer + diversity-driven
// eviction) and runs the same strict 5-gate promotion as iOS Aether3D
// v1 (≥3 frames + median sharpness ≥ 600 + az spread ≥ 3° + time
// spread ≥ 0.5 s + max motion ≤ 0.5). This module replaces both the
// old `DomeCoverageMap` (60-cell data layer) and the v3-v5 separate
// visual-only target points — one class, one source of truth.
//
// Topology: cosine-weighted lat-long grid. Equator dense, poles
// collapse to 1 point each (no degenerate stacked points). Default
// 11 rings × cosine-weighted az count = 118 total points (1, 6, 11,
// 15, 17, 18, 17, 15, 11, 6, 1 per ring).
//
// Per-frame routing: each ingested [CapturedFrameSample] is routed to
// the SINGLE nearest target point (max dot product on unit sphere).
// That point's ring buffer accepts the frame; promotion is recomputed.
// When a point newly transitions to `ok` or higher, [pointVisitedStream]
// emits its index and [notifyListeners] fires.
//
// Upload pipeline: [curateForUpload] keeps up to five diverse,
// high-quality frames per non-empty point for 3DGS / DA3 multi-view.
// Selection is greedy: sharpness matters, but near-duplicate poses lose
// to slightly different angles with healthy scale-alignment premetrics.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart' as v64;

import 'captured_frame_sample.dart';
import 'dome_cell_state.dart';
import 'dome_config.dart';
import 'ring_buffer_cell.dart';
import 'session_view_graph_curator.dart';

/// Identity + state for one target point on the cosine-weighted
/// lat-long grid.
///
/// Static fields (set once at generation): identity + geometry +
/// neighbor indices. Mutable fields ([visited], [visitedAt]) reflect
/// the user-visible promotion state — flipped to true once the
/// owning point's [RingBufferCell] state reaches `ok` or higher,
/// never reverts (high-water).
class DomeTargetPoint {
  /// Stable index in [0, totalCount). Computed
  /// `ringStart[elIndex] + azIndex`.
  final int index;

  /// Position within this point's ring (0..ringAzCount-1).
  final int azIndex;

  /// Ring index (0..elCount-1, 0 = bottom-most).
  final int elIndex;

  /// Total az points in this point's ring. Polar rings = 1.
  final int ringAzCount;

  /// Spherical coords (rad).
  final double azimuthRad;
  final double elevationRad;

  /// Pre-computed unit Cartesian — painter consumes this directly.
  final v64.Vector3 unitXyz;

  /// Indices of orthogonal neighbors. -1 = no neighbor.
  /// • E / W: within same ring (mod ringAzCount). -1 only for polar
  ///   single-point rings.
  /// • N: closest azimuth in ring above (-1 if at top ring).
  /// • S: closest azimuth in ring below (-1 if at bottom ring).
  final int eastIndex;
  final int westIndex;
  final int northIndex;
  final int southIndex;

  /// Mutable: user-visible state. Flipped true once state ≥ ok.
  /// Painter reads this for the steady-state visited rendering.
  bool visited;
  DateTime? visitedAt;

  DomeTargetPoint({
    required this.index,
    required this.azIndex,
    required this.elIndex,
    required this.ringAzCount,
    required this.azimuthRad,
    required this.elevationRad,
    required this.unitXyz,
    required this.eastIndex,
    required this.westIndex,
    required this.northIndex,
    required this.southIndex,
    this.visited = false,
    this.visitedAt,
  });
}

/// One curated frame with its point info — output of
/// [DomeTargetPoints.curateForUpload].
///
/// JSON field-name compat with the legacy az_bin/el_bin server
/// contract (so [CuratedManifest] doesn't need to change):
///   • [azBin] = azIndex within point's ring (0..ringAzCount-1)
///   • [elBin] = ringIndex (0..elCount-1)
class CuratedFrame {
  final CapturedFrameSample sample;
  final int azBin;
  final int elBin;
  final DomeCellState cellState;
  final double qualityScore;
  final int cellRankInTopK;
  final int radiusShellId;
  final double graphConnectivity;
  final double matchabilityScore;
  final List<String> da3NeighborFrameIds;

  const CuratedFrame({
    required this.sample,
    required this.azBin,
    required this.elBin,
    required this.cellState,
    required this.qualityScore,
    required this.cellRankInTopK,
    this.radiusShellId = 0,
    this.graphConnectivity = 0.0,
    this.matchabilityScore = 0.0,
    this.da3NeighborFrameIds = const <String>[],
  });
}

/// Aggregate counts for the dome status. Currently no on-screen HUD
/// consumes these (HUD removed in v3), but the API is kept for the
/// upload pipeline + diagnostics + future UI.
class DomeAggregateCounts {
  final int validFrames;
  final int emptyPoints;
  final int weakPoints;
  final int okPoints;
  final int excellentPoints;

  const DomeAggregateCounts({
    required this.validFrames,
    required this.emptyPoints,
    required this.weakPoints,
    required this.okPoints,
    required this.excellentPoints,
  });
}

/// Coverage tracker on a cosine-weighted lat-long grid. Visual = data
/// (1:1) — each point owns its [RingBufferCell] and tracks promotion
/// independently.
class DomeTargetPoints extends ChangeNotifier {
  final DomePointConfig config;
  final DomeThresholds thresholds;

  late final List<DomeTargetPoint> _points;
  late final List<RingBufferCell> _buffers; // 1:1 with _points
  late final List<DomeCellState> _states; // memoized per-point state

  int _validFrameCount = 0;
  int? _currentPointIndex;
  final Map<String, ({int cellIdx, int slotIdx})> _canonicalAdmissions =
      <String, ({int cellIdx, int slotIdx})>{};

  /// Wall-clock elapsed since last `reset()`. Reset starts the clock,
  /// every state-transition log line prefixes the elapsed seconds so
  /// users can correlate "this cell lit up at 12.3 s" with their own
  /// motion in the capture. Diagnostic-only — does not affect any
  /// promotion logic (which uses [CapturedFrameSample.timestamp] from
  /// CaptureSession's monotonic clock for time-spread checks).
  final Stopwatch _diagClock = Stopwatch();

  /// Pre-computed ring metadata.
  late final List<_RingMeta> _ringMeta;

  /// Fires once per newly-promoted point (transition to ok or higher).
  /// Repeat-promotions (ok → excellent) do not re-fire.
  final StreamController<int> _pointVisitedCtrl =
      StreamController<int>.broadcast();

  /// General per-state-transition callback. Fires for every state
  /// change (empty → weak, weak → ok, ok → excellent).
  ValueChanged<({int pointIndex, DomeCellState state})>? onPointStateChanged;

  /// Aggregate count callback. Fires after every successful ingest.
  ValueChanged<DomeAggregateCounts>? onAggregateChanged;

  bool _disposed = false;
  static const bool _kDiagLog = true;

  // Reject-stream dedupe state. Same reason hitting back-to-back at 6 Hz
  // would spam the console; we log on transition + every ~2s heartbeat
  // so a long "white wall" sequence stays visible without flooding.
  String? _lastRejectReason;
  int _consecutiveSameRejectCount = 0;
  final List<double> _acceptedRadiiM = <double>[];

  DomeTargetPoints({
    this.config = DomePointConfig.defaults,
    this.thresholds = DomeThresholds.defaults,
  }) {
    _initRingsAndPoints();
    _buffers = List.generate(
      _points.length,
      (_) => RingBufferCell(capacity: thresholds.maxFramesPerCell),
    );
    _states = List.filled(_points.length, DomeCellState.empty, growable: false);

    if (_kDiagLog) {
      // ignore: avoid_print
      print(
        '[TargetPoints] generated ${_ringMeta.length} rings, '
        '${_points.length} total points '
        '(per-ring az: ${_ringMeta.map((r) => r.azCount).join(", ")}). '
        'Each point owns its ${thresholds.maxFramesPerCell}-frame '
        'ring buffer + 5-gate v1 promotion.',
      );
    }
  }

  void _initRingsAndPoints() {
    final elStep = config.elCount > 1
        ? (config.maxElevationDeg - config.minElevationDeg) /
              (config.elCount - 1)
        : 0.0;

    // Compute per-ring az count.
    _ringMeta = List.generate(config.elCount, (el) {
      final elDeg = config.minElevationDeg + el * elStep;
      final elRad = elDeg * math.pi / 180;
      // Cosine-weighted; floor at 1 so polar rings = single point.
      final azCount = math.max(
        1,
        (config.equatorAzCount * math.cos(elRad)).round().abs(),
      );
      return _RingMeta(elIndex: el, elRad: elRad, azCount: azCount);
    });

    // Cumulative starting offset per ring.
    final ringStart = <int>[0];
    for (final r in _ringMeta) {
      ringStart.add(ringStart.last + r.azCount);
    }

    // Generate points + neighbor indices.
    final pts = <DomeTargetPoint>[];
    for (var el = 0; el < _ringMeta.length; el++) {
      final r = _ringMeta[el];
      final cosE = math.cos(r.elRad);
      final sinE = math.sin(r.elRad);
      for (var az = 0; az < r.azCount; az++) {
        final azRad = az * 2 * math.pi / r.azCount;
        final cosA = math.cos(azRad);
        final sinA = math.sin(azRad);
        final index = ringStart[el] + az;

        // E/W within ring (mod). -1 if single-point polar ring.
        final eastIdx = r.azCount > 1
            ? ringStart[el] + (az + 1) % r.azCount
            : -1;
        final westIdx = r.azCount > 1
            ? ringStart[el] + (az - 1 + r.azCount) % r.azCount
            : -1;

        // N: nearest azimuth in ring above. -1 if at top ring.
        int northIdx = -1;
        if (el < _ringMeta.length - 1) {
          final upR = _ringMeta[el + 1];
          final ratio = azRad / (2 * math.pi);
          final nearestAz = (ratio * upR.azCount).round() % upR.azCount;
          northIdx = ringStart[el + 1] + nearestAz;
        }
        // S: nearest azimuth in ring below.
        int southIdx = -1;
        if (el > 0) {
          final downR = _ringMeta[el - 1];
          final ratio = azRad / (2 * math.pi);
          final nearestAz = (ratio * downR.azCount).round() % downR.azCount;
          southIdx = ringStart[el - 1] + nearestAz;
        }

        pts.add(
          DomeTargetPoint(
            index: index,
            azIndex: az,
            elIndex: el,
            ringAzCount: r.azCount,
            azimuthRad: azRad,
            elevationRad: r.elRad,
            unitXyz: v64.Vector3(cosE * cosA, sinE, cosE * sinA),
            eastIndex: eastIdx,
            westIndex: westIdx,
            northIndex: northIdx,
            southIndex: southIdx,
          ),
        );
      }
    }
    _points = pts;
  }

  // ─── Read API ────────────────────────────────────────────────────────

  List<DomeTargetPoint> get points => List.unmodifiable(_points);
  int get totalCount => _points.length;
  int get visitedCount =>
      _states.where((s) => s.rank >= DomeCellState.ok.rank).length;
  double get visitedFraction =>
      _points.isEmpty ? 0 : visitedCount / _points.length;

  int get validFrameCount => _validFrameCount;
  int? get currentPointIndex => _currentPointIndex;
  DomeCellState stateAt(int pointIndex) => _states[pointIndex];

  /// Newly-promoted-point indices stream (transition to ≥ ok).
  Stream<int> get pointVisitedStream => _pointVisitedCtrl.stream;

  /// Plan G W2 photos-on-disk arch: stamp a JPEG path onto the sample
  /// stored at `(cellIdx, slotIdx)`. Called by CaptureSession right
  /// after a successful [ingest] return, so the buffered sample carries
  /// its on-disk JPEG location for `retainedJpegPaths` and the photos
  /// manifest writer.
  void stampJpegPath({
    required int cellIdx,
    required int slotIdx,
    required String jpegPath,
  }) {
    if (cellIdx < 0 || cellIdx >= _buffers.length) return;
    _buffers[cellIdx].setSlotJpegPath(slotIdx, jpegPath);
  }

  /// Plan G W2 photos-on-disk arch: list of every retained sample's
  /// `jpegPath` across every cell's ring buffer, filtered to non-null.
  /// CaptureSession reads this on stop() to know what to feed into the
  /// .photos.json manifest (and, eventually, into W3 DA3 inference).
  ///
  /// Order matches `points.length` × buffer iteration order — caller
  /// can sort if presentation order matters.
  List<String> get retainedJpegPaths {
    final out = <String>[];
    for (final b in _buffers) {
      for (final s in b.samples) {
        final p = s.jpegPath;
        if (p != null) out.add(p);
      }
    }
    return out;
  }

  /// Keep the in-memory retained-path view aligned with the final
  /// curated photo set after CaptureSession deletes unselected files.
  void retainOnlyJpegPaths(Set<String> keep) {
    for (final b in _buffers) {
      b.retainOnlyJpegPaths(keep);
    }
  }

  DomeAggregateCounts get aggregateCounts {
    var empty = 0, weak = 0, ok = 0, exc = 0;
    for (final s in _states) {
      switch (s) {
        case DomeCellState.empty:
          empty++;
        case DomeCellState.weak:
          weak++;
        case DomeCellState.ok:
          ok++;
        case DomeCellState.excellent:
          exc++;
      }
    }
    return DomeAggregateCounts(
      validFrames: _validFrameCount,
      emptyPoints: empty,
      weakPoints: weak,
      okPoints: ok,
      excellentPoints: exc,
    );
  }

  // ─── Mutators ────────────────────────────────────────────────────────

  /// Reset every point to empty. Called at the start of each capture.
  void reset() {
    if (_disposed) return;
    for (final b in _buffers) {
      b.clear();
    }
    for (var i = 0; i < _states.length; i++) {
      _states[i] = DomeCellState.empty;
    }
    for (final p in _points) {
      p.visited = false;
      p.visitedAt = null;
    }
    _validFrameCount = 0;
    _currentPointIndex = null;
    _canonicalAdmissions.clear();
    _lastRejectReason = null;
    _consecutiveSameRejectCount = 0;
    _acceptedRadiiM.clear();
    _diagClock
      ..reset()
      ..start();
    if (_kDiagLog) {
      // ignore: avoid_print
      print(
        '[TargetPoints] reset: ${_points.length} points cleared, '
        'thresholds: '
        'sharpness>=${thresholds.minSharpness.toStringAsFixed(0)} '
        'angular<=${thresholds.maxAngularRateRadPerSec.toStringAsFixed(2)} rad/s '
        'brightness ${thresholds.minBrightness.toStringAsFixed(0)}-'
        '${thresholds.maxBrightness.toStringAsFixed(0)} '
        '|elev|<=${thresholds.maxAbsElevationDeg.toStringAsFixed(0)}°',
      );
    }
    notifyListeners();
    onAggregateChanged?.call(aggregateCounts);
  }

  /// Format elapsed wall-clock as "+SSS.mmms" (e.g. "+12.345s") for log
  /// prefixes. Used to mark every state-change log so the user can
  /// reconstruct exactly when each cell lit up / regressed.
  String _diagElapsed() {
    final ms = _diagClock.elapsedMilliseconds;
    final s = ms / 1000.0;
    return '+${s.toStringAsFixed(3)}s';
  }

  /// Diagnostic: log a rejected frame's reason, deduped so a long
  /// "white wall" / "shaking" sequence prints only the first occurrence
  /// + a heartbeat every ~2s, not every single 6 Hz tick.
  void _logRejectIfNew({
    required String reason,
    required String detail,
    required double t,
  }) {
    if (!_kDiagLog) return;
    if (reason == _lastRejectReason) {
      _consecutiveSameRejectCount++;
      if (_consecutiveSameRejectCount % 12 == 0) {
        // ignore: avoid_print
        print(
          '[TargetPoints] ${_diagElapsed()} still rejecting $reason '
          '(×$_consecutiveSameRejectCount latest=$detail)',
        );
      }
      return;
    }
    // ignore: avoid_print
    print(
      '[TargetPoints] ${_diagElapsed()} reject $reason '
      '@ t=${t.toStringAsFixed(2)}s: $detail',
    );
    _lastRejectReason = reason;
    _consecutiveSameRejectCount = 1;
  }

  /// Called once per accepted frame — closes out the current reject
  /// run (if any) with a `resumed accepting after N x reason` line so
  /// the user can see the recovery moment.
  void _clearRejectStateIfNeeded(double t) {
    if (!_kDiagLog) return;
    if (_lastRejectReason != null) {
      // ignore: avoid_print
      print(
        '[TargetPoints] ${_diagElapsed()} resumed accepting '
        '@ t=${t.toStringAsFixed(2)}s '
        '(after $_consecutiveSameRejectCount × $_lastRejectReason)',
      );
      _lastRejectReason = null;
      _consecutiveSameRejectCount = 0;
    }
  }

  bool _isLiveRadiusOutlier(double radiusM) {
    if (!radiusM.isFinite || radiusM <= 0.05 || _acceptedRadiiM.length < 8) {
      return false;
    }
    final median = _medianRadiusM();
    if (median <= 0.05) return false;
    final ratio = radiusM > median ? radiusM / median : median / radiusM;
    return ratio > thresholds.maxLiveRadiusRatio;
  }

  double _medianRadiusM() {
    if (_acceptedRadiiM.isEmpty) return 0.0;
    final sorted = _acceptedRadiiM.toList()..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) * 0.5;
  }

  /// Ingest a frame. Hard-reject gates → nearest-point routing → per-
  /// point 5-gate promotion.
  ///
  /// Returns `(cellIdx, slotIdx)` if the frame both passed the hard
  /// gates AND was admitted to a buffer slot (either fresh slot on a
  /// non-full buffer, or replacing an evicted slot on a full buffer).
  /// Returns null if the frame failed any hard gate OR if diversity
  /// eviction declined the frame (cell already holds more novel
  /// candidates). CaptureSession uses the (cell, slot) pair to choose a
  /// JPEG path so eviction overwrites the previous slot's JPEG in-place.
  ///
  /// Hard rejects (any one drops the frame, matches Aether3D iOS):
  ///   1. sharpness < minSharpness                          (motion blur)
  ///   2. angularVelocityRadPerSec > maxAngularRateRadPerSec (hand wobble)
  ///   3. meanBrightness < minBrightness or > maxBrightness (too dark / blown)
  ///   4. abs(elevationDeg) > maxAbsElevationDeg            (ceiling / under table)
  ({int cellIdx, int slotIdx})? ingest(CapturedFrameSample sample) {
    if (_disposed) return null;
    if (sample.sharpness < thresholds.minSharpness) {
      _logRejectIfNew(
        reason: 'sharpness',
        detail:
            '${sample.sharpness.toStringAsFixed(0)} '
            '(need >=${thresholds.minSharpness.toStringAsFixed(0)})',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }
    final roiSharpness = sample.roiSharpness > 0
        ? sample.roiSharpness
        : sample.sharpness;
    final consensusSharpness = sample.sharpnessConsensus > 0
        ? sample.sharpnessConsensus
        : roiSharpness;
    if (roiSharpness < thresholds.minRoiSharpness ||
        consensusSharpness < thresholds.minSharpnessConsensus) {
      _logRejectIfNew(
        reason: 'roi_sharpness',
        detail:
            'roi=${roiSharpness.toStringAsFixed(0)} '
            'consensus=${consensusSharpness.toStringAsFixed(0)} '
            '(need roi>=${thresholds.minRoiSharpness.toStringAsFixed(0)} '
            'consensus>=${thresholds.minSharpnessConsensus.toStringAsFixed(0)})',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }
    if (sample.edgeBlockSharpness > 0 &&
        sample.edgeBlockSharpness < thresholds.minEdgeBlockSharpness &&
        consensusSharpness < thresholds.excellentMinSharpnessMedian) {
      _logRejectIfNew(
        reason: 'edge_sharpness',
        detail:
            '${sample.edgeBlockSharpness.toStringAsFixed(0)} '
            '(need >=${thresholds.minEdgeBlockSharpness.toStringAsFixed(0)})',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }
    if (sample.subjectVsBackgroundSharpnessDelta <
        thresholds.minSubjectBackgroundSharpnessDelta) {
      _logRejectIfNew(
        reason: 'subject_focus',
        detail:
            'subject-bg Δ=${sample.subjectVsBackgroundSharpnessDelta.toStringAsFixed(0)} '
            '(need >=${thresholds.minSubjectBackgroundSharpnessDelta.toStringAsFixed(0)})',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }
    if (!sample.focusStable) {
      _logRejectIfNew(
        reason: 'focus_adjusting',
        detail:
            'lens=${sample.lensPosition.toStringAsFixed(2)} '
            'focus=${sample.isAdjustingFocus} exposure=${sample.isAdjustingExposure}',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }
    if (_isLiveRadiusOutlier(sample.cameraRadiusM)) {
      _logRejectIfNew(
        reason: 'radius_jump',
        detail:
            '${sample.cameraRadiusM.toStringAsFixed(2)}m '
            '(median ${_medianRadiusM().toStringAsFixed(2)}m, '
            'max ×${thresholds.maxLiveRadiusRatio.toStringAsFixed(1)})',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }
    if (sample.angularVelocityRadPerSec > thresholds.maxAngularRateRadPerSec) {
      _logRejectIfNew(
        reason: 'angular',
        detail:
            '${sample.angularVelocityRadPerSec.toStringAsFixed(2)} rad/s '
            '(cap ${thresholds.maxAngularRateRadPerSec.toStringAsFixed(2)})',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }
    if (sample.meanBrightness < thresholds.minBrightness ||
        sample.meanBrightness > thresholds.maxBrightness) {
      _logRejectIfNew(
        reason: 'brightness',
        detail:
            '${sample.meanBrightness.toStringAsFixed(0)} '
            '(band ${thresholds.minBrightness.toStringAsFixed(0)}-'
            '${thresholds.maxBrightness.toStringAsFixed(0)})',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }
    final elevationDeg = sample.elevation * 180.0 / math.pi;
    if (elevationDeg.abs() > thresholds.maxAbsElevationDeg) {
      _logRejectIfNew(
        reason: 'elevation',
        detail:
            '${elevationDeg.toStringAsFixed(1)}° '
            '(cap ±${thresholds.maxAbsElevationDeg.toStringAsFixed(0)}°)',
        t: sample.timestamp,
      );
      _currentPointIndex = null;
      return null;
    }

    // Frame passed all 4 hard gates — emit one "resumed" line if we'd
    // been continuously rejecting so the user sees the recovery.
    _clearRejectStateIfNeeded(sample.timestamp);
    if (sample.cameraRadiusM.isFinite && sample.cameraRadiusM > 0.05) {
      _acceptedRadiiM.add(sample.cameraRadiusM);
      if (_acceptedRadiiM.length > 128) _acceptedRadiiM.removeAt(0);
    }

    // Find nearest point: max dot product on unit sphere.
    final ux = math.cos(sample.elevation) * math.cos(sample.azimuth);
    final uy = math.sin(sample.elevation);
    final uz = math.cos(sample.elevation) * math.sin(sample.azimuth);
    var bestIdx = 0;
    var bestCos = -2.0;
    for (var i = 0; i < _points.length; i++) {
      final p = _points[i];
      final c = ux * p.unitXyz.x + uy * p.unitXyz.y + uz * p.unitXyz.z;
      if (c > bestCos) {
        bestCos = c;
        bestIdx = i;
      }
    }

    final buffer = _buffers[bestIdx];
    final prevState = _states[bestIdx];
    final slotIdx = buffer.append(sample);
    _validFrameCount++;
    final raw = buffer.computeRawState(thresholds);
    buffer.bumpHighWater(raw);
    final newState = buffer.state(thresholds);
    _states[bestIdx] = newState;
    _currentPointIndex = bestIdx;

    final wasNotVisited = prevState.rank < DomeCellState.ok.rank;
    final isNowVisited = newState.rank >= DomeCellState.ok.rank;

    if (newState != prevState) {
      onPointStateChanged?.call((pointIndex: bestIdx, state: newState));

      // Log EVERY state transition with elapsed timestamp. Distinguish:
      //   • promotion (rank up):    [TargetPoints] +12.345s ↑ point #N ...
      //   • demotion (rank down):   [TargetPoints] +12.345s ↓ point #N ... DEMOTE
      //   • side-grade (same rank): not really possible with DomeCellState
      // Demotions can happen when the ring buffer's high-water-mark
      // hysteresis evicts good frames — `point.visited` stays true (the
      // visual stays "lit") but the underlying state regresses, which is
      // useful diagnostic info if the user reports "白点回退".
      final isPromotion = newState.rank > prevState.rank;
      final arrow = isPromotion ? '↑' : '↓';
      final tag = isPromotion ? 'promoted' : 'DEMOTED';
      if (_kDiagLog) {
        final p = _points[bestIdx];
        // ignore: avoid_print
        print(
          '[TargetPoints] ${_diagElapsed()} $arrow point #$bestIdx '
          '(ring ${p.elIndex} '
          'az ${p.azIndex}/${p.ringAzCount}, '
          'el=${(p.elevationRad * 180 / math.pi).toStringAsFixed(0)}°, '
          'az=${(p.azimuthRad * 180 / math.pi).toStringAsFixed(0)}°) '
          '$tag ${prevState.name} → ${newState.name} '
          '— total $visitedCount/${_points.length} '
          '(${(visitedFraction * 100).toStringAsFixed(0)}%)',
        );
      }

      if (wasNotVisited && isNowVisited) {
        // First-time promotion to ok+. Light up + emit visit event.
        _points[bestIdx].visited = true;
        _points[bestIdx].visitedAt = DateTime.now();
        _pointVisitedCtrl.add(bestIdx);
        notifyListeners();
      }
    }
    onAggregateChanged?.call(aggregateCounts);
    if (slotIdx == null) return null; // eviction declined; nothing to save
    return (cellIdx: bestIdx, slotIdx: slotIdx);
  }

  /// Force-admit a single manually-captured frame, BYPASSING the hard-reject
  /// quality gates that [ingest] applies. Routes to the nearest target point
  /// on the unit sphere (identical routing to [ingest]) and appends it to that
  /// point's ring buffer. Returns the (cellIdx, slotIdx) to stamp the saved
  /// JPEG onto, or null if the ring buffer declined the frame.
  ///
  /// Used by the RealityScan-style manual capture flow (one shutter tap = one
  /// photo): the user, not a motion/quality gate, decides when to shoot.
  ({int cellIdx, int slotIdx})? forceAdmit(CapturedFrameSample sample) {
    if (_disposed) return null;
    if (sample.cameraRadiusM.isFinite && sample.cameraRadiusM > 0.05) {
      _acceptedRadiiM.add(sample.cameraRadiusM);
      if (_acceptedRadiiM.length > 128) _acceptedRadiiM.removeAt(0);
    }
    // Find nearest point: max dot product on unit sphere (same as ingest()).
    final ux = math.cos(sample.elevation) * math.cos(sample.azimuth);
    final uy = math.sin(sample.elevation);
    final uz = math.cos(sample.elevation) * math.sin(sample.azimuth);
    var bestIdx = 0;
    var bestCos = -2.0;
    for (var i = 0; i < _points.length; i++) {
      final p = _points[i];
      final c = ux * p.unitXyz.x + uy * p.unitXyz.y + uz * p.unitXyz.z;
      if (c > bestCos) {
        bestCos = c;
        bestIdx = i;
      }
    }

    final buffer = _buffers[bestIdx];
    final prevState = _states[bestIdx];
    // force: manual capture must never be silently declined by the ring's
    // novelty/quality eviction gate (see RingBufferCell.append [FORCE]).
    final slotIdx = buffer.append(sample, force: true);
    if (slotIdx == null) return null; // buffer declined; nothing to save
    _validFrameCount++;
    final raw = buffer.computeRawState(thresholds);
    buffer.bumpHighWater(raw);
    final newState = buffer.state(thresholds);
    _states[bestIdx] = newState;
    _currentPointIndex = bestIdx;

    if (newState != prevState) {
      onPointStateChanged?.call((pointIndex: bestIdx, state: newState));
      if (prevState.rank < DomeCellState.ok.rank &&
          newState.rank >= DomeCellState.ok.rank) {
        _points[bestIdx].visited = true;
        _points[bestIdx].visitedAt = DateTime.now();
        _pointVisitedCtrl.add(bestIdx);
      }
    }
    onAggregateChanged?.call(aggregateCounts);
    // Manual capture is low-frequency, so notify on every shot: the album +
    // live count + AR cards all observe this notifier and must refresh.
    notifyListeners();
    return (cellIdx: bestIdx, slotIdx: slotIdx);
  }

  /// Replay-safe canonical projection. Reapplying one transaction returns its
  /// original placement without appending another frame or incrementing
  /// coverage counters.
  ({int cellIdx, int slotIdx})? forceAdmitCanonical(
    String transactionId,
    CapturedFrameSample sample,
  ) {
    final existing = _canonicalAdmissions[transactionId];
    if (existing != null) return existing;
    final admitted = forceAdmit(sample);
    if (admitted != null) _canonicalAdmissions[transactionId] = admitted;
    return admitted;
  }

  // ─── Upload curation (verbatim port from old DomeCoverageMap, but
  // iterating points instead of cells) ─────────────────────────────

  /// Pick the best retained frames for local reconstruction.
  ///
  /// Default behavior is 5 frames per non-empty point (118 × 5 = 590
  /// when the capture is complete). Passing [targetTotal] preserves the
  /// legacy balanced-total mode for tests / experiments.
  List<CuratedFrame> curateForUpload({
    int? targetTotal,
    int framesPerPoint = 5,
  }) {
    if (_disposed) return const [];

    // 1. Collect non-empty points.
    final candidates = <ViewGraphFrameCandidate>[];
    for (var i = 0; i < _points.length; i++) {
      final st = _states[i];
      if (st == DomeCellState.empty) continue;
      final samples = _buffers[i].samples.toList();
      if (samples.isEmpty) continue;
      final p = _points[i];
      final neighborIndices = <int>[
        p.eastIndex,
        p.westIndex,
        p.northIndex,
        p.southIndex,
      ].where((idx) => idx >= 0 && idx < _points.length).toList();
      for (final sample in samples) {
        candidates.add(
          ViewGraphFrameCandidate(
            sample: sample,
            pointIndex: i,
            azIndex: p.azIndex,
            elIndex: p.elIndex,
            state: st,
            neighborPointIndices: neighborIndices,
            neighborSupport: _neighborSupportFor(i),
          ),
        );
      }
    }
    if (candidates.isEmpty) return const [];

    final selections = SessionViewGraphCurator(
      totalBudget: targetTotal ?? 590,
      baseFramesPerPoint: math.max(1, framesPerPoint),
      softCapPerPoint: thresholds.maxFramesPerCell,
      hardCapPerPoint: math.max(thresholds.maxFramesPerCell, 20),
    ).select(candidates);

    final rankByPoint = <int, int>{};
    final out = <CuratedFrame>[];
    for (final selection in selections) {
      final c = selection.candidate;
      final rank = rankByPoint[c.pointIndex] ?? 0;
      rankByPoint[c.pointIndex] = rank + 1;
      out.add(
        CuratedFrame(
          sample: c.sample,
          azBin: c.azIndex,
          elBin: c.elIndex,
          cellState: c.state,
          qualityScore: selection.score,
          cellRankInTopK: rank,
          radiusShellId: selection.radiusShellId,
          graphConnectivity: selection.graphConnectivity,
          matchabilityScore: selection.matchabilityScore,
          da3NeighborFrameIds: selection.da3NeighborFrameIds,
        ),
      );
    }
    return out;
  }

  double _neighborSupportFor(int pointIndex) {
    final p = _points[pointIndex];
    final neighbors = <int>[
      p.eastIndex,
      p.westIndex,
      p.northIndex,
      p.southIndex,
    ].where((idx) => idx >= 0 && idx < _buffers.length).toList();
    if (neighbors.isEmpty) return 0.0;
    var occupied = 0;
    for (final idx in neighbors) {
      if (_buffers[idx].samples.isNotEmpty) occupied++;
    }
    return occupied / neighbors.length;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pointVisitedCtrl.close();
    super.dispose();
  }
}

class _RingMeta {
  final int elIndex;
  final double elRad;
  final int azCount;
  const _RingMeta({
    required this.elIndex,
    required this.elRad,
    required this.azCount,
  });
}
