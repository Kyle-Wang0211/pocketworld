// pose_chain_probe_page.dart —— B1:验「位姿 → 渲染」这条链,**不引入 VIO**。
//
// ══ 为什么先做这一段 ═══════════════════════════════════════════════════════
// 接上 VIO 之后如果看到"物体在飘",飘可能是 VIO 飘、也可能是我们这边的矩阵
// 错 —— 分不清。先把我们这半钉死,后面所有漂移就只剩一个嫌疑人。
//
// ══ 判据:重投影误差,而且阈值是**推导出来的**不是拍脑袋 ═══════════════════
//   路 A(我们的数学):世界点 → 位姿求逆得视图 → 我们自己的 frustum 投影
//                     → NDC → 像素
//   路 B(Filament 的光栅化器):标记做成**纯红**,取像后找红像素质心
//
// 路 B 走的是 Filament 真正在用的那个相机和投影 —— 它不知道路 A 算了什么。
//
// **这个量的学名是重投影误差(reprojection error)**,相机标定/SfM 的规范
// 仪器:Zhang, "A flexible new technique for camera calibration",
// IEEE TPAMI 2000, DOI 10.1109/34.888718;OpenCV `calibrateCamera` 报的
// RMS 就是它。
//
// 🔑 **但这里判据的性质与标定不同。** Holloway(Presence 1997,
// DOI 10.1162/pres.1997.6.4.413)把 AR 配准误差按来源分解:延迟、光学畸变、
// 世界-跟踪器标定、跟踪器测量……我们这条链属于**渲染变换本身**这一类,
// 而它在正确实现下应当是 **0** —— 纯确定性数学,两条路算的是同一个量。
// ⇒ 所以**不存在"可接受的误差阈值"**。允许的残差只有两项,且都能算:
//
//   ① 量化:质心是按像素数出来的,离散化残差保守取 0.5 px。
//   ② 偏心(eccentricity):标记有**有限尺寸**,透视下其像素质心≠中心的投影。
//      这是摄影测量里的已知系统误差,有学名有文献:
//      "Systematic Geometric Image Measurement Errors of Circular Object
//       Targets", The Photogrammetric Record 1999, DOI 10.1111/0031-868x.00138。
//      这里取保守上界 `屏上半径(px) × 角半径(rad)`(二阶小量)。
//
// 🔴 **外加阴性对照**:同一组位姿再跑一遍,**只给路 A 注入一个已知错误**
// (预测时少乘那次 90° 滚转),而 Filament 那边照常用正确的矩阵。那一臂的
// 残差必须**爆掉几百像素**,否则说明这把尺子没有分辨力。
//
// ⚠️ 第一版我扰动错了对象:两条路一起用错矩阵 ⇒ 它们当然还是一致的
// (实测正常臂 0.82 px / 阴性臂 0.93 px,分不开),阴性对照什么也没测出来。
//
// ══ 🔴 这个测试**不**证明什么 ═════════════════════════════════════════════
// 它证明的是"我们的数学与 Filament 的数学逐像素一致",**不是**
// `displayRollColumnMajor` 这个**值**对不对 —— roll 的正确性是相对**相机
// 图像**定义的,而本页根本没有相机。那件事只能在 B3(虚拟物体与真实特征
// 对齐)里验。别把这里的"7/7 通过"当成 roll 已经验过了。
//
// ⚠️ 口径声明:**这个测试方法是设计出来的,不是从哪里抄的。** 可引的只有
// 仪器(重投影误差)和被扣除的系统偏差(偏心),判据本身靠推导 + 阴阳对照
// 把关 —— 与 CameraProjection.rotate / displayRollColumnMajor 同一口径。
//
// 🔴 **本页不开摄像头**。B1 不需要相机,所以也不需要权限、不需要提前通知。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:thermion_flutter/thermion_flutter.dart' hide VoidCallback;

import '../pose/camera_projection.dart';
import '../pose/tracked_pose.dart';
import '../pose/world_to_renderer.dart';

