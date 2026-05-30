// CustomPainter for the v6 cosine-weighted target-point capture dome.
//
// Renders 118 target points (1,6,11,15,17,18,17,15,11,6,1 per ring)
// around the locked origin. Each point is one [DomeTargetPoint]:
//   • Unvisited: small dark-gray fill + thin white outline. Visible
//                against the AR camera feed without competing for
//                attention.
//   • Visited:   solid white dot, noticeably larger. The "white + big"
//                contrast is the only visit signal — no connecting
//                lines, no wireframe, no chromatic accent. Tried lines
//                between adjacent visited pairs first; cosine-weighted
//                rings have varying point counts so adjacency is
//                naturally irregular (squares / triangles / rhombi
//                mixed) → looked messy. Pure dot signaling is cleaner
//                and still trivially scannable.
//
// Strict design: black / white / gray only — no chromatic accent.
//
// Projection: SceneKit-equivalent perspective from camera at (0,0,2.5)
// with vertical FOV 60° — same numbers as the iOS Aether3D reference.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as v64;

import '../../capture/dome/dome_target_points.dart';

class DomePainter extends CustomPainter {
  /// All target points (visited + unvisited). Painter reads
  /// `point.visited` as the steady state and overlays
  /// [visitFadeProgress] for in-flight transitions.
  final List<DomeTargetPoint> points;

  /// World-frame orientation of the sphere relative to the camera.
  final v64.Quaternion orientation;

  /// Per-point fade progress in [0, 1]. Present ↔ point is currently
  /// transitioning from unvisited (0) → visited (1). Painter falls
  /// back to `point.visited ? 1.0 : 0.0` when the index isn't here.
  final Map<int, double> visitFadeProgress;

  /// Stored for shouldRepaint short-circuit.
  final Listenable? _repaintTrigger;

  DomePainter({
    required this.points,
    required this.orientation,
    this.visitFadeProgress = const <int, double>{},
    super.repaint,
  }) : _repaintTrigger = repaint;

  // Verbatim of iOS DomeView.swift — keep on-screen dome size
  // identical to the iOS reference 1:1.
  static const double _camZ = 2.5;
  static const double _tanHalfFov = 0.5773502691896257; // tan(30°)

  // Steady-state grayscale colors. Dark gray for unvisited (visible
  // against any AR feed without overpowering it); pure white for
  // visited (maximum contrast — "lit up").
  static const int _grayUnvisitedFill = 42; // ≈ #2A2A2A
  static const int _grayVisitedFill = 255;  // pure white
  static const double _alphaUnvisitedFill = 0.55;
  static const double _alphaVisitedFill = 1.0;
  static const double _alphaUnvisitedStroke = 0.35;
  static const double _radiusUnvisited = 2.0;
  // Visited dot is 2× the unvisited radius — the size jump is the
  // primary visit signal now that connecting lines are gone.
  static const double _radiusVisited = 4.0;

  // Front/back hemisphere alpha range. Front=1.0, back baseline=0.4.
  static const double _alphaBack = 0.4;

  @override
  void paint(Canvas canvas, Size size) {
    final frameHalf = math.min(size.width, size.height) / 2;
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Project every point through the current orientation.
    final projected = List<_ProjectedPoint>.generate(points.length, (i) {
      final p = points[i];
      final rotated = orientation.rotated(p.unitXyz);
      final invDist = 1.0 / (_camZ - rotated.z);
      final ndcX = rotated.x * invDist / _tanHalfFov;
      final ndcY = rotated.y * invDist / _tanHalfFov;
      final fade = visitFadeProgress[p.index] ?? (p.visited ? 1.0 : 0.0);
      return _ProjectedPoint(
        pos: Offset(cx + ndcX * frameHalf, cy - ndcY * frameHalf),
        depthZ: rotated.z,
        fade: fade,
      );
    }, growable: false);

    // Sort point indices back-to-front for alpha layering.
    final sortIndices = List.generate(points.length, (i) => i);
    sortIndices.sort(
        (a, b) => projected[a].depthZ.compareTo(projected[b].depthZ));

    // Draw dots.
    final dotFill = Paint()..style = PaintingStyle.fill;
    final dotStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    for (final i in sortIndices) {
      final pp = projected[i];

      // Front/back smoothstep: depthZ in [-1, 1] → visibility in [0, 1].
      final t = ((pp.depthZ + 1.0) / 2.0).clamp(0.0, 1.0);
      final visibility = t * t * (3.0 - 2.0 * t);
      final visMult = _alphaBack + (1.0 - _alphaBack) * visibility;

      final f = pp.fade;
      final gray = _lerpInt(_grayUnvisitedFill, _grayVisitedFill, f);
      final fillAlpha = _lerpDouble(_alphaUnvisitedFill, _alphaVisitedFill, f);
      // Outline visible on unvisited / fading; vanishes once fully lit.
      final strokeAlpha = _lerpDouble(_alphaUnvisitedStroke, 0.0, f);
      final r = _lerpDouble(_radiusUnvisited, _radiusVisited, f);

      // Fill.
      dotFill.color = Color.fromARGB(
        (fillAlpha * visMult * 255).clamp(0, 255).round(),
        gray,
        gray,
        gray,
      );
      canvas.drawCircle(pp.pos, r, dotFill);

      // Outline (only while visible).
      if (strokeAlpha > 0.02) {
        dotStroke.color = Colors.white.withValues(
          alpha: (strokeAlpha * visMult).clamp(0.0, 1.0),
        );
        canvas.drawCircle(pp.pos, r + 0.4, dotStroke);
      }
    }
  }

  static int _lerpInt(int a, int b, double t) =>
      (a + (b - a) * t).round();

  static double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(covariant DomePainter old) {
    if (_repaintTrigger != null) return false;
    if (old.orientation != orientation) return true;
    if (old.points.length != points.length) return true;
    if (old.visitFadeProgress.length != visitFadeProgress.length) return true;
    return false;
  }
}

class _ProjectedPoint {
  final Offset pos;
  final double depthZ;
  final double fade;

  const _ProjectedPoint({
    required this.pos,
    required this.depthZ,
    required this.fade,
  });
}
