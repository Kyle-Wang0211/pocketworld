import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/splash_solving_orb.dart';

List<String> _snapshot(List<SplashSolvingParticle> particles) => particles
    .map(
      (p) =>
          '${p.x.toStringAsFixed(8)},${p.y.toStringAsFixed(8)},'
          '${p.depth.toStringAsFixed(8)},${p.radius.toStringAsFixed(8)},'
          '${p.opacity.toStringAsFixed(8)}',
    )
    .toList(growable: false);

void main() {
  test('solving particle field is deterministic', () {
    final first = buildSplashSolvingParticles(size: 128, time: 0.6);
    final repeated = buildSplashSolvingParticles(size: 128, time: 0.6);

    expect(_snapshot(first), _snapshot(repeated));
  });

  test('solving particle field changes as time advances', () {
    final first = buildSplashSolvingParticles(size: 128, time: 0.6);
    final later = buildSplashSolvingParticles(size: 128, time: 1.1);

    expect(_snapshot(first), isNot(_snapshot(later)));
  });

  test('solving particles stay inside the requested canvas', () {
    final particles = buildSplashSolvingParticles(size: 128, time: 0.6);

    expect(particles, isNotEmpty);
    for (final particle in particles) {
      expect(particle.x, inInclusiveRange(0, 128));
      expect(particle.y, inInclusiveRange(0, 128));
      expect(particle.radius, greaterThan(0));
      expect(particle.opacity, inInclusiveRange(0, 1));
    }
  });

  test('painter carries the requested white color, speed and frozen time', () {
    final time = ValueNotifier<double>(0);
    addTearDown(time.dispose);
    final painter = SplashSolvingOrbPainter(
      time: time,
      speed: 0.8,
      color: Colors.white,
      frozenTime: 0.6,
    );

    expect(painter.speed, 0.8);
    expect(painter.color, Colors.white);
    expect(painter.frozenTime, 0.6);
  });

  test('direct-line morph starts at the live orb frame with no jump', () {
    const screen = Size(393, 852);
    final orb = buildSplashSolvingParticles(size: 128, time: 0.6);
    final morphed = buildSplashDirectLineParticles(
      screenSize: screen,
      orbSize: 128,
      time: 0.6,
      progress: 0,
    );

    expect(morphed, hasLength(orb.length));
    for (var index = 0; index < orb.length; index++) {
      expect(
        morphed[index].x,
        closeTo(screen.width / 2 - 64 + orb[index].x, 1e-9),
      );
      expect(
        morphed[index].y,
        closeTo(screen.height / 2 - 64 + orb[index].y, 1e-9),
      );
    }
  });

  test('direct-line morph ends on one full-height center line', () {
    const screen = Size(393, 852);
    final particles = buildSplashDirectLineParticles(
      screenSize: screen,
      orbSize: 128,
      time: 0.6,
      progress: 1,
    );

    expect(particles, isNotEmpty);
    expect(particles.map((p) => p.x), everyElement(closeTo(196.5, 1e-9)));
    expect(particles.map((p) => p.y).reduce(math.min), lessThan(3));
    expect(particles.map((p) => p.y).reduce(math.max), greaterThan(849));
  });

  test('direct-line morph never overshoots into a full-screen burst', () {
    const screen = Size(393, 852);
    final start = buildSplashDirectLineParticles(
      screenSize: screen,
      orbSize: 128,
      time: 0.6,
      progress: 0,
    );
    final middle = buildSplashDirectLineParticles(
      screenSize: screen,
      orbSize: 128,
      time: 0.6,
      progress: 0.5,
    );
    final end = buildSplashDirectLineParticles(
      screenSize: screen,
      orbSize: 128,
      time: 0.6,
      progress: 1,
    );

    for (var index = 0; index < start.length; index++) {
      expect(
        middle[index].x,
        inInclusiveRange(
          math.min(start[index].x, end[index].x),
          math.max(start[index].x, end[index].x),
        ),
      );
      expect(
        middle[index].y,
        inInclusiveRange(
          math.min(start[index].y, end[index].y),
          math.max(start[index].y, end[index].y),
        ),
      );
    }
  });
}
