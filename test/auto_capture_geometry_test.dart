import 'dart:math' as math;
import 'dart:typed_data';

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
    // 期望值由 camera-to-world 矩阵的转置独立推导，不从实现公式反推。
    // 若把 vector_math.rotated() 再反一次，结果会得到 1.056179114050 ——
    // 落在 0.30 阈值的另一侧。
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
      closeTo(0.115085853250, 1e-9),
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

  group('cross-platform motion roles', () {
    const intrinsics = AutoCaptureIntrinsics(
      fx: 1000,
      fy: 1000,
      cx: 500,
      cy: 500,
      imageWidth: 1000,
      imageHeight: 1000,
    );
    final target = Vector3(0, 0, -1);

    AutoCaptureGeometryFrame frame(
      Vector3 camera, {
      Quaternion? orientation,
    }) => AutoCaptureGeometryFrame(
      camera: camera,
      orientation: orientation ?? Quaternion.identity(),
      intrinsics: intrinsics,
    );

    test('camera-to-world quaternion projects its optical axis in front', () {
      // ARKit/ARCore transport camera-to-world rotations.  vector_math's
      // Quaternion.rotated() applies the inverse rotation, so this catches the
      // exact convention mismatch that made a locked subject unprojectable.
      final c2w = Matrix3.rotationY(20 * math.pi / 180);
      final orientation = Quaternion.fromRotation(c2w)..normalize();
      final expectedForward = c2w.transform(Vector3(0, 0, -1));
      final rotated = frame(Vector3.zero(), orientation: orientation);
      final target = expectedForward * 2;

      expect(rotated.forward.x, closeTo(expectedForward.x, 1e-12));
      expect(rotated.forward.y, closeTo(expectedForward.y, 1e-12));
      expect(rotated.forward.z, closeTo(expectedForward.z, 1e-12));
      expect(
        autoCaptureTargetOverlapFraction(
          base: rotated,
          current: rotated,
          target: target,
        ),
        closeTo(1.0, 1e-12),
      );
    });

    test('an unprojectable target is unknown, not zero overlap', () {
      final base = frame(Vector3.zero());
      expect(
        autoCaptureTargetOverlapFraction(
          base: base,
          current: base,
          target: Vector3(0, 0, 1),
        ),
        isNull,
      );
    });

    test('portable track retention selects 10, 12, or 15 degrees', () {
      expect(
        autoCaptureGeometryAngleDeg(
          const PortableTrackHealth(
            retentionRatio: 0.74,
            distributionHealthy: true,
          ),
        ),
        kAutoCaptureGeometryWeakDeg,
      );
      expect(autoCaptureGeometryAngleDeg(null), kAutoCaptureGeometryNormalDeg);
      expect(
        autoCaptureGeometryAngleDeg(
          const PortableTrackHealth(
            retentionRatio: 0.90,
            distributionHealthy: false,
          ),
        ),
        kAutoCaptureGeometryNormalDeg,
      );
      expect(
        autoCaptureGeometryAngleDeg(
          const PortableTrackHealth(
            retentionRatio: 0.90,
            distributionHealthy: true,
          ),
        ),
        kAutoCaptureGeometryStrongDeg,
      );
    });

    test('horizontal and vertical travel both become formal geometry', () {
      final base = frame(Vector3.zero());
      final lateral = math.tan(12 * math.pi / 180);

      final horizontal = classifyAutoCaptureMotion(
        geometryBaseline: base,
        captureBaseline: base,
        current: frame(Vector3(lateral, 0, 0)),
        target: target,
      );
      expect(horizontal.role, AutoCaptureMotionRole.geometry);
      expect(horizontal.horizontalBaselineM, closeTo(lateral, 1e-9));
      expect(horizontal.verticalBaselineM, closeTo(0, 1e-9));
      expect(horizontal.advancesGeometryBaseline, isTrue);

      final vertical = classifyAutoCaptureMotion(
        geometryBaseline: base,
        captureBaseline: base,
        current: frame(Vector3(0, lateral, 0)),
        target: target,
      );
      expect(vertical.role, AutoCaptureMotionRole.geometry);
      expect(vertical.verticalBaselineM, closeTo(lateral, 1e-9));
      expect(vertical.horizontalBaselineM, closeTo(0, 1e-9));
      expect(vertical.advancesGeometryBaseline, isTrue);
    });

    test('forward-only 1.2x scale change is a bridge, never geometry', () {
      final base = frame(Vector3.zero());
      final result = classifyAutoCaptureMotion(
        geometryBaseline: base,
        captureBaseline: base,
        current: frame(Vector3(0, 0, -0.2)),
        target: target,
      );
      expect(result.geometryParallaxDeg, closeTo(0, 1e-9));
      expect(result.depthScaleRatio, closeTo(1.25, 1e-9));
      expect(result.role, AutoCaptureMotionRole.radialBridge);
      expect(result.advancesGeometryBaseline, isFalse);
    });

    test('in-place 12 degree turn is a coverage candidate, not geometry', () {
      final base = frame(Vector3.zero());
      final result = classifyAutoCaptureMotion(
        geometryBaseline: base,
        captureBaseline: base,
        current: frame(
          Vector3.zero(),
          orientation: Quaternion.axisAngle(
            Vector3(0, 1, 0),
            12 * math.pi / 180,
          ),
        ),
        target: target,
      );
      expect(result.geometryParallaxDeg, 0);
      expect(result.viewTurnDeg, closeTo(12, 1e-9));
      expect(result.role, AutoCaptureMotionRole.rotationCoverage);
      expect(result.advancesGeometryBaseline, isFalse);
    });

    test('diagonal area overlap reaching 70 percent becomes safety capture', () {
      final base = frame(Vector3.zero());
      final result = classifyAutoCaptureMotion(
        geometryBaseline: base,
        captureBaseline: base,
        current: frame(Vector3(-0.17, -0.17, 0)),
        target: target,
      );
      expect(result.overlapFraction, closeTo(0.6889, 1e-9));
      expect(result.role, AutoCaptureMotionRole.overlapSafety);
      expect(result.shouldPromptSlowDown, isTrue);
    });

    test('1.5 degrees separates stable parallax from rotation-only motion', () {
      final base = frame(Vector3.zero());
      final current = frame(
        Vector3(math.tan(1.49 * math.pi / 180), 0, 0),
        orientation: Quaternion.axisAngle(
          Vector3(0, 1, 0),
          12 * math.pi / 180,
        ),
      );
      final result = classifyAutoCaptureMotion(
        geometryBaseline: base,
        captureBaseline: base,
        current: current,
        target: target,
      );
      expect(result.geometryParallaxDeg, closeTo(1.49, 1e-9));
      expect(result.role, AutoCaptureMotionRole.rotationCoverage);
    });

    test(
      'rotation coverage wins when turn and radial predicates are both true',
      () {
        final base = frame(Vector3.zero());
        final result = classifyAutoCaptureMotion(
          geometryBaseline: base,
          captureBaseline: base,
          current: frame(
            Vector3(0, 0, -0.2),
            orientation: Quaternion.axisAngle(
              Vector3(0, 1, 0),
              12 * math.pi / 180,
            ),
          ),
          target: target,
        );

        expect(result.viewTurnDeg, closeTo(12, 1e-9));
        expect(
          result.geometryParallaxDeg,
          lessThan(kAutoCaptureStableParallaxFloorDeg),
        );
        expect(
          result.depthScaleRatio,
          greaterThanOrEqualTo(kAutoCaptureRadialScaleStep),
        );
        expect(result.role, AutoCaptureMotionRole.rotationCoverage);
      },
    );
  });

  // ————————————————————————————————————————————————————————————————
  // 〔2026-08-19 全分支评审 / 08-20 变异复核〕零长度守卫的四个半边。
  //
  // ⚠️ 先把一句写反了的话扳正。它同时写在 51228d1 的提交信息里，提交信息
  // 改不了，所以这里是唯一能把记录留正的地方：
  //
  //   〔错〕「删掉这半边守卫 ⇒ `a.dot(b)/(la*lb)` = 0/0 = NaN；Dart 的
  //          clamp 对 NaN 原样返回，acos(NaN) = NaN ⇒ 上层 `>= 5.0` 恒为
  //          false ⇒ 闸门静默地永不触发」
  //
  // 实测：`double.nan.clamp(-1.0, 1.0)` 返回的是 **1.0**，不是 NaN。
  // (num.clamp 用 compareTo 比较，而 double.compareTo 把 NaN 排在所有数
  //  之后 ⇒ 命中 `> upperLimit` 那一支，返回上限。) 于是 acos(1.0) = **0.0**
  // —— 恰恰就是断言期望的那个 0.0。守卫在与不在，观测值逐位相同，
  // 「零长度 ⇒ 期望 0.0」这种写法因此**一个变异都咬不住**。
  //
  // 这里是**两个不同的机制**，不能混为一谈：
  //
  //  (1) cos 轻微越界(实测 v 与自身：dot/(|v||v|) = 1.0000000000000002)。
  //      NaN 是 acos 在 clamp **之后**产生的，`.clamp` 正是拦它的那道墙：
  //      删掉 `.clamp` ⇒ acos 返回 NaN ⇒ `NaN >= 5.0` 恒为 false ⇒ 闸门
  //      静默地永不触发。上面两条 acos-domain 测试守的就是这一条，
  //      它们**确实咬得住**(删 `.clamp` 当场变红)。
  //
  //  (2) 零长度向量。NaN 是 0/0 在 clamp **之前**就产生的，clamp 把它折成
  //      1.0、acos 再折成 0.0。所以零长度守卫拦的**不是 NaN 外泄**，而是
  //      一个**有限但错误的答案** —— 那才是下面四条要钉住的东西。
  //
  // 钉法：喂**接近零但非零**的长度(1e-12，仍在 1e-9 阈值之下)。除法此时
  // 完全合法，守卫在 = 0.0，守卫删掉 = **90.0**(实测逐位精确)。90 远超
  // kAutoCaptureTurnMinDeg(10°)的转角开火线 ⇒ 变异体会凭空开一枪
  // (视差版函数已退出触发链,只进遥测,但同一守卫仍防它输出错误读数)。
  // 这才是这几条测试值得存在的理由：
  // 守的不是「不崩溃」，是「不误拍」。
  //
  // 每条只让**一个**半边落到近零、另一半保持单位长 ⇒ 四个半边逐一独立钉死
  // (把 `la < 1e-9 ||` 或 `|| lb < 1e-9` 单独删掉，也只有对应那一条变红)。
  // ————————————————————————————————————————————————————————————————

  test('parallaxAngleDeg returns 0 when the BASE camera all but coincides '
      'with the target (the la half of the guard)', () {
    // a = base - target = (1e-12, 0, 0) ⇒ la = 1e-12 < 1e-9，踩 la 半边；
    // b = current - target = (0, 0, 1) ⇒ lb = 1，另一半不参与。
    // a·b = 0 ⇒ cos = 0 / (1e-12 · 1) = 0 ⇒ acos(0) = π/2 ⇒ 90.0。
    expect(
      parallaxAngleDeg(
        baseCamera: Vector3(1e-12, 0, -1),
        currentCamera: Vector3.zero(),
        target: Vector3(0, 0, -1),
      ),
      0.0,
    );
    // 真·重合(la 恰为 0)也必须是 0 —— 契约的另一端。但这一行**咬不住**
    // 变异体，见上面表头 (2)：这正是 f12d429 那条测试此前唯一断言的形状。
    expect(
      parallaxAngleDeg(
        baseCamera: Vector3(0, 0, -1),
        currentCamera: Vector3(1, 0, 0),
        target: Vector3(0, 0, -1),
      ),
      0.0,
    );
  });

  test('parallaxAngleDeg returns 0 when the CURRENT camera all but coincides '
      'with the target (the lb half of the guard)', () {
    // a = base - target = (0, 0, 1) ⇒ la = 1；
    // b = current - target = (1e-12, 0, 0) ⇒ lb = 1e-12 < 1e-9，踩 lb 半边。
    // a·b = 0 ⇒ cos = 0 / (1 · 1e-12) = 0 ⇒ acos(0) = π/2 ⇒ 90.0。
    expect(
      parallaxAngleDeg(
        baseCamera: Vector3.zero(),
        currentCamera: Vector3(1e-12, 0, -1),
        target: Vector3(0, 0, -1),
      ),
      0.0,
    );
    // 契约的另一端(lb 恰为 0)，同样不咬变异体。
    expect(
      parallaxAngleDeg(
        baseCamera: Vector3(1, 0, 0),
        currentCamera: Vector3(0, 0, -1),
        target: Vector3(0, 0, -1),
      ),
      0.0,
    );
  });

  test('viewAxisTurnDeg returns 0 on a near-zero BASE forward '
      '(the la half of the guard)', () {
    // la = |(1e-12, 0, 0)| = 1e-12 < 1e-9；lb = |(0, 0, -1)| = 1。
    // dot = 0 ⇒ cos = 0 / (1e-12 · 1) = 0 ⇒ acos(0) = π/2 ⇒ 90.0，
    // 而 90 ≥ kAutoCaptureTurnMinDeg(10) ⇒ 变异体在原地不动时也会开火。
    expect(
      viewAxisTurnDeg(
        baseForward: Vector3(1e-12, 0, 0),
        currentForward: Vector3(0, 0, -1),
      ),
      0.0,
    );
    // 契约的另一端(恰为零向量)，不咬变异体。
    expect(
      viewAxisTurnDeg(
        baseForward: Vector3.zero(),
        currentForward: Vector3(0, 0, -1),
      ),
      0.0,
    );
  });

  test('viewAxisTurnDeg returns 0 on a near-zero CURRENT forward '
      '(the lb half of the guard)', () {
    // la = 1；lb = 1e-12 < 1e-9。dot = 0 ⇒ cos = 0 ⇒ 90.0。
    expect(
      viewAxisTurnDeg(
        baseForward: Vector3(0, 0, -1),
        currentForward: Vector3(1e-12, 0, 0),
      ),
      0.0,
    );
    // 契约的另一端(恰为零向量)，不咬变异体。
    expect(
      viewAxisTurnDeg(
        baseForward: Vector3(0, 0, -1),
        currentForward: Vector3.zero(),
      ),
      0.0,
    );
  });

  test('medianSceneDepthM drops a point sitting exactly ON the camera '
      'centre (d == 0, not just d < 0)', () {
    // `d > 0` 放宽成 `d >= 0` 时,深度恰为 0 的点会进中位数、把基准帧的
    // target 拉近,视差与重叠两个判据一起被系统性放大。同文件
    // normalizedCenterShift 的 depth 守卫已经用 0 与 1e-9 两个点钉死了 ——
    // 两条守卫同形,此前只护住了一条。
    final depth = medianSceneDepthM(
      cameraPosition: Vector3.zero(),
      forward: Vector3(0, 0, -1),
      points: <ARPreviewPoint>[
        // 8 个正深度,中位数 4.5。
        for (var i = 1; i <= 8; i++) _pt(0, 0, -i.toDouble()),
        // 4 个恰好落在相机中心的点(投影深度 == 0)。
        for (var i = 0; i < 4; i++) _pt(i * 0.001, 0, 0),
      ],
    );
    expect(depth, isNotNull);
    expect(
      depth!,
      closeTo(4.5, 1e-9),
      reason: 'd == 0 must be dropped, or the median gets dragged down',
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

  // Round-2 mutation tests — 7 surviving mutations, one pattern each
  test('normalizedCenterShift takes the magnitude on the vertical axis too', () {
    // 目标在画面中心线【下方】(y 为负)。绝对值口径下结果与 y 为正时相同。
    // 若 sy 少了 .abs(),这里会得到 0.02 - 0.40 + 0.008 = -0.372。
    // 19 个既有用例的 cam.y 不是 0 就是正,所以纵轴的 .abs() 此前零覆盖 ——
    // 而横轴的同款变异会被 4 条测试当场抓死。
    expect(
      normalizedCenterShift(
        target: Vector3(0.02, -0.40, -1),
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

  test('medianSceneDepthM ignores behind-camera points even when they outnumber', () {
    // 8 个正深度 + 12 个负深度。守卫生效时只有 8 个有效点 => 中位数 1.0。
    // 若 `d > 0` 被放宽成 `d != 0`,20 个点的中位数会变成 -5.0。
    // 既有的同名测试用 8 正 + 4 负,负值是少数派、推不动中位数,抓不住这个变异。
    expect(
      medianSceneDepthM(
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -1),
        points: <ARPreviewPoint>[
          for (var i = 0; i < 8; i++) _pt(0, 0, -1.0),
          for (var i = 0; i < 12; i++) _pt(0, 0, 5.0),
        ],
      )!,
      closeTo(1.0, 1e-12),
    );
  });

  test('parallaxAngleDeg clamps the acos domain edge too', () {
    // 同一个病态向量:v·v/(|v||v|) = 1.00000000000000022204。
    // 让两个相机中心相对 target 完全同向,cos 就会踩到 acos 的定义域边界。
    // 删掉 parallaxAngleDeg 的 .clamp(-1.0, 1.0) 时这里会变成 NaN。
    final v = Vector3(
      -0.8436825206056198,
      0.6901161031643888,
      0.37529772468339395,
    );
    final deg = parallaxAngleDeg(
      baseCamera: v,
      currentCamera: v.clone(),
      target: Vector3.zero(),
    );
    expect(deg.isNaN, isFalse);
    expect(deg, closeTo(0.0, 1e-12));
  });

  test('normalizedCenterShift guards near-zero depth, not just negative depth', () {
    double? at(Vector3 target) => normalizedCenterShift(
          target: target,
          currentCamera: Vector3.zero(),
          currentOrientation: Quaternion.identity(),
          fx: 1000,
          fy: 1000,
          imageWidth: 1000,
          imageHeight: 1000,
        );

    // 深度恰为 0:守卫被削成 `depth < 0` 时会走到 0/0 = NaN。
    expect(at(Vector3.zero()), double.infinity);
    // 深度为极小正值:守卫被削弱时会得到 5e8 这种有限但荒谬的值。
    expect(at(Vector3(0.5, 0, -1e-9)), double.infinity);
  });

  test('medianSceneDepthM anchor floor is pinned on both sides', () {
    List<ARPreviewPoint> n(int count) =>
        <ARPreviewPoint>[for (var i = 0; i < count; i++) _pt(0, 0, -1.0)];
    double? depthFor(int count) => medianSceneDepthM(
          cameraPosition: Vector3.zero(),
          forward: Vector3(0, 0, -1),
          points: n(count),
        );

    // 差一即拒:7 个不够,8 个刚好够。此前只测了 2 个点,任何 >=3 的阈值都能过。
    expect(depthFor(7), isNull);
    expect(depthFor(8), closeTo(1.0, 1e-12));
  });

  test('medianSceneDepthM normalises a non-unit forward', () {
    // forward 长度为 2。归一化生效时深度是 1..9 => 中位数 5.0;
    // 删掉 .normalized() 则深度变成 2..18 => 中位数 10.0。
    expect(
      medianSceneDepthM(
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -2),
        points: <ARPreviewPoint>[
          for (var i = 1; i <= 9; i++) _pt(0, 0, -i.toDouble()),
        ],
      )!,
      closeTo(5.0, 1e-9),
    );
  });

  test('non-finite inputs are rejected by both guards', () {
    // (a) 无穷远的特征点必须被丢掉,否则它们会污染中位数。
    expect(
      medianSceneDepthM(
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -1),
        points: <ARPreviewPoint>[
          for (var i = 0; i < 8; i++) _pt(0, 0, -1.0),
          for (var i = 0; i < 12; i++) _pt(0, 0, double.negativeInfinity),
        ],
      )!,
      closeTo(1.0, 1e-12),
    );

    // (b) 无穷深度必须走 +inf 分支;删掉 !depth.isFinite 时会得到 0.0。
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, double.negativeInfinity),
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

  // ── medianDepthFromCloudXyz:触发层唯一合法的深度来源(2026-08-24)──

  group('medianDepthFromCloudXyz (live-SfM depth, the only legal source)', () {
    Float32List cloudAt(List<double> depths) {
      // 相机在原点看 -Z:深度 d 的点 = (抖动的x, 抖动的y, -d)。
      final xyz = Float32List(depths.length * 3);
      for (var i = 0; i < depths.length; i++) {
        xyz[i * 3] = (i % 7) * 0.01;
        xyz[i * 3 + 1] = (i % 5) * 0.01;
        xyz[i * 3 + 2] = -depths[i];
      }
      return xyz;
    }

    test('returns the median depth along the view axis', () {
      final depths = List<double>.generate(100, (i) => 1.0 + i * 0.01);
      expect(
        medianDepthFromCloudXyz(
          xyz: cloudAt(depths),
          cameraPosition: Vector3.zero(),
          forward: Vector3(0, 0, -1),
          sampleStride: 1,
        ),
        closeTo(1.495, 0.01),
      );
    });

    test('points behind the camera or nearer than 5 cm are ignored', () {
      // 贴脸噪点门(>0.05m)与验尸脚本同一条;负深度 = 相机背后。
      final depths = <double>[
        ...List<double>.filled(20, 0.01), // 贴脸
        ...List<double>.filled(20, -1.0), // 背后
        ...List<double>.filled(21, 1.3), // 真场景
      ];
      expect(
        medianDepthFromCloudXyz(
          xyz: cloudAt(depths),
          cameraPosition: Vector3.zero(),
          forward: Vector3(0, 0, -1),
          sampleStride: 1,
        ),
        closeTo(1.3, 1e-6),
      );
    });

    test('too few valid points yields null, never a made-up depth', () {
      // 「不知道」必须编码成 null —— 上层拿 null 走兜底位移,而不是拿一个
      // 少数点凑出来的数去缩放阈值(rawFeaturePoints 就是这么撒谎的)。
      expect(
        medianDepthFromCloudXyz(
          xyz: cloudAt(List<double>.filled(kAutoCaptureMinDepthAnchors - 1, 1.0)),
          cameraPosition: Vector3.zero(),
          forward: Vector3(0, 0, -1),
          sampleStride: 1,
        ),
        isNull,
      );
      expect(
        medianDepthFromCloudXyz(
          xyz: Float32List(0),
          cameraPosition: Vector3.zero(),
          forward: Vector3(0, 0, -1),
        ),
        isNull,
      );
    });

    test('sampling stride keeps the median stable on a dense cloud', () {
      final depths = List<double>.generate(20000, (i) => 1.0 + (i % 100) * 0.01);
      final full = medianDepthFromCloudXyz(
        xyz: cloudAt(depths),
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -1),
        sampleStride: 1,
      )!;
      final sampled = medianDepthFromCloudXyz(
        xyz: cloudAt(depths),
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -1),
      )!;
      expect(sampled, closeTo(full, 0.05));
    });

    test('the camera pose matters — a translated camera reads a different '
        'depth', () {
      final depths = List<double>.filled(50, 2.0);
      expect(
        medianDepthFromCloudXyz(
          xyz: cloudAt(depths),
          cameraPosition: Vector3(0, 0, -1.0), // 前移 1m
          forward: Vector3(0, 0, -1),
          sampleStride: 1,
        ),
        closeTo(1.0, 1e-6),
      );
    });
  });
}
