// zero_arkit_camera_preview_test.dart —— 开关 ON 时预览不再是黑屏占位的判据。
//
// 四组:
//   (A) 几何:1920×1440 转 90° 进满宽 3:4 的预览框,aspect-fill 裁剪**恒等**,
//       内参逐字段不变(阴性对照:整屏 1179×2556 会裁 277.2 px/边);
//   (B) 预览模块**不开相机、不建会话、不建探针球、不建天空盒、不销毁引擎、
//       不碰 asset** —— 这些都归别处,源码级钉死;
//   (C) 采集页 ON 分支挂的是 `ZeroArkitCameraPreview`,OFF 分支的
//       `UiKitView` 原样只此一处;
//   (D) `VioArPoseProvider.lastTrackedPose` 是**引擎系、未换轴**的位姿,
//       与 `lastPose`(ARKit 口径)的位置按 `(−y,+z,−x)` 相差 —— 两条不能混。
//
// 🔴 不 pump `ZeroArkitCameraPreview`:它内部是 `ViewerWidget`,单测环境没有
//    Filament(`ThermionFlutterPlugin.createViewer` 走平台通道)。能在这里
//    验的只有它**不做什么**与它的输入几何;「画出来了」只有真机的
//    `[zero-arkit-preview] 判据:` 那一行能证明。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/capture_format.dart'
    show pwPreviewAspect;
import 'package:pocketworld_flutter/vio/ffi/xrslam_bindings.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/display_transform.dart';
import 'package:pocketworld_flutter/vio/pose/engine_pose_poller.dart';
import 'package:pocketworld_flutter/vio/pose/vio_ar_pose_provider.dart';
import 'package:pocketworld_flutter/vio/pose/xrslam_world_axis.dart';
import 'package:pocketworld_flutter/vio/render/zero_arkit_camera_preview.dart';
import 'package:vector_math/vector_math_64.dart';

/// 相机采集尺寸(传感器方向)与内参,与 `ZeroArkitCaptureRuntime` 默认值
/// 及 09-16 实测中位 fx 同口径。
const PinholeIntrinsics _captured = PinholeIntrinsics(
  fx: 1359.37,
  fy: 1359.37,
  cx: 960.0,
  cy: 720.0,
  imageWidth: 1920,
  imageHeight: 1440,
);

String _src(String rel) => File(rel).readAsStringSync();

