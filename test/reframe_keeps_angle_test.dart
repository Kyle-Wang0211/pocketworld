// "回到初始点云大小":编辑态只复位取景,视角保持不变。
//
// [2026-08-09 用户签决] "当我点击'回到初始点云大小',视角保持不变,不需要
// 回到顶部视角。" —— reframe 在编辑态保留 yaw/pitch/roll,只复位
// pivot/pan/zoom(zoom 回编辑取景 = 全点入框)。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

(Float32List, Uint8List) cloud() {
  const n = 600;
  final xyz = Float32List(n * 3);
  final rgb = Uint8List(n * 3)..fillRange(0, n * 3, 255);
  final rnd = math.Random(2);
  for (var i = 0; i < n * 3; i++) {
    xyz[i] = rnd.nextDouble() * 2 - 1;
  }
  return (xyz, rgb);
}

void main() {
  testWidgets('编辑态 reframe:yaw/pitch 不动,zoom 回编辑取景', (tester) async {
    final (xyz, rgb) = cloud();
    final controller = CloudViewController();
    await tester.pumpWidget(
      MaterialApp(
        home: SparseCloudView(
          xyz: xyz,
          rgb: rgb,
          editing: true,
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    // 摆一个"前视"姿态(pitch=0, yaw=1.2)—— 模拟用户点过骰子侧面。
    controller.moveTo((
      yaw: 1.2,
      pitch: 0,
      roll: 0,
      zoom: 3.0,
      panX: 40,
      panY: -20,
      pivotX: 9,
      pivotY: 9,
      pivotZ: 9,
    ));
    await tester.pumpAndSettle();

    controller.requestReframe();
    await tester.pumpAndSettle();

    final st = tester.state(find.byType(SparseCloudView)) as dynamic;
    expect(
      st.debugPitch as double,
      closeTo(0, 1e-6),
      reason: 'reframe 把视角拽走了(用户:"视角保持不变,不需要回到顶部视角")',
    );
    final frame = editingFrameOf(xyz);
    final cam = st.debugCamera as CloudViewCamera;
    expect(cam.yaw, closeTo(1.2, 1e-6), reason: 'yaw 被重置了');
    expect(cam.zoom, closeTo(frame.zoom, 1e-6), reason: 'zoom 没回编辑取景');
    expect(cam.panX, closeTo(0, 1e-6));
    expect(
      cam.pivotX,
      closeTo(frame.center[0], 1e-6),
      reason: 'pivot 没回框中心(严丝合缝框与相机必须同心)',
    );
  });
}
