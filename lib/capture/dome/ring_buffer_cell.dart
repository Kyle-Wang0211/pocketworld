// Per-cell ring buffer + state computation.
//
// Ported from Aether3D's `ObjectModeV2CoverageMap.swift::RingBufferCell`.
//
// Two non-obvious mechanisms in here, both inherited verbatim:
//
//   (1) DIVERSITY-DRIVEN EVICTION.
//       Naive FIFO eviction means a 30 fps burst at one pose pushes out
//       all earlier-captured frames from other angles. So when the buffer
//       is full, we don't drop the oldest — we drop the LEAST NOVEL frame
//       (smallest distance to its nearest neighbor in the buffer). If the
//       new frame isn't more novel than what's there, we keep the buffer
//       and let the new frame go. This keeps the buffer's az/el spread
//       high.
//
//   (2) MONOTONIC HIGH-WATER STATE.
//       Once a cell is shown to the user as `excellent`, it must NOT
//       revert to `ok` because a slightly worse frame got admitted
//       afterwards. We track `_highWater` and never let `state()` report
//       a state lower than what was previously achieved. Eviction (1)
//       protects the buffer's contents; (2) protects the user-facing
//       indicator from one-tick instability in the aggregate metrics.

import 'dart:math' as math;

import 'captured_frame_sample.dart';
import 'dome_cell_state.dart';
import 'dome_thresholds.dart';

class RingBufferCell {
  final int capacity;
  final List<CapturedFrameSample> _buf = <CapturedFrameSample>[];
  DomeCellState _highWater = DomeCellState.empty;

  RingBufferCell({required int capacity}) : capacity = math.max(4, capacity);

  /// Read-only view of the current samples (oldest-first insertion order).
  List<CapturedFrameSample> get samples => List.unmodifiable(_buf);

  /// All frame IDs currently retained — used by the upload curator.
  List<String> get frameIds =>
      _buf.map((s) => s.frameId).toList(growable: false);

  void clear() {
    _buf.clear();
    _highWater = DomeCellState.empty;
  }

  /// Insert a new sample. If the buffer is full, do diversity-driven
  /// eviction: replace the least novel resident with the new one IFF the
  /// new one is more novel (or equally novel but higher quality).
  ///
  /// Returns the slot index where `s` landed:
  ///   • on a non-full buffer: the new last index
  ///   • on a full buffer with successful eviction: the replaced index
  ///   • when eviction declined the new frame: `null`
  ///
  /// CaptureSession uses the returned slot to choose a JPEG path
  /// (`cell_<cellIdx>_slot_<slotIdx>_<frameId>.jpg`)。[2026-07-11 色彩
  /// 污染修复] 文件名带 frameId,驱逐不再同名覆盖旧 JPEG——旧文件仍被
  /// SfM fed jsonl 引用(colorize/resume 取色),由 colorize 后的
  /// deferred prune 统一清理。
  int? append(CapturedFrameSample s) {
    if (_buf.length < capacity) {
      _buf.add(s);
      return _buf.length - 1;
    }
    // Buffer full → find the least novel resident.
    var worstIdx = 0;
    var worstNovelty = double.infinity;
    for (var i = 0; i < _buf.length; i++) {
      final novelty = _minDistance(of: _buf[i], to: _buf, excluding: i);
      if (novelty < worstNovelty) {
        worstNovelty = novelty;
        worstIdx = i;
      }
    }
    final newNovelty = _minDistance(of: s, to: _buf, excluding: null);
    final worstQuality = _qualityOf(_buf[worstIdx]);
    final newQuality = _qualityOf(s);

    // Primary: replace if new frame is meaningfully more novel.
    // Secondary: same novelty but higher quality (deduplicates near-
    //            identical frames, keeping the sharper one).
    final shouldReplace =
        newNovelty > worstNovelty + 0.001 ||
        ((newNovelty - worstNovelty).abs() <= 1.0 && newQuality > worstQuality);
    if (shouldReplace) {
      _buf[worstIdx] = s;
      return worstIdx;
    }
    return null;
  }

  /// Bump the cell's "highest state ever shown" so future `state()` reads
  /// don't slide back down.
  void bumpHighWater(DomeCellState next) {
    if (next.rank > _highWater.rank) _highWater = next;
  }

  /// Plan G W2 photos-on-disk arch: stamp a JPEG path onto the sample
  /// at the given slot. Used by CaptureSession right after [append]
  /// returns its slot index, so the buffered sample carries its
  /// on-disk JPEG location. Out-of-range slots are no-ops (defensive
  /// against a sample being evicted before the stamp lands — eviction
  /// is synchronous in our flow so this shouldn't fire in practice).
  void setSlotJpegPath(int slotIdx, String jpegPath) {
    if (slotIdx < 0 || slotIdx >= _buf.length) return;
    _buf[slotIdx] = _buf[slotIdx].withJpegPath(jpegPath);
  }