/// 只留代码,剥掉 `//` 行注释 —— (B) 组断言的是「代码不做什么」,
/// 注释里解释「为什么不做」时必然会提到那些名字。
String _code(String src) => src
    .split('\n')
    .where((String l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('(A) 预览框几何', () {
    test('🔴 3:4 预览框 ⇒ 转 90° 后 aspect-fill 裁剪恒等,内参不动', () {
      // 与 ar_render_loop.step 同序:先转到显示方向,再在显示方向上算裁剪。
      final int rot = DisplayTransform.cameraToDisplayRotation(
        sensorOrientationDegrees: 90,
        displayRotation: ScreenRotation.degrees0,
        frontFacing: false,
      );
      expect(rot, 90, reason: 'iOS 后置横向传感器 + 竖屏 ⇒ 转 90°');
      final PinholeIntrinsics rotated = CameraProjection.rotate(
        _captured,
        rot,
        convention: PrincipalPointConvention.pixelCenter,
      );
      expect(rotated.imageWidth, 1440);
      expect(rotated.imageHeight, 1920);

      // CapturePreviewRect:满宽,高 = 宽 / pwPreviewAspect。iPhone 14 Pro
      // 逻辑宽 393 × dpr 3 = 1179 px。
      expect(pwPreviewAspect, 3 / 4, reason: '预览框口径变了,本测试前提失效');
      const int viewportW = 1179;
      final int viewportH = (viewportW / pwPreviewAspect).round();
      final ImageCrop crop = CameraProjection.aspectFillCrop(
        imageWidth: rotated.imageWidth,
        imageHeight: rotated.imageHeight,
        viewportWidth: viewportW,
        viewportHeight: viewportH,
      );
      // 同比 ⇒ 视口在图像坐标里就是整张图。允许 1 px 内的取整。
      expect(crop.offsetX.abs(), lessThan(1.0));
      expect(crop.offsetY.abs(), lessThan(1.0));
      expect((crop.width - 1440).abs(), lessThan(1.0));
      expect((crop.height - 1920).abs(), lessThan(1.0));

      final PinholeIntrinsics k = CameraProjection.applyCrop(rotated, crop);
      expect(k.fx, closeTo(rotated.fx, 1e-9));
      expect(k.fy, closeTo(rotated.fy, 1e-9));
      expect(k.cx, closeTo(rotated.cx, 1.0));
      expect(k.cy, closeTo(rotated.cy, 1.0));
      expect(k.imageWidth, rotated.imageWidth);
      expect(k.imageHeight, rotated.imageHeight);
    });

    test('阴性对照:整屏视口会裁掉短轴(每边 ≈277 px)—— 本测试分得开', () {
      final ImageCrop crop = CameraProjection.aspectFillCrop(
        imageWidth: 1440,
        imageHeight: 1920,
        viewportWidth: 1179,
        viewportHeight: 2556,
      );
      // camera_projection.dart 文件头实算的量级:每边 277.2 px。
      expect(crop.offsetX, closeTo(277.2, 0.5));
      expect(crop.offsetY.abs(), lessThan(1e-9));
    });

    test('UV 变换与投影裁剪同源:3:4 框下 UV 也是整图(fracU = fracV = 1)', () {
      final UvTransform uv = DisplayTransform.compute(
        imageWidth: 1920,
        imageHeight: 1440,
        viewportWidth: 1179,
        viewportHeight: 1572,
        rotationDegrees: 90,
      );
      // 行主序 3×3;整图时缩放项的绝对值为 1(旋转把它挪到非对角位)。
      final List<double> m = uv.m;
      final double scaleMagnitude =
          <double>[m[0].abs(), m[1].abs(), m[3].abs(), m[4].abs()]
              .reduce((double a, double b) => a > b ? a : b);
      expect(scaleMagnitude, closeTo(1.0, 1e-3));
    });
  });

  group('(B) 预览模块不做的事(源码级)', () {
    final String preview =
        _code(_src('lib/vio/render/zero_arkit_camera_preview.dart'));

    test('🔴 不开相机、不建会话 —— 归 ZeroArkitCaptureRuntime', () {
      expect(preview, isNot(contains('PwCameraSlot.start(')));
      expect(preview, isNot(contains('PwCameraSlot.stop(')));
      expect(preview, isNot(contains('XrslamSession.start(')));
      expect(preview, isNot(contains('ZeroArkitCameraGate.')));
    });

    test('🔴 不建探针球、不建天空盒、不自起渲染循环', () {
      expect(preview, isNot(contains('createWorldMarker(')));
      expect(preview, isNot(contains('setBackgroundColor(')));
      expect(preview, isNot(contains('background:')));
      expect(preview, isNot(contains('Ticker')));
      expect(preview, isNot(contains('viewer.render(')));
      expect(preview, isNot(contains('setRendering(')));
      expect(preview, contains('registerRequestFrameHook('));
    });

    test('🔴 不销毁别人的引擎、不双重释放 asset', () {
      expect(preview, contains('destroyEngineOnUnload: false'));
      expect(preview, isNot(contains('destroyEngineOnUnload: true')));
      expect(preview, isNot(contains('destroyAsset(')));
      expect(preview, isNot(contains('loop.dispose(')));
      expect(preview, contains('disposeForViewerTeardown('));
      expect(preview, contains('viewer.onDispose('));
    });

    test('常量与台架页同口径', () {
      expect(kZeroArkitCameraFeedMaterial,
          'assets/materials/pw_camera_feed.filamat');
      expect(kZeroArkitPreviewCaptureAtTick, 90);
      expect(kZeroArkitPreviewLogEveryTicks, 60);
      expect(
        _src('pubspec.yaml'),
        contains('- assets/materials/pw_camera_feed.filamat'),
        reason: '材质没进 assets ⇒ rootBundle.load 真机抛错,预览恒黑',
      );
    });
  });

  group('(C) 采集页接线', () {
    final String page = _src('lib/ui/official_capture/ar_capture_page.dart');

    test('ON 分支挂 ZeroArkitCameraPreview,且在 CapturePreviewRect 里', () {
      expect(page, contains('ZeroArkitCameraPreview('));
      final int at = page.indexOf('ZeroArkitCameraPreview(');
      final String before = page.substring((at - 400).clamp(0, at), at);
      expect(before, contains('CapturePreviewRect('));
      expect(before, contains('PwVioPoseSourceSwitch.isSelfVio'));
      // 采集尺寸从运行时拿,不在页面里另写一份 1920/1440。
      final String after = page.substring(at, at + 300);
      expect(after, contains('imageWidth: rt.captureWidth'));
      expect(after, contains('imageHeight: rt.captureHeight'));
      expect(after, contains('lastTrackedPose'));
    });

    test('🔴 OFF 分支的 ARKit UiKitView 原样、只此一处', () {
      expect(
        'pocketworld_official_arkit_preview'.allMatches(page).length,
        1,
      );
      expect(page, isNot(contains("CapturePreviewRect(child: SizedBox.expand())")),
          reason: '旧的恒黑占位应当已被替掉');
    });
  });

  group('(D) 引擎系位姿 vs ARKit 口径', () {
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
              quaternionXyzw: const <double>[0.0, 0.0, 0.0, 1.0],
              translationXyz: const <double>[0.1, 0.2, 0.3],
              timestampSeconds: 1.0,
            ),
          ),
          intrinsicsReader: () => _captured,
        );

    test('tick 之前 null;tick 之后是引擎原样的平移(未换轴)', () async {
      final VioArPoseProvider p = provider();
      expect(p.lastTrackedPose, isNull);
      p.tick();
      final pos = p.lastTrackedPose?.position;
      expect(pos, isNotNull);
      expect(pos!.x, closeTo(0.1, 1e-12));
      expect(pos.y, closeTo(0.2, 1e-12));
      expect(pos.z, closeTo(0.3, 1e-12));
      await p.dispose();
    });

    test('🔴 与 lastPose(ARKit 口径)差的正是 xrslam_world_axis 那个换轴', () async {
      final VioArPoseProvider p = provider();
      p.tick();
      final Vector3 arkit = p.lastPose!.position;
      final Vector3 expected = xrslamPositionToArkit(Vector3(0.1, 0.2, 0.3));
      expect(arkit.x, closeTo(expected.x, 1e-12));
      expect(arkit.y, closeTo(expected.y, 1e-12));
      expect(arkit.z, closeTo(expected.z, 1e-12));
      // 两条**不相等** —— 混用就是把 z-up 塞进 y-up 的消费者。
      expect(arkit.x == 0.1 && arkit.y == 0.2 && arkit.z == 0.3, isFalse);
      await p.dispose();
    });

    test('stop 之后不再交出陈旧位姿', () async {
      final VioArPoseProvider p = provider();
      p.tick();
      expect(p.lastTrackedPose, isNotNull);
      await p.stop();
      expect(p.lastTrackedPose, isNull);
      await p.dispose();
    });
  });
}
