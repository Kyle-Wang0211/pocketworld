// display_transform.dart — 相机图像 → 屏幕的 UV 变换。纯 Dart,零平台调用,
// **三端同一份**。
//
// ══ 这一份存在的全部理由 ═══════════════════════════════════════════════════
// 三家厂商各有一个 API 干这件事:
//   * ARKit  `ARFrame.displayTransform(for:viewportSize:)`
//   * ARCore `Frame.transformCoordinates2d(OPENGL_NDC → TEXTURE_NORMALIZED)`
//   * 鸿蒙   `HMS_AREngine_ARFrame_TransformDisplayUvCoords`(**只有 C/NDK
//            有,ArkTS 侧不存在** —— ArkTS 的 `ARView` 替你合成,拿不到纹理)
//
// 调它们 = 三份代码 + 绑死三家 AR 运行时 + 继承它们各自的坑。而这个变换是
// **纯几何**:输入只有传感器朝向、屏幕旋转、图像尺寸、视口尺寸,外加一条
// aspect-fill 规则。自己算,三个 API 全都不用调。
//
// ⚠️ 顺带绕开三个已证实的坑:
//   1. **ARKit 那两个 API 在 iOS 27 已弃用**,替代者要求先设
//      `ARSession.viewLayer`,而我们写自定义渲染器、不用 `ARSCNView` ⇒
//      不自己设就永久拿不到。自己算的话这条迁移债根本不存在。
//   2. **ARCore `DisplayRotationHelper:137`** 的
//      `(sensorOrientation − displayOrientation + 360) % 360` 与安卓官方公式
//      在 ROTATION_90/270 上**差 180°**。奇偶性一致所以它自己用没错,但
//      **不能直接拿去做图像旋转**。
//   3. **华为自己的样例 `app_util.h:125-138` 把 90↔270 映反了**。照抄就是
//      横屏背景倒 180°。
//
// ══ 公式出处 ═══════════════════════════════════════════════════════════════
// 复刻 AOSP CameraX 的分解(**Apache-2.0**,逐文件许可头已核):
//   `camera/camera-core/src/main/java/androidx/camera/core/impl/utils/
//    TransformUtils.java:351-364` 的 `getRectToRect(source, target,
//    rotationDegrees, mirroring)`:源矩形 → 归一化矩形 `(-1,-1)-(1,1)` →
//   `postRotate` → 可选 `postScale(-1,1)` 镜像 → `postConcat` 到目标。
//   以及 `camera-view/.../PreviewTransformation.java:288-306`(用
//   `TransformationInfo.getCropRect()` + `getRotationDegrees()` 组装)。
// 旋转那一半的规范出处是安卓官方 camera2 预览文档的 "Orientation calculation":
//   `rotation = (sensorOrientationDegrees − deviceOrientationDegrees·sign
//                + 360) % 360`,`sign` 前置摄像头 +1、后置 −1。
// 🔴 **aspect-fill 那一半全球没有规范表述**。最接近的是 ARCore
//   `Session.setDisplayGeometry` 的一句:"Sets the aspect ratio, coordinate
//   scaling, and display rotation. This data is used by UV conversion,
//   projection matrix generation, and hit test logic." —— 注意它把 **UV 变换、
//   投影矩阵、hit test 绑在同一个输入上**,这正是本文件与
//   `camera_projection.dart` 必须用**同一个** crop 的原因。
//
// ⚰️ **不能抄**:Unity AR Foundation 的 `displayMatrix`(Unity Companion
// License,仅限 Unity 项目)。它是唯一把三家统一起来的实现,但许可不可用 ——
// 而且它为了统一**改了 ARCore 那一侧**(6.0.0-pre.5 改成行主序并折进 y 翻转),
// 这本身就是"三家原生约定并不相同"的直接证据。
//
// ══ 输出约定 ═══════════════════════════════════════════════════════════════
// 输出一个 3×3,作用在**归一化图像 UV**(左上原点,与 ARKit 一致 ——
// `ARCamera.h:111/:120` 明文 "origin at top-left")上,得到**采样用的 UV**。
// 这与 Filament AR 样例的形状一致:`camera_feed.mat:24`
//   `material.uv0 = (materialParams.textureTransform * float3(material.uv0,
//   1.0)).rg;`
// 🔴 材质必须设 `flipUV: false`(Filament 默认 `true`,会再翻一次 y)。

