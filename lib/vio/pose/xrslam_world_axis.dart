// xrslam_world_axis.dart —— XRSLAM 世界系(z 向上)→ ARKit 世界系(y 向上)。
//
// ══ 为什么需要它 ═══════════════════════════════════════════════════════════
// 开关 ON 时位姿来自 XRSLAM,而下游(`CaptureSession` 的 az/el 数学、dome、
// `gravity_align`、落盘 manifest 的 `arkit_extrinsic_4x4`)全部按 **ARKit 的
// y 向上** 写的。不换轴就把一个 z-up 的位姿塞进 y-up 的消费者里 ——
// 不会抛任何异常,只会让 elevation、重力对齐、dome 全部静静地错。
//
// ══ 🔴 真值出处(只有一条,别的都不是)═══════════════════════════════════
// 2026-09-16 共享录制实测:同一份录制上把 XRSLAM 轨迹与 ARKit 轨迹做 SE(3)
// 拟合,得到的置换是
//
//     x_A = −y_X      y_A = +z_X      z_A = −x_X
//
// 这是**实测拟合**出来的,不是从「z-up vs y-up」推出来的 —— 从惯例只能推出
// 「有一个轴换到了 y」,推不出三个轴各自的符号。
//
// 🔴 仓里还有**第二个互相矛盾的记录**:上游 `xrslam-ios` 的 SceneKit 显示侧
// 硬编码 `(x,y,z) → (−y,−x,−z)`(见 `vio_pose_source.dart` 文件头)。
//
// ⚠️ **我一开始写错了一条理由,这里把它改正**:我曾断言上游那个行列式是 −1
//    (镜像),所以可以直接判掉。**算了一遍,不是** —— 两个候选的行列式
//    **都是 +1**,都是真旋转。determinant 分不开它们。
//
// 真正分得开的是**重力轴落到哪**。两者在 ARKit 系里差一个绕 **x 轴的 90°**
// (`U · Mᵀ` 固定 x、把 y→−z、z→+y,算式见单测),这不是 gauge 自由度:
//
//   · 实测那个:XRSLAM 的重力轴 `+z` → ARKit 的 **`+y`**。
//   · 上游那个:XRSLAM 的 `+z` → ARKit 的 **`−z`**(一个**水平**方向)。
//
// 而 ARKit 的 `worldAlignment = .gravity`(`OfficialAetherARKitPlugin.swift`
// 里写死)保证 **y 就是重力反方向**,XRSLAM 的世界系同样是重力对齐的 z-up。
// ⇒ 只有实测那个能让两边的「上」对上。上游那个是**显示侧**把 SceneKit 的
//   相机朝向一起掰过来用的,不是世界系换算,拿来当世界系换算会让整个
//   dome 躺倒 90°。
// ⇒ 结论不变(用实测那个),但理由换成了上面这条能算的,不是那条错的。
//
// ══ 🔴 不做杠杆臂 ═══════════════════════════════════════════════════════════
// `EnginePosePoller._readFromEngine` 取的是 **CAMERA_POSE**
// (`PwXrslamTransportCore.cpp:229` 的 `PW_XRSLAM_T_WORLD_CAMERA`),
// ARKit 的 `camera.transform` 也是相机位姿 ⇒ **两边同口径,不需要再加
// 33.75 mm 的 `p_bc`**。那个杠杆臂只在一边是 body 位姿时才要补
// (2026-09-16 我们正是因为没补它而带着 3.38 cm 的偏差比了很久)。
// 本文件**不**碰平移的模长,只做轴的重排与取反。
//
// ══ 怎么作用到姿态上 ═══════════════════════════════════════════════════════
// 位置是向量:`p_A = P · p_X`,P 是下面那个置换矩阵。
// 姿态是 camera→world 的旋转 `R_X`(世界系是 X 的):换系后
// `R_A = P · R_X`。
// 🔴 **不是** `P · R_X · Pᵀ` —— 那是「两边的系都换」的相似变换。这里只有
//    **世界系**换了,相机自身的局部系(右/上/后)两边是同一套(ARKit 与
//    XRSLAM 的相机系都是 OpenGL 式 x右 y上 z朝后),所以只左乘。
//    这一条有单测钉:把一个「相机看向 XRSLAM 的 +z(天花板)」的姿态换过去,
//    必须变成「看向 ARKit 的 +y(天花板)」。

