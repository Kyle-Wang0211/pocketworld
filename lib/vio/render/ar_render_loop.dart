// ar_render_loop.dart — 把相机帧、内参、显示方向、位姿接成一帧渲染。
//
// ══ 这一份是"衔接层",不是新算法 ═══════════════════════════════════════════
// 每一块都已经各自有出处了(见各文件头):
//   * CameraFeedTriangle   ← filament hello-ar FullScreenTriangle.cpp
//   * DisplayTransform     ← AOSP CameraX getRectToRect + 安卓官方旋转公式
//   * CameraProjection     ← glFrustum / OpenXR xr_linear.h / ROS 裁剪顺序
//   * WorldToRenderer      ← 实测重力轴 + OpenXR 坐标系约定
//   * PwCameraSlot         ← 深度 1 保留槽,配对 acquire/release
// 本文件只负责**按正确顺序把它们串起来**,以及把"两条路必须用同一个输入"
// 这条约束落实成代码。
//
// ══ 🔴 "同一个输入"是什么意思 ═════════════════════════════════════════════
// 背景图的 UV 变换和虚拟内容的投影矩阵,必须来自**同一个旋转 + 同一个
// aspect-fill 裁剪**。ARCore 的 `Session.setDisplayGeometry` 文档把这件事
// 写在一句话里:"Sets the aspect ratio, coordinate scaling, and display
// rotation. This data is used by UV conversion, projection matrix generation,
// and hit test logic." —— 一个输入,三个出口。
// 两边不一致的症状是"虚拟内容与视频有固定错位",看起来**像标定不准**,
// 不像少转了一次。所以这里只算一次 [_DisplayGeometry],两边共用。
//
// ══ 帧序 ═════════════════════════════════════════════════════════════════
// 上游 `FilamentApp.cpp:52-56` 的顺序:喂纹理 → 喂 UV 变换 → 设相机模型
// 矩阵 → 设投影 → render。我们照这个顺序,只把 `setCustomProjection` 换成
// `setProjection`(理由见 camera_projection.dart 文件头:前者渲染与剔除
// 共用一个矩阵,静默丢掉深度精度那个技巧)。
//
// ══ 🔴 时间对齐 ═══════════════════════════════════════════════════════════
// 相机帧与位姿必须是**同一时刻**的。Jacobs 等人 I3D 1997
// (`10.1145/253284.253306`)把"流间相对延迟"立为独立的错配源,解法是
// 「在时间上对齐各流」。所以这里**不做**任何位姿外推/预测
// (不抄 OpenXR 的 predictedDisplayTime),而是取与当前帧配对的那个位姿。
// 深度 1 的槽天然给出"最新一帧",位姿源给出"最新一个位姿",两者的配对
// 目前靠时间戳在上游完成 —— 本文件不偷偷补偿。

// 见 camera_feed_triangle.dart 里同样的注释:这一行同时带来 thermion 的
// 类型、dart:typed_data 与 vector_math_64。
import 'package:thermion_flutter/thermion_flutter.dart';

import '../pose/camera_projection.dart';
import '../pose/camera_slot_ffi.dart';
import '../pose/display_transform.dart';
import '../pose/tracked_pose.dart';
import '../pose/world_to_renderer.dart';
import 'camera_feed_triangle.dart';

/// 一帧渲染之后的计账。用来判断"没画出来"到底卡在哪一环。
class ArFrameOutcome {
  const ArFrameOutcome({
    required this.hadFrame,
    required this.hadIntrinsics,
    required this.hadProjection,
    required this.hadPose,
  });

  /// 槽里有没有新帧。连续为 false = 相机没在交付。
  final bool hadFrame;

  /// 相机有没有自报内参。
  final bool hadIntrinsics;

  /// 投影矩阵有没有算出来(内参不可用或 near/far 非法会是 false)。
  final bool hadProjection;

  /// 位姿有没有到位(VALID 位)。为 false 时相机模型矩阵**保持不动**,
  /// 不会被塞一个单位矩阵 —— 见 [WorldToRenderer.viewMatrixColumnMajor]
  /// 里关于"不要编造相机在原点"的说明。
  final bool hadPose;

  @override
  String toString() => 'ArFrame(frame:$hadFrame K:$hadIntrinsics '
      'proj:$hadProjection pose:$hadPose)';
}

/// 一次算出、两边共用的显示几何。
class _DisplayGeometry {
  const _DisplayGeometry({
    required this.rotationDegrees,
    required this.rotatedIntrinsics,
    required this.croppedIntrinsics,
  });

