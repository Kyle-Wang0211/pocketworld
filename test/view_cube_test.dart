// view_cube_test.dart — 3D 朝向立方体与相机绑定语义守门。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
