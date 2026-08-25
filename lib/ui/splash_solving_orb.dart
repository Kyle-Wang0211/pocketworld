// Realtime solving orb for the PocketWorld Flutter splash overlay.
//
// Source-derived from flutter_thinking_orbs 0.1.0, solving/rubik mode only:
// https://github.com/iamEtornam/thinking-orbs
// Revision: 24115f7fe39da85a85b1eeb638dcfc7becaa7022
//
// MIT License
//
// Copyright (c) 2026 Bright Sunu
//
// This is a Flutter port of "thinking-orbs"
// (https://github.com/Jakubantalik/thinking-orbs) by Jakub Antalik, used
// under the MIT License. The orb animation algorithms and tunings originate
// from that project.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const int _latRings = 9;
const int _lonDensity = 24;
const int _moveCount = 14;
const double _bakedSpeed = 1.82;
const double _rBase = 0.63;
const double _rDepth = 1.785;
const double _rActive = 0.315;
const double _inkFar = 0.62;
const double _inkSpan = 0.54;
const double _radiusPower = 0.6;
const double _minimumRadius = 0.3;

/// A realtime, monochrome solving particle orb for the startup overlay.
class SplashSolvingOrb extends StatefulWidget {
  const SplashSolvingOrb({
    super.key,
    this.size = 128,
    this.speed = 0.8,
    this.color = Colors.white,
    this.animate = true,
  }) : assert(size > 0),
       assert(speed > 0);

  /// Representative upstream frame used when reduced motion is requested.
  static const double reducedMotionTime = 0.6;

  final double size;
  final double speed;
  final Color color;
  final bool animate;

  @override
  State<SplashSolvingOrb> createState() => _SplashSolvingOrbState();
}

class _SplashSolvingOrbState extends State<SplashSolvingOrb>
    with SingleTickerProviderStateMixin {
  late final Stopwatch _elapsed;
  late final ValueNotifier<double> _time;
  late final Ticker _ticker;
  bool _reducedMotion = false;
  bool _tickerModeEnabled = true;

  @override
  void initState() {
    super.initState();
    _elapsed = Stopwatch();
    _time = ValueNotifier<double>(0);
    _ticker = createTicker(_onTick);
  }

  void _onTick(Duration _) {
    _time.value = _elapsed.elapsedMicroseconds / Duration.microsecondsPerSecond;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant SplashSolvingOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    final shouldAnimate =
        widget.animate && !_reducedMotion && _tickerModeEnabled;
    if (shouldAnimate) {
      if (!_elapsed.isRunning) _elapsed.start();
      if (!_ticker.isActive) _ticker.start();
      return;
    }
    if (_ticker.isActive) _ticker.stop();
    if (_elapsed.isRunning) _elapsed.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Solving',
      image: true,
      container: true,
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: SplashSolvingOrbPainter(
            time: _time,
            speed: widget.speed,
            color: widget.color,
            frozenTime: _reducedMotion
                ? SplashSolvingOrb.reducedMotionTime
                : null,
          ),
          size: Size.square(widget.size),
        ),
      ),
    );
  }
}

/// One projected, depth-shaded particle in a solving-orb frame.
@immutable
class SplashSolvingParticle {
  const SplashSolvingParticle({
    required this.x,
    required this.y,
    required this.depth,
    required this.radius,
    required this.opacity,
    required this.lineT,
  });

  final double x;
  final double y;
  final double depth;
  final double radius;
  final double opacity;
  final double lineT;
}

class _Move {
  const _Move(this.axis, this.lowerBound, this.upperBound, this.angle);

  final int axis;
  final double lowerBound;
  final double upperBound;
  final double angle;
}

class _SolveCycle {
  const _SolveCycle(this.amounts, this.active);

  final List<double> amounts;
  final int active;
}

final List<_Move> _moves = List<_Move>.generate(_moveCount, (index) {
  final axis = math.min(2, (_hash(index.toDouble(), 2.3) * 3).floor());
  final lowerBound =
      -1.0 + 0.5 * math.min(3, (_hash(index.toDouble(), 5.9) * 4).floor());
  final direction = _hash(index.toDouble(), 7.7) < 0.5 ? 1 : -1;
  return _Move(axis, lowerBound, lowerBound + 0.5, direction * math.pi / 2);
}, growable: false);

