// DomeView — the floating capture-guidance sphere.
//
// v3 paradigm: target-point coverage. The user-visible signal is N
// discrete points on a Fibonacci sphere; each flips white → dark gray
// when the user's view direction lands within `visitAngleThresholdDeg`
// of it AND the upstream `GuidanceEngine` has just accepted the frame
// (verbatim port of iOS Aether3D's multi-dim audit). The legacy
// 60-cell graded state machine still runs inside `DomeCoverageMap`,
// but it no longer drives this widget — it's now the upload curator's
// data source only.
//
// What this widget does:
//   - Smoothly rotate the dome to follow the AR pose's azimuth /
//     elevation (yaw + pitch lerp on a Ticker, α=0.2 default).
//   - Subscribe to `targetPoints.pointVisitedStream` and start a 300 ms
//     fade animation per newly-visited point.
//   - Repaint via Listenable (no widget rebuild on Ticker tick).
//   - Snap-on-lock: when `snapKey` flips, jump straight to the new
//     orientation instead of lerping (prevents the "球漂移就位" bug).
//   - Tracking-frozen: when `trackingFrozen` is true, freeze the dome
//     orientation at its last value (no pose updates) but keep the dots
//     at full contrast. Tried 0.4 alpha first; on devices under thermal
//     pressure ARKit can drop tracking for 1-2 s right after lockOrigin
//     (visual SLAM resource constraints), and the dimming made that
//     moment read as "灰色卡死" to the user. The frozen pose itself is
//     enough signal that the orientation isn't responding; dimming the
//     visited dots on top of that hides the user's progress and feels
//     worse than just "球停了一下".
//
//     With CaptureSession's hybrid IMU↔ARKit resolver in place
//     (`_resolveHybridPose`), `trackingFrozen` is now expected to fire
//     only during the very brief post-lock window where ARKit hasn't
//     yet been .normal once (so we have no IMU offset anchor); from the
//     first ARKit-normal frame onward, ARKit limited episodes fall back
//     to IMU dead-reckoning and the upstream `pose.isTracking` stays
//     true. So the freeze + glide-back ramp below is mostly defensive
//     against degenerate sensor failure, not the routine path.
//
// What it explicitly does NOT do:
//   - HUD text label (no "X 帧 · Y 深绿" — pure visual feedback).
//   - Wireframe / equator / grid lines (no rings, see user feedback).
//   - Active arrow guidance (let the user move freely).
//   - Multi-pass orbit prompts (this is a 2C product; let users explore).
//   - Cell color grading (gone with the cell state machine).
//
// Sign-flip vs iOS rotation:
//   `vector_math_64.Quaternion.rotate(v)` does `conjugate(q) * v * q`
//   (see pub.dev/vector_math/quaternion.dart:344), the OPPOSITE of
//   iOS's standard `q * v * conjugate(q)`. To match iOS's
//   `simdOrientation = pitchQ * yawQ` (yaw first, then pitch) we use
//   the inverse: `yawQ_negated * pitchQ_negated`. See
//   `_updateOrientationFromSmooth` for the full derivation.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:vector_math/vector_math_64.dart' as v64;

import '../../official_capture/dome/dome_config.dart';
import '../../official_capture/telemetry_writer.dart';
import '../../official_capture/dome/dome_target_points.dart';
import 'dome_painter.dart';

class DomeView extends StatefulWidget {
  final DomeTargetPoints targetPoints;
  final double targetYaw;
  final double targetPitch;
  final bool trackingFrozen;

  /// Optional tap handler — Aether3D taps the dome to finish recording.
  final VoidCallback? onTap;

  /// Animation / smoothing config. See [DomeAnimationConfig].
  final DomeAnimationConfig animation;

  /// Useful for re-snapping when the user re-locks origin or restarts.
  final Object? snapKey;

  const DomeView({
    super.key,
    required this.targetPoints,
    required this.targetYaw,
    required this.targetPitch,
    this.trackingFrozen = false,
    this.onTap,
    this.animation = const DomeAnimationConfig(),
    this.snapKey,
  });

