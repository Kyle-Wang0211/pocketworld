// world_to_renderer.dart — 引擎世界系(z 向上) → 渲染器世界系(y 向上)。
// 纯 Dart,零 Flutter 依赖,**与具体渲染器无关** —— 三端同一份。
//
// ══ 这个换轴是**实测判死**的,不是抄来的,也不是推的 ═════════════════════
//
// 判据:比力 = −重力。把每一帧的位姿旋转作用到同时刻的加速度计读数上,
// 转到世界系,平均。它落在哪个轴,那个轴就是"上"。
//
// 语料:`run-eb74a545`(原生 640×480 录制,120 s,3584 帧零丢帧)的
// `imu.csv` + 同一份录制的确定性回放 `poses.tum`。**3543/3543 帧全部配上**:
//
//     世界系平均比力 = (+0.0325, −0.0134, +9.7441) m/s²
//     模长 9.7442   (标称重力 9.80665,差 0.6%)
//     次强轴 / 主导轴 = 0.33%
//
// ⇒ 主导轴 +z,比力 = −重力 ⇒ 重力指向 −z ⇒ **引擎世界系 z 轴向上**。
//
// ══ 🔴 上游那个换轴是错的,不能抄 ═══════════════════════════════════════
//
// `xrslam-ios/visualizer/src/XRSLAM_iOS.mm:212-220` 硬编码
// `(x,y,z) → (−y,−x,−z)`。把实测的"上"方向送进去,落在 **−z**:
//
//     上游映射   (+0.0325,−0.0134,+9.7441) → (+0.013, −0.033, −9.744)
//                                              主导轴 −z ⇒ 上被映射成了"前"
//
// 它是个合法旋转(det=+1),但它把"上"送到了渲染器的前方。我们生产的
// `PwVioSlamFeeder.swift:2224-2234` 抄的正是这一版(标签
// `official_scene_kit_ios`)。今天它只喂遥测,所以没出事;**一旦有人把它
// 接上渲染,内容会整体倒 90°**。
//
// ══ 偏航(yaw)一律不烘进常数 ═══════════════════════════════════════════
//
// 我们记忆里另有一个"实测 SE(3) 拟合"的映射 `(−y, +z, −x)`,它**也**把上
// 映射到上 —— 它和下面这个正解只差**一个绕"上"轴的偏航**。
//
// 而偏航在 VIO 里**恰好是不可观的**:GVINS(arXiv:2103.07899)给出不可观
// 方向恰好 4 个 —— x, y, z, **yaw**;roll/pitch 可观正是因为加速度计观测
// 得到重力。所以那个拟合里的偏航是**那一场相对 ARKit 的任意值**,把它固化
// 成常数等于把一次会话的偶然量写进代码。
//
// ⇒ 本文件只做**重力对齐的那两个自由度**。任何偏航对齐必须是显式的、
//   按会话的、单独一步,不属于这里。
//
// ══ 🔴 [pw 2026-09-22 换轴统一] 本文件的 `zUpToYUp` 改口径:台架/探针专用 ══
//
// 仓里长期并存两条**互相独立**的「引擎系 z-up → y-up」换轴:
//
//   (1) `xrslam_world_axis.dart`  `x_A=−y_X, y_A=+z_X, z_A=−x_X`
//       —— 09-16 共享录制对 ARKit 做 SE(3) 拟合的实测置换;
//   (2) 本文件 `zUpToYUp`         绕 X 轴 −90°,`(x,y,z)→(x,z,−y)`
//       —— 上面那段实测重力轴判死的最小旋转。
//
// 两者都把引擎的上 `(0,0,1)` 送到 y-up 的上 `(0,1,0)`,差的**只是一个绕竖轴
// 的偏航**,而且这个偏航是**算得出来的**,不是"大概差一点":
//
//     D = M₁ · M₂ᵀ = | 0 0  1 |
//                    | 0 1  0 |   = Ry(+90°)
//                    |−1 0  0 |
//
// (逐元素算式与断言见 `test/zero_arkit_axis_unify_test.dart`。验算:引擎的
//  `+x` 经 (2) 落到 renderer 的 `+x`,经 (1) 落到 ARKit 的 `−z`;
//  Ry(+90°) 把 `+x` 送到 `−z` ✓。)
//
// 偏航在 VIO 里不可观(上一段 GVINS),所以"哪个偏航对"**没有物理答案**;
// 但两条必须一致,否则把按 `ARPose` 摆的东西(照片卡片、点云)画进 Filament
// 预览时,会整体绕竖轴转 90°,看起来像标定错。
//
// ⇒ **定案:生产路径以 `xrslam_world_axis.dart` 为唯一换轴**(它的消费者
//   最多:dome 的 az/el、`gravity_align`、落盘的 `arkit_extrinsic_4x4`;而且
//   `VioArPoseProvider.lockOrigin` 本来就会按会话重锚偏航 `_worldYaw`,
//   固化在它里面的那个偏航只是"约定",不是"真值")。
// ⇒ 本文件的 `zUpToYUp` **保留给台架页 / 探针页**:它们喂的是**引擎系**的
//   `TrackedPose`,手上根本没有 `ARPose`,这条路仍然需要一个自洽的换轴。
//   **生产预览不再走它** —— 见 [PoseFrame] 与 `ArRenderLoop.step` 的
//   `poseFrame` 参数。
//
// ══ 渲染器约定(三家一致,所以这一份能跨端)═════════════════════════════
// OpenXR 规范(fundamentals.adoc:1240-1252):"This API uses a Cartesian
// right-handed coordinate system",VIEW 空间 "+Y up, +X to the right, and
// −Z forward"。SceneKit 与 Filament 同一约定。Unity 是左手系,需要**额外**
// 的手性翻转,不在本文件内(需要时另写,别混进来)。

