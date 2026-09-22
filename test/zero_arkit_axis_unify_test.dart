// zero_arkit_axis_unify_test.dart —— 零 ARKit 臂里两套「引擎系 z-up → y-up」
// 换轴统一成一条之后的判据。
//
// ══ 统一前的现状(两条互相独立的换轴并存)═══════════════════════════════
//   M₁ = `xrslam_world_axis.dart`  `x_A=−y_X, y_A=+z_X, z_A=−x_X`
//        消费者:`VioArPoseProvider._toArPose` → dome 的 az/el、
//        `gravity_align`、落盘的 `arkit_extrinsic_4x4`。**生产数据那条路。**
//   M₂ = `WorldToRenderer.zUpToYUp`  绕 X 轴 −90°,`(x,y,z)→(x,z,−y)`
//        消费者:`ArRenderLoop.step` → Filament 的相机模型矩阵。
//
// 两条都把引擎的上 `(0,0,1)` 送到 y-up 的上 `(0,1,0)`,差的只是**一个绕竖轴
// 的偏航**。偏航在 VIO 里不可观(GVINS arXiv:2103.07899,world_to_renderer
// 文件头),所以「哪个偏航对」没有物理答案 —— 但两条**必须一致**,否则把按
// `ARPose` 摆的东西(照片卡片、点云)画进 Filament 预览时会整体绕竖轴转一个
// 角度,看起来像标定错。
//
// ══ 定案 ═════════════════════════════════════════════════════════════════
// **生产路径以 M₁(`xrslam_world_axis.dart`)为唯一换轴**;M₂ 保留给台架页 /
// 探针页(它们喂的是引擎系 `TrackedPose`,手上没有 `ARPose`)。
//
// ══ 本文件钉四件事 ═══════════════════════════════════════════════════════
//   (A) 两条老换轴之间那个偏航**算出来是多少度** —— 不是「差一个偏航」这种
//       说法,是 Ry(+90.000°),逐元素给出;
//   (B) 统一后:同一个引擎位姿经「provider → y-up → 渲染器(rendererYUp)」
//       得到的相机模型矩阵,与「`xrslam_world_axis` 直接算」**逐元素一致**;
//   (C) 阴性:把 y-up 位姿误按 `engineZUp` 喂进去,矩阵与正确结果**不同**
//       —— 证明「同一份位姿被换两次」是可检出的,不是静默故障;
//   (D) 源码级:预览与采集页不再拿 `lastTrackedPose` 当渲染输入;
//       台架页零改动(不出现 `poseFrame`)。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_bindings.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/engine_pose_poller.dart';
import 'package:pocketworld_flutter/vio/pose/tracked_pose.dart';
import 'package:pocketworld_flutter/vio/pose/vio_ar_pose_provider.dart';
import 'package:pocketworld_flutter/vio/pose/world_to_renderer.dart';
import 'package:pocketworld_flutter/vio/pose/xrslam_world_axis.dart';
import 'package:vector_math/vector_math_64.dart';

// ── 3×3 行主序的小工具。只在本文件用,故意不抽到 lib —— 生产代码里没有
//    「两个换轴互相比」这件事,那正是本文件要消灭的东西。 ──────────────────

List<List<double>> _transpose(List<List<double>> m) => <List<double>>[
      <double>[m[0][0], m[1][0], m[2][0]],
      <double>[m[0][1], m[1][1], m[2][1]],
      <double>[m[0][2], m[1][2], m[2][2]],
    ];

List<List<double>> _matmul(List<List<double>> a, List<List<double>> b) =>
    List<List<double>>.generate(
      3,
      (int r) => List<double>.generate(
        3,
        (int c) => a[r][0] * b[0][c] + a[r][1] * b[1][c] + a[r][2] * b[2][c],
      ),
    );

List<double> _apply(List<List<double>> m, List<double> v) => <double>[
      m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
      m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
      m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    ];

double _det(List<List<double>> m) =>
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
    m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
    m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);

/// 内参:与 `zero_arkit_camera_preview_test.dart` 同一组,只为让
/// `VioArPoseProvider` 有个不抛的内参源(本文件不验内参)。
const PinholeIntrinsics _captured = PinholeIntrinsics(
  fx: 1359.37,
  fy: 1359.37,
  cx: 960.0,
  cy: 720.0,
  imageWidth: 1920,
  imageHeight: 1440,
);

/// 一个**不平凡**的引擎位姿:绕 (1,2,3)/|…| 转 37°,平移 (0.11, −0.27, 0.43)。
/// 🔴 故意不用单位四元数 + 轴对齐平移 —— 那种输入下「换了一次」和「换了两次」
///    可能恰好相等,阴性对照就废了。
final Quaternion _qEngine = Quaternion.axisAngle(
  Vector3(1, 2, 3).normalized(),
  37 * math.pi / 180.0,
)..normalize();
const List<double> _pEngine = <double>[0.11, -0.27, 0.43];

