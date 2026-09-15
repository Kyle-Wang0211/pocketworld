// dense_live_cloud.dart — the DISPLAY copy of a dense job that is still running.
//
// PWDense v2 delivers one chunk per reference frame the moment that frame is fused (pwdense_run2). The PLY on
// disk stays the full delivery; this class only accumulates what the viewer draws, and the viewer's ceiling is
// the review point budget (ReviewPointCloudPolicy.kPointBudget = Potree's default 1 M — the Dart painter
// projects and sorts every drawn point every frame).
//
// The rule is fixed, not tuned: each chunk of n points is kept with stride
//     k = max(1, ceil(framesPlanned * n / budget))
// so once all framesPlanned frames have arrived the accumulated copy is still about one budget's worth, and a
// point kept early is never dropped later (the display only ever grows). A hard clamp at [budget] covers the
// case where more frames arrive than were planned, or where per-frame rounding creeps over the line.
//
// Full counts are kept separately: [sourcePoints] counts every delivered point, not the displayed subset.
import 'dart:math' as math;
import 'dart:typed_data';

import '../point_cloud_display/progressive_octree_order.dart'
    show ReviewPointCloudPolicy;

class DenseLiveCloud {
  DenseLiveCloud({
    int framesPlanned = 1,
    this.budget = ReviewPointCloudPolicy.kPointBudget,
  }) : framesPlanned = framesPlanned < 1 ? 1 : framesPlanned;

  /// Number of reference frames the job is expected to deliver. 1 (the default) means "unknown": keep every
  /// point until the caller knows better — the [budget] clamp still applies.
  final int framesPlanned;

  /// Display ceiling. Defaults to the review budget; injectable so tests need not push a million points.
  final int budget;

  Float32List _xyzBuf = Float32List(0);
  Uint8List _rgbBuf = Uint8List(0);
  int _kept = 0;

  Float32List _xyz = Float32List(0);
  Uint8List _rgb = Uint8List(0);

  int _sourcePoints = 0;
  int _frames = 0;
  int _lastFrameIndex = -1;

  /// Packed xyz of the display copy. A NEW instance after every [addChunk] — the painter repaints on identity
  /// change — and stable between chunks.
  Float32List get xyz => _xyz;

  /// Packed rgb of the display copy, same length rule (3 bytes per point) and same identity contract as [xyz].
  Uint8List get rgb => _rgb;

  /// Points currently displayed (after the stride), never above [budget].
  int get points => _kept;

  /// Every point delivered so far, before the stride — what the PLY will hold for these frames.
  int get sourcePoints => _sourcePoints;

  /// Chunks received so far (one per fused reference frame).
  int get frames => _frames;

  /// `frame_index` of the last chunk, -1 before the first one.
  int get lastFrameIndex => _lastFrameIndex;

  bool get isEmpty => _kept == 0;

  /// Keep-one-in-k for a chunk of [chunkPoints] points. Deterministic, per chunk, from the plan alone.
  int strideFor(int chunkPoints) {
    if (chunkPoints <= 0) return 1;
    final k = (framesPlanned * chunkPoints / budget).ceil();
    return k < 1 ? 1 : k;
  }

  /// Appends one fused reference frame. [xyz] is n*3 floats and [rgb] n*3 bytes (a short buffer is truncated to
  /// the shorter of the two rather than throwing: a malformed chunk must not kill the job).
  void addChunk({
    required int frameIndex,
    required Float32List xyz,
    required Uint8List rgb,
  }) {
    final n = math.min(xyz.length ~/ 3, rgb.length ~/ 3);
    _frames++;
    _lastFrameIndex = frameIndex;
    _sourcePoints += n;
    if (n > 0) {
      final k = strideFor(n);
      var take = (n + k - 1) ~/ k; // ceil(n / k)
      final room = budget - _kept;
      if (take > room) take = room;
      if (take > 0) {
        _ensureCapacity(_kept + take);
        for (var i = 0; i < take; i++) {
          final src = i * k * 3;
          final dst = (_kept + i) * 3;
          _xyzBuf[dst] = xyz[src];
          _xyzBuf[dst + 1] = xyz[src + 1];
          _xyzBuf[dst + 2] = xyz[src + 2];
          _rgbBuf[dst] = rgb[src];
          _rgbBuf[dst + 1] = rgb[src + 1];
          _rgbBuf[dst + 2] = rgb[src + 2];
        }
        _kept += take;
      }
    }
    _publish();
  }

  /// One copy per chunk (chunks arrive a few per second at most), so the painter sees a new identity and never
  /// reads a buffer that is being appended to.
  void _publish() {
    _xyz = _xyzBuf.sublist(0, _kept * 3);
    _rgb = _rgbBuf.sublist(0, _kept * 3);
  }

  void _ensureCapacity(int points) {
    if (_xyzBuf.length >= points * 3) return;
    var cap = _xyzBuf.length ~/ 3;
    if (cap < 1024) cap = 1024;
    while (cap < points) {
      cap *= 2;
    }
    if (cap > budget)
      cap =
          budget; // points <= budget always (the caller clamps to the remaining room)
    if (cap < points) cap = points;
    final xyzBuf = Float32List(cap * 3);
    xyzBuf.setRange(0, _kept * 3, _xyzBuf);
    final rgbBuf = Uint8List(cap * 3);
    rgbBuf.setRange(0, _kept * 3, _rgbBuf);
    _xyzBuf = xyzBuf;
    _rgbBuf = rgbBuf;
  }
}