  final int rotationDegrees;

  /// 传感器方向 → 显示方向之后的内参。
  final PinholeIntrinsics rotatedIntrinsics;

  /// 再按 aspect-fill 裁剪之后的内参。**投影矩阵用的是这一个。**
  final PinholeIntrinsics croppedIntrinsics;
}

/// 最小可见回路。
class ArRenderLoop {
  ArRenderLoop._({
    required ThermionViewer viewer,
    required CameraFeedTriangle triangle,
    required this.imageWidth,
    required this.imageHeight,
    required this.sensorOrientationDegrees,
    required this.frontFacing,
    required this.near,
    required this.far,
    required this.principalPointConvention,
  })  : _viewer = viewer,
        _triangle = triangle;

  final ThermionViewer _viewer;
  final CameraFeedTriangle _triangle;

  /// 相机交付帧的尺寸,**传感器方向**。
  final int imageWidth;
  final int imageHeight;

  /// 传感器安装角,顺时针度数。
  ///
  /// 🔴 iOS 没有对应的 API。AVCaptureVideoDataOutput 在不设
  /// `videoRotationAngle` 时交付的是传感器原生方向,后置相机是横向的,
  /// 相当于安卓的 `SENSOR_ORIENTATION = 90`。我们**故意**不在连接层设旋转
  /// (那会让系统替我们旋转像素、还会改内参口径),而是自己算变换 —— 这样
  /// 三端同一条路。安卓/鸿蒙从 `CameraCharacteristics.SENSOR_ORIENTATION`
  /// / 相应属性读真值填进来。
  final int sensorOrientationDegrees;

  final bool frontFacing;

  final double near;
  final double far;

  /// 🔴 必须与内参的来源约定一致。相机自报的内参(iOS
  /// `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`)跟 ARKit 同一套,
  /// 即**像素中心**;见 camera_projection.dart 文件头。
  final PrincipalPointConvention principalPointConvention;

  bool _disposed = false;