double _hash(double a, double b) {
  final value = math.sin(a * 12.9898 + b * 78.233) * 43758.5453;
  return value - value.floorToDouble();
}

_SolveCycle _solveCycle(double time) {
  const slotDuration = 0.42;
  const restDuration = 1.2;
  const cycleDuration = 2 * _moveCount * slotDuration + restDuration;
  final cycleTime = time % cycleDuration;
  final amounts = List<double>.filled(_moveCount, 0);
  var active = -1;

  if (cycleTime < 2 * _moveCount * slotDuration) {
    final slot = (cycleTime / slotDuration).floor();
    final progress = (cycleTime - slot * slotDuration) / slotDuration;
    final clamped = math.min(1, progress / 0.7);
    final eased = 1 - math.pow(1 - clamped, 3).toDouble();
    if (slot < _moveCount) {
      for (var index = 0; index < slot; index++) {
        amounts[index] = 1;
      }
      amounts[slot] = eased;
      active = slot;
    } else {
      final reverseIndex = 2 * _moveCount - 1 - slot;
      for (var index = 0; index < reverseIndex; index++) {
        amounts[index] = 1;
      }
      amounts[reverseIndex] = 1 - eased;
      active = reverseIndex;
    }
  }
  return _SolveCycle(amounts, active);
}

({double x, double y, double z, bool active}) _applyMoves(
  double initialX,
  double initialY,
  double initialZ,
  _SolveCycle cycle,
) {
  var x = initialX;
  var y = initialY;
  var z = initialZ;
  var active = false;

  for (var index = 0; index < _moves.length; index++) {
    if (cycle.amounts[index] <= 0) continue;
    final move = _moves[index];
    final coordinate = switch (move.axis) {
      0 => x,
      1 => y,
      _ => z,
    };
    if (coordinate < move.lowerBound || coordinate >= move.upperBound) {
      continue;
    }
    if (index == cycle.active) active = true;

    final angle = move.angle * cycle.amounts[index];
    final cosine = math.cos(angle);
    final sine = math.sin(angle);
    if (move.axis == 0) {
      final nextY = y * cosine - z * sine;
      z = y * sine + z * cosine;
      y = nextY;
    } else if (move.axis == 1) {
      final nextX = x * cosine + z * sine;
      z = -x * sine + z * cosine;
      x = nextX;
    } else {
      final nextX = x * cosine - y * sine;
      y = x * sine + y * cosine;
      x = nextX;
    }
  }
  return (x: x, y: y, z: z, active: active);
}

({double x, double y, double z}) _project({
  required double x,
  required double y,
  required double z,
  required double yaw,
  required double tilt,
  required double center,
  required double scale,
}) {
  final tiltSine = math.sin(tilt);
  final tiltCosine = math.cos(tilt);
  final yawSine = math.sin(yaw);
  final yawCosine = math.cos(yaw);
  final rotatedX = x * yawCosine + z * yawSine;
  final rotatedZ = -x * yawSine + z * yawCosine;
  final rotatedY = y * tiltCosine - rotatedZ * tiltSine;
  final depth = y * tiltSine + rotatedZ * tiltCosine;
  return (x: center + rotatedX * scale, y: center - rotatedY * scale, z: depth);
}