import 'tracked_pose.dart';

/// 一个 [TrackedPose] **已经在哪个世界系里**。
///
/// 🔴 它存在的唯一理由是:**同一份位姿绝不能被换两次轴**。换两次不会抛、
/// 不会崩、跟踪看起来也完全正常,只是内容整体歪掉 —— 与上游 PR #70
/// 「外参被应用了两次」同一类故障。把"这份位姿在哪个系"做成显式参数,
/// 双换就变成一个能在单测里检出的事实(阴性对照见
/// `test/zero_arkit_axis_unify_test.dart`)。
enum PoseFrame {
  /// 引擎世界系(XRSLAM,z 向上),**未换轴**。
  ///
  /// 台架页 `ar_minimal_loop_page.dart` 与探针页喂的就是这一档 ——
  /// 它们直接读 `VioPoseSource` 的输出,手上没有 `ARPose`。
  /// 这一档会在本文件里走 [WorldToRenderer.zUpToYUp]。
  engineZUp,

  /// **已经是 y 向上的渲染器世界系**,不要再换。
  ///
  /// 生产路径喂这一档:`VioArPoseProvider` 已按 `xrslam_world_axis.dart`
  /// 换过一次(同一次换算同时供给 `ARPose.position/orientation/extrinsic4x4`),
  /// 渲染器直接用那份结果。ARKit 世界系与 OpenXR/Filament 的渲染器世界系
  /// 是同一套约定(右手、y 上、相机看 −z),所以这一档不需要任何再换算。
  rendererYUp,
}

/// 引擎世界系 ↔ 渲染器世界系。
abstract final class WorldToRenderer {
  /// 绕 X 轴 −90°:`(x, y, z)_world → (x, z, −y)_renderer`。
  ///
  /// 验证:world 的上 `(0,0,1)` → renderer `(0,1,0)`,正是 renderer 的上。
  /// det = +1(真旋转,不是镜像 —— 两边都是右手系,不存在手性翻转)。
  ///
  /// 这是把 z-up 送成 y-up 的**最小**旋转:它不动 x 轴,因此不引入任何偏航。
  static const List<List<double>> zUpToYUp = <List<double>>[
    <double>[1, 0, 0],
    <double>[0, 0, 1],
    <double>[0, -1, 0],
  ];

  /// 对应的四元数,分量顺序 [x, y, z, w]。绕 X 转 −90° ⇒
  /// `(sin(−45°), 0, 0, cos(−45°))`。
  static const double _s = -0.7071067811865476; // sin(-45°)
  static const double _c = 0.7071067811865476; //  cos(-45°)
  static const PoseQuaternion zUpToYUpQuaternion = PoseQuaternion(_s, 0, 0, _c);