  /// 建回路。**不会**打开相机 —— 相机由调用方用 [PwCameraSlot.start] 显式
  /// 打开,因为开摄像头是一件要先告诉用户的事。
  static Future<ArRenderLoop> create(
    ThermionViewer viewer, {
    required Uint8List materialBytes,
    required int imageWidth,
    required int imageHeight,
    int sensorOrientationDegrees = 90,
    bool frontFacing = false,
    double near = 0.01,
    double far = 100.0,
    PrincipalPointConvention principalPointConvention =
        PrincipalPointConvention.pixelCenter,
  }) async {
    final CameraFeedTriangle triangle = await CameraFeedTriangle.create(
      viewer,
      materialBytes: materialBytes,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
    return ArRenderLoop._(
      viewer: viewer,
      triangle: triangle,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      sensorOrientationDegrees: sensorOrientationDegrees,
      frontFacing: frontFacing,
      near: near,
      far: far,
      principalPointConvention: principalPointConvention,
    );
  }

  /// 算一次显示几何。UV 变换与投影矩阵都从这里出,**保证同源**。
  _DisplayGeometry? _geometry({
    required PinholeIntrinsics? intrinsics,
    required ScreenRotation displayRotation,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    final int rot = DisplayTransform.cameraToDisplayRotation(
      sensorOrientationDegrees: sensorOrientationDegrees,
      displayRotation: displayRotation,
      frontFacing: frontFacing,
    );
    if (intrinsics == null) {
      return _DisplayGeometry(
        rotationDegrees: rot,
        rotatedIntrinsics: const PinholeIntrinsics(
            fx: 0, fy: 0, cx: 0, cy: 0, imageWidth: 0, imageHeight: 0),
        croppedIntrinsics: const PinholeIntrinsics(
            fx: 0, fy: 0, cx: 0, cy: 0, imageWidth: 0, imageHeight: 0),
      );
    }

    // 1) 传感器方向 → 显示方向。
    final PinholeIntrinsics rotated = CameraProjection.rotate(
      intrinsics,
      rot,
      convention: principalPointConvention,
    );

    // 2) aspect-fill:铺满视口,溢出居中裁掉。
    //    🔴 必须在**旋转之后**的坐标里算 —— DisplayTransform.compute 里的
    //    那一半也是在旋转之后的尺寸上算的(它用 rotatedW/rotatedH)。
    //    在旋转前算就是两边用了不同的裁剪,错位。
    final ImageCrop crop = CameraProjection.aspectFillCrop(
      imageWidth: rotated.imageWidth,
      imageHeight: rotated.imageHeight,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );

    return _DisplayGeometry(
      rotationDegrees: rot,
      rotatedIntrinsics: rotated,
      croppedIntrinsics: CameraProjection.applyCrop(rotated, crop),
    );
  }

  /// 走一帧。
  ///
  /// [pose] 为 `null` 或未跟踪时,相机模型矩阵**保持上一次的值**。
  Future<ArFrameOutcome> step({
    required int viewportWidth,
    required int viewportHeight,
    required ScreenRotation displayRotation,
    TrackedPose? pose,
  }) async {
    if (_disposed) {
      return const ArFrameOutcome(
        hadFrame: false,
        hadIntrinsics: false,
        hadProjection: false,
        hadPose: false,
      );
    }

    // ── 1. 喂纹理 ──────────────────────────────────────────────────────────
    // 🔴 必须走 withFrameAsync:setExternalImage 是异步的(排到渲染线程),
    // 同步版会在 Filament 自己 retain 之前就把缓冲还掉。
    final bool? fed = await PwCameraSlot.withFrameAsync<bool>((int addr) async {
      await _triangle.setFrame(addr);
      return true;
    });
    final bool hadFrame = fed == true;

    // ── 2. 内参 → 显示几何 ─────────────────────────────────────────────────
    // 🔴 每帧重取。自动对焦全程在动,台架实测单场 120 s fx 漂 10.90%
    // (426.842 → 476.037)。缓存一次等于把第 0 帧的焦距冻住 —— 那正是台架
    // 上追了一天的那笔账。
    final PinholeIntrinsics? k = PwCameraSlot.intrinsics(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
    final _DisplayGeometry? geom = _geometry(
      intrinsics: k,
      displayRotation: displayRotation,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );

    // ── 3. UV 变换 ────────────────────────────────────────────────────────
    if (geom != null) {
      await _triangle.setTransform(DisplayTransform.compute(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        rotationDegrees: geom.rotationDegrees,
        mirrored: frontFacing,
      ));
    }

    // ── 4. 投影 ───────────────────────────────────────────────────────────
    bool hadProjection = false;
    if (k != null && geom != null) {
      final FrustumBounds? f = CameraProjection.frustum(
        geom.croppedIntrinsics,
        near: near,
        far: far,
        convention: principalPointConvention,
      );
      if (f != null) {
        final Camera camera = await _viewer.getActiveCamera();
        // 🔴 setProjection,不是 setCustomProjection。前者同时建"无穷远的
        // 渲染矩阵 + 有限远的剔除矩阵"(details/Camera.cpp:129-182);
        // 后者单矩阵重载两边共用,静默丢掉深度精度。上游样例就是那么错的。
        await camera.setProjection(
          Projection.Perspective,
          f.left,
          f.right,
          f.bottom,
          f.top,
          f.near,
          f.far,
        );
        hadProjection = true;
      }
    }

    // ── 5. 位姿 ───────────────────────────────────────────────────────────
    bool hadPose = false;
    if (pose != null) {
      final List<double>? model =
          WorldToRenderer.modelMatrixColumnMajor(pose);
      if (model != null) {
        final Camera camera = await _viewer.getActiveCamera();
        // 🔴 位姿也必须绕光轴滚过去,和投影矩阵那一半配对。
        // 投影用的是**旋转过的**内参(第 4 步的 geom.croppedIntrinsics),
        // 那等价于"相机绕光轴转了 rotationDegrees"。只转内参不转位姿,
        // 背景是正的而虚拟内容整体歪 90° —— 两边各自都对,合起来错。
        // 推导与阳性对照见 WorldToRenderer.displayRollColumnMajor。
        final List<double> rolled = geom == null
            ? model
            : WorldToRenderer.multiplyColumnMajor(
                model,
                WorldToRenderer.displayRollColumnMajor(geom.rotationDegrees),
              );
        // 🔴 setModelMatrix 收的是 world_from_camera,不是视图矩阵。
        // 两者差一次求逆,而且搞反了**不会崩、跟踪看起来也正常**,只是内容
        // 朝反方向动(上游 PR #70 那一类)。
        await camera.setModelMatrix(Matrix4.fromList(rolled));
        hadPose = true;
      }
    }

    // ── 6. 出图 ───────────────────────────────────────────────────────────
    await _viewer.render();

    return ArFrameOutcome(
      hadFrame: hadFrame,
      hadIntrinsics: k != null,
      hadProjection: hadProjection,
      hadPose: hadPose,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _triangle.destroy();
  }
}
