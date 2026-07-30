// test/selection_rect_math_test.dart — 选区 2D 矩形手柄数学(纯函数)测试。
//
// TDD RED→GREEN:先写此文件确认失败(文件不存在),再实现
// selection_cloud_view.dart 的纯函数部分使其转绿。
//
// applyBoxPan 方向断言(controller correction,覆盖 brief 原始实现):
// Task 2 实测锁定 upAxisWorld() 返回屏幕 −y(向上)方向的世界向量,
// rightAxisWorld() 是屏幕 +x(向右)方向。brief 的
// `cy + (r[1]·dx + u[1]·dy)·wpp` 在垂直方向会反(往下拖 dy>0 会把盒往
// 屏幕上方移),已按 controller correction 修正为
// `cy + (r[1]·dx − u[1]·dy)·wpp` 等价写法。测试用逐分量 closeTo 断言方向,
// 不能只断 moved>0。
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_rect_handles.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

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
  const box = SelectionBox(cx: 0, cy: 0, cz: 0, sx: 2, sy: 4, sz: 6);

  test('Front 视角(yaw0,pitch0):可见轴 = 局部 x/y', () {
    final b = boxScreenBasis(_proj(), box);
    expect(b.hAxis, 0); // x
    expect(b.vAxis, 1); // y
    // 屏幕投影带负号(sx = ox − x1·f/depth):局部 +x → 屏幕 −x
    expect(b.hSx, lessThan(0));
    // y 向上为正、屏幕 y 向下 ⇒ 局部 +y → 屏幕 −y
    expect(b.vSy, lessThan(0));
  });

  test('Top 视角(pitch=−π/2):可见轴 = 局部 x/z', () {
    final b = boxScreenBasis(_proj(pitch: -3.141592653589793 / 2), box);
    expect(b.hAxis, 0); // x
    expect(b.vAxis, 2); // z
  });

  test('Right 视角(yaw=π/2):可见轴 = 局部 z/y', () {
    final b = boxScreenBasis(_proj(yaw: 3.141592653589793 / 2), box);
    expect(b.hAxis, 2); // z
    expect(b.vAxis, 1); // y
  });

  test('盒 yaw 被相机 yaw 抵消后仍是干净的 x/y(滑杆语义)', () {
    final turned = SelectionBox.withYaw(
      cx: 0,
      cy: 0,
      cz: 0,
      sx: 2,
      sy: 4,
      sz: 6,
      yawDeg: 30,
    );
    // 相机 yaw = preset(0) + 盒 yaw(30°) —— Task 5 的组装约定
    final b = boxScreenBasis(_proj(yaw: 30 * 3.141592653589793 / 180), turned);
    expect(b.hAxis, 0);
    expect(b.vAxis, 1);
    // 抵消后矩形保持屏幕对齐:单位局部轴的屏幕分量 ≈ scale(全量落在
    // 水平方向,没有泄漏到另一轴)
    expect(b.hSx.abs(), greaterThan(b.scale * 0.9));
  });

  test('selectionScreenRect:半宽/半高 = 半尺寸×scale', () {
    final b = boxScreenBasis(_proj(), box);
    final r = selectionScreenRect(b, box);
    expect(r.width, closeTo(box.sx * b.scale, 1e-6));
    expect(r.height, closeTo(box.sy * b.scale, 1e-6));
    expect(r.center.dx, closeTo(b.cxS, 1e-6));
  });

  test('hitRectHandle:角/边/空白', () {
    const r = Rect.fromLTRB(100, 100, 300, 260);
    expect(hitRectHandle(r, const Offset(102, 98)), RectHandle.cornerTL);
    expect(hitRectHandle(r, const Offset(300, 180)), RectHandle.edgeR);
    expect(hitRectHandle(r, const Offset(200, 262)), RectHandle.edgeB);
    expect(hitRectHandle(r, const Offset(200, 180)), isNull); // 矩形内部空白
    expect(hitRectHandle(r, const Offset(10, 10)), isNull);
  });

  test('拖 edgeR 向屏幕右:hAxis 尺寸变、对面不动', () {
    final b = boxScreenBasis(_proj(), box);
    // Front 视角 hSx<0:屏幕右移 = 局部 −x 方向 ⇒ edgeR 对应局部 −x 面
    // 外扩。不管符号怎么落,不变量是:受控轴是 x、y/z 不变、对面世界坐标
    // 不动、矩形右边跟手。
    final out = applyRectHandleDrag(
      box: box,
      basis: b,
      h: RectHandle.edgeR,
      screenDelta: const Offset(20, 0),
      minHalfSize: 0.01,
    );
    expect(out.sy, closeTo(box.sy, 1e-9));
    expect(out.sz, closeTo(box.sz, 1e-9));
    expect(out.sx, greaterThan(box.sx)); // 往外拖 = 变大
    // 对面(edgeL 对应的局部面)世界位置不动:
    final worldGrow = 20 / b.scale;
    expect(out.sx, closeTo(box.sx + worldGrow, 1e-6));
    // 中心沿受控面方向补偿一半
    expect(
      (out.cx - box.cx).abs() + (out.cz - box.cz).abs(),
      closeTo(worldGrow / 2, 1e-6),
    );
  });

  test('拖 cornerBR:h/v 两轴都变,第三轴不变', () {
    final b = boxScreenBasis(_proj(), box);
    final out = applyRectHandleDrag(
      box: box,
      basis: b,
      h: RectHandle.cornerBR,
      screenDelta: const Offset(10, 10),
      minHalfSize: 0.01,
    );
    expect(out.sx, isNot(closeTo(box.sx, 1e-9)));
    expect(out.sy, isNot(closeTo(box.sy, 1e-9)));
    expect(out.sz, closeTo(box.sz, 1e-9));
  });

  test('clamp:往里挤穿也不退化', () {
    final b = boxScreenBasis(_proj(), box);
    final out = applyRectHandleDrag(
      box: box,
      basis: b,
      h: RectHandle.edgeR,
      screenDelta: const Offset(-99999, 0),
      minHalfSize: 0.05,
    );
    expect(out.sx, greaterThanOrEqualTo(0.1));
  });

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

  test('正交模式:selectionScreenRect 与盒 8 角投影严格重合(可见两轴)', () {
    // 用户签决"屏幕框外必须全红"的几何前提:正交下矩形 == 盒投影,
    // 任何点若屏幕落在矩形外,其可见两轴必出盒 ⇒ contains 必假 ⇒ 必红。
    final box2 = SelectionBox.withYaw(
      cx: 0.3,
      cy: -0.2,
      cz: 0.5,
      sx: 1.6,
      sy: 2.4,
      sz: 3.2,
      yawDeg: 25,
    );
    final cam = CloudCamera(
      yaw: 25 * 3.141592653589793 / 180, // 相机抵消盒 yaw(联动约定)
      pitch: 0,
      zoom: 1.2,
      panX: 0,
      panY: 0,
      pivotX: 0,
      pivotY: 0,
      pivotZ: 0,
      radius: 2,
      orthographic: true,
    );
    final proj = cam.projectionFor(const Size(400, 700));
    final basis = boxScreenBasis(proj, box2);
    final rect = selectionScreenRect(basis, box2);
    // 8 角投影的包围矩形应与 selectionScreenRect 重合(容差 1e-6)
    double minX = 1e18, maxX = -1e18, minY = 1e18, maxY = -1e18;
    for (final c in selectionBoxCorners(box2)) {
      final (sx, sy, _) = proj.project(c[0], c[1], c[2]);
      minX = math.min(minX, sx);
      maxX = math.max(maxX, sx);
      minY = math.min(minY, sy);
      maxY = math.max(maxY, sy);
    }
    expect(rect.left, closeTo(minX, 1e-6));
    expect(rect.right, closeTo(maxX, 1e-6));
    expect(rect.top, closeTo(minY, 1e-6));
    expect(rect.bottom, closeTo(maxY, 1e-6));
  });

  // ── [2026-07-30 实机定罪] 斜朝向框:矩形必须等于盒投影的真实外接范围 ──
  //
  // 病理:草稿存档里的框带 yawDeg=-41.2°(滑轨转框留下的合法朝向)。旧
  // selectionScreenRect 把"盒沿局部轴的尺寸"直接当屏幕边长,只在局部轴与
  // 屏幕轴平行时成立;斜 41.2° 时盒真实投影宽 = sx·cos41+sz·sin41 = 5.18,
  // 而矩形只画 sx = 3.43 ⇒ 矩形画在盒里面小 34%,矩形外那一圈点其实在 3D
  // 盒内(判定为内、不红)—— 用户实机报"框外的点云没有变红"的真凶。
  group('斜朝向框(实机草稿 yawDeg=-41.2°)', () {
    final skew = SelectionBox.withYaw(
      cx: -0.2268750841983959,
      cy: -0.2792477736933909,
      cz: 2.1342483015100395,
      sx: 3.4273421857647204,
      sy: 2.9928319280554696,
      sz: 3.9394953630036667,
      yawDeg: -41.21212121212105,
    );

    ({Rect rect, Rect trueBounds}) measure({
      double yaw = 0,
      double pitch = 0,
      bool ortho = true,
    }) {
      final proj = CloudCamera(
        yaw: yaw,
        pitch: pitch,
        zoom: 1,
        panX: 0,
        panY: 0,
        pivotX: skew.cx,
        pivotY: skew.cy,
        pivotZ: skew.cz,
        radius: 3,
        orthographic: ortho,
      ).projectionFor(const Size(400, 800));
      final rect = selectionScreenRect(boxScreenBasis(proj, skew), skew);
      var x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
      for (final c in selectionBoxCorners(skew)) {
        final (sx, sy, _) = proj.project(c[0], c[1], c[2]);
        x0 = math.min(x0, sx);
        x1 = math.max(x1, sx);
        y0 = math.min(y0, sy);
        y1 = math.max(y1, sy);
      }
      return (rect: rect, trueBounds: Rect.fromLTRB(x0, y0, x1, y1));
    }

    test('正俯视(初始视角):矩形 = 盒 8 角投影外接矩形', () {
      final m = measure(yaw: math.pi, pitch: -math.pi / 2);
      expect(m.rect.left, closeTo(m.trueBounds.left, 1e-6));
      expect(m.rect.top, closeTo(m.trueBounds.top, 1e-6));
      expect(m.rect.width, closeTo(m.trueBounds.width, 1e-6));
      expect(m.rect.height, closeTo(m.trueBounds.height, 1e-6));
    });

    test('Front 视角:矩形 = 盒 8 角投影外接矩形', () {
      final m = measure();
      expect(m.rect.width, closeTo(m.trueBounds.width, 1e-6));
      expect(m.rect.height, closeTo(m.trueBounds.height, 1e-6));
    });

    test('45° 斜视(旧实现选轴平局退化):h≠v 且矩形仍外接', () {
      final m = measure(yaw: math.pi / 4, pitch: -math.pi / 2);
      expect(m.rect.width, closeTo(m.trueBounds.width, 1e-6));
      expect(m.rect.height, closeTo(m.trueBounds.height, 1e-6));
    });
  });
}
