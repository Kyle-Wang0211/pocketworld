import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';

void main() {
  test('project() 与手工展开逐位一致(随机相机×随机点)', () {
    final rnd = math.Random(42);
    for (var t = 0; t < 200; t++) {
      final cam = CloudCamera(
        yaw: rnd.nextDouble() * 6 - 3,
        pitch: rnd.nextDouble() * 3 - 1.5,
        zoom: 0.3 + rnd.nextDouble() * 3,
        panX: rnd.nextDouble() * 100 - 50,
        panY: rnd.nextDouble() * 100 - 50,
        pivotX: rnd.nextDouble() * 4 - 2,
        pivotY: rnd.nextDouble() * 4 - 2,
        pivotZ: rnd.nextDouble() * 4 - 2,
        radius: 0.5 + rnd.nextDouble() * 5,
      );
      const size = Size(390, 700);
      final p = cam.projectionFor(size);
      final wx = rnd.nextDouble() * 8 - 4;
      final wy = rnd.nextDouble() * 8 - 4;
      final wz = rnd.nextDouble() * 8 - 4;
      // 手工展开 = sparse_cloud_view paint() 的原式
      final cosY = math.cos(cam.yaw), sinY = math.sin(cam.yaw);
      final cosP = math.cos(cam.pitch), sinP = math.sin(cam.pitch);
      final half = size.shortestSide * 0.5;
      final f = half * cam.fillK * cam.zoom;
      final camDist = cam.radius * 3.2;
      final ox = size.width * 0.5 + cam.panX;
      final oy = size.height * 0.5 + cam.panY;
      final px = wx - cam.pivotX, py = wy - cam.pivotY, pz = wz - cam.pivotZ;
      final x1 = px * cosY + pz * sinY;
      final z1 = -px * sinY + pz * cosY;
      final y2 = py * cosP - z1 * sinP;
      final z2 = py * sinP + z1 * cosP;
      final depth = z2 + camDist;
      final (sx, sy, d) = p.project(wx, wy, wz);
      expect(d, closeTo(depth, 1e-9));
      expect(sx, closeTo(ox - x1 * f / depth, 1e-9));
      expect(sy, closeTo(oy - y2 * f / depth, 1e-9));
    }
  });

  test('worldPerPixelAt:1 像素屏幕位移 ≈ depth/f 世界位移', () {
    const cam = CloudCamera(
      yaw: 0.3,
      pitch: -0.4,
      zoom: 1,
      panX: 0,
      panY: 0,
      pivotX: 0,
      pivotY: 0,
      pivotZ: 0,
      radius: 2,
    );
    const size = Size(400, 400);
    final p = cam.projectionFor(size);
    final wpp = p.worldPerPixelAt(5.0);
    expect(wpp, closeTo(5.0 / p.f, 1e-12));
  });

  test('视平面基向量:right/up 与投影一致(数值微分验证)', () {
    const cam = CloudCamera(
      yaw: 0.7,
      pitch: -0.5,
      zoom: 1.4,
      panX: 3,
      panY: -8,
      pivotX: 0.2,
      pivotY: -0.1,
      pivotZ: 0.4,
      radius: 1.5,
    );
    const size = Size(390, 700);
    final p = cam.projectionFor(size);
    const w = (0.5, -0.3, 0.8);
    final (sx0, sy0, d0) = p.project(w.$1, w.$2, w.$3);
    // 沿 rightAxisWorld 移动 ε 世界距离 → 屏幕 x 增加 ε·f/depth,y 不变
    final r = p.rightAxisWorld();
    const eps = 1e-4;
    final (sx1, sy1, _) = p.project(
      w.$1 + r[0] * eps,
      w.$2 + r[1] * eps,
      w.$3 + r[2] * eps,
    );
    expect((sx1 - sx0) / eps, closeTo(-1 * -1 * p.f / d0, 1e-2)); // +f/depth
    expect((sy1 - sy0).abs() / eps, lessThan(1e-2));
    final u = p.upAxisWorld();
    final (sx2, sy2, _) = p.project(
      w.$1 + u[0] * eps,
      w.$2 + u[1] * eps,
      w.$3 + u[2] * eps,
    );
    expect((sy2 - sy0) / eps, closeTo(-p.f / d0, 1e-2)); // 屏幕 y 向下为正
    expect((sx2 - sx0).abs() / eps, lessThan(1e-2));
  });
}
