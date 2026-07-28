// 3D bound-box gizmo 手柄:几何 / 命中 / 拖拽逆映射守门。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_handles_3d.dart';

const _box = SelectionBox(
  cx: 0.2,
  cy: -0.1,
  cz: 0.5,
  sx: 1.0,
  sy: 0.6,
  sz: 1.4,
  yawDeg: 25,
);

CloudProjection _proj({bool ortho = false, double yaw = 0.6}) => CloudCamera(
  yaw: yaw,
  pitch: -0.42,
  zoom: 1,
  panX: 0,
  panY: 0,
  pivotX: 0.2,
  pivotY: -0.1,
  pivotZ: 0.5,
  radius: 1.5,
  orthographic: ortho,
).projectionFor(const Size(390, 640));

void main() {
  test('手柄集合 = 6 面 + 8 角,面手柄在面中心、角手柄在角上', () {
    expect(kBoxHandles3D.length, 14);
    expect(kBoxHandles3D.where(isCornerHandle).length, 8);

    // +x 面手柄 = 盒心沿局部 x 轴外移半边长。
    final ax = boxWorldAxes(_box);
    final p = handleWorldPos(_box, (sx: 1, sy: 0, sz: 0));
    expect(p[0], closeTo(_box.cx + ax[0][0] * _box.sx / 2, 1e-12));
    expect(p[1], closeTo(_box.cy, 1e-12));
    expect(p[2], closeTo(_box.cz + ax[0][2] * _box.sx / 2, 1e-12));

    // 角手柄恰在盒的角上:略微内缩在盒内,略微外扩就出盒(角点本身在
    // 边界面上,浮点往返会压线,不做等号断言)。
    for (final h in kBoxHandles3D.where(isCornerHandle)) {
      final w = handleWorldPos(_box, h);
      final inside = [
        _box.cx + (w[0] - _box.cx) * 0.98,
        _box.cy + (w[1] - _box.cy) * 0.98,
        _box.cz + (w[2] - _box.cz) * 0.98,
      ];
      expect(_box.contains(inside[0], inside[1], inside[2]), isTrue);
      // 再外推一点点就出盒。
      final out = [
        w[0] + (w[0] - _box.cx) * 0.02,
        w[1] + (w[1] - _box.cy) * 0.02,
        w[2] + (w[2] - _box.cz) * 0.02,
      ];
      expect(_box.contains(out[0], out[1], out[2]), isFalse);
    }
  });

  test('面手柄拖拽:只改该轴尺寸,对面不动(透视与正交都成立)', () {
    for (final ortho in [false, true]) {
      final proj = _proj(ortho: ortho);
      const h = (sx: 1, sy: 0, sz: 0);
      // 该轴在屏幕上的方向,沿它拖 40px。
      final at = handleWorldPos(_box, h);
      final axes = boxWorldAxes(_box);
      final (x0, y0, _) = proj.project(at[0], at[1], at[2]);
      final (x1, y1, _) = proj.project(
        at[0] + axes[0][0] * 0.01,
        at[1] + axes[0][1] * 0.01,
        at[2] + axes[0][2] * 0.01,
      );
      final dir = Offset(x1 - x0, y1 - y0);
      final unit = dir / dir.distance;

      final out = applyHandle3DDrag(
        box: _box,
        proj: proj,
        handle: h,
        screenDelta: unit * 40,
        minHalfSize: 0.01,
      );
      // 只有 x 轴尺寸变大,另外两轴分毫不动。
      expect(out.sx, greaterThan(_box.sx), reason: 'ortho=$ortho');
      expect(out.sy, closeTo(_box.sy, 1e-12));
      expect(out.sz, closeTo(_box.sz, 1e-12));
      // 对面(−x 侧面中心)保持不动 —— gizmo 的核心语义。
      final beforeOpp = handleWorldPos(_box, (sx: -1, sy: 0, sz: 0));
      final afterOpp = handleWorldPos(out, (sx: -1, sy: 0, sz: 0));
      for (var i = 0; i < 3; i++) {
        expect(
          afterOpp[i],
          closeTo(beforeOpp[i], 1e-9),
          reason: 'ortho=$ortho',
        );
      }
    }
  });

  test('角手柄拖拽:三轴同动,对角固定', () {
    final proj = _proj();
    const h = (sx: 1, sy: 1, sz: 1);
    final before = handleWorldPos(_box, (sx: -1, sy: -1, sz: -1));
    final out = applyHandle3DDrag(
      box: _box,
      proj: proj,
      handle: h,
      screenDelta: const Offset(25, -18),
      minHalfSize: 0.01,
    );
    final after = handleWorldPos(out, (sx: -1, sy: -1, sz: -1));
    for (var i = 0; i < 3; i++) {
      expect(after[i], closeTo(before[i], 1e-9));
    }
    // 至少两个轴有变化(三轴同动;正对视线的轴可能没有屏幕方向)。
    final changed = [
      (out.sx - _box.sx).abs() > 1e-9,
      (out.sy - _box.sy).abs() > 1e-9,
      (out.sz - _box.sz).abs() > 1e-9,
    ].where((e) => e).length;
    expect(changed, greaterThanOrEqualTo(2));
  });

  test('最小尺寸 clamp:狂拖收缩不会翻负,对面仍不动', () {
    final proj = _proj();
    const h = (sx: 1, sy: 0, sz: 0);
    const minHalf = 0.05;
    final before = handleWorldPos(_box, (sx: -1, sy: 0, sz: 0));
    var b = _box;
    for (var i = 0; i < 40; i++) {
      b = applyHandle3DDrag(
        box: b,
        proj: proj,
        handle: h,
        screenDelta: const Offset(-30, 0),
        minHalfSize: minHalf,
      );
    }
    expect(b.sx, greaterThanOrEqualTo(minHalf * 2 - 1e-12));
    final after = handleWorldPos(b, (sx: -1, sy: 0, sz: 0));
    for (var i = 0; i < 3; i++) {
      expect(after[i], closeTo(before[i], 1e-9));
    }
  });

  test('命中:点在手柄上返回该手柄,远处返回 null', () {
    final proj = _proj();
    for (final h in kBoxHandles3D) {
      final w = handleWorldPos(_box, h);
      final (sx, sy, _) = proj.project(w[0], w[1], w[2]);
      final hit = hitBoxHandle3D(_box, proj, Offset(sx, sy));
      expect(hit, isNotNull);
      // 命中的手柄投影位置应与探针点重合(可能有并列点,取最近即可)。
      final hw = handleWorldPos(_box, hit!);
      final (hx, hy, _) = proj.project(hw[0], hw[1], hw[2]);
      expect((Offset(hx, hy) - Offset(sx, sy)).distance, lessThan(1e-6));
    }
    expect(hitBoxHandle3D(_box, proj, const Offset(-500, -500)), isNull);
  });

  test('轮廓内外判定:盒心在内,远处在外', () {
    final proj = _proj();
    final (cx, cy, _) = proj.project(_box.cx, _box.cy, _box.cz);
    expect(pointInBoxSilhouette(_box, proj, Offset(cx, cy)), isTrue);
    expect(pointInBoxSilhouette(_box, proj, const Offset(-300, -300)), isFalse);
    // 所有 8 角投影都应在轮廓内(凸包性质)。
    for (final h in kBoxHandles3D.where(isCornerHandle)) {
      final w = handleWorldPos(_box, h);
      final (x, y, _) = proj.project(w[0], w[1], w[2]);
      expect(pointInBoxSilhouette(_box, proj, Offset(x, y)), isTrue);
    }
  });

  test('yawDeg 旋转下手柄仍贴合盒(轴随盒转)', () {
    const rotated = SelectionBox(
      cx: 0,
      cy: 0,
      cz: 0,
      sx: 1,
      sy: 1,
      sz: 2,
      yawDeg: 90,
    );
    // yaw=90° ⇒ 局部 x 轴指向世界 +z。
    final p = handleWorldPos(rotated, (sx: 1, sy: 0, sz: 0));
    expect(p[0], closeTo(0, 1e-12));
    expect(p[2], closeTo(0.5, 1e-12));
    // 局部 z 轴(半长 1)指向世界 −x。
    final q = handleWorldPos(rotated, (sx: 0, sy: 0, sz: 1));
    expect(q[0], closeTo(-1, 1e-12));
    expect(q[2], closeTo(0, 1e-12));
    expect(math.max(p[1].abs(), q[1].abs()), closeTo(0, 1e-12));
  });
}
