// PocketWorld Android capture — deferral without loss.
//
// On a device whose SENSOR_INFO_TIMESTAMP_SOURCE is UNKNOWN, camera frames can
// start arriving before the BOOTTIME-MONOTONIC offset has been fixed. Two ways
// to handle that are wrong:
//
//   * Convert with a guessed offset (usually 0). Every early frame then carries
//     a wrong instant, and nothing downstream can tell — the error is silent
//     and permanent.
//   * Drop the early frames. Permanent frame loss, which the delivery contract
//     forbids outright.
//
// The third way is to hold the metadata and resolve it once the offset lands.
// That is a postponement, which fail-safe is allowed to be.
//
// A suspend (ClockOffsetVerdict.suspendJump) invalidates the offset that was in
// force, so anything still pending must be resolved with the NEW offset. That
// falls out of the design: pending frames hold raw metadata, never a converted
// stamp, so they are resolved exactly once and always against a current offset.
//
// SIZE
//   This buffer holds FrameMetadata — five integers per frame, not pixels. A
//   thousand pending frames is a few tens of kilobytes, so there is no memory
//   argument for evicting, which is the argument that would otherwise be used
//   to justify dropping. The caller's image buffer is a separate concern with a
//   separate budget; [pendingCount] and [highWaterMark] exist so the caller can
//   see pressure building and slow ADMISSION, which is upstream backpressure,
//   rather than discard anything already admitted.

import 'camera_timebase.dart';
import 'clock_offset.dart';

class DeferredFrameBuffer {
  DeferredFrameBuffer(this.timeBase);

  final CameraTimeBase timeBase;

  final List<FrameMetadata> _pending = <FrameMetadata>[];
  int _highWaterMark = 0;
  int _admitted = 0;
  int _resolved = 0;

  int get pendingCount => _pending.length;
  int get highWaterMark => _highWaterMark;
  int get admittedCount => _admitted;
  int get resolvedCount => _resolved;

  /// Invariant the caller can assert at any point: nothing has been lost.
  bool get isConserving => _admitted == _resolved + _pending.length;

  /// Offer a frame. Returns its [FrameStamp] when it could be resolved now,
  /// or null when it was buffered. A null is NOT a failure and NOT a drop.
  FrameStamp? admit(FrameMetadata m, {ClockOffset? offset}) {
    _admitted++;
    final s = timeBase.resolve(m, offset: offset);
    if (s.isResolved) {
      _resolved++;
      return s;
    }
    _pending.add(m);
    if (_pending.length > _highWaterMark) _highWaterMark = _pending.length;
    return null;
  }

  /// Resolve everything held, oldest frame first, and empty the buffer.
  ///
  /// Ordering is by frameNumber, which camera2 guarantees is monotonically
  /// increasing within a session — arrival order is not guaranteed once a
  /// reprocessing request is in flight.
  List<FrameStamp> drain(ClockOffset offset) {
    if (_pending.isEmpty) return const <FrameStamp>[];
    _pending.sort((a, b) => a.frameNumber.compareTo(b.frameNumber));
    final out = <FrameStamp>[];
    for (final m in _pending) {
      final s = timeBase.resolve(m, offset: offset);
      // resolve() with a non-null offset cannot defer, so this is total.
      out.add(s);
      _resolved++;
    }
    _pending.clear();
    return out;
  }
}