  /// 把一个世界系方向/位置转到渲染器世界系。
  static List<double> convertVector(List<double> v) => <double>[
        zUpToYUp[0][0] * v[0] + zUpToYUp[0][1] * v[1] + zUpToYUp[0][2] * v[2],
        zUpToYUp[1][0] * v[0] + zUpToYUp[1][1] * v[1] + zUpToYUp[1][2] * v[2],
        zUpToYUp[2][0] * v[0] + zUpToYUp[2][1] * v[1] + zUpToYUp[2][2] * v[2],
      ];

  /// 把位姿的旋转转到渲染器世界系:`q' = c ⊗ q`。
  ///
  /// 🔴 注意这里是**左乘**,不是共轭 `c ⊗ q ⊗ c⁻¹`。位姿的四元数表示的是
  /// world_from_body;换世界系只改左边那个系,所以只左乘一次。上游那段之所以
  /// 能用"对分量做同一个置换"蒙混过去,是因为它那个映射恰好是 180° 对合;
  /// 我们这个是 90°,**不是对合**,照抄分量置换会错。
  static PoseQuaternion convertRotation(PoseQuaternion q) {
    const PoseQuaternion c = zUpToYUpQuaternion;
    return PoseQuaternion(
      c.w * q.x + c.x * q.w + c.y * q.z - c.z * q.y,
      c.w * q.y - c.x * q.z + c.y * q.w + c.z * q.x,
      c.w * q.z + c.x * q.y - c.y * q.x + c.z * q.w,
      c.w * q.w - c.x * q.x - c.y * q.y - c.z * q.z,
    );
  }

  /// **world_from_camera**,4×4 列主序 —— 这是 Filament `Camera::setModelMatrix`
  /// 要的那个,**不是**视图矩阵。
  ///
  /// 🔴 两者差一次求逆,而且搞反了**不会崩、跟踪看起来也正常**,只是内容
  /// 朝反方向动 —— 正是上游 PR #70「虚拟物体反向滑走」那一类故障(那次
  /// 的根因是外参被应用了两次,症状同样是跟踪完全正常)。所以这里把两个
  /// 出口都提供、各自写明收方,而不是只给一个让调用方自己猜。
  ///
  /// 依据:Google 自己的跨端 AR 帧契约
  /// `google-ar/jetpack-xr-natives` `impress/core/ar/ar_frame.h`(Apache-2.0,
  /// © 2024 Google LLC)携带的是 `model_matrix`,注释原文
  /// *"The model matrix to use for placing the virtual camera."*
  /// 而 Filament 的 AR 样例也是 `camera->setModelMatrix(frame.view)`,传进去
  /// 的是 ARKit 的 `frame.camera.transform`,即 world-from-camera。
  ///
  /// 返回 `null` 的条件与 [viewMatrixColumnMajor] 相同,理由也相同。
  ///
  /// [frame] 说明传进来的 [pose] **已经在哪个系里**:默认
  /// [PoseFrame.engineZUp](台架/探针的既有口径,零改动);
  /// 传 [PoseFrame.rendererYUp] 时本函数**一次换轴都不做**,只把四元数
  /// 归一化后铺成矩阵 —— 生产路径的换轴已经在 `xrslam_world_axis.dart`
  /// 里做过了,再做一次就是双换。
  static List<double>? modelMatrixColumnMajor(
    TrackedPose pose, {
    PoseFrame frame = PoseFrame.engineZUp,
  }) {
    final PoseQuaternion? q = pose.orientation;
    final PosePosition? p = pose.position;
    if (q == null || p == null) return null;

    final PoseQuaternion r = _toRenderer(q, frame);
    final List<double> t = _toRendererVector(<double>[p.x, p.y, p.z], frame);

    final double x = r.x, y = r.y, z = r.z, w = r.w;
    return <double>[
      1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0, //
      2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0, //
      2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0, //
      t[0], t[1], t[2], 1, //
    ];
  }