/// Builds one deterministic solving-orb frame at [time] seconds.
List<SplashSolvingParticle> buildSplashSolvingParticles({
  required double size,
  required double time,
}) {
  assert(size > 0);
  final center = size / 2;
  final scale = center * 0.82;
  final yaw = time * 0.55;
  final tilt = 0.35 + 0.1 * math.sin(time * 0.9);
  final radiusScale = math.pow(size / 300, _radiusPower).toDouble();
  final cycle = _solveCycle(time);
  final particles = <SplashSolvingParticle>[];
  final particleCount = List<int>.generate(_latRings + 1, (latitudeIndex) {
    final latitude = -math.pi / 2 + (latitudeIndex / _latRings) * math.pi;
    return math.max(1, (math.cos(latitude).abs() * _lonDensity).round());
  }).fold<int>(0, (sum, count) => sum + count);
  var sequenceIndex = 0;

  for (var latitudeIndex = 0; latitudeIndex <= _latRings; latitudeIndex++) {
    final latitude = -math.pi / 2 + (latitudeIndex / _latRings) * math.pi;
    final latitudeCosine = math.cos(latitude);
    final latitudeSine = math.sin(latitude);
    final longitudeCount = math.max(
      1,
      (latitudeCosine.abs() * _lonDensity).round(),
    );

    for (
      var longitudeIndex = 0;
      longitudeIndex < longitudeCount;
      longitudeIndex++
    ) {
      final longitude = longitudeIndex / longitudeCount * 2 * math.pi;
      final moved = _applyMoves(
        latitudeCosine * math.cos(longitude),
        latitudeSine,
        latitudeCosine * math.sin(longitude),
        cycle,
      );
      final projected = _project(
        x: moved.x,
        y: moved.y,
        z: moved.z,
        yaw: yaw,
        tilt: tilt,
        center: center,
        scale: scale,
      );
      final normalizedDepth = (projected.z + 1) / 2;
      final radius = math.max(
        _minimumRadius,
        (_rBase + _rDepth * normalizedDepth + (moved.active ? _rActive : 0)) *
            radiusScale,
      );
      final upstreamInk =
          _inkFar - _inkSpan * normalizedDepth - (moved.active ? 0.14 : 0);
      final opacity = (1 - upstreamInk).clamp(0.0, 1.0);

      particles.add(
        SplashSolvingParticle(
          x: projected.x,
          y: projected.y,
          depth: projected.z,
          radius: radius,
          opacity: opacity,
          lineT: sequenceIndex++ / (particleCount - 1),
        ),
      );
    }
  }

  particles.sort((a, b) => a.depth.compareTo(b.depth));
  return particles;
}

/// Builds the direct, non-overshooting morph from the centered solving orb to
/// a full-height vertical line. The caller supplies eased [progress].
List<SplashSolvingParticle> buildSplashDirectLineParticles({
  required Size screenSize,
  required double orbSize,
  required double time,
  required double progress,
}) {
  assert(screenSize.width > 0 && screenSize.height > 0);
  assert(orbSize > 0);
  final amount = progress.clamp(0.0, 1.0);
  final centerX = screenSize.width / 2;
  final centerY = screenSize.height / 2;
  final orbOffsetX = centerX - orbSize / 2;
  final orbOffsetY = centerY - orbSize / 2;
  final orb = buildSplashSolvingParticles(size: orbSize, time: time);

  return orb
      .map((particle) {
        final startX = orbOffsetX + particle.x;
        final startY = orbOffsetY + particle.y;
        final targetY = particle.lineT * screenSize.height;
        return SplashSolvingParticle(
          x: startX + (centerX - startX) * amount,
          y: startY + (targetY - startY) * amount,
          depth: particle.depth,
          radius: particle.radius + (0.5 - particle.radius) * amount,
          opacity: particle.opacity + (0.68 - particle.opacity) * amount,
          lineT: particle.lineT,
        );
      })
      .toList(growable: false);
}

/// Full-screen field used only by the final splash exit. It owns the same
/// realtime clock as [SplashSolvingOrb], freezes that exact phase when the
/// morph starts, and then moves every particle directly to the center line.
class SplashDirectLineField extends StatefulWidget {
  const SplashDirectLineField({
    super.key,
    required this.morphProgress,
    this.orbSize = 128,
    this.speed = 0.8,
    this.color = Colors.white,
    this.animate = true,
  }) : assert(morphProgress >= 0 && morphProgress <= 1),
       assert(orbSize > 0),
       assert(speed > 0);

  final double morphProgress;
  final double orbSize;
  final double speed;
  final Color color;
  final bool animate;

  @override
  State<SplashDirectLineField> createState() => _SplashDirectLineFieldState();
}

