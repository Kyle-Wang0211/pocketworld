// PocketWorld Android capture — clock-base normalisation.
//
// PROBLEM
//   Android has two monotonic clocks that a capture pipeline must reconcile:
//     * CLOCK_MONOTONIC  == System.nanoTime()                 (stops during suspend)
//     * CLOCK_BOOTTIME   == SystemClock.elapsedRealtimeNanos() (keeps ticking)
//   SensorEvent.timestamp is BOOTTIME on every conformant device.
//   Camera2's CaptureResult.SENSOR_TIMESTAMP is BOOTTIME *only* when
//   CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE == REALTIME.
//   When the source is UNKNOWN the camera stamp lives in an unrelated monotonic
//   base (in practice CLOCK_MONOTONIC), so image and IMU cannot be fused until
//   the offset between the two bases is measured.
//
//   offset := BOOTTIME - MONOTONIC  ==  accumulated suspend time.
//   It is therefore **monotonically non-decreasing** in exact arithmetic, and it
//   jumps (never slides) whenever the SoC suspends. A measured decrease is
//   physically impossible and is treated as an anomaly to surface, never as a
//   value to silently adopt.
//
// ESTIMATOR
//   Cristian's algorithm / NTP "minimum round-trip" selection. Each probe reads
//   the clocks in the order  mono, boot, mono. Then
//       offset      = boot - (monoBefore + monoAfter) / 2
//       uncertainty = (monoAfter - monoBefore) / 2         (a hard error bound)
//   Out of N probes we keep the one with the SMALLEST uncertainty. Averaging is
//   wrong here: a probe that was preempted between the two mono reads carries an
//   arbitrarily large, one-sided error, and averaging lets that error in.
//
// FAIL-SAFE CONTRACT
//   This class never discards data and never invents a value. If no probe is
//   usable it returns `noUsableProbe` and the previously accepted offset stays
//   in force (deferral, not loss). If the offset moves backwards it returns
//   `anomalyBackwards`, keeps the old offset, and the caller MUST surface it.

/// One triple of clock reads taken back-to-back on the same thread.
class ClockProbe {
  const ClockProbe({
    required this.monoBeforeNs,
    required this.bootNs,
    required this.monoAfterNs,
  });

  /// System.nanoTime() read immediately before [bootNs].
  final int monoBeforeNs;

  /// SystemClock.elapsedRealtimeNanos() read between the two mono reads.
  final int bootNs;

  /// System.nanoTime() read immediately after [bootNs].
  final int monoAfterNs;

  bool get isWellFormed => monoAfterNs >= monoBeforeNs;

  /// Half of the window the boot read is known to lie inside. Hard bound.
  int get uncertaintyNs => (monoAfterNs - monoBeforeNs) ~/ 2;

  /// BOOTTIME - MONOTONIC, using the window midpoint as the mono estimate.
  int get offsetNs => bootNs - ((monoBeforeNs + monoAfterNs) ~/ 2);
}

/// An accepted offset with the bound it was accepted under.
class ClockOffset {
  const ClockOffset({
    required this.offsetNs,
    required this.uncertaintyNs,
    required this.measuredAtBootNs,
  });

  final int offsetNs;
  final int uncertaintyNs;
  final int measuredAtBootNs;

  /// Convert a CLOCK_MONOTONIC stamp (camera, when TIMESTAMP_SOURCE==UNKNOWN)
  /// into the BOOTTIME base that SensorEvent.timestamp already uses.
  int monotonicToBoot(int monoNs) => monoNs + offsetNs;

  /// Inverse, for handing a BOOTTIME instant back to a monotonic-based API.
  int bootToMonotonic(int bootNs) => bootNs - offsetNs;

  @override
  String toString() =>
      'ClockOffset(offset=${offsetNs}ns, +/-${uncertaintyNs}ns, at=${measuredAtBootNs}ns)';
}

enum ClockOffsetVerdict {
  /// First offset ever accepted. Nothing to compare against.
  firstFix,

  /// Offset moved by less than the suspend threshold. Normal.
  stable,

  /// Offset jumped forward: the SoC suspended. Anything holding a converted
  /// timestamp across this instant must be re-anchored.
  suspendJump,

  /// Offset moved backwards by more than the combined error bound. Physically
  /// impossible for BOOTTIME-MONOTONIC. Old offset retained; surface this.
  anomalyBackwards,