  /// 绕光轴的滚转:**camera_from_displayCamera**,4×4 列主序,渲染器约定。
  ///
  /// ══ 它是 `CameraProjection.rotate` 的另一半,两个必须同时用 ═══════════
  /// 把相机图像旋转 [degrees]° 显示,等价于**绕光轴旋转了相机**。所以除了
  /// 把内参转过去(那一半给投影矩阵),位姿也得跟着转 —— 否则背景是正的、
  /// 虚拟内容整体歪 90°。只做一半是"没衔接对"的典型:两边各自都对,合起来错。
  ///
  /// 用法(右乘,因为它是**相机系内部**的换基):
  ///     world_from_displayCamera = world_from_camera · camera_from_displayCamera
  ///
  /// ══ 推导 ═════════════════════════════════════════════════════════════
  /// 从像素映射推。顺时针 90° 是 `(x,y) → (H-1-y, x)`,代进针孔模型
  /// (a = X/Z,b = Y/Z,y 向下):
  ///     x' = (H-1) - (fy·b + cy) = fy·(−b) + ((H-1)−cy)
  ///     y' =         fx·a + cx
  /// 也就是显示系的视线分量 `(a', b') = (−b, a)`,即
  /// **OpenCV 相机系**(x 右,y 下,z 前)里
  ///     v_display = M · v_sensor,  M(90) = [[0,−1,0],[1,0,0],[0,0,1]]
  /// 我们要的是反过来的换基,即 Mᵀ。
  ///
  /// 再换到**渲染器相机系**(x 右,y **上**,z **向后** —— OpenXR
  /// `fundamentals.adoc:1240-1252`,Filament 同):两者差 `F = diag(1,−1,−1)`,
  /// 且 F⁻¹ = F,所以 `R_render = F · Mᵀ · F`。逐个算完 90/180/270,结果
  /// 收敛成一个很干净的形式:
  ///
  ///     R_render(θ) = Rz(θ)   —— 绕 z 轴转 θ,右手系。
  ///
  /// (90° 验算:F·Mᵀ·F = [[0,−1,0],[1,0,0],[0,0,1]] = Rz(90) ✓;
  ///  270° 验算:= [[0,1,0],[−1,0,0],[0,0,1]] = Rz(270) ✓。)
  ///
  /// 🔴 出处口径:与 `CameraProjection.rotate` 一样,这是**推导**不是引用。
  /// 把关靠 test/vio/pose/rotate_intrinsics_agreement_test.dart 那组阳性对照。
  ///
  /// 🔴 这**不是**那个 OpenCV↔渲染器的相机约定翻转(`diag(1,−1,−1)` 本身)。
  /// 那一项取决于喂进来的位姿是 body 系还是相机系,是另一笔单独的账,见
  /// [viewMatrixColumnMajor] 里的说明 —— 别把两件事混成一次乘法。
  static List<double> displayRollColumnMajor(int degrees) {
    final int rot = ((degrees % 360) + 360) % 360;
    final double c = switch (rot) { 0 => 1, 90 => 0, 180 => -1, 270 => 0, _ => double.nan };
    final double s = switch (rot) { 0 => 0, 90 => 1, 180 => 0, 270 => -1, _ => double.nan };
    if (c.isNaN) {
      throw ArgumentError.value(
          degrees, 'degrees', '只支持 0/90/180/270,收到 $degrees');
    }
    // Rz(θ) 行主序是 [[c,-s,0],[s,c,0],[0,0,1]];列主序按列连续存放。
    return <double>[
      c, s, 0, 0, //
      -s, c, 0, 0, //
      0, 0, 1, 0, //
      0, 0, 0, 1, //
    ];
  }

  /// 两个 4×4 列主序相乘:`a · b`。
  static List<double> multiplyColumnMajor(List<double> a, List<double> b) {
    final List<double> out = List<double>.filled(16, 0);
    for (int col = 0; col < 4; col++) {
      for (int row = 0; row < 4; row++) {
        double sum = 0;
        for (int k = 0; k < 4; k++) {
          // 列主序:元素 (row, k) 在 a[k*4 + row]。
          sum += a[k * 4 + row] * b[col * 4 + k];
        }
        out[col * 4 + row] = sum;
      }
    }
    return out;
  }

