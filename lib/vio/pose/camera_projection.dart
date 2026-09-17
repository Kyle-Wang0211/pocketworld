// camera_projection.dart — 相机内参 → 投影矩阵。纯 Dart,零平台调用,**三端同一份**。
//
// ══ 为什么这一份能跨端 ═══════════════════════════════════════════════════
// 三家厂商各有一个投影矩阵 API:ARKit `projectionMatrixForOrientation:`、
// ARCore `Camera.getProjectionMatrix`、鸿蒙 `HMS_AREngine_ARCamera_
// GetProjectionMatrix`。调它们 = 三份代码 + 绑死三家 AR 运行时。
//
// 但投影矩阵是**可以自己算的** —— 输入只有 fx, fy, cx, cy, 图像尺寸,
// 近远平面。而我们本来就有自己的内参(相机自报 / XRSLAM 标定),不需要
// 任何厂商替我们算。**⇒ 三个 AR API 全都不用调。**
//
// ══ 公式与出处 ═══════════════════════════════════════════════════════════
// 规范形式是 OpenGL `glFrustum`(Khronos 参考页),内参→视锥的桥接:
//
//     left = -near·cx/fx        right  =  near·(W-cx)/fx
//     top  =  near·cy/fy        bottom = -near·(H-cy)/fy
//
// 该桥接经三路独立验证一致到 2.2e-16:glFrustum 代数、OpenXR 的正切形式
// (`OpenXR-SDK-Source/src/common/xr_linear.h:564-566`,**文件内就带
// `SPDX-License-Identifier: Apache-2.0`**,收**四个独立正切**因而能表达
// 任意非居中主点)、以及数值回代。
//
// 🔴 **y 翻转已经编码在"谁进 top、谁进 bottom"里** —— cy 从上往下量
// (OpenCV/ARKit 约定,+y 向下),而 GL 的 +y 向上。若标定是左下原点,
// 交换 top/bottom。不要在别处再翻一次。
//
// ⚰️ **不能抄的**:Kyle Simek 那页(CC BY-NC-SA,**非商业**)、Unity AR
// Foundation(Unity Companion)、`laanlabs/metal-splats`(Inria 非商业)。
// 数学本身不可版权,但他的文字/图/代码不能进商业产品。
//
// ══ 🔑 半像素约定 —— 主动选,不要靠默认 ═════════════════════════════════
// 苹果 SDK 头文件 `ARCamera.h:56-63` 原文:
//     "The origin is at the center of the upper-left pixel."
// (网页文档写的是 "top-left corner",**头文件更精确**。)
// 是**像素中心**约定 ⇒ 图像跨 `[-0.5, W-0.5]` 而不是 `[0, W]`:
//
//     left = -near·(cx+0.5)/fx    right  =  near·(W-0.5-cx)/fx
//     top  =  near·(cy+0.5)/fy    bottom = -near·(H-0.5-cy)/fy
//
// 代价量化(fx=1459):半像素 = 0.0196° ⇒ 1 m 处 0.34 mm、5 m 处 1.71 mm
// 横向配准误差。**压在我们实测的噪声地板下(ARKit ~5.5mm / XRSLAM ~17.8mm),
// 所以不是优先项 —— 但它是系统性偏差,而且改它免费。**
// ⚠️ Gazebo `gz-sensors` 的 `buildProjectionMatrix` 用的是**角**约定
// (`0, _imageWidth`),照抄就继承半像素偏移。这里做成显式参数。
//
// ══ 🔴 中心裁剪必须我们自己修 ═══════════════════════════════════════════
// 两家厂商都只给**传感器系**内参,外加一个**已经烘进裁剪**的显示系投影
// 矩阵,**没有**裁剪修正过的内参:
//   * ARKit `projectionMatrixForOrientation:` 文档原话 "provides an
//     **aspect fill**";而无参的 `ARCamera.projectionMatrix` **不含裁剪** ——
//     两者之差恰好就是裁剪。
//   * ARCore 的 `getImageIntrinsics`/`getTextureIntrinsics` 都标 "unrotated",
//     两者的差别是 CPU 图 vs GPU 纹理分辨率,**不是**屏幕裁剪。
// ⇒ **我们用自己的内参驱动投影,没有任何人会替我们做这件事。**
//
// 正确顺序抄 ROS `image_geometry/src/pinhole_camera_model.cpp:195-208`:
//   **先在全图坐标里减去裁剪原点,再缩放 f 和 c。顺序反了是经典 bug。**
// ⚠️ 该包许可在源头含糊(`package.xml` 同时声明 Apache-2.0 与 BSD,包内
// 无 LICENSE,两个源文件连版权头都没有)⇒ 这里只复刻**顺序**,不抄代码。
//
// ══ Filament 对接 ════════════════════════════════════════════════════════
// 🔴 用 `setProjection(PERSPECTIVE, l, r, b, t, near, far)`,**不要**用
// `setCustomProjection`。前者直接收非对称视锥,而且**同时建两个矩阵** ——
// 有限远的给剔除、无穷远的给渲染(`details/Camera.cpp:129-182`);后者的
// 单矩阵重载是 `setCustomProjection(p, p, ...)`,渲染剔除共用一个,**静默
// 丢掉深度精度那个技巧**。Filament 自己的 AR 样例就是这么错的。
// 所以本文件的主要出口是 [FrustumBounds] 而不是一个 4×4 矩阵。
//
// Filament 公开 API 是 **GL 约定**(`Camera.h:269-270`:"must match the
// OpenGL convention, that is all 3 axis are mapped to [-1, 1]"),反向 Z 与
// Metal 的 [0,1] 深度范围**全在引擎内部处理**。⇒ 我们只出 GL 约定。