/// 合成内参。取生产影子那一档的量级(640×480,fx≈fy≈437),因为投影链的
/// 数值行为跟内参的量级有关,用一个不现实的值等于没测。
const PinholeIntrinsics _kSyntheticK = PinholeIntrinsics(
  fx: 437.222,
  fy: 437.222,
  cx: 330.5, // 故意**非居中**:主点居中的话左右搞反也看不出来
  cy: 225.25,
  imageWidth: 640,
  imageHeight: 480,
);

const double _kNear = 0.01;
const double _kFar = 100.0;
const int _kRotationDegrees = 90; // iPhone 后置 + 竖屏,与实机一致
// 标记半边长。选 1 cm 是两头夹出来的:
//   * 太小 ⇒ 屏上不够几十个像素,质心估计噪声大、甚至找不到;
//   * 太大 ⇒ 偏心误差(见文件头②)上来,污染判据。
// 1 cm @ 0.8 m:角半径 ≈ 0.0125 rad,屏上半径约 5–6 px、面积约 100 px。
// 偏心上界 ≈ 5.5 × 0.0125 ≈ 0.07 px,远在量化界之下。
const double _kCubeHalfSize = 0.01;
const double _kCubeDistance = 0.8; // 摆在相机前 0.8 m

/// 一组合成位姿(**引擎世界系,z 向上**)。
/// 取值要让物体落在屏幕不同位置 —— 都落在正中央的话,左右/上下搞反也能"通过"。
class _SyntheticPose {
  const _SyntheticPose(this.label, this.pose);
  final String label;
  final TrackedPose pose;
}

List<_SyntheticPose> _buildPoses() {
  PoseQuaternion q(double angleDeg, double ax, double ay, double az) {
    final double a = angleDeg * math.pi / 180.0 / 2.0;
    final double s = math.sin(a);
    final double n = math.sqrt(ax * ax + ay * ay + az * az);
    return PoseQuaternion(ax / n * s, ay / n * s, az / n * s, math.cos(a));
  }

  TrackedPose p(PoseQuaternion rot, double x, double y, double z) =>
      TrackedPose.tracked(
        orientation: rot,
        position: PosePosition(x, y, z),
        timestampSeconds: 0,
      );

  // 🔴 必须是**参考位姿的小扰动**:标记现在固定在世界里,位姿一大就看不见它。
  // 但扰动也不能太小 —— 全是单位位姿的话,旋转部分错了也看不出来。
  // 取 ≤15° 的转 + ≤8 cm 的移,实测能保证标记留在画面内。
  return <_SyntheticPose>[
    _SyntheticPose('参考(单位位姿)', p(const PoseQuaternion(0, 0, 0, 1), 0, 0, 0)),
    _SyntheticPose('绕 z 转 12°', p(q(12, 0, 0, 1), 0, 0, 0)),
    _SyntheticPose('绕 z 转 -12°', p(q(-12, 0, 0, 1), 0, 0, 0)),
    _SyntheticPose('绕 x 转 8°', p(q(8, 1, 0, 0), 0, 0, 0)),
    _SyntheticPose('绕 y 转 -8°', p(q(-8, 0, 1, 0), 0, 0, 0)),
    _SyntheticPose('平移 (0.06,-0.04,0.03)',
        p(const PoseQuaternion(0, 0, 0, 1), 0.06, -0.04, 0.03)),
    _SyntheticPose('复合:转 10° + 移',
        p(q(10, 0.3, 0.6, 0.74), 0.05, 0.03, -0.04)),
  ];
}

class PoseChainProbePage extends StatefulWidget {
  const PoseChainProbePage({super.key});

  @override
  State<PoseChainProbePage> createState() => _PoseChainProbePageState();
}

class _PoseChainProbePageState extends State<PoseChainProbePage> {
  Future Function()? _frameHook;
  ThermionViewer? _viewer;
  ThermionAsset? _cube;
  Size _viewport = Size.zero;
  double _dpr = 1.0;

