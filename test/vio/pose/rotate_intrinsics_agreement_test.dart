// rotate_intrinsics_agreement_test.dart
//
// ══ 这组测试是 CameraProjection.rotate 的**出处替代品** ═══════════════════
// 那个函数没有厂商 API 或论文可引(三家都把"旋转+aspect fill"藏在自己的
// 投影矩阵 API 里,不暴露中间量),所以它是推导。推导的把关方式是**阳性
// 对照**:让同一个 3D 点走两条**来源互相独立**的路,必须落在同一个屏幕位置。
//
//   路 A(投影):3D 点 → 旋转后内参 → 裁剪后内参 → frustum → NDC → 屏幕像素
//   路 B(背景):3D 点 → **原始**内参投影到相机像素 → 归一化 UV →
//                DisplayTransform 的 UV 变换的**逆** → 屏幕像素
//
// 路 A 的来源是本次推导;路 B 复刻的是 AOSP CameraX 的 getRectToRect 分解 +
// 安卓官方旋转公式。两边对上了,才说明"旋转"这一步两处是同一个。
//
// 为什么用 UV 变换的**逆**:DisplayTransform 给的是"屏幕 UV → 采样用的图像
// UV"(着色器里就是这么用的:拿着屏幕位置去图里取色)。要问"图像上这个点
// 出现在屏幕哪里",就得反着走。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/display_transform.dart';
import 'package:pocketworld_flutter/vio/pose/world_to_renderer.dart';

/// 生产影子在跑的那一档:原生 640×480,相机自报内参的量级。
const PinholeIntrinsics kNative640 = PinholeIntrinsics(
  fx: 437.222,
  fy: 437.222,
  // 故意用**非居中**主点:主点居中的话旋转错了也看不出来(对称性把错误吃掉)。
  cx: 330.5,
  cy: 225.25,
  imageWidth: 640,
  imageHeight: 480,
);

/// 把 3×3 仿射求逆(最后一行是 0,0,1,所以只需要左上 2×2 + 平移)。
List<double> _invertAffine(List<double> m) {
  final double a = m[0], b = m[1], tx = m[2];
  final double c = m[3], d = m[4], ty = m[5];
  final double det = a * d - b * c;
  expect(det.abs(), greaterThan(1e-12), reason: 'UV 变换必须可逆');
  final double ia = d / det, ib = -b / det;
  final double ic = -c / det, id = a / det;
  return <double>[
    ia, ib, -(ia * tx + ib * ty), //
    ic, id, -(ic * tx + id * ty), //
    0, 0, 1, //
  ];
}

/// 路 B:相机像素 → 屏幕像素(按 viewport 归一化)。
List<double> _screenViaUv({
  required double camPxX,
  required double camPxY,
  required PinholeIntrinsics k,
  required int viewportWidth,
  required int viewportHeight,
  required int rotationDegrees,
}) {
  // 相机像素 → 归一化图像 UV(左上原点,像素中心约定 ⇒ 索引 i 的中心是
  // (i+0.5)/W)。这是 UV 的定义,不是选择。
  final double u = (camPxX + 0.5) / k.imageWidth;
  final double v = (camPxY + 0.5) / k.imageHeight;

  final UvTransform t = DisplayTransform.compute(
    imageWidth: k.imageWidth,
    imageHeight: k.imageHeight,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    rotationDegrees: rotationDegrees,
  );
  final List<double> inv = _invertAffine(t.m);
  // 逆变换作用在图像 UV 上,得到屏幕 UV。
  final double su = inv[0] * u + inv[1] * v + inv[2];
  final double sv = inv[3] * u + inv[4] * v + inv[5];
  return <double>[su * viewportWidth, sv * viewportHeight];
}