import 'dart:math' as math;

/// 针孔内参,像素单位。
class PinholeIntrinsics {
  const PinholeIntrinsics({
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.imageWidth,
    required this.imageHeight,
  });

  final double fx;
  final double fy;

  /// 主点。约定由 [PrincipalPointConvention] 决定,**不要假设**。
  final double cx;
  final double cy;

  final int imageWidth;
  final int imageHeight;

  bool get isUsable =>
      fx.isFinite &&
      fy.isFinite &&
      cx.isFinite &&
      cy.isFinite &&
      fx > 0 &&
      fy > 0 &&
      imageWidth > 0 &&
      imageHeight > 0;

  @override
  String toString() =>
      'K(fx:$fx fy:$fy cx:$cx cy:$cy ${imageWidth}x$imageHeight)';
}

/// 主点坐标的原点约定。**显式选择,不设"聪明"的默认。**
enum PrincipalPointConvention {
  /// 主点从**左上角像素的中心**量起 ⇒ 图像跨 `[-0.5, W-0.5]`。
  /// 苹果 `ARCamera.h:56-63` 明文用的是这个。
  pixelCenter,

  /// 主点从**左上角**量起 ⇒ 图像跨 `[0, W]`。OpenCV 的多数文档、
  /// Gazebo `buildProjectionMatrix` 用的是这个。
  corner,
}

/// 非对称视锥在近平面上的四个边界,眼空间坐标,米。
///
/// 这是交给 Filament `setProjection` 的形状,也是 OpenXR 正切形式的形状
/// (除以 near 即得四个正切)。
class FrustumBounds {
  const FrustumBounds({
    required this.left,
    required this.right,
    required this.bottom,
    required this.top,
    required this.near,
    required this.far,
  });

  final double left;
  final double right;
  final double bottom;
  final double top;
  final double near;
  final double far;

  /// OpenXR `xr_linear.h` 的四正切形式。near 在其中会约掉。
  double get tanLeft => left / near;
  double get tanRight => right / near;
  double get tanBottom => bottom / near;
  double get tanTop => top / near;

  /// 水平总视场角(度)。**两个半角之和**,不是 `2·atan(W/2/fx)`。
  ///
  /// 🔴 上游 XRSLAM 正是在这里错的:`XRSLAM_iOS.mm:121` 硬编码
  /// `2·atan(cy/fy) = 66.13°`,而真实总垂直视场是
  /// `atan(cy/fy) + atan((H-cy)/fy) = 51.95°` —— **27% 误差**,根因就是
  /// 假设主点居中。SceneKit 的 `fieldOfView` 只能表达对称视锥,所以那个
  /// 错误在 SceneKit 里**无法修正**;搬到能收非对称视锥的渲染器才有解。
  double get horizontalFovDegrees =>
      (math.atan(right / near) - math.atan(left / near)) * 180.0 / math.pi;

  double get verticalFovDegrees =>
      (math.atan(top / near) - math.atan(bottom / near)) * 180.0 / math.pi;

  @override
  String toString() => 'Frustum(l:$left r:$right b:$bottom t:$top '
      'n:$near f:$far)';
}

/// 一次中心裁剪/缩放:图像如何被摆进视口。
class ImageCrop {
  const ImageCrop({
    required this.offsetX,
    required this.offsetY,
    required this.width,
    required this.height,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
  });

  /// 裁剪矩形在**全图像素坐标**里的原点。
  final double offsetX;
  final double offsetY;

  /// 裁剪矩形的尺寸,全图像素。
  final double width;
  final double height;

  /// 裁剪之后再施加的缩放(例如降采样)。
  final double scaleX;
  final double scaleY;

