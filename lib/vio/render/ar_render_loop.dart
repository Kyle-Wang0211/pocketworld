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
import 'dart:math' as math;

import 'package:flutter/services.dart' show ByteData, rootBundle;
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
    this.rotationDegrees,
    this.croppedIntrinsics,
    this.frustum,
    this.uv,
  });

  /// 以下四项只为诊断:出了问题要能看出**是哪一环算错**,而不是只知道
  /// "没显示"。都可能为 null(那一环没走到)。
  final int? rotationDegrees;
  final PinholeIntrinsics? croppedIntrinsics;
  final FrustumBounds? frustum;
  final UvTransform? uv;

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
      'proj:$hadProjection pose:$hadPose rot:$rotationDegrees)';

  /// 诊断用的多行展开。
  String toDiagnosticString() => <String>[
        'ArFrame frame=$hadFrame K=$hadIntrinsics proj=$hadProjection '
            'pose=$hadPose rot=$rotationDegrees',
        '  K(cropped) = $croppedIntrinsics',
        '  frustum    = $frustum',
        '  uv         = $uv',
      ].join('\n');
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

  // ── 分段耗时实测 ────────────────────────────────────────────────────────
  // 🔴 为什么要逐段:2026-09-19 实测 `Push` 1.9ms / `Run` 0.0ms —— **引擎不是
  //    瓶颈**(帧间隔 16.7ms),但 `displaced` 仍有 57%。说明开销在渲染回路
  //    这一侧,而 step() 有六段,不逐段量就只能猜是哪一段。
  //    ⚠️ 只量**同步耗时**;`await` 出去的等待也会算进来,这正是要看的
  //    (喂纹理和出图都是异步排到渲染线程)。
  final Stopwatch _stepClock = Stopwatch()..start();
  final List<int> _marks = List<int>.filled(7, 0);
  final List<List<int>> _stageMicros =
      List<List<int>>.generate(6, (_) => <int>[]);

  void _t(int i) {
    _marks[i] = _stepClock.elapsedMicroseconds;
    if (i > 0) {
      final List<int> v = _stageMicros[i - 1];
      v.add(_marks[i] - _marks[i - 1]);
      if (v.length > 240) v.removeAt(0);
    }
  }

  // ══ B3 世界锚点标记(方向自检)═══════════════════════════════════════════
  // 🔴 为什么需要它:所有"链路通了"的指标(state=1 / hasPos=true / pose=true)
  //    证明的都是**数据流到了**,没有一条证明**数据用对了**。位姿符号反了、
  //    轴映射错了,这些指标**照样全绿**,而画面会朝错误方向动。
  //    `pose_chain_probe_page.dart` 的文件头把这件事命名为 **B3(虚拟物体与
  //    真实特征对齐)**,并明确说 B1 的 "7/7 通过" **不能**替代它:
  //      "roll 的正确性是相对**相机图像**定义的,而本页根本没有相机。"
  //
  // 🔴 **世界点只算一次**(抄探针页那条用一次失败换来的教训):
  //    若每帧从当前模型矩阵派生 right/up/back 再定位,模型矩阵一变标记跟着变,
  //    **朝向错误被自己抵消**,测试永远不会失败(实测正常臂 1.71px、
  //    阴性臂 1.58px,分不开 —— 那是在断言代码等于它自己)。
  //
  // 判据(不需要标定参照物):符号/轴映射错误是**成倍、反向**的粗差,
  // 正常拍房间就能看出来 —— 球应当像**钉在空中某一点**:手机动,它在画面里
  // 的位置相应变化,但它在房间里的位置不变。若它跟着手机走、或朝反方向飞,
  // 就是这条链错了。
  //
  // ⚠️ 判读前提:引擎初始化完成(state=1)**之前**位姿是 null,相机矩阵根本
  //    没被设过 —— 这段窗口里球必然"跟着手机走",那是**正常的**,不是缺陷。
  //    页面顶部那条 TRACKING 指示灯变绿之后才开始判。
  /// 三个锚点的规格:(距离 m, 横移 m, 纵移 m, r, g, b)。
  ///
  /// ══ 为什么不照抄探针页的 1 cm @ 0.8 m ══
  ///   那组数是给**机器判据**定的:屏上半径 5–6 px、面积约 100 px,刚好够算
  ///   质心,又小到把偏心误差(Photogrammetric Record 1999)压在量化界之下。
  ///   本页的判据是**人眼看房间**,质心和偏心都不参与,约束换成了两条:
  ///     ① 单个锚点太近 ⇒ 稍一转身就出画,可观察窗口只有一两秒
  ///        (实测:0.8 m 那版用户的原话是"后来就看不见红球了");
  ///     ② 3 m 处要仍然看得见 ⇒ 直径 0.20 m 的角直径 2·atan(0.1/3)=3.8°,
  ///        约占竖屏视场(≈60°)的 6%,几十个像素,肉眼没问题。
  ///   三个不同深度 ⇒ 转身时**总有一个在画面里**;近大远小本身还顺带自证
  ///   投影矩阵没错。
  ///
  /// 三个都给了**不同方向**的横纵偏移:全摆正中的话,左右或上下搞反了也看
  /// 不出来(这条抄探针页 `_SyntheticPose` 的注释原文)。
  static const List<List<double>> _kMarkerSpecs = <List<double>>[
    <double>[1.0, 0.20, 0.15, 1.0, 0.1, 0.1], // 近 · 红 · 右上
    <double>[2.0, -0.30, -0.10, 0.1, 1.0, 0.1], // 中 · 绿 · 左下
    <double>[3.0, 0.05, 0.35, 0.2, 0.4, 1.0], // 远 · 蓝 · 正上
  ];

  /// 球半径(米)。直径 0.20 m —— 见 [_kMarkerSpecs] 的②。
  static const double _kMarkerRadius = 0.10;

  final List<ThermionAsset> _markers = <ThermionAsset>[];
  final List<List<double>> _markerWorlds = <List<double>>[];

  /// 建世界锚点标记。[rotationDegrees] 与显示滚转同口径。
  Future<void> createWorldMarker({required int rotationDegrees}) async {
    if (_markers.isNotEmpty) return;
    final ByteData mb =
        await rootBundle.load('assets/materials/pw_solid.filamat');
    // 🔴 不写 `Material` 这个类型名:Flutter 的 material.dart 与 thermion 都
    //    导出同名类型,写出来就是 ambiguous import(分析器只给 info,
    //    **编译期才报错**)。抄探针页,用推断。
    final solid =
        await FilamentApp.instance!.createMaterial(mb.buffer.asUint8List());
    for (final List<double> s in _kMarkerSpecs) {
      // 一份材质、三个实例 —— 每个实例自己的 color 参数。
      final MaterialInstance mi = await solid.createInstance();
      await mi.setParameterFloat4('color', s[3], s[4], s[5], 1.0); // unlit
      // 用**球**不用立方体 —— 抄探针页:偏心误差的文献分析(Photogrammetric
      // Record 1999)针对的是圆形/球形标记,立方体在透视下可见面不对称。
      _markers.add(await _viewer.createGeometry(
        GeometryHelper.sphere(),
        materialInstances: <MaterialInstance>[mi],
      ));
      _markerWorlds.add(_computeMarkerWorld(rotationDegrees, s[0], s[1], s[2]));
    }
  }

  /// 用**参考位姿**(单位位姿 + 正确 roll)定标记位置:相机前方 [d] 米,
  /// 再按相机自己的 right/up 轴偏移 [ox]/[oy]。
  List<double> _computeMarkerWorld(
      int rotationDegrees, double d, double ox, double oy) {
    final List<double> base = WorldToRenderer.modelMatrixColumnMajor(
      TrackedPose.tracked(
        orientation: const PoseQuaternion(0, 0, 0, 1),
        position: const PosePosition(0, 0, 0),
        timestampSeconds: 0,
      ),
    )!;
    final List<double> m = WorldToRenderer.multiplyColumnMajor(
      base,
      WorldToRenderer.displayRollColumnMajor(rotationDegrees),
    );
    double at(int r, int c) => m[c * 4 + r];
    List<double> axis(int c) => <double>[at(0, c), at(1, c), at(2, c)];
    final List<double> right = axis(0);
    final List<double> up = axis(1);
    final List<double> back = axis(2); // 相机看 −z ⇒ 前方是 −back
    return <double>[
      at(0, 3) - back[0] * d + right[0] * ox + up[0] * oy,
      at(1, 3) - back[1] * d + right[1] * ox + up[1] * oy,
      at(2, 3) - back[2] * d + right[2] * ox + up[2] * oy,
    ];
  }

  // ══ 取证:球此刻在**相机系**的哪里 ═══════════════════════════════════
  // 🔴 "滑走了、转回来也找不到"有好几种互斥的成因,肉眼分不开:
  //      ① 位姿平移量级不对(尺度/单位)⇒ 手机没动多少,相机跑出几十米;
  //      ② model/view 矩阵搞反 ⇒ 相机朝反方向动(本文件与
  //         world_to_renderer.dart 都点名过这是上游 PR #70 那一类);
  //      ③ 球压根被摆到了相机背后 ⇒ 转多少度都不可能看到;
  //      ④ 位姿在漂 ⇒ 静止时 t 也在涨。
  //    把每个球的相机系坐标打出来,四者立刻可分:看 z 的符号和量级。
  //    渲染器相机看 −z(OpenXR fundamentals.adoc:1240-1252),所以
  //    **前方 ⇒ z<0**,距离 = −z。
  List<double>? _lastRolled;
  int _lastRotationDegrees = -1;

  /// `null` = 还没推过位姿。否则是一行可读的取证串。
  String? markerDiagnostic() {
    final List<double>? m = _lastRolled;
    if (m == null || _markerWorlds.isEmpty) return null;
    final List<double> t = <double>[m[12], m[13], m[14]];
    final StringBuffer b = StringBuffer();
    b.write('cam_t=(${t[0].toStringAsFixed(2)},'
        '${t[1].toStringAsFixed(2)},${t[2].toStringAsFixed(2)})'
        ' |t|=${_norm(t).toStringAsFixed(2)}m rot=$_lastRotationDegrees');
    for (int i = 0; i < _markerWorlds.length; i++) {
      final List<double> w = _markerWorlds[i];
      final List<double> d = <double>[w[0] - t[0], w[1] - t[1], w[2] - t[2]];
      // p_cam = Rᵀ·(p_world − t);列主序里 R[j][i] = m[i*4+j] ⇒ Rᵀ 的第 i 行
      // 就是 m 的第 i 列的前三个。
      final List<double> c = <double>[
        for (int i2 = 0; i2 < 3; i2++)
          m[i2 * 4] * d[0] + m[i2 * 4 + 1] * d[1] + m[i2 * 4 + 2] * d[2],
      ];
      b.write(' | #$i cam=(${c[0].toStringAsFixed(2)},'
          '${c[1].toStringAsFixed(2)},${c[2].toStringAsFixed(2)})');
    }
    return b.toString();
  }

  static double _norm(List<double> v) =>
      math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

  /// 六段各自的 p50(毫秒),顺序:喂纹理/内参/UV/投影/位姿/出图。
  /// `null` = 还没有样本。
  List<double>? stageP50Millis() {
    if (_stageMicros[0].isEmpty) return null;
    return <double>[
      for (final List<int> v in _stageMicros)
        v.isEmpty
            ? 0
            : (List<int>.of(v)..sort())[v.length ~/ 2] / 1000.0,
    ];
  }
  final CameraFeedTriangle _triangle;

  /// 诊断用:场景里那个 renderable 的实体。
  ThermionEntity get triangleEntity => _triangle.asset.entity;

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
  ///
  /// [onFrameAddress] 在**喂纹理的那次 acquire 内**被调用一次,拿到的是该帧的
  /// CVPixelBuffer 地址。给"同一帧还要喂给 VIO 引擎"的场合用 —— 见下方注释,
  /// 这是抄上游的一次-lock-两用途,不是两次 acquire。
  Future<ArFrameOutcome> step({
    required int viewportWidth,
    required int viewportHeight,
    required ScreenRotation displayRotation,
    TrackedPose? pose,
    void Function(int pixelBufferAddress)? onFrameAddress,
  }) async {
    if (_disposed) {
      return const ArFrameOutcome(
        hadFrame: false,
        hadIntrinsics: false,
        hadProjection: false,
        hadPose: false,
      );
    }

    _t(0);
    // ── 1. 喂纹理 ──────────────────────────────────────────────────────────
    // 🔴 必须走 withFrameAsync:setExternalImage 是异步的(排到渲染线程),
    // 同步版会在 Filament 自己 retain 之前就把缓冲还掉。
    // 🔴 **一次 acquire,两个消费者** —— 抄上游 `XRSLAM_iOS.mm:130-150`:
    //   它对同一个 CVPixelBuffer 只 lock 一次,从同一个 baseAddress 派生两路
    //   (`cvtColor(raw,cvimage,BGRA2GRAY)` 给 SLAM、`BGRA2RGB` 给显示),
    //   再 unlock。显示与 SLAM 消费的是**同一帧**、在**同一个回调**里。
    // ⚠️ 我们的槽只有一格:各取各的会互相挤掉 —— 2026-09-19 实测,
    //   分两次取时 displaced 从 337 涨到 2127(丢帧 11%→56%),
    //   而且渲染侧 hadFrame 常年 false。
    // [onFrameAddress] 让调用方在**同一次 acquire 内**把这帧喂给引擎,
    // 渲染器本身不需要知道引擎的存在。
    final bool? fed = await PwCameraSlot.withFrameAsync<bool>((int addr) async {
      onFrameAddress?.call(addr);
      await _triangle.setFrame(addr);
      return true;
    });
    final bool hadFrame = fed == true;

    _t(1);
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

    _t(2);
    // ── 3. UV 变换 ────────────────────────────────────────────────────────
    UvTransform? lastUv;
    if (geom != null) {
      lastUv = DisplayTransform.compute(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        rotationDegrees: geom.rotationDegrees,
        mirrored: frontFacing,
      );
      await _triangle.setTransform(lastUv);
    }

    _t(3);
    // ── 4. 投影 ───────────────────────────────────────────────────────────
    bool hadProjection = false;
    FrustumBounds? lastFrustum;
    if (k != null && geom != null) {
      final FrustumBounds? f = CameraProjection.frustum(
        geom.croppedIntrinsics,
        near: near,
        far: far,
        convention: principalPointConvention,
      );
      lastFrustum = f;
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

    _t(4);
    // ── 5. 位姿 ───────────────────────────────────────────────────────────
    // 🔴 标记摆在**固定世界点**,每帧位置不变 —— 画面里的视差完全来自相机
    //    矩阵的变化。这正是判据成立的前提:标记若跟着相机走,就测不出朝向错。
    // 🔴 `GeometryHelper.sphere()` 出的是**单位半径**球(geometry.dart:31-32,
    //    x=cosφ·sinθ / y=cosθ / z=sinφ·sinθ,模长恒 1)⇒ scale 就是半径,
    //    不是直径。旧注释写"scale 0.02 = 直径 2 cm"是错的,那其实是 4 cm。
    for (int i = 0; i < _markers.length; i++) {
      await _markers[i].setTransform(Matrix4.identity()
        ..setTranslation(Vector3(
            _markerWorlds[i][0], _markerWorlds[i][1], _markerWorlds[i][2]))
        ..scaleByDouble(
            _kMarkerRadius, _kMarkerRadius, _kMarkerRadius, 1.0));
    }

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
        _lastRolled = rolled;
        _lastRotationDegrees = geom?.rotationDegrees ?? -1;
        hadPose = true;
      }
    }

    _t(5);
    // ── 6. 出图 ───────────────────────────────────────────────────────────
    // 🔴 **不在这里调 `viewer.render()`**。
    //
    // ViewerWidget 起来之后 viewer 自己就有渲染循环在跑。再手动 render 一次
    // 等于同一个 Renderer 上两对 beginFrame/endFrame 并发,真机实测直接撞
    // Filament 的断言并 SIGABRT:
    //     Precondition in endFrame:410
    //     reason: SwapChain must remain valid until endFrame is called.
    //
    // 而"关掉自带循环再自己渲染"这条路也不通:`setRendering(false)` 实际是
    // 把 View 标成不可渲染(见 ar_minimal_loop_page.dart 里的说明),场景会
    // 整个不画。
    //
    // ⚠️ 代价:本函数推的状态(纹理/投影/UV)与"哪一帧被呈现"之间没有严格
    // 配对,某一帧可能用上一帧的纹理。对"背景出不出得来"这个判据无影响,但
    // 接位姿之后必须解决 —— 正解是 `FilamentApp.registerRequestFrameHook`,
    // 它就是"每帧渲染前跑一段"的接缝。这是一笔明写的欠账,不是遗漏。

    _t(6);

    return ArFrameOutcome(
      hadFrame: hadFrame,
      hadIntrinsics: k != null,
      hadProjection: hadProjection,
      hadPose: hadPose,
      rotationDegrees: geom?.rotationDegrees,
      croppedIntrinsics: geom?.croppedIntrinsics,
      frustum: lastFrustum,
      uv: lastUv,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _triangle.destroy();
  }

  /// 给「ViewerWidget 先于本回路拆掉」的场合用 —— 生产采集页就是。
  ///
  /// 只销毁纹理/采样器/材质,**不碰 asset**(它已由 `viewer.dispose()` →
  /// `destroyAssets()` 销毁;再碰就是双重释放,见
  /// [CameraFeedTriangle.destroyGpuResourcesOnly])。之后 [step] 直接返回。
  Future<void> disposeForViewerTeardown() async {
    if (_disposed) return;
    _disposed = true;
    await _triangle.destroyGpuResourcesOnly();
  }
}