import 'dart:math' as math;

/// 屏幕旋转,顺时针度数。三端的原始值单位不同,在入口统一:
///   * iOS   `UIInterfaceOrientation`
///   * 安卓  `Display.getRotation()` 是**索引** 0/1/2/3
///   * 鸿蒙  `display.rotation` 也是**索引** 0/1/2/3,而
///           `camera.ImageRotation` 却是**度数** 0/90/180/270 —— 这两个在
///           鸿蒙里混用是实打实的集成陷阱。
enum ScreenRotation {
  degrees0(0),
  degrees90(90),
  degrees180(180),
  degrees270(270);

  const ScreenRotation(this.degrees);
  final int degrees;

  /// 从安卓/鸿蒙的 0/1/2/3 索引来。
  static ScreenRotation fromIndex(int i) => switch (i & 3) {
        0 => ScreenRotation.degrees0,
        1 => ScreenRotation.degrees90,
        2 => ScreenRotation.degrees180,
        _ => ScreenRotation.degrees270,
      };
}

/// 3×3 仿射,行主序存放,作用于列向量 `(u, v, 1)`。
///
/// 🔴 交给 Filament 时要按**列主序**填 `mat3f`。`CGAffineTransform` 的
/// `[a b; c d; tx ty]` 恰好就是列主序,所以从它转过去不需要转置 ——
/// 这一点 Filament 的 AR 样例利用了,但换个来源就不成立,所以本类型
/// 显式提供 [toColumnMajor]。
class UvTransform {
  const UvTransform(this.m);

  /// 行主序 9 个元素:`[m00 m01 m02, m10 m11 m12, m20 m21 m22]`。
  final List<double> m;

  static const UvTransform identity = UvTransform(<double>[
    1, 0, 0, //
    0, 1, 0, //
    0, 0, 1, //
  ]);

  /// 作用在一个 UV 上。
  List<double> apply(double u, double v) => <double>[
        m[0] * u + m[1] * v + m[2],
        m[3] * u + m[4] * v + m[5],
      ];

  /// 列主序,给 `mat3f`。
  List<double> toColumnMajor() => <double>[
        m[0], m[3], m[6], //
        m[1], m[4], m[7], //
        m[2], m[5], m[8], //
      ];

  UvTransform multiply(UvTransform o) {
    final List<double> r = List<double>.filled(9, 0);
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        double s = 0;
        for (int k = 0; k < 3; k++) {
          s += m[i * 3 + k] * o.m[k * 3 + j];
        }
        r[i * 3 + j] = s;
      }
    }
    return UvTransform(r);
  }

  @override
  String toString() => 'UvTransform(${m.map((double x) => x.toStringAsFixed(4))})';
}

abstract final class DisplayTransform {
  /// 相机相对显示的旋转,度数,顺时针。
  ///
  /// 复刻安卓官方 camera2 预览文档的 "Orientation calculation":
  ///   `(sensorOrientation − displayRotation·sign + 360) % 360`
  /// [frontFacing] 为真时 `sign = +1`,否则 `−1`。
  ///
  /// 🔴 **这与 ARCore `DisplayRotationHelper:137` 不是同一个函数** ——
  /// 后者写的是 `(sensor − display + 360) % 360`,在 ROTATION_90/270 上与
  /// 本式差 180°。它对它自己的用法(只取奇偶)是对的,但**拿来转图像是错的**。
  /// 本文件按官方公式实现。
  static int cameraToDisplayRotation({
    required int sensorOrientationDegrees,
    required ScreenRotation displayRotation,
    required bool frontFacing,
  }) {
    final int sign = frontFacing ? 1 : -1;
    return (sensorOrientationDegrees - displayRotation.degrees * sign + 360) %
        360;
  }

