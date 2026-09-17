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
// ══ 渲染器约定(三家一致,所以这一份能跨端)═════════════════════════════
// OpenXR 规范(fundamentals.adoc:1240-1252):"This API uses a Cartesian
// right-handed coordinate system",VIEW 空间 "+Y up, +X to the right, and
// −Z forward"。SceneKit 与 Filament 同一约定。Unity 是左手系,需要**额外**
// 的手性翻转,不在本文件内(需要时另写,别混进来)。

import 'tracked_pose.dart';

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
  static List<double>? modelMatrixColumnMajor(TrackedPose pose) {
    final PoseQuaternion? q = pose.orientation;
    final PosePosition? p = pose.position;
    if (q == null || p == null) return null;

    final PoseQuaternion r = convertRotation(q).normalized();
    final List<double> t = convertVector(<double>[p.x, p.y, p.z]);

    final double x = r.x, y = r.y, z = r.z, w = r.w;
    return <double>[
      1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0, //
      2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0, //
      2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0, //
      t[0], t[1], t[2], 1, //
    ];
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
  static List<double>? viewMatrixColumnMajor(TrackedPose pose) {
    final PoseQuaternion? q = pose.orientation;
    final PosePosition? p = pose.position;
    if (q == null || p == null) return null;

    final PoseQuaternion r = convertRotation(q).normalized();
    final List<double> t = convertVector(<double>[p.x, p.y, p.z]);

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
}