  final List<_SyntheticPose> _poses = _buildPoses();
  int _index = 0;
  int _settle = 0;
  bool _busy = false;
  /// 阴性对照臂:不施加 displayRoll。跑完正常臂后翻转,重跑同一组位姿。
  bool _negativeArm = false;
  final List<double> _posErr = <double>[];
  final List<double> _negErr = <double>[];
  final List<String> _report = <String>[];
  String _status = '等待渲染器…';

  @override
  void dispose() {
    final hook = _frameHook;
    if (hook != null) {
      FilamentApp.instance?.unregisterRequestFrameHook(hook);
      _frameHook = null;
    }
    super.dispose();
  }

  Future<void> _onViewer(ThermionViewer viewer) async {
    try {
      _viewer = viewer;
      await viewer.setPostProcessing(false);
      // 🔴 不传 background(会建天空盒),清屏用纯黑 —— 纯黑背景下"找红像素"
      // 才不会被别的东西污染。
      await FilamentApp.instance!.setClearOptions(0.0, 0.0, 0.0, 1.0);

      // 🔴 **不用 thermion 的 ubershader**。它要求顶点属性 0x1d
      // (POSITION|COLOR|UV0|UV1),而 thermion 自己的几何构建器只声明 0xd
      // (GeometrySceneAssetBuilder.cpp:168-170 写死三项),真机实测报
      //   [entity=3, primitive @ 0] missing required attributes (0x1d), declared=0xd
      // 用我们自己那个只要 POSITION 的 pw_solid(matinfo 自证:Required
      // attributes 只有 position),把这层耦合摘掉。
      final ByteData matBytes =
          await rootBundle.load('assets/materials/pw_solid.filamat');
      // 🔴 不写 `Material` 这个类型名:Flutter 的 material.dart 和 thermion
      // 都导出叫 Material 的类型,写出来就是 ambiguous import。分析器只给
      // info、**编译期才报错**,所以这里用推断。
      final solid = await FilamentApp.instance!
          .createMaterial(matBytes.buffer.asUint8List());
      final MaterialInstance mi = await solid.createInstance();
      // 纯红,且 unlit ⇒ 不受光照影响,像素值可预期(判据要按"纯红"找它)。
      await mi.setParameterFloat4('color', 1.0, 0.0, 0.0, 1.0);
      final cube = await viewer.createGeometry(
        // 🔴 用**球**不用立方体:偏心误差(eccentricity)的文献分析
        // (Photogrammetric Record 1999, DOI 10.1111/0031-868x.00138)针对的
        // 正是圆形/球形标记,用球那个上界才站得住;立方体在透视下可见面不
        // 对称,质心偏差没有对应的解析式。
        GeometryHelper.sphere(),
        materialInstances: <MaterialInstance>[mi],
      );
      _cube = cube;

      if (!mounted) return;
      setState(() => _status = '运行中:${_poses.length} 组合成位姿');

      final hook = _onFrame;
      _frameHook = hook;
      await FilamentApp.instance!.registerRequestFrameHook(hook);
    } catch (e, st) {
      if (mounted) setState(() => _status = '建场景失败:$e\n$st');
      debugPrint('[posechain] 建场景失败: $e\n$st');
    }
  }

  /// 标记的固定世界位置(渲染器世界系)。只算一次。
  List<double>? _worldTarget;