  static const ImageCrop none =
      ImageCrop(offsetX: 0, offsetY: 0, width: -1, height: -1);

  bool get isNone => width <= 0 || height <= 0;
}

abstract final class CameraProjection {
  /// 把内参按裁剪修正。
  ///
  /// 顺序**先减后缩**,复刻 ROS `image_geometry` 的顺序(见文件头)。
  /// 反过来先缩放再减偏移是经典 bug:偏移是在全图坐标里量的。
  static PinholeIntrinsics applyCrop(
    PinholeIntrinsics k,
    ImageCrop crop,
  ) {
    if (crop.isNone) return k;
    // 1) 在全图坐标里平移主点。
    final double cxShifted = k.cx - crop.offsetX;
    final double cyShifted = k.cy - crop.offsetY;
    // 2) 然后才缩放,f 与 c 同时缩放。
    return PinholeIntrinsics(
      fx: k.fx * crop.scaleX,
      fy: k.fy * crop.scaleY,
      cx: cxShifted * crop.scaleX,
      cy: cyShifted * crop.scaleY,
      imageWidth: (crop.width * crop.scaleX).round(),
      imageHeight: (crop.height * crop.scaleY).round(),
    );
  }

  /// 为了把一张 [imageWidth]×[imageHeight] 的图**aspect-fill** 进
  /// [viewportWidth]×[viewportHeight] 的视口,需要裁掉什么。
  ///
  /// aspect fill = 放大到铺满,溢出的部分居中裁掉。ARKit 的
  /// `projectionMatrixForOrientation:` 文档原话就是 "provides an aspect
  /// fill for the provided viewport size"。
  ///
  /// 实算过的量级:1920×1440 采集 + 1179×2556 竖屏视口 ⇒ 缩放 1.33125,
  /// 每边裁掉 277.2 px,**短轴视场少约 38%**。这不是细节。
  static ImageCrop aspectFillCrop({
    required int imageWidth,
    required int imageHeight,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    if (imageWidth <= 0 ||
        imageHeight <= 0 ||
        viewportWidth <= 0 ||
        viewportHeight <= 0) {
      return ImageCrop.none;
    }
    final double scale = math.max(
      viewportWidth / imageWidth,
      viewportHeight / imageHeight,
    );
    // 视口在图像坐标里占多大。
    final double visibleW = viewportWidth / scale;
    final double visibleH = viewportHeight / scale;
    return ImageCrop(
      offsetX: (imageWidth - visibleW) / 2.0,
      offsetY: (imageHeight - visibleH) / 2.0,
      width: visibleW,
      height: visibleH,
    );
  }

  /// 内参 → 非对称视锥。**这是交给 Filament `setProjection` 的东西。**
  ///
  /// [convention] 必须显式传;两种约定差半个像素,见文件头的量化。
  static FrustumBounds? frustum(
    PinholeIntrinsics k, {
    required double near,
    required double far,
    required PrincipalPointConvention convention,
  }) {
    if (!k.isUsable) return null;
    if (!(near.isFinite && far.isFinite) || near <= 0 || far <= near) {
      return null;
    }
    // 像素中心约定下图像跨 [-0.5, W-0.5];角约定下跨 [0, W]。
    final double half = convention == PrincipalPointConvention.pixelCenter
        ? 0.5
        : 0.0;
    final double w = k.imageWidth.toDouble();
    final double h = k.imageHeight.toDouble();
    return FrustumBounds(
      left: -near * (k.cx + half) / k.fx,
      right: near * (w - half - k.cx) / k.fx,
      // cy 从上往下量,GL 的 +y 向上 ⇒ 上边界用 cy,下边界用 (H-cy)。
      top: near * (k.cy + half) / k.fy,
      bottom: -near * (h - half - k.cy) / k.fy,
      near: near,
      far: far,
    );
  }

  /// `glFrustum` 的 4×4,**列主序**,GL 约定(三轴都映到 [-1,1])。
  ///
  /// 只在必须交一个矩阵时用(例如某个渲染器没有非对称视锥入口)。
  /// **对 Filament 请用 [frustum] + `setProjection`** —— 见文件头。
  static List<double> glProjectionColumnMajor(FrustumBounds f) {
    final double rl = f.right - f.left;
    final double tb = f.top - f.bottom;
    final double fn = f.far - f.near;
    return <double>[
      2 * f.near / rl, 0, 0, 0, //
      0, 2 * f.near / tb, 0, 0, //
      (f.right + f.left) / rl, (f.top + f.bottom) / tb, -(f.far + f.near) / fn,
      -1, //
      0, 0, -2 * f.far * f.near / fn, 0, //
    ];
  }
}