  /// Drop JPEG references that did not survive final upload curation.
  /// The files are deleted by CaptureSession; this keeps in-memory
  /// retainedJpegPaths consistent with the post-prune directory.
  void retainOnlyJpegPaths(Set<String> keep) {
    for (var i = 0; i < _buf.length; i++) {
      final path = _buf[i].jpegPath;
      if (path != null && !keep.contains(path)) {
        _buf[i] = _buf[i].withJpegPath(null);
      }
    }
  }

  /// User-facing state. Equal to the higher of (a) recomputed-from-buffer
  /// or (b) the historical high-water mark.
  DomeCellState state(DomeThresholds t) {
    final raw = computeRawState(t);
    return raw.rank >= _highWater.rank ? raw : _highWater;
  }

  /// Re-derived purely from the buffer contents — used to bump the high
  /// water mark, NOT to drive the visible state directly.
  DomeCellState computeRawState(DomeThresholds t) {
    if (_buf.isEmpty) return DomeCellState.empty;
    // Verbatim from Aether3D RingBufferCell.computeRawState — 1-2
    // frames is weak, 3+ frames runs the excellent gates.
    if (_buf.length <= 2) return DomeCellState.weak;
    if (_buf.length >= t.excellentMinFrames) {
      // azimuth spread (degrees, wraps short-way)
      final azsDeg = _buf.map((s) => s.azimuth * 180 / math.pi).toList();
      final minAz = azsDeg.reduce(math.min);
      final maxAz = azsDeg.reduce(math.max);
      var azSpread = maxAz - minAz;
      if (azSpread > 180) azSpread = 360 - azSpread;
      // wall-clock spread between oldest & newest
      final timeSpread = _buf.last.timestamp - _buf.first.timestamp;
      // median sharpness
      final sortedSharp = _buf.map((s) => s.sharpness).toList()..sort();
      final medSharp = sortedSharp[sortedSharp.length ~/ 2];
      // worst motion
      final maxMotion = _buf.map((s) => s.motionScore).reduce(math.max);

      if (azSpread >= t.excellentMinAzSpreadDeg &&
          timeSpread >= t.excellentMinTimeSpreadSec &&
          medSharp >= t.excellentMinSharpnessMedian &&
          maxMotion <= t.excellentMaxMotion) {
        return DomeCellState.excellent;
      }
    }
    return DomeCellState.ok;
  }

  // ─── Static scoring helpers (no `this` deps for testability) ─────────

  /// Per-frame quality scalar — sharpness leads, motion deducts. Constant
  /// 1000 brings motion (0..1) into the same magnitude band as sharpness
  /// (typical 100..2000). Mirrors the Aether3D weighting.
  static double _qualityOf(CapturedFrameSample s) {
    final sharp = s.sharpnessConsensus > 0
        ? s.sharpnessConsensus
        : (s.roiSharpness > 0 ? s.roiSharpness : s.sharpness);
    final focus = s.focusStable ? 1.0 : 0.0;
    final subjectFocusPenalty = s.subjectVsBackgroundSharpnessDelta < -350
        ? 250.0
        : 0.0;
    return 0.45 * sharp +
        0.10 * s.edgeBlockSharpness +
        120.0 * focus -
        0.3 * s.motionScore * 1000 -
        subjectFocusPenalty;
  }

  /// Distance metric between two frames in (az°, el°, t-sec×10) space.
  /// 1 second of time-spread is treated as ≈ 10° of angle-spread, an
  /// empirical weighting that says "going around the object slowly" feels
  /// roughly like "moving through 10° of arc per second".
  static double _sampleDistance(CapturedFrameSample a, CapturedFrameSample b) {
    final dAz = ((a.azimuth - b.azimuth).abs() * 180 / math.pi);
    final dEl = ((a.elevation - b.elevation).abs() * 180 / math.pi);
    final dT = (a.timestamp - b.timestamp).abs() * 10;
    final dR = _radiusDistance(a.cameraRadiusM, b.cameraRadiusM) * 18;
    return math.sqrt(dAz * dAz + dEl * dEl + dT * dT + dR * dR);
  }

  static double _radiusDistance(double a, double b) {
    if (!a.isFinite || !b.isFinite || a <= 0.05 || b <= 0.05) return 0.0;
    return (math.log(a) - math.log(b)).abs();
  }

  /// Minimum distance from `s` to every other frame in `buf`, optionally
  /// excluding one index (for self-comparison).
  static double _minDistance({
    required CapturedFrameSample of,
    required List<CapturedFrameSample> to,
    required int? excluding,
  }) {
    var m = double.infinity;
    for (var i = 0; i < to.length; i++) {
      if (i == excluding) continue;
      final d = _sampleDistance(of, to[i]);
      if (d < m) m = d;
    }
    return m == double.infinity ? 0 : m;
  }
}
