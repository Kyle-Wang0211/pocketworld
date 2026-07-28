// view_cube_test.dart — 3D 朝向立方体与相机绑定语义守门。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/view_cube.dart';

void main() {
  test('六个预设姿态下,正对相机的面 = 该预设的标签(绑定语义)', () {
    // (yaw, pitch) → 期望正对面。与 kOrientationPresets 一致。
    final cases = <(double, double, String)>[
      (0, -math.pi / 2, 'Top'),
      (0, 0, 'Front'),
      (math.pi / 2, 0, 'Right'),
      (math.pi, 0, 'Back'),
      (-math.pi / 2, 0, 'Left'),
      (0, math.pi / 2, 'Bottom'),
    ];
    for (final (yaw, pitch, label) in cases) {
      final visible = visibleViewCubeFaces(yaw, pitch);
      expect(visible, contains(label), reason: 'yaw=$yaw pitch=$pitch');
      // 正对时对面绝不可见
      const opp = {
        'Top': 'Bottom',
        'Bottom': 'Top',
        'Front': 'Back',
        'Back': 'Front',
        'Right': 'Left',
        'Left': 'Right',
      };
      expect(visible, isNot(contains(opp[label])), reason: label);
    }
  });

  test('Top 视角原地转 90°(yaw+π/2):Top 仍可见 —— 立方体跟着转', () {
    final v = visibleViewCubeFaces(math.pi / 2, -math.pi / 2);
    expect(v, contains('Top'));
  });

  test('斜视角可见 3 面(体对角方向)', () {
    final v = visibleViewCubeFaces(math.pi / 4, -math.pi / 5);
    expect(v.length, 3);
    expect(v, containsAll(['Top', 'Front', 'Right']));
  });

  testWidgets('ViewCube 渲染不崩,姿态变化触发重绘', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: ViewCube(viewYaw: 0.3, viewPitch: -0.4)),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: ViewCube(viewYaw: 1.3, viewPitch: 0.2)),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test('primaryViewCubeFace:任何姿态只有一个标签;六预设正对面正确', () {
    final cases = <(double, double, String)>[
      (0, -math.pi / 2, 'Top'),
      (0, 0, 'Front'),
      (math.pi / 2, 0, 'Right'),
      (math.pi, 0, 'Back'),
      (-math.pi / 2, 0, 'Left'),
      (0, math.pi / 2, 'Bottom'),
    ];
    for (final (yaw, pitch, label) in cases) {
      expect(
        primaryViewCubeFace(yaw, pitch),
        label,
        reason: 'yaw=$yaw pitch=$pitch',
      );
    }
    // 斜视角(用户截图场景:两面同时可见)也只返回一个 —— 更朝向相机的
    // 那面。yaw=40°(<45°)时 Front 仍更正对。
    expect(primaryViewCubeFace(40 * math.pi / 180, 0), 'Front');
    expect(primaryViewCubeFace(50 * math.pi / 180, 0), 'Right');
    // Bottom + 滑杆任意角:primary 恒 Bottom(立方体随滑杆原地转,标签
    // 不闪跳)。
    expect(primaryViewCubeFace(1.234, math.pi / 2), 'Bottom');
  });

  test('骰子是真透视立方体:近大远小明显,且不溢出画布太多', () {
    // [2026-07-29 用户签决] "右上角的立方体需要是一个真正的立方体,需要有
    // 透视"。正交下六面永远等大(像展开的纸盒);透视下同向边应有可见的
    // 长度差,但不能夸张到把立方体拉变形。
    const size = Size(72, 72);
    final proj = CloudCamera(
      yaw: 0.6,
      pitch: -0.42,
      zoom: 1,
      panX: 0,
      panY: 0,
      pivotX: 0,
      pivotY: 0,
      pivotZ: 0,
      radius: 1,
      fillK: kViewCubeFillK,
      orthographic: kViewCubeOrthographic,
    ).projectionFor(size);

    expect(kViewCubeOrthographic, isFalse, reason: '必须是透视');

    Offset px(List<double> w) {
      final (x, y, _) = proj.project(w[0], w[1], w[2]);
      return Offset(x, y);
    }

    // 单位立方体 8 角。
    final corners = <List<double>>[];
    for (final z in [-1.0, 1.0]) {
      for (final y in [-1.0, 1.0]) {
        for (final x in [-1.0, 1.0]) {
          corners.add([x, y, z]);
        }
      }
    }
    const groups = [
      [
        [0, 1],
        [2, 3],
        [4, 5],
        [6, 7],
      ],
      [
        [0, 2],
        [1, 3],
        [4, 6],
        [5, 7],
      ],
      [
        [0, 4],
        [1, 5],
        [2, 6],
        [3, 7],
      ],
    ];
    for (final g in groups) {
      final lens = g
          .map((e) => (px(corners[e[0]]) - px(corners[e[1]])).distance)
          .toList();
      final ratio = lens.reduce(math.max) / lens.reduce(math.min);
      // 有透视(>1.05)但不夸张(<1.8)。
      expect(ratio, greaterThan(1.05), reason: '看不出透视:$ratio');
      expect(ratio, lessThan(1.8), reason: '透视过强会把立方体拉变形:$ratio');
    }

    // 立方体不应严重溢出画布(没有 ClipRect,溢出会压到旁边的 UI)。
    final half = size.width / 2;
    for (final c in corners) {
      final p = px(c);
      expect((p.dx - half).abs(), lessThan(half * 1.25));
      expect((p.dy - half).abs(), lessThan(half * 1.25));
    }
  });
}
