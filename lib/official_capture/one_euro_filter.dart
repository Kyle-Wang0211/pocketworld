// One-Euro filter — display-layer smoothing for the streaming SfM point cloud.
//
// [AR-SMOOTH 2026-08-05] Cross-platform display smoothing core. Pure Dart, no
// platform AR SDK dependency: it operates only on positions + a timestamp, so
// the same implementation runs on iOS / Android / HarmonyOS (the cross-platform
// anchor verdict rejected native ARAnchor because Huawei has no ARCore — see
// project_pocketworld_ar_display_stability_verdict).
//
// WHY (research-grounded): the every-frame previewTracked display shows real
// local-BA points that the backend keeps nudging (per-frame local BA, periodic
// global BA). Drawing each new algo position directly makes those nudges — and
// especially a global-BA checkpoint — read as jitter/snap. The One-Euro filter
// (Casiez, Roussel, Vogel, CHI 2012) is the interaction-systems standard for
// exactly this: a low-pass whose cutoff ADAPTS to speed, so it suppresses
// jitter when a point is at rest (low speed → low cutoff → heavy smoothing) yet
// tracks fast motion with low lag (high speed → high cutoff → light smoothing).
//
// ⚠️ This HIDES high-frequency jitter; it does NOT fix geometric error. A ghost
// point sits smoothly at the wrong place. Ghosts stay a stage/matching-layer
// problem (project_pocketworld_ghost_layer_final_verdict). This layer is only
// for the visible-stability half of the "zero visible jitter" goal.
//
// Reference: https://direction.bordeaux.inria.fr/~roussel/publications/2012-CHI-one-euro-filter.pdf

import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as vm;

/// Exponential low-pass with a per-step smoothing factor `alpha`.
///
/// `alpha` is derived from the cutoff frequency and the timestep so the amount
/// of smoothing is frame-rate independent (a burst of frames does not
/// over-smooth). `alpha == 1` passes the input through unchanged; smaller
/// `alpha` smooths harder.
class _LowPass {
  double? _prev;
  double get value => _prev ?? 0.0;
  bool get hasValue => _prev != null;

  double filter(double x, double alpha) {
    final prev = _prev;
    final y = prev == null ? x : alpha * x + (1.0 - alpha) * prev;
    _prev = y;
    return y;
  }

  void reset() => _prev = null;
}

/// Scalar One-Euro filter.
///
/// Tunables (device A/B decides the final values — do not treat defaults as
/// validated):
///  - [minCutoff] Hz: cutoff at zero speed. Lower ⇒ steadier at rest but more
///    lag when motion starts. The dominant knob for "how still does a resting
///    point look".
///  - [beta]: speed coefficient. Higher ⇒ less lag during fast motion (cutoff
///    rises with speed). The dominant knob for "does it keep up when the cloud
///    grows/shifts fast".
///  - [dCutoff] Hz: cutoff of the internal speed estimate. 1.0 is the paper's
///    default and rarely needs changing.
class OneEuroFilter {
  OneEuroFilter({
    this.minCutoff = 1.0,
    this.beta = 0.0,
    this.dCutoff = 1.0,
  })  : assert(minCutoff > 0, 'minCutoff must be > 0'),
        assert(dCutoff > 0, 'dCutoff must be > 0'),
        assert(beta >= 0, 'beta must be >= 0');

  final double minCutoff;
  final double beta;
  final double dCutoff;

  final _LowPass _x = _LowPass();
  final _LowPass _dx = _LowPass();
  double? _lastRaw;

  static double _alpha(double cutoff, double dt) {
    final tau = 1.0 / (2.0 * math.pi * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }

  /// Feed a new raw value observed [dt] seconds after the previous one.
  /// [dt] must be > 0; a non-positive dt returns the raw value unfiltered
  /// (fail-open — a bad clock must never freeze or NaN the display).
  double filter(double x, double dt) {
    if (!(dt > 0) || !x.isFinite) {
      _lastRaw = x.isFinite ? x : _lastRaw;
      return _x.hasValue ? _x.value : x;
    }
    final prevRaw = _lastRaw;
    _lastRaw = x;
    final rawDeriv = prevRaw == null ? 0.0 : (x - prevRaw) / dt;
    final edx = _dx.filter(rawDeriv, _alpha(dCutoff, dt));
    final cutoff = minCutoff + beta * edx.abs();
    return _x.filter(x, _alpha(cutoff, dt));
  }

  void reset() {
    _x.reset();
    _dx.reset();
    _lastRaw = null;
  }
}

/// Vector3 One-Euro filter: three independent scalar filters sharing one
/// timestep. Independent-per-axis matches the reference implementations and is
/// correct here because display jitter has no cross-axis coupling worth modeling.
class OneEuroFilter3 {
  OneEuroFilter3({
    double minCutoff = 1.0,
    double beta = 0.0,
    double dCutoff = 1.0,
  })  : _x = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff),
        _y = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff),
        _z = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff);

  final OneEuroFilter _x;
  final OneEuroFilter _y;
  final OneEuroFilter _z;

  vm.Vector3 filter(vm.Vector3 v, double dt) => vm.Vector3(
        _x.filter(v.x, dt),
        _y.filter(v.y, dt),
        _z.filter(v.z, dt),
      );

  void reset() {
    _x.reset();
    _y.reset();
    _z.reset();
  }
}