import 'package:vector_math/vector_math_64.dart';

/// XRSLAM(z-up)→ ARKit(y-up)的置换矩阵,**行主序**写法:
///
///     | 0 −1  0 |
///     | 0  0  1 |
///     |−1  0  0 |
///
/// 逐行读就是文件头那三条:`x_A = −y_X` / `y_A = +z_X` / `z_A = −x_X`。
const List<List<double>> kXrslamToArkitRows = <List<double>>[
  <double>[0, -1, 0],
  <double>[0, 0, 1],
  <double>[-1, 0, 0],
];

/// 置换矩阵的行列式。**必须是 +1** —— 它是个真旋转,不是镜像。
///
/// ⚠️ 这一条**分不开**两个候选(上游那个 `(−y,−x,−z)` 的行列式也是 +1,
///    算过)。它挡的是别的东西:任何一次把某个轴写成两遍、或漏一个符号的
///    手滑,都会让行列式不再是 ±1。真正把两个候选分开的判据是
///    「XRSLAM 的 +z 必须落到 ARKit 的 +y」,单测里那一条才是。
const double kXrslamToArkitDeterminant = 1.0;

/// XRSLAM 世界系下的位置 → ARKit 世界系下的位置。
///
/// 纯轴重排 + 取反,**模长严格不变**(单测钉)。不缩放、不平移、不补杠杆臂。
Vector3 xrslamPositionToArkit(Vector3 pX) => Vector3(
  -pX.y, // x_A = −y_X
  pX.z, //  y_A = +z_X
  -pX.x, // z_A = −x_X
);

/// XRSLAM 世界系下的 camera→world 姿态 → ARKit 世界系下的同一姿态。
///
/// `R_A = P · R_X`(只左乘,理由见文件头)。输入非单位四元数时**原样返回**
/// —— 退化四元数(引擎第一个 `TRACKING_SUCCESS` 会返回零范数,09-16 实测)
/// 在这里归一化只会把「坏数据」伪装成「好数据」;上游 `VioPoseSource`
/// 已经有 `isUsableRotation` 的闸,让它继续挡。
Quaternion xrslamOrientationToArkit(Quaternion qX) {
  final double n2 =
      qX.x * qX.x + qX.y * qX.y + qX.z * qX.z + qX.w * qX.w;
  if (!n2.isFinite || n2 < 1e-12) return qX;

  final Matrix3 rX = Matrix3.identity();
  qX.copyRotationInto(rX);

  final Matrix3 p = _permutationMatrix();
  final Matrix3 rA = p * rX as Matrix3;

  return Quaternion.fromRotation(rA)..normalize();
}

/// 换系后的 camera→world 4×4(列主序 16 个 double),与既有
/// `ARPose.extrinsic4x4` 同形状 **且现在同系**。
List<double> xrslamCameraToWorldArkitColumnMajor(
  Quaternion qX,
  Vector3 pX,
) {
  final Matrix4 m = Matrix4.compose(
    xrslamPositionToArkit(pX),
    xrslamOrientationToArkit(qX),
    Vector3(1, 1, 1),
  );
  return List<double>.generate(16, (i) => m.storage[i], growable: false);
}

Matrix3 _permutationMatrix() {
  // Matrix3.new 的参数顺序是**列主序**(arg0..2 = 第一列)。按行写的表要转置
  // 着喂进去 —— 这一处写反不会抛,只会让整条链安静地错,所以逐元素取,
  // 不靠记忆里的参数顺序。
  final Matrix3 m = Matrix3.zero();
  for (int r = 0; r < 3; r++) {
    for (int c = 0; c < 3; c++) {
      m.setEntry(r, c, kXrslamToArkitRows[r][c]);
    }
  }
  return m;
}

/// 置换矩阵的行列式,给单测用(也给任何想验证「这是旋转不是镜像」的人)。
double xrslamToArkitDeterminant() => _permutationMatrix().determinant();