  /// 视图矩阵 = camera_from_world,4×4 **列主序**(`Matrix4` 的存储顺序,
  /// 也是 Filament / OpenGL / Metal 的惯例)。
  ///
  /// 返回 `null` 的情形,以及为什么不返回单位矩阵:
  ///   * 位置 VALID 位未置(3DOF 一档)。**视图矩阵需要平移** —— 只有朝向时
  ///     交出一个平移为零的视图矩阵,等价于宣称"相机在世界原点",那是编造。
  ///     3DOF 的正确用法是只驱动**朝向**(天空盒/全景那一类),调用方必须
  ///     显式走另一条路,不能靠这里默默填零。
  ///   * 朝向 VALID 位未置。
  ///
  /// 🔴 本函数**不**含相机自身的轴约定翻转(OpenCV 相机看 +z,渲染器相机
  /// 看 −z,差一个 `diag(1,−1,−1)`)。那一步取决于位姿是 body 系还是相机系,
  /// 而我们这条链给的是 **body pose**(`XRSLAMTryGetLatestPose` 文档原话),
  /// body→camera 的外参目前 `q_bo` 是单位四元数、`p_bo` 是零。哪天外参不再
  /// 是单位量,那一步必须显式加在调用方,不能藏在这里 —— 上游 PR #70
  /// 「虚拟物体反向滑走」的根因正是**外参被应用了两次**,而当时跟踪看起来
  /// 完全正常。
  ///
  /// [frame] 与 [modelMatrixColumnMajor] 同义,默认同样是
  /// [PoseFrame.engineZUp]。
  static List<double>? viewMatrixColumnMajor(
    TrackedPose pose, {
    PoseFrame frame = PoseFrame.engineZUp,
  }) {
    final PoseQuaternion? q = pose.orientation;
    final PosePosition? p = pose.position;
    if (q == null || p == null) return null;

    final PoseQuaternion r = _toRenderer(q, frame);
    final List<double> t = _toRendererVector(<double>[p.x, p.y, p.z], frame);

    // world_from_camera 的旋转矩阵。
    final double x = r.x, y = r.y, z = r.z, w = r.w;
    final List<List<double>> rwc = <List<double>>[
      <double>[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
      <double>[2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
      <double>[2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ];

    // view = (world_from_camera)⁻¹ = [Rᵀ | −Rᵀ·t]。刚体逆:转置加一次乘法,
    // 不做通用求逆 —— 通用求逆在这里既慢又会引入数值噪声。
    // (与 OpenXR `xr_linear.h:391-408` `XrMatrix4x4f_InvertRigidBody` 同形。)
    final List<double> negRt = <double>[
      -(rwc[0][0] * t[0] + rwc[1][0] * t[1] + rwc[2][0] * t[2]),
      -(rwc[0][1] * t[0] + rwc[1][1] * t[1] + rwc[2][1] * t[2]),
      -(rwc[0][2] * t[0] + rwc[1][2] * t[1] + rwc[2][2] * t[2]),
    ];

    // 列主序:第 i 列连续存放。
    return <double>[
      rwc[0][0], rwc[0][1], rwc[0][2], 0, //
      rwc[1][0], rwc[1][1], rwc[1][2], 0, //
      rwc[2][0], rwc[2][1], rwc[2][2], 0, //
      negRt[0], negRt[1], negRt[2], 1, //
    ];
  }

  // ── 换不换轴,只在这两个私有出口上分叉 ──────────────────────────────────
  // 🔴 故意只写一处分叉:两个矩阵出口各自写一遍 `if (frame == ...)`,迟早
  //    有人只改一边,而改漏了**不会抛** —— 位置换了轴、姿态没换,是最难
  //    看出来的那种错(物体位置对、朝向歪)。

  /// [PoseFrame.rendererYUp] 时**原样归一化**;[PoseFrame.engineZUp] 时走
  /// [convertRotation]。
  static PoseQuaternion _toRenderer(PoseQuaternion q, PoseFrame frame) =>
      switch (frame) {
        PoseFrame.engineZUp => convertRotation(q).normalized(),
        PoseFrame.rendererYUp => q.normalized(),
      };

  /// 同上,位置那一半。
  static List<double> _toRendererVector(List<double> v, PoseFrame frame) =>
      switch (frame) {
        PoseFrame.engineZUp => convertVector(v),
        PoseFrame.rendererYUp => <double>[v[0], v[1], v[2]],
      };
}