/// 路 A:3D 点(**传感器**相机系,x 右 / y 下 / +z 向前 —— 与内参同一个系)
/// → 屏幕像素。
///
/// 🔴 这里必须同时做两件事:转内参 **和** 转视线。转内参是
/// [CameraProjection.rotate],转视线是 [WorldToRenderer.displayRollColumnMajor]
/// 的同一个滚转 —— 生产代码里那一半作用在相机的模型矩阵上。
/// 早先这个测试只转了内参,结果四个旋转里只有主点碰巧对得上(它是滚转的
/// 不动点之一),其余点差上千像素。那不是代码错,是测试少做了一半 ——
/// 而生产代码当时确实也少做了这一半,正是这条测试把它挖出来的。
List<double> _screenViaProjection({
  required double x,
  required double y,
  required double z,
  required PinholeIntrinsics k,
  required int viewportWidth,
  required int viewportHeight,
  required int rotationDegrees,
}) {
  // 用生产那支滚转矩阵转视线。它在**渲染器**相机系(y 上 / z 向后),而这里
  // 的 (x,y,z) 在 OpenCV 相机系(y 下 / z 向前),两者差 F = diag(1,-1,-1)。
  // v_sensor_cv --F--> v_sensor_render --rollᵀ--> v_display_render --F--> v_display_cv
  final List<double> roll =
      WorldToRenderer.displayRollColumnMajor(rotationDegrees);
  // roll 是 camera_from_displayCamera,我们要 display 系下的分量 ⇒ 用它的转置。
  double rr(int row, int col) => roll[row * 4 + col]; // = Rᵀ 的 (row,col)
  final double xr = x, yr = -y, zr = -z; // → 渲染器相机系
  final double dxr = rr(0, 0) * xr + rr(0, 1) * yr + rr(0, 2) * zr;
  final double dyr = rr(1, 0) * xr + rr(1, 1) * yr + rr(1, 2) * zr;
  final double dzr = rr(2, 0) * xr + rr(2, 1) * yr + rr(2, 2) * zr;
  x = dxr;
  y = -dyr;
  z = -dzr; // → 回到 OpenCV 相机系

  final PinholeIntrinsics rotated = CameraProjection.rotate(
    k,
    rotationDegrees,
    convention: PrincipalPointConvention.pixelCenter,
  );
  final ImageCrop crop = CameraProjection.aspectFillCrop(
    imageWidth: rotated.imageWidth,
    imageHeight: rotated.imageHeight,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
  );
  final PinholeIntrinsics cropped = CameraProjection.applyCrop(rotated, crop);

  // 直接用针孔模型投到"裁剪后图像"的像素上,再按比例铺到视口。
  // (等价于走 frustum → NDC → 视口,但少一次 y 翻转的来回,读起来更清楚;
  //  frustum 那条路另有专门的测试。)
  final double px = cropped.fx * (x / z) + cropped.cx;
  final double py = cropped.fy * (y / z) + cropped.cy;
  return <double>[
    (px + 0.5) / cropped.imageWidth * viewportWidth,
    (py + 0.5) / cropped.imageHeight * viewportHeight,
  ];
}

