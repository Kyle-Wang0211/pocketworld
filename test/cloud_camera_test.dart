import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart'
    show SparseCloudPainter;

void main() {
  test('fillK 默认值与 SparseCloudPainter.fitFillK 同源不漂移', () {
    // cloud_camera.dart 的 CloudCamera.fillK 默认值与
    // sparse_cloud_view.dart 的 SparseCloudPainter.fitFillK 曾是两个各写
    // 一份的字面量(都是 2.6),没有任何东西守着它们不漂移 —— 漂移会让
    // 选区页手柄矩形静默错尺度。这条测试就是那道守卫:任一边改了数值而
    // 另一边没跟着改,这里就会先炸。
    expect(
      const CloudCamera(
        yaw: 0,
        pitch: 0,
        zoom: 1,
        panX: 0,
        panY: 0,
        pivotX: 0,
        pivotY: 0,
        pivotZ: 0,
        radius: 1,
      ).fillK,
      SparseCloudPainter.fitFillK,
    );
  });

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
      final camDist = cam.radius * kCamDistK;
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

  test('正交模式:除数恒 camDist,与手工展开一致;worldPerPixel 与深度无关', () {
    final rnd = math.Random(7);
    for (var t = 0; t < 50; t++) {
      final cam = CloudCamera(
        yaw: rnd.nextDouble() * 6 - 3,
        pitch: rnd.nextDouble() * 3 - 1.5,
        zoom: 0.5 + rnd.nextDouble() * 2,
        panX: 0,
        panY: 0,
        pivotX: 0,
        pivotY: 0,
        pivotZ: 0,
        radius: 1 + rnd.nextDouble() * 3,
        orthographic: true,
      );
      const size = Size(400, 400);
      final p = cam.projectionFor(size);
      final wx = rnd.nextDouble() * 4 - 2;
      final wy = rnd.nextDouble() * 4 - 2;
      final wz = rnd.nextDouble() * 4 - 2;
      final cosY = math.cos(cam.yaw), sinY = math.sin(cam.yaw);
      final cosP = math.cos(cam.pitch), sinP = math.sin(cam.pitch);
      final f = size.shortestSide * 0.5 * cam.fillK * cam.zoom;
      final camDist = cam.radius * kCamDistK;
      final x1 = wx * cosY + wz * sinY;
      final z1 = -wx * sinY + wz * cosY;
      final y2 = wy * cosP - z1 * sinP;
      final z2 = wy * sinP + z1 * cosP;
      final (sx, sy, d) = p.project(wx, wy, wz);
      // depth 仍是真值(排序/裁剪语义不变),但缩放除数恒 camDist。
      expect(d, closeTo(z2 + camDist, 1e-9));
      expect(sx, closeTo(200 - x1 * f / camDist, 1e-9));
      expect(sy, closeTo(200 - y2 * f / camDist, 1e-9));
      expect(p.worldPerPixelAt(d), closeTo(camDist / f, 1e-12));
      expect(p.worldPerPixelAt(999), closeTo(camDist / f, 1e-12));
    }
  });

  test('SO(3) 工具:compose↔decompose 随机 roundtrip', () {
    final rnd = math.Random(11);
    for (var i = 0; i < 200; i++) {
      final yaw = rnd.nextDouble() * 6 - 3;
      final pitch = rnd.nextDouble() * 3 - 1.5;
      final roll = rnd.nextDouble() * 6 - 3;
      final m = composeViewMatrix(yaw, pitch, roll);
      final (y2, p2, r2) = decomposeViewMatrix(m);
      final m2 = composeViewMatrix(y2, p2, r2);
      for (var k = 0; k < 9; k++) {
        expect(m2[k], closeTo(m[k], 1e-9), reason: 'i=$i k=$k');
      }
    }
  });

  test('slerp 端点与角度:相邻面 90°,对面 180°;落定即目标', () {
    List<double> pose(double y, double p) => composeViewMatrix(y, p, 0);
    // Front→Top:90°
    var (_, ang) = axisAngleOf(
      mulTransposed(pose(0, -math.pi / 2), pose(0, 0)),
    );
    expect(ang, closeTo(math.pi / 2, 1e-9));
    // Bottom(lastH=Front 停留态)→ Back:单轴一次旋转(过极翻+回正合成)
    final from = pose(0, math.pi / 2);
    final to = pose(math.pi, 0);
    final (axis, a2) = axisAngleOf(mulTransposed(to, from));
    expect(a2, closeTo(math.pi, 1e-6));
    // 中点姿态仍是正交矩阵且 t=1 精确落到目标
    final mid = mulMatrix(rotationFromAxisAngle(axis, a2 / 2), from);
    final (my, mp, mr) = decomposeViewMatrix(mid);
    final re = composeViewMatrix(my, mp, mr);
    for (var k = 0; k < 9; k++) {
      expect(re[k], closeTo(mid[k], 1e-9));
    }
    final end = mulMatrix(rotationFromAxisAngle(axis, a2), from);
    for (var k = 0; k < 9; k++) {
      expect(end[k], closeTo(to[k], 1e-9));
    }
  });

  test('roll 管线:project 带 roll 与手工二维旋转一致;基向量含 roll', () {
    const cam = CloudCamera(
      yaw: 0.4,
      pitch: -0.3,
      zoom: 1,
      panX: 0,
      panY: 0,
      pivotX: 0,
      pivotY: 0,
      pivotZ: 0,
      radius: 2,
      roll: 0.7,
    );
    const size = Size(400, 400);
    final p = cam.projectionFor(size);
    const noRoll = CloudCamera(
      yaw: 0.4,
      pitch: -0.3,
      zoom: 1,
      panX: 0,
      panY: 0,
      pivotX: 0,
      pivotY: 0,
      pivotZ: 0,
      radius: 2,
    );
    final p0 = noRoll.projectionFor(size);
    final (sx0, sy0, d0) = p0.project(0.5, -0.2, 0.7);
    final (sx1, sy1, d1) = p.project(0.5, -0.2, 0.7);
    expect(d1, closeTo(d0, 1e-12));
    final c = math.cos(0.7), s = math.sin(0.7);
    final dx = sx0 - 200, dy = sy0 - 200;
    expect(sx1, closeTo(200 + dx * c - dy * s, 1e-9));
    expect(sy1, closeTo(200 + dx * s + dy * c, 1e-9));
    // 基向量数值微分(roll 下 right/up 仍应与投影一致)
    final r = p.rightAxisWorld();
    const eps = 1e-4;
    final (rx, ry, _) = p.project(
      0.5 + r[0] * eps,
      -0.2 + r[1] * eps,
      0.7 + r[2] * eps,
    );
    expect((rx - sx1) / eps, greaterThan(0)); // 屏幕 +x
    expect(((ry - sy1) / eps).abs(), lessThan(1e-1));
  });
}
