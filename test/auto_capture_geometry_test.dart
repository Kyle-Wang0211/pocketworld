import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

ARPreviewPoint _pt(double x, double y, double z) =>
    ARPreviewPoint(position: Vector3(x, y, z), r: 0, g: 0, b: 0, confidence: 1);

void main() {
  test('medianSceneDepthM projects onto the forward axis', () {
    // Camera at origin looking down -Z. Points at depth 1,2,3 => median 2.
    final depth = medianSceneDepthM(
      cameraPosition: Vector3.zero(),
      forward: Vector3(0, 0, -1),
      points: <ARPreviewPoint>[
        for (var i = 0; i < 3; i++) _pt(0, 0, -(i + 1).toDouble()),
        // pad to the 8-anchor minimum with copies of the same depths
        for (var i = 0; i < 3; i++) _pt(0.1, 0.1, -(i + 1).toDouble()),
        _pt(0, 0, -2.0),
        _pt(0, 0, -2.0),
      ],
    );
    expect(depth, isNotNull);
    expect(depth!, closeTo(2.0, 1e-9));
  });

  test('medianSceneDepthM returns null below the anchor minimum', () {
    expect(
      medianSceneDepthM(
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -1),
        points: <ARPreviewPoint>[_pt(0, 0, -1), _pt(0, 0, -2)],
      ),
      isNull,
    );
  });

  test('medianSceneDepthM drops points behind the camera', () {
    // 8 valid at depth 1.0 plus 4 behind-camera points that must not count.
    final depth = medianSceneDepthM(
      cameraPosition: Vector3.zero(),
      forward: Vector3(0, 0, -1),
      points: <ARPreviewPoint>[
        for (var i = 0; i < 8; i++) _pt(0, 0, -1.0),
        for (var i = 0; i < 4; i++) _pt(0, 0, 5.0),
      ],
    );
    expect(depth!, closeTo(1.0, 1e-9));
  });

  test('parallaxAngleDeg is the angle subtended at the target', () {
    // Target 1m ahead; camera slides 1m sideways => 45°.
    final target = Vector3(0, 0, -1);
    expect(
      parallaxAngleDeg(
        baseCamera: Vector3.zero(),
        currentCamera: Vector3(1, 0, 0),
        target: target,
      ),
      closeTo(45.0, 1e-9),
    );
  });

  test('parallaxAngleDeg is ~0 for pure forward motion — the double-wall case',
      () {
    // Walking straight at the object: base, current and target are collinear.
    final target = Vector3(0, 0, -1);
    final deg = parallaxAngleDeg(
      baseCamera: Vector3.zero(),
      currentCamera: Vector3(0, 0, -0.5),
      target: target,
    );
    expect(deg, lessThan(0.001));
  });

  test('viewAxisTurnDeg measures the angle between optical axes', () {
    expect(
      viewAxisTurnDeg(
        baseForward: Vector3(0, 0, -1),
        currentForward: Vector3(1, 0, 0),
      ),
      closeTo(90.0, 1e-9),
    );
  });

  test('normalizedCenterShift is zero when the target stays centred', () {
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, -1),
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      closeTo(0.0, 1e-9),
    );
  });

  test('normalizedCenterShift grows with lateral camera translation', () {
    // Target 1m ahead, fx = imageWidth => a 0.3m sideways slide puts the
    // target 0.3 * imageWidth px off centre => s = 0.30.
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, -1),
        currentCamera: Vector3(-0.3, 0, 0),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      closeTo(0.30, 1e-9),
    );
  });

  test('normalizedCenterShift is infinite when the target falls behind', () {
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, 1), // behind a camera that looks down -Z
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      double.infinity,
    );
  });

  // New tests from fix round 1
  test('normalizedCenterShift distinguishes world→camera from its inverse', () {
    // 期望值由相机基向量点积独立推导(right/up/forward = q.rotated(局部轴)),
    // 不是从实现公式反推。若 `.inverted()` 被删掉(变换方向写反),
    // 这里会得到 0.115085853250 —— 落在 0.30 阈值的另一侧。
    final q = Quaternion.axisAngle(Vector3(0, 1, 0), 20 * math.pi / 180);
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, -1),
        currentCamera: Vector3(0.5, 0, 0),
        currentOrientation: q,
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      closeTo(1.056179114050, 1e-9),
    );
  });

  test('normalizedCenterShift pairs fx with width and fy with height', () {
    // fx != fy 且 imageWidth != imageHeight,x/y 都非零:
    // sx = 1000*0.2/1 / 1000 = 0.2,sy = 500*0.3/1 / 2000 = 0.075
    // 面积口径 => 0.2 + 0.075 - 0.015 = 0.26
    // 若把 fx/imageWidth 与 fy/imageHeight 配对写反,结果会变。
    expect(
      normalizedCenterShift(
        target: Vector3(0.2, 0.3, -1),
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 500,
        imageWidth: 1000,
        imageHeight: 2000,
      ),
      closeTo(0.26, 1e-12),
    );
  });

  test('normalizedCenterShift does not drop the vertical axis', () {
    // sx = 0.02,sy = 0.40 => 0.412。若实现写成 `return sx;`,这里会是 0.02。
    expect(
      normalizedCenterShift(
        target: Vector3(0.02, 0.40, -1),
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      closeTo(0.412, 1e-12),
    );
  });

  test('normalizedCenterShift combines both axes as area overlap loss', () {
    double? shiftAt(double d) => normalizedCenterShift(
          target: Vector3(0, 0, -1),
          currentCamera: Vector3(-d, -d, 0),
          currentOrientation: Quaternion.identity(),
          fx: 1000,
          fy: 1000,
          imageWidth: 1000,
          imageHeight: 1000,
        );

    // 45 度斜向,两轴各 0.30:面积损失 0.51,即重叠只剩 49%。
    // 旧的 max(sx, sy) 在这里只给 0.30 —— 正好卡在阈值上,于是斜向运动
    // 被系统性推迟触发,重叠掉到 RS 官方下限 60% 以下才开火。
    expect(shiftAt(0.30)!, closeTo(0.51, 1e-12));

    // 两轴各 0.16:面积损失 0.2944,仍在 0.30 阈值下(重叠 70.56%)。
    expect(shiftAt(0.16)!, closeTo(0.2944, 1e-12));
  });

  test('normalizedCenterShift returns null for unusable intrinsics', () {
    double? withIntrinsics(double fx, double fy, int w, int h) =>
        normalizedCenterShift(
          target: Vector3(0, 0, -1),
          currentCamera: Vector3.zero(),
          currentOrientation: Quaternion.identity(),
          fx: fx,
          fy: fy,
          imageWidth: w,
          imageHeight: h,
        );

    // null,不是 +inf —— +inf 会被上层读成"立刻拍"。
    expect(withIntrinsics(0, 1000, 1000, 1000), isNull);
    expect(withIntrinsics(1000, 0, 1000, 1000), isNull);
    expect(withIntrinsics(1000, 1000, 0, 1000), isNull);
    expect(withIntrinsics(1000, 1000, 1000, 0), isNull);

    // 而"目标在相机背后"仍然是 +inf,两种情形可区分。
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, 1),
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      double.infinity,
    );
  });

  test('angle helpers stay finite at the acos domain edge', () {
    // 实测:这个向量与自身的 dot/(|v||v|) = 1.00000000000000022204,
    // 不 clamp 的 math.acos 直接返回 NaN。而 NaN 在上层的 `>= 5.0` /
    // `>= 10.0` 比较里恒为 false ⇒ 闸门会**静默地永不触发**,不报错不崩溃。
    final v = Vector3(
      -0.8436825206056198,
      0.6901161031643888,
      0.37529772468339395,
    );
    final turn = viewAxisTurnDeg(baseForward: v, currentForward: v.clone());
    expect(turn.isNaN, isFalse);
    expect(turn, closeTo(0.0, 1e-9));

    final par = parallaxAngleDeg(
      baseCamera: Vector3.zero(),
      currentCamera: Vector3(1e-9, 0, 0),
      target: Vector3(0, 0, -1),
    );
    expect(par.isNaN, isFalse);
    expect(par, lessThan(0.001));
  });

  test('parallaxAngleDeg returns 0 when a camera coincides with the target', () {
    expect(
      parallaxAngleDeg(
        baseCamera: Vector3(0, 0, -1),
        currentCamera: Vector3(1, 0, 0),
        target: Vector3(0, 0, -1),
      ),
      0.0,
    );
  });

  test('medianSceneDepthM averages the two middle values', () {
    // 深度 1,1,1,2,3,4,4,4 => 两中值 2 与 3 => 2.5
    final depths = <double>[1, 1, 1, 2, 3, 4, 4, 4];
    expect(
      medianSceneDepthM(
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -1),
        points: <ARPreviewPoint>[for (final d in depths) _pt(0, 0, -d)],
      )!,
      closeTo(2.5, 1e-12),
    );
  });

  test('medianSceneDepthM honours camera position and an oblique axis', () {
    // 相机在 (1,2,3),光轴 = 绕 +Y 转 20 度后的前向;9 个点分别在光轴上
    // 1..9 米处 => 奇数个 => 中位数 5.0。
    final q = Quaternion.axisAngle(Vector3(0, 1, 0), 20 * math.pi / 180);
    final fwd = q.rotated(Vector3(0, 0, -1));
    final cam = Vector3(1, 2, 3);
    final pts = <ARPreviewPoint>[
      for (var i = 1; i <= 9; i++)
        ARPreviewPoint(
          position: cam + fwd * i.toDouble(),
          r: 0,
          g: 0,
          b: 0,
          confidence: 1,
        ),
    ];
    expect(
      medianSceneDepthM(cameraPosition: cam, forward: fwd, points: pts)!,
      closeTo(5.0, 1e-9),
    );
  });

  test('viewAxisTurnDeg normalises non-unit vectors', () {
    // 两条共面向量,长度分别为 5 和 2,夹角 60 度。
    // 若归一化除法被删掉,dot=5 会让 acos 直接超出定义域。
    final a = Vector3(5, 0, 0);
    final b = Vector3(2 * math.cos(60 * math.pi / 180), 2 * math.sin(60 * math.pi / 180), 0);
    expect(viewAxisTurnDeg(baseForward: a, currentForward: b), closeTo(60.0, 1e-9));
  });
}