class _SplashDirectLineFieldState extends State<SplashDirectLineField>
    with SingleTickerProviderStateMixin {
  late final Stopwatch _elapsed;
  late final ValueNotifier<double> _time;
  late final Ticker _ticker;
  double? _frozenRawTime;
  bool _reducedMotion = false;
  bool _tickerModeEnabled = true;

  @override
  void initState() {
    super.initState();
    _elapsed = Stopwatch();
    _time = ValueNotifier<double>(0);
    _ticker = createTicker((_) {
      _time.value =
          _elapsed.elapsedMicroseconds / Duration.microsecondsPerSecond;
    });
    if (widget.morphProgress > 0) _frozenRawTime = 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant SplashDirectLineField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.morphProgress == 0 && widget.morphProgress > 0) {
      _frozenRawTime = _time.value;
    } else if (oldWidget.morphProgress > 0 && widget.morphProgress == 0) {
      _frozenRawTime = null;
    }
    _syncTicker();
  }

  void _syncTicker() {
    final shouldAnimate =
        widget.animate &&
        widget.morphProgress == 0 &&
        !_reducedMotion &&
        _tickerModeEnabled;
    if (shouldAnimate) {
      if (!_elapsed.isRunning) _elapsed.start();
      if (!_ticker.isActive) _ticker.start();
      return;
    }
    if (_ticker.isActive) _ticker.stop();
    if (_elapsed.isRunning) _elapsed.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      label: 'Solving',
      image: true,
      container: true,
      child: SizedBox.expand(
        child: CustomPaint(
          painter: SplashDirectLinePainter(
            time: _time,
            frozenRawTime: _reducedMotion
                ? SplashSolvingOrb.reducedMotionTime /
                      (_bakedSpeed * widget.speed)
                : _frozenRawTime,
            morphProgress: widget.morphProgress,
            orbSize: widget.orbSize,
            speed: widget.speed,
            color: widget.color,
            devicePixelRatio: devicePixelRatio,
          ),
        ),
      ),
    );
  }
}

class SplashDirectLinePainter extends CustomPainter {
  SplashDirectLinePainter({
    required this.time,
    required this.frozenRawTime,
    required this.morphProgress,
    required this.orbSize,
    required this.speed,
    required this.color,
    required this.devicePixelRatio,
  }) : super(repaint: time);

  final ValueListenable<double> time;
  final double? frozenRawTime;
  final double morphProgress;
  final double orbSize;
  final double speed;
  final Color color;
  final double devicePixelRatio;
  final Paint _paint = Paint()..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rawTime = frozenRawTime ?? time.value;
    final drawTime = rawTime * _bakedSpeed * speed;
    final particles = buildSplashDirectLineParticles(
      screenSize: size,
      orbSize: orbSize,
      time: drawTime,
      progress: morphProgress,
    );
    final particleAlpha = 1 - ((morphProgress - 0.58) / 0.42).clamp(0.0, 1.0);
    for (final particle in particles) {
      final alpha = particle.opacity * particleAlpha;
      if (alpha < 0.02) continue;
      _paint.color = color.withValues(alpha: alpha);
      canvas.drawCircle(
        Offset(particle.x, particle.y),
        particle.radius,
        _paint,
      );
    }

    final lineAlpha = ((morphProgress - 0.58) / 0.42).clamp(0.0, 1.0);
    if (lineAlpha > 0) {
      final width = 2 / devicePixelRatio;
      _paint
        ..isAntiAlias = false
        ..color = color.withValues(alpha: lineAlpha);
      canvas.drawRect(
        Rect.fromLTWH(size.width / 2 - width / 2, 0, width, size.height),
        _paint,
      );
      _paint.isAntiAlias = true;
    }
  }

  @override
  bool shouldRepaint(covariant SplashDirectLinePainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.frozenRawTime != frozenRawTime ||
        oldDelegate.morphProgress != morphProgress ||
        oldDelegate.orbSize != orbSize ||
        oldDelegate.speed != speed ||
        oldDelegate.color != color ||
        oldDelegate.devicePixelRatio != devicePixelRatio;
  }
}

/// Paints one realtime solving-orb frame using device-native Canvas circles.
class SplashSolvingOrbPainter extends CustomPainter {
  SplashSolvingOrbPainter({
    required this.time,
    required this.speed,
    required this.color,
    this.frozenTime,
  }) : super(repaint: time);

  final ValueListenable<double> time;
  final double speed;
  final Color color;
  final double? frozenTime;

  final Paint _paint = Paint()..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    if (side <= 0) return;
    if (size.width != size.height) {
      canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    }
    final drawTime = frozenTime ?? time.value * _bakedSpeed * speed;
    final particles = buildSplashSolvingParticles(size: side, time: drawTime);
    for (final particle in particles) {
      if (particle.opacity < 0.02) continue;
      _paint.color = color.withValues(alpha: particle.opacity);
      canvas.drawCircle(
        Offset(particle.x, particle.y),
        particle.radius,
        _paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SplashSolvingOrbPainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.speed != speed ||
        oldDelegate.color != color ||
        oldDelegate.frozenTime != frozenTime;
  }
}
