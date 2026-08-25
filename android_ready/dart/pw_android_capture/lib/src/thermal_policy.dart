// PocketWorld Android capture — thermal governor.
//
// PROBLEM
//   Thermal stability is a hard product constraint. Android exposes two signals:
//
//     PowerManager.getCurrentThermalStatus()            (API 29)
//       -> THERMAL_STATUS_NONE(0) .. THERMAL_STATUS_SHUTDOWN(6). Coarse, and it
//          only changes AFTER throttling has begun.
//     PowerManager.getThermalHeadroom(int forecastSeconds)   (API 30)
//       -> float. 0.0 = cold, 1.0 = the onset of THERMAL_STATUS_SEVERE.
//          Continuous and forecastable, so it is the signal we steer on.
//
//   Three documented hazards, all verified against Google's own text:
//     (a) "Don't call the GetThermalHeadroom() API too frequently. If you do so,
//         the API returns NaN. You shouldn't call it more than once every 10
//         seconds."  (ADPF thermal guide)
//         The android.os.PowerManager reference states the weaker bound
//         ("significantly faster than once per second"). We obey the STRICTER
//         of the two, because violating it costs us the signal entirely.
//     (b) "If the initial value of GetThermalHeadroom() is NaN, the API is not
//         available on the device."  -> permanent unsupported, fall back to
//         status-only steering. Never treat NaN as 0.0.
//     (c) "Avoid calling from multiple threads" -> a single owner enforces the
//         interval. This class IS that owner; it is the thing that says when.
//
// FAIL-SAFE CONTRACT
//   The only actions this governor can emit are `proceed`, `shed` and `defer`.
//   There is deliberately NO action that drops a frame or lowers capture
//   quality: fail-safe may postpone work, never discard it, and the product has
//   no user-visible quality tier to fall back to. `defer` means the caller
//   applies backpressure upstream (stop admitting NEW work) while every sample
//   already accepted is still delivered.

/// PowerManager.THERMAL_STATUS_* — values are the platform's, 0..6.
class ThermalStatus {
  static const int none = 0;
  static const int light = 1;
  static const int moderate = 2;
  static const int severe = 3;
  static const int critical = 4;
  static const int emergency = 5;
  static const int shutdown = 6;
}

enum ThermalAction {
  /// Full-rate capture.
  proceed,

  /// Shed non-essential work (preview densification, thumbnailing, uploads).
  /// The capture stream itself is untouched.
  shed,

  /// Apply backpressure: admit no NEW work. Nothing already admitted is
  /// dropped — this is a postponement, not a loss.
  defer,
}

enum HeadroomState {
  /// No headroom sample has been accepted yet.
  unknown,

  /// getThermalHeadroom returned NaN on the very first call: per Google's
  /// guide the API is not implemented on this device. Permanent.
  unsupported,

  /// A real value is in force.
  live,

  /// We had a real value and then got NaN. The last good value stays in force
  /// and we keep polling; we never substitute a fabricated number.
  stale,
}

class ThermalSample {
  const ThermalSample({
    required this.atMs,
    required this.headroom,
    required this.status,
  });

  /// SystemClock.elapsedRealtime() in ms.
  final int atMs;

  /// getThermalHeadroom(forecastSeconds) result. May be double.nan.
  final double headroom;

  /// getCurrentThermalStatus() result, 0..6.
  final int status;
}

class ThermalVerdict {
  const ThermalVerdict({
    required this.action,
    required this.headroomState,
    required this.effectiveHeadroom,
    required this.status,
    required this.reason,
  });

  final ThermalAction action;
  final HeadroomState headroomState;

  /// The headroom actually used for the decision: the last accepted real
  /// sample. Null when we have never had one.
  final double? effectiveHeadroom;

  final int status;

  /// Machine-readable cause, for the capture log.
  final String reason;

  @override
  String toString() => 'ThermalVerdict(${action.name}, ${headroomState.name}, '
      'h=${effectiveHeadroom?.toStringAsFixed(3) ?? "-"}, s=$status, $reason)';
}

class ThermalPolicy {
  ThermalPolicy({
    this.minPollIntervalMs = 10000,
    this.enterShedHeadroom = 0.85,
    this.exitShedHeadroom = 0.75,
    this.enterDeferHeadroom = 0.95,
    this.exitDeferHeadroom = 0.85,
    this.deferStatus = ThermalStatus.severe,
    this.shedStatus = ThermalStatus.moderate,
  })  : assert(minPollIntervalMs >= 10000,
            'Google: do not call getThermalHeadroom more than once per 10 s'),
        assert(exitShedHeadroom < enterShedHeadroom),
        assert(exitDeferHeadroom < enterDeferHeadroom),
        assert(enterShedHeadroom < enterDeferHeadroom);