String _src(String rel) => File(rel).readAsStringSync();

/// 只留代码,剥掉 `//` 行注释 —— 源码级断言问的是「代码做不做」,
/// 注释里解释「为什么不做」时必然会提到那些名字。
String _code(String src) => src
    .split('\n')
    .where((String l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('(A) 两条老换轴之间差的那个偏航 = Ry(+90°)', () {
    // M₁:xrslam_world_axis(实测 SE(3) 拟合);M₂:WorldToRenderer.zUpToYUp。
    final List<List<double>> m1 = kXrslamToArkitRows;
    final List<List<double>> m2 = WorldToRenderer.zUpToYUp;
    // v_A = M₁·v_X = D·(M₂·v_X) ⇒ D = M₁·M₂ᵀ(M₂ 是旋转,M₂⁻¹ = M₂ᵀ)。
    final List<List<double>> d = _matmul(m1, _transpose(m2));

    test('🔴 两条都把引擎的上 (0,0,1) 送到 y-up 的上 (0,1,0)', () {
      const List<double> up = <double>[0, 0, 1];
      for (final List<List<double>> m in <List<List<double>>>[m1, m2]) {
        final List<double> mapped = _apply(m, up);
        expect(mapped[0], closeTo(0, 1e-15));
        expect(mapped[1], closeTo(1, 1e-15));
        expect(mapped[2], closeTo(0, 1e-15));
      }
      // ⇒ 重力那两个自由度两条一致,**差的只可能是绕竖轴的偏航**。
    });

    test('🔴 差值 D = M₁·M₂ᵀ 逐元素 = [[0,0,1],[0,1,0],[−1,0,0]]', () {
      const List<List<double>> expected = <List<double>>[
        <double>[0, 0, 1],
        <double>[0, 1, 0],
        <double>[-1, 0, 0],
      ];
      for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
          expect(d[r][c], closeTo(expected[r][c], 1e-15),
              reason: 'D[$r][$c] 与手算不符');
        }
      }
      expect(_det(d), closeTo(1.0, 1e-15), reason: '必须是真旋转,不是镜像');
    });

    test('🔴 D 是**绕 y 的纯旋转**,角度 = +90.000°', () {
      // Ry(θ) = [[cosθ, 0, sinθ], [0, 1, 0], [−sinθ, 0, cosθ]]。
      // 「纯绕 y」的机械判据:y 行与 y 列除对角外全零,且对角为 1。
      expect(d[1][1], closeTo(1.0, 1e-15));
      expect(d[0][1], closeTo(0.0, 1e-15));
      expect(d[2][1], closeTo(0.0, 1e-15));
      expect(d[1][0], closeTo(0.0, 1e-15));
      expect(d[1][2], closeTo(0.0, 1e-15));
      // 剩下的 2×2 必须是个平面旋转。
      expect(d[0][0], closeTo(d[2][2], 1e-15));
      expect(d[0][2], closeTo(-d[2][0], 1e-15));

      final double degrees = math.atan2(d[0][2], d[0][0]) * 180.0 / math.pi;
      // 🔴 **这就是那个数**:+90.000°,不是「差一个偏航」这种说法。
      expect(degrees, closeTo(90.0, 1e-12));

      // 直观验算:引擎的 +x 经 M₂ 落到 renderer 的 +x,经 M₁ 落到 ARKit 的 −z;
      // Ry(+90°) 正是把 +x 送到 −z。
      expect(_apply(m2, <double>[1, 0, 0]), <double>[1, 0, 0]);
      final List<double> viaM1 = _apply(m1, <double>[1, 0, 0]);
      expect(viaM1[0], closeTo(0, 1e-15));
      expect(viaM1[1], closeTo(0, 1e-15));
      expect(viaM1[2], closeTo(-1, 1e-15));
    });

    test('D 对任意向量都成立(不是只在上向量上巧合)', () {
      const List<List<double>> samples = <List<double>>[
        <double>[1, 0, 0],
        <double>[0, 1, 0],
        <double>[0, 0, 1],
        <double>[0.11, -0.27, 0.43],
        <double>[-3.5, 7.25, 0.125],
      ];
      for (final List<double> v in samples) {
        final List<double> viaM1 = _apply(m1, v);
        final List<double> viaDm2 = _apply(d, _apply(m2, v));
        for (int i = 0; i < 3; i++) {
          expect(viaDm2[i], closeTo(viaM1[i], 1e-14), reason: 'v=$v i=$i');
        }
      }
    });
  });

  group('(B) 统一后:provider → y-up → 渲染器 = xrslam_world_axis 直接算', () {
    const MethodChannel sensors =
        MethodChannel('dev.fluttercommunity.plus/sensors/method');
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sensors, (_) async => null);
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sensors, null);
    });

    VioArPoseProvider provider() => VioArPoseProvider(
          pollInterval: const Duration(hours: 1),
          poller: EnginePosePoller(
            readEngine: () => EngineSnapshot(
              state: XRSLAMState.XRSLAM_STATE_TRACKING_SUCCESS.value,
              quaternionXyzw: <double>[
                _qEngine.x,
                _qEngine.y,
                _qEngine.z,
                _qEngine.w,
              ],
              translationXyz: _pEngine,
              timestampSeconds: 1.0,
            ),
          ),
          intrinsicsReader: () => _captured,
        );

    test('🔴 相机模型矩阵与 xrslamCameraToWorldArkitColumnMajor 逐元素一致',
        () async {
      final VioArPoseProvider p = provider();
      p.tick();

      final TrackedPose? yUp = p.lastRendererPose;
      expect(yUp, isNotNull, reason: 'tick 之后必须有已换轴的位姿');

      // 走渲染器那条路:rendererYUp ⇒ ArRenderLoop 一次都不再换轴。
      final List<double> model =
          WorldToRenderer.modelMatrixColumnMajor(yUp!,
              frame: PoseFrame.rendererYUp)!;
      // 与 step() 同序:模型矩阵右乘显示滚转。竖屏 0° 时它是单位阵,
      // 乘上去是为了走的确实是 step 那条路,而不是只验了一半。
      final List<double> rolled = WorldToRenderer.multiplyColumnMajor(
        model,
        WorldToRenderer.displayRollColumnMajor(0),
      );

      // 直接算:落盘 `arkit_extrinsic_4x4` 走的就是这个函数。
      final List<double> direct = xrslamCameraToWorldArkitColumnMajor(
        _qEngine,
        Vector3(_pEngine[0], _pEngine[1], _pEngine[2]),
      );

      for (int i = 0; i < 16; i++) {
        expect(rolled[i], closeTo(direct[i], 1e-12), reason: '第 $i 个元素不一致');
      }
      await p.dispose();
    });

    test('🔴 与同一帧 ARPose 出自同一次换算(位置/朝向逐字段相等)', () async {
      final VioArPoseProvider p = provider();
      p.tick();
      final TrackedPose yUp = p.lastRendererPose!;
      final Vector3 arPos = p.lastPose!.position;
      final Quaternion arQ = p.lastPose!.orientation;
      expect(yUp.position!.x, closeTo(arPos.x, 1e-15));
      expect(yUp.position!.y, closeTo(arPos.y, 1e-15));
      expect(yUp.position!.z, closeTo(arPos.z, 1e-15));
      expect(yUp.orientation!.x, closeTo(arQ.x, 1e-15));
      expect(yUp.orientation!.y, closeTo(arQ.y, 1e-15));
      expect(yUp.orientation!.z, closeTo(arQ.z, 1e-15));
      expect(yUp.orientation!.w, closeTo(arQ.w, 1e-15));
      await p.dispose();
    });

    test('OpenXR 四个标志位与 lastTrackedPose 逐位相同(换轴不动可读性)',
        () async {
      final VioArPoseProvider p = provider();
      p.tick();
      final TrackedPose engine = p.lastTrackedPose!;
      final TrackedPose yUp = p.lastRendererPose!;
      expect(yUp.flagSummary, engine.flagSummary);
      expect(yUp.timestampSeconds, engine.timestampSeconds);
      await p.dispose();
    });

    test('stop 之后 y-up 那条也清空(不留陈旧位姿的后门)', () async {
      final VioArPoseProvider p = provider();
      p.tick();
      expect(p.lastRendererPose, isNotNull);
      await p.stop();
      expect(p.lastRendererPose, isNull);
      expect(p.lastTrackedPose, isNull);
      await p.dispose();
    });
  });

  group('(C) 阴性:同一份位姿被换两次是可检出的', () {
    /// 已经是 y-up 的那份位姿(直接按 M₁ 算,不经 provider —— 本组只验矩阵)。
    TrackedPose yUpPose() {
      final Quaternion qa = xrslamOrientationToArkit(_qEngine);
      final Vector3 pa = xrslamPositionToArkit(
        Vector3(_pEngine[0], _pEngine[1], _pEngine[2]),
      );
      return TrackedPose.tracked(
        orientation: PoseQuaternion(qa.x, qa.y, qa.z, qa.w),
        position: PosePosition(pa.x, pa.y, pa.z),
        timestampSeconds: 1.0,
      );
    }

    test('🔴 y-up 位姿误按 engineZUp 喂进去 ⇒ 矩阵与正确结果不同', () {
      final TrackedPose pose = yUpPose();
      final List<double> right = WorldToRenderer.modelMatrixColumnMajor(
        pose,
        frame: PoseFrame.rendererYUp,
      )!;
      final List<double> wrong = WorldToRenderer.modelMatrixColumnMajor(
        pose,
        frame: PoseFrame.engineZUp,
      )!;
      // 至少有一个元素差得**肉眼可见**,不是浮点噪声。
      double maxAbsDiff = 0;
      for (int i = 0; i < 16; i++) {
        final double dlt = (right[i] - wrong[i]).abs();
        if (dlt > maxAbsDiff) maxAbsDiff = dlt;
      }
      expect(maxAbsDiff, greaterThan(0.1),
          reason: '双换若与单换几乎相等,这个阴性对照就分不开任何东西');
    });

    test('🔴 而且差的正是多余的那一次 zUpToYUp(平移逐元素对得上)', () {
      final TrackedPose pose = yUpPose();
      final List<double> wrong = WorldToRenderer.modelMatrixColumnMajor(
        pose,
        frame: PoseFrame.engineZUp,
      )!;
      final PosePosition p = pose.position!;
      final List<double> twice =
          WorldToRenderer.convertVector(<double>[p.x, p.y, p.z]);
      // 列主序:平移在第 4 列,下标 12/13/14。
      expect(wrong[12], closeTo(twice[0], 1e-15));
      expect(wrong[13], closeTo(twice[1], 1e-15));
      expect(wrong[14], closeTo(twice[2], 1e-15));
    });

    test('台架口径零改动:不传 frame ≡ 传 engineZUp', () {
      final TrackedPose engine = TrackedPose.tracked(
        orientation: PoseQuaternion(
          _qEngine.x,
          _qEngine.y,
          _qEngine.z,
          _qEngine.w,
        ),
        position: PosePosition(_pEngine[0], _pEngine[1], _pEngine[2]),
        timestampSeconds: 1.0,
      );
      final List<double> byDefault =
          WorldToRenderer.modelMatrixColumnMajor(engine)!;
      final List<double> explicitZUp = WorldToRenderer.modelMatrixColumnMajor(
        engine,
        frame: PoseFrame.engineZUp,
      )!;
      for (int i = 0; i < 16; i++) {
        expect(byDefault[i], explicitZUp[i], reason: '第 $i 个元素');
      }
      // 视图矩阵那一半同理(同一个私有分叉)。
      final List<double> vDefault =
          WorldToRenderer.viewMatrixColumnMajor(engine)!;
      final List<double> vZUp = WorldToRenderer.viewMatrixColumnMajor(
        engine,
        frame: PoseFrame.engineZUp,
      )!;
      for (int i = 0; i < 16; i++) {
        expect(vDefault[i], vZUp[i], reason: 'view 第 $i 个元素');
      }
    });
  });

  group('(D) 源码级:渲染输入不再是 lastTrackedPose', () {
    test('🔴 预览 widget 不拿 lastTrackedPose 当渲染输入,且显式 rendererYUp',
        () {
      final String preview =
          _code(_src('lib/vio/render/zero_arkit_camera_preview.dart'));
      expect(preview, isNot(contains('lastTrackedPose')));
      expect(preview, contains('poseFrame: PoseFrame.rendererYUp'));
    });

    test('🔴 采集页 ON 分支改读 lastRendererPose', () {
      final String page =
          _code(_src('lib/ui/official_capture/ar_capture_page.dart'));
      expect(page, isNot(contains('lastTrackedPose')));
      expect(page, contains('lastRendererPose'));
    });

    test('🔴 换轴只在两处发生,且回路里只有一条分叉', () {
      final String loop = _code(_src('lib/vio/render/ar_render_loop.dart'));
      // 回路自己不再直接决定换不换 —— 它把 frame 原样传下去。
      expect(loop, contains('frame: poseFrame'));
      expect(loop, isNot(contains('WorldToRenderer.convertRotation(')));
      expect(loop, isNot(contains('WorldToRenderer.convertVector(')));
    });

    test('台架页零改动:不出现 poseFrame', () {
      final String bench =
          _code(_src('lib/vio/render/ar_minimal_loop_page.dart'));
      expect(bench, isNot(contains('poseFrame')));
      expect(bench, isNot(contains('PoseFrame')));
    });
  });
}
