// 滑杆旋转期间"框在屏幕上不动"的投影不变性守门。
//
// [2026-07-28 用户签决] 相机 viewYaw = 基准 + box.yawDeg;滑杆 +Δ 时,
// 盒绕相机枢轴(点云 fit 中心)刚性旋转 +Δ(公转+自转)。本测试断言:
// 任意基准姿态/任意 Δ 下,盒 8 角的屏幕投影逐点不变(1e-6)。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart'
    show selectionBoxCorners;

void main() {
  test('盒绕相机枢轴刚性旋转 ⇒ 屏幕投影逐点不变', () {
    const pivot = (cx: 0.3, cy: -0.2, cz: 1.1);
    const radius = 2.0;
    // 框心刻意偏离枢轴(用户实机指认的漂移正来自这个偏心)。
    final box = SelectionBox.withYaw(
      cx: 0.9,
      cy: 0.1,
      cz: 0.4,
      sx: 1.2,
      sy: 0.8,
      sz: 1.6,
      yawDeg: 17.0,
    );
    const size = Size(390, 600);

    CloudProjection cam(double boxYawDeg, double pitch, double roll) =>
        CloudCamera(
          yaw: 0.7 + boxYawDeg * math.pi / 180.0,
          pitch: pitch,
          zoom: 1.3,
          panX: 4,
          panY: -6,
          pivotX: pivot.cx,
          pivotY: pivot.cy,
          pivotZ: pivot.cz,
          radius: radius,
          orthographic: true,
          roll: roll,
        ).projectionFor(size);

    List<(double, double)> project(SelectionBox b, double pitch, double roll) {
      final proj = cam(b.yawDeg, pitch, roll);
      return selectionBoxCorners(b)
          .map(
            (c) => (
              proj.project(c[0], c[1], c[2]).$1,
              proj.project(c[0], c[1], c[2]).$2,
            ),
          )
          .toList();
    }

    for (final (pitch, roll) in [(0.0, 0.0), (-0.9, 0.0), (0.5, 1.2)]) {
      final before = project(box, pitch, roll);
      for (final delta in [25.0, -60.0, 180.0, 3.7]) {
        final rotated = box.rotatedAroundAxis(
          axis: const [0, 1, 0],
          deltaDeg: delta,
          pivotX: pivot.cx,
          pivotY: pivot.cy,
          pivotZ: pivot.cz,
        );
        final after = project(rotated, pitch, roll);
        for (var i = 0; i < 8; i++) {
          expect(after[i].$1, closeTo(before[i].$1, 1e-6));
          expect(after[i].$2, closeTo(before[i].$2, 1e-6));
        }
      }
    }
  });

  test('刚性旋转保体积/保内含语义:旋转前后 contains 对应旋转点一致', () {
    final box = SelectionBox.withYaw(
      cx: 0.9,
      cy: 0.1,
      cz: 0.4,
      sx: 1.2,
      sy: 0.8,
      sz: 1.6,
      yawDeg: 17.0,
    );
    const px = 0.3, pz = 1.1;
    const delta = 41.0;
    final rotated = box.rotatedAroundAxis(
      axis: const [0, 1, 0],
      deltaDeg: delta,
      pivotX: px,
      pivotY: 0,
      pivotZ: pz,
    );
    // 用同一个旋转矩阵转参考点(手写公式与 Rodrigues 旋向相反,会假阳性)。
    final r = rotAboutAxisDeg(const [0, 1, 0], delta);
    final rnd = math.Random(7);
    for (var i = 0; i < 200; i++) {
      final wx = box.cx + (rnd.nextDouble() - 0.5) * 3;
      final wy = box.cy + (rnd.nextDouble() - 0.5) * 2;
      final wz = box.cz + (rnd.nextDouble() - 0.5) * 3;
      // 世界点跟着同一刚性旋转走,内含关系必须不变。
      final dx = wx - px, dy = wy, dz = wz - pz;
      final rx = px + r[0] * dx + r[1] * dy + r[2] * dz;
      final rz = pz + r[6] * dx + r[7] * dy + r[8] * dz;
      expect(rotated.contains(rx, wy, rz), box.contains(wx, wy, wz));
    }
  });
}