  /// Minimum spacing between getThermalHeadroom calls.
  ///
  /// Provenance: verbatim from Google's ADPF thermal guide — "You shouldn't
  /// call it more than once every 10 seconds." Not a tuned number; it is the
  /// documented precondition for the API returning a number at all. The assert
  /// makes it impossible to configure a violating value.
  final int minPollIntervalMs;

  /// Headroom band edges.
  ///
  /// Provenance: 1.0 is defined by the platform as the onset of
  /// THERMAL_STATUS_SEVERE, so it is a real physical landmark, not a guess.
  /// We must act BEFORE it, and we sample only every 10 s, so we need margin
  /// for one whole sampling interval of unobserved rise. 0.85 leaves 15% of
  /// the band; 0.95 is the last-resort brake.
  ///
  /// The exit edges sit a full 0.10 below the entry edges. That gap is the
  /// load-bearing part: with a 10 s sample interval, a governor without
  /// hysteresis flaps between shedding and resuming every sample when headroom
  /// sits on the edge, which is itself a thermal load. The
  /// `thermal_policy_test` "does not flap" case pins this.
  final double enterShedHeadroom;
  final double exitShedHeadroom;
  final double enterDeferHeadroom;
  final double exitDeferHeadroom;

  /// Status floors, used on their own when headroom is unsupported.
  final int deferStatus;
  final int shedStatus;

  int? _lastPollMs;
  double? _lastGoodHeadroom;
  HeadroomState _state = HeadroomState.unknown;
  ThermalAction _action = ThermalAction.proceed;
  bool _everSampled = false;

  HeadroomState get headroomState => _state;
  ThermalAction get action => _action;
  double? get lastGoodHeadroom => _lastGoodHeadroom;
  int? get lastPollMs => _lastPollMs;

  /// True when enough time has passed to call getThermalHeadroom again.
  /// The caller MUST gate on this; calling early is what produces NaN.
  bool shouldPoll(int nowMs) {
    if (_state == HeadroomState.unsupported) return false;
    final last = _lastPollMs;
    return last == null || (nowMs - last) >= minPollIntervalMs;
  }

  /// Milliseconds until the next legal poll (0 when it is legal now).
  int msUntilNextPoll(int nowMs) {
    final last = _lastPollMs;
    if (last == null) return 0;
    final due = last + minPollIntervalMs - nowMs;
    return due > 0 ? due : 0;
  }

  ThermalVerdict ingest(ThermalSample s) {
    _lastPollMs = s.atMs;

    final isNaN = s.headroom.isNaN;
    if (isNaN) {
      if (!_everSampled) {
        // First ever call returned NaN -> the device has no thermal HAL for
        // this API. Permanent; stop polling and steer on status alone.
        _state = HeadroomState.unsupported;
      } else if (_state == HeadroomState.live) {
        _state = HeadroomState.stale;
      }
    } else {
      _lastGoodHeadroom = s.headroom;
      _state = HeadroomState.live;
    }
    _everSampled = true;

    // Status is the hard floor: it is reported by the platform after throttling
    // has already started, so it can only raise severity, never lower it.
    ThermalAction statusFloor;
    if (s.status >= deferStatus) {
      statusFloor = ThermalAction.defer;
    } else if (s.status >= shedStatus) {
      statusFloor = ThermalAction.shed;
    } else {
      statusFloor = ThermalAction.proceed;
    }

    final h = _lastGoodHeadroom;
    ThermalAction headroomAction;
    String reason;
    if (h == null) {
      headroomAction = ThermalAction.proceed;
      reason = _state == HeadroomState.unsupported
          ? 'headroom-unsupported:status-only'
          : 'headroom-unknown:status-only';
    } else {
      headroomAction = _withHysteresis(h);
      reason = _state == HeadroomState.stale
          ? 'headroom-stale-hold'
          : 'headroom-band';
    }

    final merged = _moreSevere(headroomAction, statusFloor);
    if (merged != headroomAction) {
      reason = 'status-floor';
    }
    _action = merged;

    return ThermalVerdict(
      action: merged,
      headroomState: _state,
      effectiveHeadroom: h,
      status: s.status,
      reason: reason,
    );
  }

  ThermalAction _withHysteresis(double h) {
    switch (_action) {
      case ThermalAction.proceed:
        if (h >= enterDeferHeadroom) return ThermalAction.defer;
        if (h >= enterShedHeadroom) return ThermalAction.shed;
        return ThermalAction.proceed;
      case ThermalAction.shed:
        if (h >= enterDeferHeadroom) return ThermalAction.defer;
        if (h <= exitShedHeadroom) return ThermalAction.proceed;
        return ThermalAction.shed;
      case ThermalAction.defer:
        if (h <= exitShedHeadroom) return ThermalAction.proceed;
        if (h <= exitDeferHeadroom) return ThermalAction.shed;
        return ThermalAction.defer;
    }
  }

  static ThermalAction _moreSevere(ThermalAction a, ThermalAction b) =>
      a.index >= b.index ? a : b;
}