  /// 完整的 UV 变换。
  ///
  /// [imageWidth]/[imageHeight] 是**未旋转**的相机图像尺寸(传感器方向)。
  /// [viewportWidth]/[viewportHeight] 是屏幕上的绘制区域。
  ///
  /// 步骤,与 CameraX 的分解一一对应:
  ///   1. UV `[0,1]²` → 居中归一化 `[-1,1]²`
  ///   2. 旋转 [rotationDegrees](把传感器方向转到显示方向)
  ///   3. aspect-fill 缩放:放大到铺满视口,溢出居中裁掉
  ///   4. 可选镜像(前置摄像头)
  ///   5. 回到 `[0,1]²`
  ///
  /// 🔴 第 3 步必须与 `CameraProjection.aspectFillCrop` 用**同一条规则** ——
  /// 背景裁掉多少,投影矩阵就得少看多少。两者不一致 = 虚拟内容与视频错位,
  /// 而且错得像"标定不准"。ARCore 的 `setDisplayGeometry` 文档把 UV 变换、
  /// 投影矩阵、hit test 绑在同一个输入上,就是这个道理。
  static UvTransform compute({
    required int imageWidth,
    required int imageHeight,
    required int viewportWidth,
    required int viewportHeight,
    required int rotationDegrees,
    bool mirrored = false,
  }) {
    if (imageWidth <= 0 ||
        imageHeight <= 0 ||
        viewportWidth <= 0 ||
        viewportHeight <= 0) {
      return UvTransform.identity;
    }
    final int rot = ((rotationDegrees % 360) + 360) % 360;

    // 旋转后图像在显示方向上的尺寸。
    final bool swapped = rot == 90 || rot == 270;
    final double rotatedW = (swapped ? imageHeight : imageWidth).toDouble();
    final double rotatedH = (swapped ? imageWidth : imageHeight).toDouble();

    // aspect fill:放大到铺满,取较大的那个比例。
    final double scale = math.max(
      viewportWidth / rotatedW,
      viewportHeight / rotatedH,
    );
    // 视口在旋转后图像坐标里占的比例(≤1,溢出的被裁掉)。
    final double visibleFracX = (viewportWidth / scale) / rotatedW;
    final double visibleFracY = (viewportHeight / scale) / rotatedH;

    // 1) [0,1] -> [-1,1],中心为原点。
    UvTransform t = const UvTransform(<double>[
      2, 0, -1, //
      0, 2, -1, //
      0, 0, 1, //
    ]);

    // 2) 旋转。顺时针 rot 度作用在 y 向下的坐标系上。
    final double c = math.cos(rot * math.pi / 180.0);
    final double s = math.sin(rot * math.pi / 180.0);
    t = UvTransform(<double>[
      c, -s, 0, //
      s, c, 0, //
      0, 0, 1, //
    ]).multiply(t);

    // 3) aspect-fill 裁剪:只保留可见比例。
    t = UvTransform(<double>[
      visibleFracX, 0, 0, //
      0, visibleFracY, 0, //
      0, 0, 1, //
    ]).multiply(t);

    // 4) 镜像。
    if (mirrored) {
      t = const UvTransform(<double>[
        -1, 0, 0, //
        0, 1, 0, //
        0, 0, 1, //
      ]).multiply(t);
    }

    // 5) [-1,1] -> [0,1]。
    t = const UvTransform(<double>[
      0.5, 0, 0.5, //
      0, 0.5, 0.5, //
      0, 0, 1, //
    ]).multiply(t);

    return t;
  }
}
