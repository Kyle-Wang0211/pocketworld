import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/display_transform.dart';

void expectUv(List<double> got, double u, double v, {double tol = 1e-9}) {
  expect(got[0], closeTo(u, tol), reason: 'u: $got');
  expect(got[1], closeTo(v, tol), reason: 'v: $got');
}

void main() {
  group('相机相对显示的旋转', () {
    test('后置摄像头,官方公式', () {
      // sensor=90, back(sign=-1): (90 + display + 360) % 360
      for (final (ScreenRotation r, int want) in <(ScreenRotation, int)>[
        (ScreenRotation.degrees0, 90),
        (ScreenRotation.degrees90, 180),
        (ScreenRotation.degrees180, 270),
        (ScreenRotation.degrees270, 0),
      ]) {
        expect(
          DisplayTransform.cameraToDisplayRotation(
              sensorOrientationDegrees: 90, displayRotation: r, frontFacing: false),
          want,
          reason: '$r',
        );
      }
    });

    test('🔴 与 ARCore DisplayRotationHelper:137 在 90/270 上差 180°', () {
      for (final ScreenRotation r in <ScreenRotation>[
        ScreenRotation.degrees90, ScreenRotation.degrees270
      ]) {
        final int ours = DisplayTransform.cameraToDisplayRotation(
            sensorOrientationDegrees: 90, displayRotation: r, frontFacing: false);
        final int arcore = (90 - r.degrees + 360) % 360;
        expect((ours - arcore).abs() % 360, 180, reason: '$r 应当差 180°');
        // 奇偶性一致 —— 这就是为什么 ARCore 自己用没错。
        expect((ours ~/ 90) % 2, (arcore ~/ 90) % 2);
      }
    });

    test('前置摄像头符号相反', () {
      expect(
        DisplayTransform.cameraToDisplayRotation(
            sensorOrientationDegrees: 270,
            displayRotation: ScreenRotation.degrees90,
            frontFacing: true),
        180,
      );
    });

    test('索引→度数(安卓/鸿蒙的 0/1/2/3)', () {
      expect(ScreenRotation.fromIndex(0).degrees, 0);
      expect(ScreenRotation.fromIndex(1).degrees, 90);
      expect(ScreenRotation.fromIndex(2).degrees, 180);
      expect(ScreenRotation.fromIndex(3).degrees, 270);
    });
  });

  group('UV 变换', () {
    test('同比例、零旋转 ⇒ 恒等', () {
      final t = DisplayTransform.compute(
        imageWidth: 640, imageHeight: 480,
        viewportWidth: 1280, viewportHeight: 960,
        rotationDegrees: 0,
      );
      expectUv(t.apply(0, 0), 0, 0);
      expectUv(t.apply(1, 1), 1, 1);
      expectUv(t.apply(0.5, 0.5), 0.5, 0.5);
    });

    test('中心永远是中心 —— 任何旋转、任何视口', () {
      for (final int rot in <int>[0, 90, 180, 270]) {
        for (final (int vw, int vh) in <(int, int)>[
          (1179, 2556), (2556, 1179), (1000, 1000)
        ]) {
          final t = DisplayTransform.compute(
            imageWidth: 640, imageHeight: 480,
            viewportWidth: vw, viewportHeight: vh,
            rotationDegrees: rot,
          );
          expectUv(t.apply(0.5, 0.5), 0.5, 0.5, tol: 1e-12);
        }
      }
    });

    test('aspect-fill:窄视口只在一个轴上收缩取样范围', () {
      // 640x480 图,竖屏视口 ⇒ 旋转 0 时水平方向要裁。
      final t = DisplayTransform.compute(
        imageWidth: 640, imageHeight: 480,
        viewportWidth: 480, viewportHeight: 640,
        rotationDegrees: 0,
      );
      // scale = max(480/640, 640/480) = 1.3333;可见 x 比例 = (480/1.3333)/640 = 0.5625
      final a = t.apply(0, 0.5);
      final b = t.apply(1, 0.5);
      expect(b[0] - a[0], closeTo(0.5625, 1e-9), reason: 'x 取样范围应收缩');
      final c0 = t.apply(0.5, 0);
      final c1 = t.apply(0.5, 1);
      expect(c1[1] - c0[1], closeTo(1.0, 1e-9), reason: 'y 不该收缩');
    });

    test('旋转 90° 把 u 轴换到 v 轴', () {
      final t = DisplayTransform.compute(
        imageWidth: 480, imageHeight: 480,   // 方图,排除 aspect 干扰
        viewportWidth: 480, viewportHeight: 480,
        rotationDegrees: 90,
      );
      // (1, 0.5) 绕中心顺时针 90° ⇒ (0.5, 1)
      expectUv(t.apply(1, 0.5), 0.5, 1, tol: 1e-9);
      expectUv(t.apply(0.5, 0), 1, 0.5, tol: 1e-9);
    });

    test('旋转 180° 是对合', () {
      final t = DisplayTransform.compute(
        imageWidth: 480, imageHeight: 480,
        viewportWidth: 480, viewportHeight: 480,
        rotationDegrees: 180,
      );
      expectUv(t.apply(0, 0), 1, 1, tol: 1e-9);
      expectUv(t.apply(1, 1), 0, 0, tol: 1e-9);
    });

    test('镜像只翻 u', () {
      final t = DisplayTransform.compute(
        imageWidth: 480, imageHeight: 480,
        viewportWidth: 480, viewportHeight: 480,
        rotationDegrees: 0, mirrored: true,
      );
      expectUv(t.apply(0, 0.25), 1, 0.25, tol: 1e-9);
    });

    test('坏输入返回恒等而不是 NaN', () {
      final t = DisplayTransform.compute(
        imageWidth: 0, imageHeight: 480,
        viewportWidth: 100, viewportHeight: 100, rotationDegrees: 0);
      expectUv(t.apply(0.3, 0.7), 0.3, 0.7);
    });
  });

  group('列主序输出', () {
    test('toColumnMajor 是行主序的转置', () {
      const t = UvTransform(<double>[1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(t.toColumnMajor(), <double>[1, 4, 7, 2, 5, 8, 3, 6, 9]);
    });
  });
}
