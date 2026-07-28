// test/selection_rect_math_test.dart — 盒平移数学(纯函数)测试。
//
// [2026-07-28 用户签决"新版框改成 3D 的"] 2D 屏幕矩形手柄整套已删除
// (boxScreenBasis / selectionScreenRect / hitRectHandle / applyRectHandleDrag),
// 手柄改 3D bound-box gizmo,见 selection_handles_3d_test.dart。本文件只
// 保留仍在役的 applyBoxPan 方向断言:
// applyBoxPan 方向断言(controller correction,覆盖 brief 原始实现):
// Task 2 实测锁定 upAxisWorld() 返回屏幕 −y(向上)方向的世界向量,
// rightAxisWorld() 是屏幕 +x(向右)方向。brief 的
// `cy + (r[1]·dx + u[1]·dy)·wpp` 在垂直方向会反(往下拖 dy>0 会把盒往
// 屏幕上方移),已按 controller correction 修正为
// `cy + (r[1]·dx − u[1]·dy)·wpp` 等价写法。测试用逐分量 closeTo 断言方向,
// 不能只断 moved>0。
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_handles_3d.dart';

CloudProjection _proj({double yaw = 0, double pitch = 0}) => CloudCamera(
  yaw: yaw,
  pitch: pitch,
  zoom: 1,
  panX: 0,
  panY: 0,
  pivotX: 0,
  pivotY: 0,
  pivotZ: 0,
  radius: 2,
).projectionFor(const Size(400, 400));

void main() {
  const box = SelectionBox(cx: 0, cy: 0, cz: 0, sx: 2, sy: 4, sz: 6, yawDeg: 0);

  test('applyBoxPan:屏幕拖动平移盒中心,尺寸不变,方向遵循 controller correction', () {
    final proj = _proj(); // yaw=0,pitch=0 ⇒ right=[-1,0,0]、up=[0,1,0]
    final out = applyBoxPan(
      box: box,
      proj: proj,
      screenDelta: const Offset(10, -6),
      depth: 6.4,
    );
    expect(out.sx, box.sx);
    final wpp = proj.worldPerPixelAt(6.4);
    // controller correction:垂直分量用 −screenDelta.dy。
    // right=[-1,0,0] ⇒ cx -= 10·wpp;up=[0,1,0] ⇒ cy += (-(-6))·wpp = 6·wpp
    // 与 brief 附注一致:cx−=10·wpp、cy+=6·wpp。
    expect(out.cx, closeTo(box.cx - 10 * wpp, 1e-9));
    expect(out.cy, closeTo(box.cy + 6 * wpp, 1e-9));
    expect(out.cz, closeTo(box.cz, 1e-9));
    final moved =
        (out.cx - box.cx).abs() +
        (out.cy - box.cy).abs() +
        (out.cz - box.cz).abs();
    expect(moved, greaterThan(0));
  });
}