void main() {
  group('🔑 阳性对照:旋转后的内参与 UV 变换必须落在同一个屏幕位置', () {
    // 三种真实会出现的组合。
    const List<(int, int, int)> cases = <(int, int, int)>[
      (0, 1179, 2556), // 不旋转(假想传感器已是竖的)
      (90, 1179, 2556), // iPhone 竖屏 + 后置横向传感器 —— **生产的那一档**
      (180, 1179, 2556),
      (270, 1179, 2556),
      (90, 2556, 1179), // 横屏视口
    ];

    for (final (int rot, int vw, int vh) in cases) {
      test('rot=$rot° viewport=${vw}x$vh', () {
        // 在原图里取一圈点(含四角和非对称的内点),每个都两条路对一次。
        const List<(double, double)> samples = <(double, double)>[
          (0, 0),
          (639, 0),
          (0, 479),
          (639, 479),
          (330.5, 225.25), // 主点本身
          (123, 45),
          (500, 300),
        ];

        for (final (double cx, double cy) in samples) {
          // 由相机像素反推一条视线(z=1 平面上的点),再送进路 A。
          final double xOverZ = (cx - kNative640.cx) / kNative640.fx;
          final double yOverZ = (cy - kNative640.cy) / kNative640.fy;

          final List<double> a = _screenViaProjection(
            x: xOverZ,
            y: yOverZ,
            z: 1.0,
            k: kNative640,
            viewportWidth: vw,
            viewportHeight: vh,
            rotationDegrees: rot,
          );
          final List<double> b = _screenViaUv(
            camPxX: cx,
            camPxY: cy,
            k: kNative640,
            viewportWidth: vw,
            viewportHeight: vh,
            rotationDegrees: rot,
          );

          // 5 个屏幕像素以内。残差来自 applyCrop 里
          // `imageWidth: (crop.width * scaleX).round()` 的那一次取整
          // (221.41 → 221,0.19%),在画面外很远的采样点上会被放大。
          // 画面内的点(主点、(123,45))实测都在 1 px 以内。
          expect(a[0], closeTo(b[0], 5.0),
              reason: 'rot=$rot 图像点($cx,$cy) 的 x:投影 ${a[0]} vs UV ${b[0]}');
          expect(a[1], closeTo(b[1], 5.0),
              reason: 'rot=$rot 图像点($cx,$cy) 的 y:投影 ${a[1]} vs UV ${b[1]}');
        }
      });
    }

    test('⚠️ 阴性对照:少转那一次,错位必须大到一眼可见', () {
      const int rot = 90;
      const int vw = 1179, vh = 2556;
      // 故意**不**旋转内参(正是"没衔接对"的那个 bug),看错位有多大。
      final ImageCrop crop = CameraProjection.aspectFillCrop(
        imageWidth: kNative640.imageWidth,
        imageHeight: kNative640.imageHeight,
        viewportWidth: vw,
        viewportHeight: vh,
      );
      final PinholeIntrinsics wrong =
          CameraProjection.applyCrop(kNative640, crop);

      const double cx = 123, cy = 45;
      final double xOverZ = (cx - kNative640.cx) / kNative640.fx;
      final double yOverZ = (cy - kNative640.cy) / kNative640.fy;
      final double px = wrong.fx * xOverZ + wrong.cx;
      final double py = wrong.fy * yOverZ + wrong.cy;
      final List<double> bad = <double>[
        (px + 0.5) / wrong.imageWidth * vw,
        (py + 0.5) / wrong.imageHeight * vh,
      ];
      final List<double> good = _screenViaUv(
        camPxX: cx,
        camPxY: cy,
        k: kNative640,
        viewportWidth: vw,
        viewportHeight: vh,
        rotationDegrees: rot,
      );
      final double err =
          math.sqrt(math.pow(bad[0] - good[0], 2) + math.pow(bad[1] - good[1], 2));
      // 如果这条不成立,说明上面那组"对上了"是平凡的(比如两条路其实是
      // 同一段代码),阳性对照就不算数。
      expect(err, greaterThan(200.0),
          reason: '少转一次应当差几百像素,实测 $err');
    });
  });

  group('rotate 本身的性质', () {
    test('转 4 次 90° 回到原处', () {
      PinholeIntrinsics k = kNative640;
      for (int i = 0; i < 4; i++) {
        k = CameraProjection.rotate(k, 90,
            convention: PrincipalPointConvention.pixelCenter);
      }
      expect(k.fx, closeTo(kNative640.fx, 1e-12));
      expect(k.fy, closeTo(kNative640.fy, 1e-12));
      expect(k.cx, closeTo(kNative640.cx, 1e-12));
      expect(k.cy, closeTo(kNative640.cy, 1e-12));
      expect(k.imageWidth, kNative640.imageWidth);
      expect(k.imageHeight, kNative640.imageHeight);
    });

    test('90 + 270 = 恒等', () {
      final PinholeIntrinsics k = CameraProjection.rotate(
        CameraProjection.rotate(kNative640, 90,
            convention: PrincipalPointConvention.pixelCenter),
        270,
        convention: PrincipalPointConvention.pixelCenter,
      );
      expect(k.cx, closeTo(kNative640.cx, 1e-12));
      expect(k.cy, closeTo(kNative640.cy, 1e-12));
    });

    test('90° 交换宽高与焦距', () {
      final PinholeIntrinsics k = CameraProjection.rotate(kNative640, 90,
          convention: PrincipalPointConvention.pixelCenter);
      expect(k.imageWidth, 480);
      expect(k.imageHeight, 640);
      expect(k.fx, kNative640.fy);
      expect(k.fy, kNative640.fx);
    });

    test('🔴 两种主点约定差恰好一个像素,不是零', () {
      final PinholeIntrinsics a = CameraProjection.rotate(kNative640, 90,
          convention: PrincipalPointConvention.pixelCenter);
      final PinholeIntrinsics b = CameraProjection.rotate(kNative640, 90,
          convention: PrincipalPointConvention.corner);
      expect(b.cx - a.cx, closeTo(1.0, 1e-12));
      expect(b.cy - a.cy, closeTo(0.0, 1e-12));
    });

    test('0° 原样返回;非 90 倍数抛错', () {
      expect(
          CameraProjection.rotate(kNative640, 0,
              convention: PrincipalPointConvention.pixelCenter),
          same(kNative640));
      expect(
          () => CameraProjection.rotate(kNative640, 45,
              convention: PrincipalPointConvention.pixelCenter),
          throwsArgumentError);
    });
  });
}