  /// Every probe was malformed or too wide. Old offset (if any) retained.
  noUsableProbe,
}

class ClockOffsetUpdate {
  const ClockOffsetUpdate({
    required this.verdict,
    required this.offset,
    required this.deltaNs,
    required this.rejectedProbes,
    required this.totalProbes,
  });

  final ClockOffsetVerdict verdict;

  /// The offset in force AFTER this update (null only before any first fix).
  final ClockOffset? offset;

  /// newOffset - previousOffset, or 0 when there was no previous offset.
  final int deltaNs;

  final int rejectedProbes;
  final int totalProbes;

  /// True when consumers holding converted timestamps must re-anchor.
  bool get requiresReanchor => verdict == ClockOffsetVerdict.suspendJump;

  /// True when the caller must stop and surface the condition to a human.
  bool get requiresHumanAttention =>
      verdict == ClockOffsetVerdict.anomalyBackwards;
}

class ClockOffsetEstimator {
  ClockOffsetEstimator({
    this.maxProbeUncertaintyNs = 200000, // 200 us
    this.suspendJumpThresholdNs = 1000000, // 1 ms
  });

  /// Reject a probe whose mono window is wider than this.
  ///
  /// Provenance: three vDSO clock_gettime reads on arm64 complete in well under
  /// a microsecond. A 200 us window means the thread was descheduled between
  /// the reads, i.e. the probe measures the scheduler, not the clocks. This is
  /// a *reject* threshold, not a precision claim: with best-of-N selection it
  /// only bites when EVERY probe was preempted, and then we defer rather than
  /// adopt a bad value.
  final int maxProbeUncertaintyNs;

  /// A forward jump at least this large is read as "the SoC suspended".
  ///
  /// Provenance: the smallest real suspend is tens of milliseconds; the largest
  /// measurement noise is bounded by [maxProbeUncertaintyNs] (200 us) on both
  /// sides. 1 ms sits between the two by more than 2x on the noise side and
  /// more than 10x on the event side, so no plausible device moves the verdict.
  final int suspendJumpThresholdNs;

  ClockOffset? _current;

  ClockOffset? get current => _current;

  /// Convert a monotonic stamp with the offset currently in force.
  /// Returns null before the first fix — callers must buffer, never guess.
  int? monotonicToBoot(int monoNs) => _current?.monotonicToBoot(monoNs);

  ClockOffsetUpdate ingest(List<ClockProbe> probes) {
    ClockProbe? best;
    var rejected = 0;
    for (final p in probes) {
      if (!p.isWellFormed || p.uncertaintyNs > maxProbeUncertaintyNs) {
        rejected++;
        continue;
      }
      if (best == null || p.uncertaintyNs < best.uncertaintyNs) {
        best = p;
      }
    }

    if (best == null) {
      return ClockOffsetUpdate(
        verdict: ClockOffsetVerdict.noUsableProbe,
        offset: _current,
        deltaNs: 0,
        rejectedProbes: rejected,
        totalProbes: probes.length,
      );
    }

    final candidate = ClockOffset(
      offsetNs: best.offsetNs,
      uncertaintyNs: best.uncertaintyNs,
      measuredAtBootNs: best.bootNs,
    );

    final previous = _current;
    if (previous == null) {
      _current = candidate;
      return ClockOffsetUpdate(
        verdict: ClockOffsetVerdict.firstFix,
        offset: candidate,
        deltaNs: 0,
        rejectedProbes: rejected,
        totalProbes: probes.length,
      );
    }

    final delta = candidate.offsetNs - previous.offsetNs;
    final combinedBound = previous.uncertaintyNs + candidate.uncertaintyNs;

    if (delta < -combinedBound) {
      // Impossible direction. Keep the old offset: adopting it would silently
      // corrupt every future conversion.
      return ClockOffsetUpdate(
        verdict: ClockOffsetVerdict.anomalyBackwards,
        offset: previous,
        deltaNs: delta,
        rejectedProbes: rejected,
        totalProbes: probes.length,
      );
    }

    _current = candidate;
    return ClockOffsetUpdate(
      verdict: delta > suspendJumpThresholdNs
          ? ClockOffsetVerdict.suspendJump
          : ClockOffsetVerdict.stable,
      offset: candidate,
      deltaNs: delta,
      rejectedProbes: rejected,
      totalProbes: probes.length,
    );
  }
}