  /// 用**参考位姿**(单位位姿 + 正确的 roll)定标记位置:摆在相机前方
  /// [_kCubeDistance] 米,并给一个**横向/纵向偏移**,免得落在画面正中 ——
  /// 正中的话左右/上下搞反也看不出来。
  List<double> _computeWorldTarget() {
    final List<double> base = WorldToRenderer.modelMatrixColumnMajor(
      TrackedPose.tracked(
        orientation: const PoseQuaternion(0, 0, 0, 1),
        position: const PosePosition(0, 0, 0),
        timestampSeconds: 0,
      ),
    )!;
    final List<double> m = WorldToRenderer.multiplyColumnMajor(
      base,
      WorldToRenderer.displayRollColumnMajor(_kRotationDegrees),
    );
    List<double> axis(int c) =>
        <double>[_at(m, 0, c), _at(m, 1, c), _at(m, 2, c)];
    final List<double> right = axis(0);
    final List<double> up = axis(1);
    final List<double> back = axis(2); // 相机看 −z ⇒ 前方是 −back
    const double ox = 0.10, oy = 0.14;
    return <double>[
      _at(m, 0, 3) - back[0] * _kCubeDistance + right[0] * ox + up[0] * oy,
      _at(m, 1, 3) - back[1] * _kCubeDistance + right[1] * ox + up[1] * oy,
      _at(m, 2, 3) - back[2] * _kCubeDistance + right[2] * ox + up[2] * oy,
    ];
  }

  // ── 列主序 4×4 小工具 ────────────────────────────────────────────────────
  static double _at(List<double> m, int row, int col) => m[col * 4 + row];