  @override
  State<DomeView> createState() => _DomeViewState();
}

class _DomeViewState extends State<DomeView>
    with SingleTickerProviderStateMixin {
  // ── Painter-facing state. References handed to DomePainter once;
  // we mutate them in place each tick / visit so the painter sees
  // current state without any constructor churn.
  final v64.Quaternion _orientation = v64.Quaternion.identity();
  final Map<int, double> _currentVisitFades = <int, double>{};
  final _DomeRepaintNotifier _repaintNotifier = _DomeRepaintNotifier();

  // ── Smoothing — drives `_orientation`.
  double _smoothYaw = 0;
  double _smoothPitch = 0;
  bool _hasSnappedInitial = false;

  late final Ticker _ticker;

  // ── Diagnostic counters. Window-summary every 5 s plus per-event
  // transitions for snap / trackingFrozen / new visits, so we can
  // verify the system from `flutter run --release` console output.
  static const bool _kDiagLog = true;
  final Stopwatch _diagClock = Stopwatch()..start();
  int _diagNotifies = 0;
  int _diagSnaps = 0;
  int _diagFrozenToggles = 0;
  int _diagPointsVisited = 0;

  // ── Visit fade animations. New visit → entry added; Ticker advances
  // each tick; entry removed once duration elapses (point's
  // `visited=true` keeps it permanently rendered as visited from then
  // on).
  final Map<int, DateTime> _visitFadeStarts = <int, DateTime>{};

  // ── Frozen→unfrozen ramp. When trackingFrozen flips false the
  // accumulated yaw/pitch delta (the camera-frame change while we
  // weren't applying it) is in general non-zero, so applying the
  // current default `smoothingAlpha=1.0` would produce a visible jump.
  // Instead, on the unfreeze edge we record the timestamp + frozen
  // duration. While the unfreeze window is active, _onTick uses a
  // ramped alpha that starts at 0.15 and lerps back up to the configured
  // smoothingAlpha over min(frozen-duration, 500 ms). This gives short
  // limited(initializing) blips ~100 ms a barely-visible glide and
  // longer drops a smoother but still bounded catch-up.
  DateTime? _frozenSince;
  DateTime? _unfreezeStart;
  Duration _unfreezeRampLen = Duration.zero;
  static const Duration _maxUnfreezeRamp = Duration(milliseconds: 500);
  static const double _unfreezeAlphaFloor = 0.15;

  // Cached axis vectors so axisAngle doesn't re-allocate every tick.
  static final v64.Vector3 _yAxis = v64.Vector3(0, 1, 0);
  static final v64.Vector3 _xAxis = v64.Vector3(1, 0, 0);

  StreamSubscription<int>? _pointVisitedSub;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _pointVisitedSub = widget.targetPoints.pointVisitedStream.listen(
      _handlePointVisited,
    );
  }

  @override
  void didUpdateWidget(DomeView old) {
    super.didUpdateWidget(old);
    if (widget.snapKey != old.snapKey) {
      _hasSnappedInitial = false;
      if (_kDiagLog) {
        // ignore: avoid_print
        print(
          '[DomeView] snapKey ${old.snapKey} → ${widget.snapKey}, '
          'will re-snap on next tick',
        );
      }
    }
    if (old.trackingFrozen != widget.trackingFrozen) {
      _diagFrozenToggles++;
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[DomeView] trackingFrozen → ${widget.trackingFrozen}');
      }
      final now = DateTime.now();
      if (widget.trackingFrozen) {
        // Entering frozen — record start so we can size the unfreeze ramp.
        _frozenSince = now;
      } else {
        // Leaving frozen — the longer we were stuck, the bigger the
        // delta we need to absorb without a hard jump. Cap at 500 ms so
        // a multi-second drop doesn't leave the dome lazily catching up
        // for that whole time.
        final frozenFor = _frozenSince == null
            ? Duration.zero
            : now.difference(_frozenSince!);
        _unfreezeRampLen = frozenFor > _maxUnfreezeRamp
            ? _maxUnfreezeRamp
            : frozenFor;
        _unfreezeStart = _unfreezeRampLen.inMilliseconds > 16 ? now : null;
        _frozenSince = null;
      }
    }
    if (widget.targetPoints != old.targetPoints) {
      _pointVisitedSub?.cancel();
      _pointVisitedSub = widget.targetPoints.pointVisitedStream.listen(
        _handlePointVisited,
      );
      _visitFadeStarts.clear();
      _currentVisitFades.clear();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pointVisitedSub?.cancel();
    _repaintNotifier.dispose();
    super.dispose();
  }

  // ─── Per-frame tick: smooth orientation + advance visit fades ───────

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    if (widget.trackingFrozen) return;

    final ty = widget.targetYaw;
    final tp = widget.targetPitch;
    bool changed = false;

    if (!_hasSnappedInitial) {
      _smoothYaw = ty;
      _smoothPitch = tp;
      _hasSnappedInitial = true;
      changed = true;
      _diagSnaps++;
      if (_kDiagLog) {
        // ignore: avoid_print
        print(
          '[DomeView] snap → '
          '(yaw=${ty.toStringAsFixed(3)}, pitch=${tp.toStringAsFixed(3)})',
        );
      }
    } else {
      final baseAlpha = widget.animation.smoothingAlpha;
      // If we just left a frozen window, ramp from a low alpha back up
      // to baseAlpha over `_unfreezeRampLen`. This keeps the user from
      // seeing a visible jump when ARKit briefly drops to .limited and
      // recovers — the dome glides into place instead of teleporting.
      double alpha = baseAlpha;
      if (_unfreezeStart != null) {
        final since = DateTime.now().difference(_unfreezeStart!);
        if (since >= _unfreezeRampLen) {
          _unfreezeStart = null;
          _unfreezeRampLen = Duration.zero;
        } else {
          final t =
              since.inMilliseconds /
              _unfreezeRampLen.inMilliseconds.clamp(1, 1 << 30);
          alpha = _unfreezeAlphaFloor + (baseAlpha - _unfreezeAlphaFloor) * t;
        }
      }
      final epsilon = widget.animation.smoothEpsilon;
      final newYaw = _lerpAngle(_smoothYaw, ty, alpha);
      final newPitch = _lerp(_smoothPitch, tp, alpha);
      if ((newYaw - _smoothYaw).abs() > epsilon ||
          (newPitch - _smoothPitch).abs() > epsilon) {
        _smoothYaw = newYaw;
        _smoothPitch = newPitch;
        changed = true;
      }
    }

    if (changed) {
      _updateOrientationFromSmooth();
    }

    // Visit fade transitions — once they're all done, drops back to the
    // converged-no-paint path above.
    if (_advanceFades()) {
      changed = true;
    }

    if (changed) {
      _repaintNotifier.notify();
      _diagNotifies++;
    }

    // 5-second window summary. `0 notify` while the user holds the
    // phone still + no in-flight fades is the headline "we stopped
    // burning frames" signal.
    if (_kDiagLog && _diagClock.elapsedMilliseconds >= 5000) {
      final secs = _diagClock.elapsedMilliseconds / 1000;
      final hz = _diagNotifies / secs;
      // ignore: avoid_print
      print(
        '[DomeView] 5s window: $_diagNotifies notify '
        '(${hz.toStringAsFixed(1)} Hz), '
        '$_diagSnaps snap, $_diagFrozenToggles frozenToggle, '
        '$_diagPointsVisited visited',
      );
      _diagNotifies = 0;
      _diagSnaps = 0;
      _diagFrozenToggles = 0;
      _diagPointsVisited = 0;
      _diagClock.reset();
      _diagClock.start();
    }
  }

  void _updateOrientationFromSmooth() {
    // See class header for the vector_math vs iOS rotation-convention
    // math (negate angles AND reverse multiplication order).
    final yawQ = v64.Quaternion.axisAngle(_yAxis, -_smoothYaw);
    final pitchQ = v64.Quaternion.axisAngle(_xAxis, -_smoothPitch);
    final result = yawQ * pitchQ;
    _orientation.setValues(result.x, result.y, result.z, result.w);
  }

  /// Returns `true` if any fade is in progress (caller must trigger a
  /// repaint). When the fade-starts map is empty we fall back to the
  /// "no paint when stationary" optimization.
  bool _advanceFades() {
    if (_visitFadeStarts.isEmpty) {
      if (_currentVisitFades.isEmpty) return false;
      _currentVisitFades.clear();
      return true;
    }
    final fadeDuration = widget.targetPoints.config.visitFadeDuration;
    final now = DateTime.now();
    final finished = <int>[];
    _visitFadeStarts.forEach((key, start) {
      final dt = now.difference(start);
      if (dt < Duration.zero) return;
      if (dt < fadeDuration) {
        _currentVisitFades[key] =
            dt.inMicroseconds / fadeDuration.inMicroseconds;
      } else {
        // Fade complete — point is permanently visited; drop the entry
        // so the "currentFades empty → no repaint" check kicks in
        // again. Painter will read `point.visited` as the steady state.
        finished.add(key);
      }
    });
    for (final k in finished) {
      _visitFadeStarts.remove(k);
      _currentVisitFades.remove(k);
    }
    return true;
  }

  void _handlePointVisited(int idx) {
    if (!mounted) return;
    _diagPointsVisited++;
    _visitFadeStarts[idx] = DateTime.now();
    // Light tactile tick per visit. `selectionClick` is the lightest
    // iOS haptic; iOS's haptic engine self-throttles when called in
    // rapid succession, so multi-visit bursts don't cause buzz.
    //
    // That throttling claim covers repeated calls on THIS generator. It says
    // nothing about this tick landing on top of the shutter's own haptic,
    // which is a different channel entirely: the shutter fires
    // UIImpactFeedbackGenerator(.heavy) natively, inside the SceneKit render
    // callback for the black card's first frame. The two are independent, so
    // nothing stops them coinciding — a user reported feeling two buzzes
    // almost simultaneously on 2026-08-31 during a session whose shutter
    // haptics were 1473 ms apart at their closest, which the shutter timeline
    // alone cannot explain.
    //
    // Observation only: this event exists so the interval between a dome tick
    // and a shutter haptic can be MEASURED rather than inferred. Correlate
    // against photo_feedback_presented, which is the moment the shutter
    // haptic fires. Nothing here changes when or whether the tick plays.
    TelemetryWriter.instance.event('dome_haptic_tick', {
      'point_index': idx,
      'visited_in_window': _diagPointsVisited,
    });
    HapticFeedback.selectionClick();
  }

  // ─── Helpers ────────────────────────────────────────────────────────

  static double _lerp(double a, double b, double alpha) => a + (b - a) * alpha;

  /// Lerps an angle (radians) along the SHORT path so spinning past ±π
  /// doesn't cause the sphere to whip the long way around.
  static double _lerpAngle(double a, double b, double alpha) {
    var d = (b - a) % (2 * math.pi);
    if (d > math.pi) d -= 2 * math.pi;
    if (d < -math.pi) d += 2 * math.pi;
    return a + d * alpha;
  }

  @override
  Widget build(BuildContext context) {
    // This `build` only runs when the widget tree above us has changed
    // (trackingFrozen, snapKey, smoothingAlpha, …) — not on every
    // Ticker tick. The painter holds references to the same mutable
    // `_orientation`, `_currentVisitFades`, and the points list for
    // the lifetime of this State, and `_repaintNotifier` is what
    // causes CustomPaint to actually call `paint()` again.
    // No Opacity wrapper: trackingFrozen freezes the orientation
    // (`_onTick` early-returns when frozen) but the dots stay at full
    // contrast. See class header for why we removed the 0.4 alpha.
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox.expand(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: DomePainter(
              points: widget.targetPoints.points,
              orientation: _orientation,
              visitFadeProgress: _currentVisitFades,
              repaint: _repaintNotifier,
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiny ChangeNotifier exposed so the State can call `notify()`
/// directly. Used as DomePainter's `repaint:` Listenable — bumping it
/// triggers a repaint without going through `setState` / widget
/// rebuild.
class _DomeRepaintNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