  /// 刚体求逆:[Rᵀ | −Rᵀt]。不做通用求逆 —— 慢且引数值噪声。
  static List<double> _invertRigid(List<double> m) {
    final List<double> out = List<double>.filled(16, 0);
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        out[c * 4 + r] = _at(m, c, r); // 转置
      }
    }
    for (int r = 0; r < 3; r++) {
      double s = 0;
      for (int k = 0; k < 3; k++) {
        s += _at(m, k, r) * _at(m, k, 3);
      }
      out[3 * 4 + r] = -s;
    }
    out[15] = 1;
    return out;
  }

  static List<double> _mulVec4(List<double> m, List<double> v) => <double>[
        for (int r = 0; r < 4; r++)
          _at(m, r, 0) * v[0] +
              _at(m, r, 1) * v[1] +
              _at(m, r, 2) * v[2] +
              _at(m, r, 3) * v[3],
      ];

  Future<void> _onFrame() async {
    final viewer = _viewer;
    final cube = _cube;
    if (viewer == null || cube == null || !mounted || _busy) return;
    if (_index >= _poses.length) return;
    if (_viewport.width <= 0) return;
    _busy = true;
    try {
      final int vw = (_viewport.width * _dpr).round();
      final int vh = (_viewport.height * _dpr).round();
      final _SyntheticPose sp = _poses[_index];

      // ── 1. 投影:与生产走**同一条**代码路径 ────────────────────────────
      final PinholeIntrinsics rotated = CameraProjection.rotate(
        _kSyntheticK,
        _kRotationDegrees,
        convention: PrincipalPointConvention.pixelCenter,
      );
      final ImageCrop crop = CameraProjection.aspectFillCrop(
        imageWidth: rotated.imageWidth,
        imageHeight: rotated.imageHeight,
        viewportWidth: vw,
        viewportHeight: vh,
      );
      final PinholeIntrinsics cropped =
          CameraProjection.applyCrop(rotated, crop);
      final FrustumBounds? f = CameraProjection.frustum(
        cropped,
        near: _kNear,
        far: _kFar,
        convention: PrincipalPointConvention.pixelCenter,
      );
      if (f == null) {
        debugPrint('[posechain] frustum 算不出来,跳过');
        _index++;
        return;
      }

      // ── 2. 相机模型矩阵 = 位姿 · 滚转 ──────────────────────────────────
      final List<double>? base =
          WorldToRenderer.modelMatrixColumnMajor(sp.pose);
      if (base == null) {
        _index++;
        return;
      }
      final List<double> model = WorldToRenderer.multiplyColumnMajor(
        base,
        WorldToRenderer.displayRollColumnMajor(_kRotationDegrees),
      );
      // 🔴 阴性对照:**只扰动路 A(我们的预测)**,Filament 那边照常用正确的
      // model。
      //
      // 第一版我扰动错了对象 —— 两条路一起用没加 roll 的矩阵,于是它们当然
      // 还是一致的(实测正常臂 0.82 px / 阴性臂 0.93 px,分不开),阴性对照
      // 什么也没测出来。要测的是**这把尺子有没有分辨力**:给路 A 注入一个
      // 已知错误,残差必须爆掉。
      final List<double> predictModel = _negativeArm ? base : model;

      // ── 3. 标记摆在**固定的世界点**上 ─────────────────────────────────
      //
      // 🔴 这里曾经是个致命的设计缺陷,被阴性对照抓出来:原来把标记摆在
      // **相机自己的坐标轴**上(camPos − back·d + right·ox + up·oy),而
      // right/up/back 全取自那同一个模型矩阵 ⇒ 模型矩阵一变,标记跟着变,
      // **朝向错误被自己抵消**,测试永远不会失败(实测正常臂 1.71 px、
      // 阴性臂 1.58 px,分不开)。那是在断言代码等于它自己。
      //
      // 正解:世界点**只算一次**(用参考位姿定位置),之后所有位姿、
      // 两条臂都用同一个点。这样相机朝向一错,它在屏上就会挪。
      final List<double> target = _worldTarget ??= _computeWorldTarget();
      final Matrix4 cubeXf = Matrix4.identity()
        ..setTranslation(Vector3(target[0], target[1], target[2]))
        ..scaleByDouble(_kCubeHalfSize * 2, _kCubeHalfSize * 2, _kCubeHalfSize * 2, 1.0);
      await cube.setTransform(cubeXf);

      // ── 4. 设相机 ─────────────────────────────────────────────────────
      final Camera camera = await viewer.getActiveCamera();
      await camera.setProjection(
          Projection.Perspective, f.left, f.right, f.bottom, f.top, f.near, f.far);
      await camera.setModelMatrix(Matrix4.fromList(model));

      // ── 5. 等几帧让状态落地,再判 ──────────────────────────────────────
      if (_settle < 3) {
        _settle++;
        return;
      }
      _settle = 0;

      // 路 A:我们自己的数学(阴性臂用被注入错误的 predictModel)
      final List<double> view = _invertRigid(predictModel);
      final List<double> eye =
          _mulVec4(view, <double>[target[0], target[1], target[2], 1.0]);
      final List<double> proj = CameraProjection.glProjectionColumnMajor(f);
      final List<double> clip = _mulVec4(proj, eye);
      if (clip[3].abs() < 1e-12) {
        _index++;
        return;
      }
      final double ndcX = clip[0] / clip[3];
      final double ndcY = clip[1] / clip[3];
      // NDC +y 向上,屏幕 +y 向下。
      final double predX = (ndcX * 0.5 + 0.5) * vw;
      final double predY = (1.0 - (ndcY * 0.5 + 0.5)) * vh;

      // 路 B:Filament 的光栅化器
      final ({double x, double y, int count})? red = await _redCentroid(vw, vh);

      // 允许残差的上界,**逐组推导**:
      //   ① 量化 0.5 px;② 偏心 ≈ 屏上半径 × 角半径(见文件头)。
      // 屏上半径由红块面积反推(面积 ≈ π r²),比硬编码更贴合实际投影。
      final double angularRadius = _kCubeHalfSize / _kCubeDistance;
      final String line;
      if (red == null || red.count < 20) {
        line = '🔴 ${sp.label}${_negativeArm ? "[阴性]" : ""}: 找不到红块'
            '(count=${red?.count ?? 0}) '
            '预测=(${predX.toStringAsFixed(1)}, ${predY.toStringAsFixed(1)})';
      } else {
        final double pixRadius = math.sqrt(red.count / math.pi);
        final double bound = 0.5 + pixRadius * angularRadius;
        final double dx = red.x - predX;
        final double dy = red.y - predY;
        final double err = math.sqrt(dx * dx + dy * dy);
        (_negativeArm ? _negErr : _posErr).add(err);
        // 阴性臂:注入的是"少乘一次 90° 滚转",屏上位移应当是几百像素级。
        // 只要远超上界就算这把尺子有分辨力。
        final String mark = _negativeArm
            ? (err > 50 * bound ? '✅阴性(该错就错⇒尺子有分辨力)'
                                : '🔴阴性也过⇒这把尺子测不出朝向错')
            : (err <= bound ? '✅' : '🔴');
        line = '$mark ${sp.label}: 预测=(${predX.toStringAsFixed(1)}, '
            '${predY.toStringAsFixed(1)}) 实测=(${red.x.toStringAsFixed(1)}, '
            '${red.y.toStringAsFixed(1)}) 残差=${err.toStringAsFixed(2)} px '
            '上界=${bound.toStringAsFixed(2)} (r≈${pixRadius.toStringAsFixed(1)}px)';
      }
      debugPrint('[posechain] $line');
      _report.add(line);
      _index++;
      if (mounted) {
        setState(() {
          _status = _index >= _poses.length
              ? '完成 ${_report.length}/${_poses.length}'
              : '运行中 ${_index + 1}/${_poses.length}';
        });
      }
      if (_index >= _poses.length) {
        if (!_negativeArm) {
          debugPrint('[posechain] ===== 正常臂完 ⇒ 转阴性对照臂(不施加 roll)=====');
          _negativeArm = true;
          _index = 0;
          _report.add('—— 以下为阴性对照(不施加 displayRoll)——');
        } else {
          double mean(List<double> v) =>
              v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
          final int pass =
              _report.where((String r) => r.startsWith('✅')).length;
          debugPrint('[posechain] ===== 汇总 =====');
          debugPrint('[posechain] 正常臂 平均残差 = '
              '${mean(_posErr).toStringAsFixed(2)} px (n=${_posErr.length})');
          debugPrint('[posechain] 阴性臂 平均残差 = '
              '${mean(_negErr).toStringAsFixed(2)} px (n=${_negErr.length})');
          debugPrint('[posechain] 判据:正常臂应≈0(只剩量化+偏心),'
              '阴性臂应大幅超标。通过 $pass 项。');
        }
      }
    } catch (e, st) {
      debugPrint('[posechain] 第 $_index 组出错: $e\n$st');
      _index++;
    } finally {
      _busy = false;
    }
  }

  /// 取像并找纯红像素的质心。
  Future<({double x, double y, int count})?> _redCentroid(
      int vw, int vh) async {
    final shots = await FilamentApp.instance!.capture(null);
    if (shots.isEmpty) return null;
    final (_, Uint8List bytes) = shots.first;
    final Float32List px = bytes.buffer.asFloat32List();
    final int n = px.length ~/ 4;
    if (n == 0) return null;
    // 取像的宽高按视口推;若对不上就按实际像素数反推行宽。
    final int w = (n == vw * vh) ? vw : vw;
    double sx = 0, sy = 0;
    int count = 0;
    for (int i = 0; i < n; i++) {
      final double r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
      if (r > 0.5 && g < 0.2 && b < 0.2) {
        sx += (i % w).toDouble();
        sy += (i ~/ w).toDouble();
        count++;
      }
    }
    if (count == 0) return (x: 0.0, y: 0.0, count: 0);
    return (x: sx / count, y: sy / count, count: count);
  }

  @override
  Widget build(BuildContext context) {
    _viewport = MediaQuery.of(context).size;
    _dpr = MediaQuery.of(context).devicePixelRatio;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ViewerWidget(
              initial: const ColoredBox(color: Colors.black),
              manipulatorType: ManipulatorType.NONE,
              transformToUnitCube: false,
              postProcessing: false,
              destroyEngineOnUnload: true,
              onViewerAvailable: _onViewer,
            ),
          ),
          Positioned(
            left: 10,
            top: MediaQuery.of(context).padding.top + 10,
            right: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: DefaultTextStyle(
                  style: const TextStyle(
                      color: Colors.white, fontSize: 10, height: 1.35),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(_status),
                      ..._report.map(Text.new),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
