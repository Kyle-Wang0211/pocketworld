// zero_arkit_capture_path_test.dart —— 「开关 ON = 完全不启动 ARKit」的判据。
//
// 六组:
//   (A) **ARSession 没起**:`pocketworld_official_arkit` 这条 MethodChannel 上
//       一条 `startSession` 都没有,而 OFF 时**有**(阴性对照 —— 没有它,
//       「没调」可能只是因为测试压根没接上通道);
//   (B) 相机由我们起:`pw_zero_arkit_camera_start` 被调,参数是 1920×1440/30/0.835,
//       租约拿不到时**失败关闭**不去抢;
//   (C) 内参换算:采集尺寸 → 喂料尺寸,fx **不是 0**(安卓喂料链在这一步漏过);
//   (D) 尺度 provenance:没有用户输入之前恒 `vio_unanchored`,
//       `mayReportAbsoluteDimensions == false`;量过距离之后才变;
//   (E) 照片:按签名调对方的接口;接口不可用时**如实 unsupported**,不假装成功;
//   (F) 每机常量 c:查表命中 / 未测机型 0 / 显式覆盖优先,**原样进 `startSession`**
//       (`_FakePlatform.sessionTimeOffsets` 记账),回执带值与来源。
//
// 🔴 全程**不等真实定时器**:`pollInterval` 传一个长到不会触发的值,手工 tick。

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/capture_session.dart';
import 'package:pocketworld_flutter/official_capture/metric_rescale.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:pocketworld_flutter/vio/capture/camera_time_offset.dart';
import 'package:pocketworld_flutter/vio/capture/zero_arkit_capture_runtime.dart';
import 'package:pocketworld_flutter/vio/capture/zero_arkit_photo_api.dart';
import 'package:pocketworld_flutter/vio/capture/zero_arkit_scale_provenance.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_session.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/camera_slot_ffi.dart';
import 'package:pocketworld_flutter/vio/pose/vio_ar_pose_provider.dart';
import 'package:pocketworld_flutter/vio/pose/zero_arkit_camera_gate.dart';

const MethodChannel _arkitChannel =
    MethodChannel('pocketworld_official_arkit');

/// `CaptureSession.attach()` 会起 `OrientationTracker`(sensors_plus)。
/// 单测里那个插件不存在 ⇒ `MissingPluginException` 会以未捕获异步异常的形式
/// 把用例判红。桩掉它,与 `vio_pose_consumption_wiring_test.dart:105` 同款。
const MethodChannel _sensorsMethodChannel =
    MethodChannel('dev.fluttercommunity.plus/sensors/method');

/// 记账用的假平台。
class _FakePlatform implements ZeroArkitPlatform {
  _FakePlatform({
    this.cameraRc = 0,
    this.intrinsicsValue,
    this.sessionError,
  });

  int cameraRc;
  PinholeIntrinsics? intrinsicsValue;
  String? sessionError;

  final List<List<Object>> startCameraCalls = <List<Object>>[];
  int stopCameraCalls = 0;
  int destroySessionCalls = 0;
  final List<CameraIntrinsics> sessionIntrinsics = <CameraIntrinsics>[];
  final List<double> sessionTimeOffsets = <double>[];

  @override
  int startCamera({
    required int width,
    required int height,
    required double fps,
    required double lensPosition,
  }) {
    startCameraCalls.add(<Object>[width, height, fps, lensPosition]);
    return cameraRc;
  }

  @override
  void stopCamera() => stopCameraCalls++;

  @override
  bool cameraOwnedBySelfVio() => cameraRc == 0;

  @override
  PinholeIntrinsics? intrinsics({
    required int imageWidth,
    required int imageHeight,
  }) =>
      intrinsicsValue;

  @override
  CameraExposure? exposure() => null;

  @override
  XrslamSessionStart startSession({
    required CameraIntrinsics intrinsics,
    required double cameraTimeOffsetSeconds,
  }) {
    sessionIntrinsics.add(intrinsics);
    sessionTimeOffsets.add(cameraTimeOffsetSeconds);
    return XrslamSessionStart(createRc: 1, error: sessionError);
  }

  @override
  void destroySession() => destroySessionCalls++;
}

class _FakePhotoApi implements ZeroArkitPhotoApi {
  _FakePhotoApi({this.available = true});

  final bool available;
  final List<int> requests = <int>[];
  ZeroArkitPhotoResult? pending;

  @override
  int? capturePhoto(int requestId) {
    if (!available) return null;
    requests.add(requestId);
    pending = ZeroArkitPhotoResult(
      requestId: requestId,
      path: '/tmp/zero_arkit_$requestId.jpg',
      fx: 1400,
      fy: 1400,
      cx: 960,
      cy: 720,
      width: 1920,
      height: 1440,
      timestampSeconds: 12.5,
      exposureSeconds: 0.00833,
    );
    return requestId;
  }

  @override
  ZeroArkitPhotoResult? photoResult() => pending;
}

PinholeIntrinsics _capturedK() => const PinholeIntrinsics(
      fx: 1359.37,
      fy: 1359.37,
      cx: 960.0,
      cy: 720.0,
      imageWidth: 1920,
      imageHeight: 1440,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> arkitCalls = <String>[];

  setUp(() {
    arkitCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_arkitChannel, (MethodCall call) async {
      arkitCalls.add(call.method);
      if (call.method == 'isAvailable') return true;
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_sensorsMethodChannel, (_) async => null);
    ZeroArkitCameraGate.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_arkitChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_sensorsMethodChannel, null);
    ZeroArkitCameraGate.debugReset();
  });

  group('(A) ARSession 没起', () {
    test('🔴 ON:整条 attach 走完,ARKit 通道上一条 startSession 都没有', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final provider = VioArPoseProvider(
        runtime: ZeroArkitCaptureRuntime(platform: platform),
        photoApi: _FakePhotoApi(),
        // 长到不会自己触发 —— 本测试手工 tick。
        pollInterval: const Duration(hours: 1),
      );
      final session = CaptureSession(
        targetPoints: null,
        poseProvider: provider,
      );

      await session.attach();
      provider.tick();

      expect(
        arkitCalls,
        isEmpty,
        reason: '开关 ON 时 ARKit 通道上出现了 $arkitCalls —— '
            '「完全不启动 ARKit」这条就没成立',
      );
      expect(arkitCalls, isNot(contains('startSession')));
      // 相机确实归我们了。
      expect(platform.startCameraCalls, hasLength(1));

      await provider.dispose();
      await session.dispose();
    });

    test('🔴 阴性对照 —— OFF(平台臂)时同一条通道上**有** startSession', () async {
      // 没有这一条,上面那个「没调」可能只是因为测试根本没接上通道。
      final session = CaptureSession(targetPoints: null);
      await session.attach();
      expect(
        arkitCalls,
        contains('startSession'),
        reason: '平台臂没发 startSession ⇒ 上面那条「没发」不构成证据',
      );
      await session.dispose();
    });
  });

  group('(B) 相机归我们', () {
    test('起相机的参数 = 1920×1440 / 30fps / 锁镜头 0.835', () {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = ZeroArkitCaptureRuntime(platform: platform).start();
      expect(r.ok, isTrue, reason: r.toString());
      expect(platform.startCameraCalls.single, <Object>[1920, 1440, 30.0, 0.835]);
    });

    test('🔴 租约拿不到(ARKit 还占着)⇒ 失败关闭,不建会话、不去抢', () {
      final platform = _FakePlatform(
        cameraRc: kZeroArkitCameraBusy,
        intrinsicsValue: _capturedK(),
      );
      final r = ZeroArkitCaptureRuntime(platform: platform).start();
      expect(r.ok, isFalse);
      expect(r.blockedByArkit, isTrue);
      expect(r.sessionStarted, isFalse);
      expect(platform.sessionIntrinsics, isEmpty);
      expect(r.error, contains('ARKit'));
    });

    test('🔴 相机没自报内参 ⇒ 不建会话(不拿 PLACEHOLDER 内参开跑)', () {
      final platform = _FakePlatform(intrinsicsValue: null);
      final rt = ZeroArkitCaptureRuntime(platform: platform);
      final r = rt.start();
      expect(r.ok, isFalse);
      expect(r.sessionStarted, isFalse);
      expect(platform.sessionIntrinsics, isEmpty);
      // 失败路径要把相机停掉,否则相机开着而什么都没在跑。
      expect(platform.stopCameraCalls, greaterThanOrEqualTo(1));
      expect(rt.started, isFalse);
    });

    test('会话起不来 ⇒ 相机也停掉,不留一个空转的采集', () {
      final platform = _FakePlatform(
        intrinsicsValue: _capturedK(),
        sessionError: 'IMU 起不来 rc=-4',
      );
      final r = ZeroArkitCaptureRuntime(platform: platform).start();
      expect(r.ok, isFalse);
      expect(r.error, contains('IMU'));
      expect(platform.stopCameraCalls, 1);
    });

    test('start 幂等;stop 后相机与会话都停', () {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final rt = ZeroArkitCaptureRuntime(platform: platform);
      rt.start();
      rt.start();
      expect(platform.startCameraCalls, hasLength(1));
      rt.stop();
      expect(platform.destroySessionCalls, 1);
      expect(platform.stopCameraCalls, 1);
      expect(rt.started, isFalse);
    });

    test('provider.stop() 把运行时一起停掉(离开采集页相机不能还开着)', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final provider = VioArPoseProvider(
        runtime: ZeroArkitCaptureRuntime(platform: platform),
        photoApi: _FakePhotoApi(),
        pollInterval: const Duration(hours: 1),
      );
      provider.start();
      expect(platform.startCameraCalls, hasLength(1));
      await provider.stop();
      expect(platform.stopCameraCalls, 1);
      await provider.dispose();
    });
  });

  group('(C) 内参换算', () {
    test('1920×1440 → 640×480:fx/fy/cx/cy 各按自己的方向比例缩,分辨率跟着改', () {
      final k = scaleIntrinsicsForFeed(
        captured: _capturedK(),
        feedWidth: 640,
        feedHeight: 480,
      );
      // 640/1920 = 1/3,480/1440 = 1/3。
      expect(k.fx, closeTo(1359.37 / 3, 1e-9));
      expect(k.fy, closeTo(1359.37 / 3, 1e-9));
      expect(k.cx, closeTo(320.0, 1e-9));
      expect(k.cy, closeTo(240.0, 1e-9));
      expect(k.resolutionWidth, 640);
      expect(k.resolutionHeight, 480);
    });

    test('🔴 fx 绝不为 0(安卓喂料链在这一步漏写过)', () {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      ZeroArkitCaptureRuntime(platform: platform).start();
      final CameraIntrinsics fed = platform.sessionIntrinsics.single;
      expect(fed.fx, greaterThan(0));
      expect(fed.fy, greaterThan(0));
      expect(fed.provenance, FieldProvenance.deviceApi);
    });

    test('各向异性也对(非等比时 x/y 用各自的比例)', () {
      final k = scaleIntrinsicsForFeed(
        captured: const PinholeIntrinsics(
          fx: 1000,
          fy: 800,
          cx: 500,
          cy: 400,
          imageWidth: 1000,
          imageHeight: 800,
        ),
        feedWidth: 500,
        feedHeight: 200,
      );
      expect(k.fx, closeTo(500, 1e-9)); // ×0.5
      expect(k.fy, closeTo(200, 1e-9)); // ×0.25
      expect(k.cx, closeTo(250, 1e-9));
      expect(k.cy, closeTo(100, 1e-9));
    });

    test('尺寸非法就抛,不静默产出 0', () {
      expect(
        () => scaleIntrinsicsForFeed(
          captured: const PinholeIntrinsics(
            fx: 1,
            fy: 1,
            cx: 1,
            cy: 1,
            imageWidth: 0,
            imageHeight: 0,
          ),
          feedWidth: 640,
          feedHeight: 480,
        ),
        throwsArgumentError,
      );
      expect(
        () => scaleIntrinsicsForFeed(
          captured: _capturedK(),
          feedWidth: 0,
          feedHeight: 480,
        ),
        throwsArgumentError,
      );
    });
  });

  group('(D) 尺度 provenance', () {
    test('🔴 默认恒 vio_unanchored,mayReportAbsoluteDimensions == false', () {
      final provider = VioArPoseProvider(
        photoApi: _FakePhotoApi(),
        pollInterval: const Duration(hours: 1),
      );
      expect(provider.scaleState.provenance, kScaleProvenanceVioUnanchored);
      expect(provider.scaleState.mayReportAbsoluteDimensions, isFalse);
      expect(
        provider.scaleState.toJson()['scale'],
        'vio_unanchored',
      );
      expect(
        provider.scaleState.toJson()['may_report_absolute_dimensions'],
        isFalse,
      );
      expect(provider.scaleState.rescale, isNull);
    });

    test('量过一段已知距离之后才变成 user_measured_distance', () {
      final provider = VioArPoseProvider(
        photoApi: _FakePhotoApi(),
        pollInterval: const Duration(hours: 1),
      );
      // 两点相距 1.0(模型单位),真实 1.1 m ⇒ s = 1.1。
      final xyz = Float32List.fromList(<double>[0, 0, 0, 1, 0, 0]);
      final MetricRescaleResult r = provider.anchorScaleWithUserDistance(
        xyz: xyz,
        pointA: const <double>[0, 0, 0],
        pointB: const <double>[1, 0, 0],
        realDistanceMeters: 1.1,
      );
      expect(r.provenance.scaleFactor, closeTo(1.1, 1e-12));
      expect(
        provider.scaleState.provenance,
        kScaleProvenanceUserDistance,
      );
      expect(provider.scaleState.mayReportAbsoluteDimensions, isTrue);
      expect(provider.scaleState.rescale, isNotNull);
    });

    test('🔴 缩放被拒时尺度状态**不变**(仍是未锚定)', () {
      final provider = VioArPoseProvider(
        photoApi: _FakePhotoApi(),
        pollInterval: const Duration(hours: 1),
      );
      final xyz = Float32List.fromList(<double>[0, 0, 0, 1, 0, 0]);
      expect(
        () => provider.anchorScaleWithUserDistance(
          xyz: xyz,
          pointA: const <double>[0, 0, 0],
          pointB: const <double>[1, 0, 0],
          // s = 100 ⇒ 远超 ±50% 的带外门(几乎只能是单位搞错)。
          realDistanceMeters: 100.0,
        ),
        throwsA(isA<MetricRescaleException>()),
      );
      expect(provider.scaleState.provenance, kScaleProvenanceVioUnanchored);
      expect(provider.scaleState.mayReportAbsoluteDimensions, isFalse);
    });

    test('三个 provenance 取值互不相同(读回执的人要能分辨)', () {
      expect(
        <String>{
          kScaleProvenanceVioUnanchored,
          kScaleProvenanceUserDistance,
          kScaleProvenanceArkitAnchor,
        },
        hasLength(3),
      );
    });
  });

  group('(F) 每机常量 c 进会话', () {
    tearDown(PwDeviceMachine.debugReset);

    test('查表命中:iPhone15,2 ⇒ startSession 收到 0.003 s,回执 measured', () {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = ZeroArkitCaptureRuntime(
        platform: platform,
        machineIdentifier: 'iPhone15,2',
      ).start();
      expect(r.ok, isTrue, reason: r.toString());
      // 🔴 判据就在这一行:引擎那头收到的数**就是**查表出来的数。
      expect(platform.sessionTimeOffsets.single, closeTo(0.003, 1e-12));
      expect(r.cameraTimeOffsetSeconds, closeTo(0.003, 1e-12));
      expect(r.cameraTimeOffset.provenance, FieldProvenance.measured);
      expect(r.cameraTimeOffset.isMeasuredForThisDevice, isTrue);
      expect(
        r.cameraTimeOffset.describe,
        'c=3.00ms provenance=measured(iPhone15,2)',
      );
      // 回执 toString 也要带这一行 —— 报告是从它抄的。
      expect(r.toString(), contains('provenance=measured(iPhone15,2)'));
    });

    test('🔴 未测机型 ⇒ startSession 收到 0,回执 PLACEHOLDER —— 不拿 3 ms 顶', () {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = ZeroArkitCaptureRuntime(
        platform: platform,
        machineIdentifier: 'iPhone99,9',
      ).start();
      expect(r.ok, isTrue, reason: r.toString());
      expect(platform.sessionTimeOffsets.single, 0.0);
      expect(r.cameraTimeOffset.provenance, FieldProvenance.placeholder);
      expect(r.cameraTimeOffset.isMeasuredForThisDevice, isFalse);
      expect(r.cameraTimeOffset.machine, 'iPhone99,9');
    });

    test('机型还不知道(查表没回来)⇒ 0 / PLACEHOLDER(机型未知),与本刀之前逐位相同', () {
      // 不传 machineIdentifier、没有 debugOverride;单测里 `pw_vio_timebase`
      // 通道不存在 ⇒ `PwDeviceMachine.cached` 为 null。这就是文件头写的
      // 「已知窗口」在单测里的样子。
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = ZeroArkitCaptureRuntime(platform: platform).start();
      expect(r.ok, isTrue, reason: r.toString());
      expect(platform.sessionTimeOffsets.single, 0.0);
      expect(r.cameraTimeOffset.provenance, FieldProvenance.placeholder);
      expect(r.cameraTimeOffset.machine, isNull);
      expect(r.cameraTimeOffset.describe, contains('机型未知'));
    });

    test('机型缓存热了之后,不传参的运行时(采集页那种构造法)也查得到表', () {
      // 采集页是 `ZeroArkitCaptureRuntime()` 裸构造 —— 这条对应它。
      PwDeviceMachine.debugOverride = 'iPhone15,2';
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = ZeroArkitCaptureRuntime(platform: platform).start();
      expect(platform.sessionTimeOffsets.single, closeTo(0.003, 1e-12));
      expect(r.cameraTimeOffset.provenance, FieldProvenance.measured);
      expect(r.cameraTimeOffset.machine, 'iPhone15,2');
    });

    test('显式覆盖(dart-define 口径)优先于查表,原样进 startSession', () {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = ZeroArkitCaptureRuntime(
        platform: platform,
        cameraTimeOffset: resolveCameraTimeOffset(
          machine: 'iPhone15,2',
          overrideMillisRaw: '8',
        ),
      ).start();
      expect(platform.sessionTimeOffsets.single, closeTo(0.008, 1e-12));
      expect(r.cameraTimeOffset.provenance, FieldProvenance.devOverride);
      expect(r.cameraTimeOffset.isMeasuredForThisDevice, isFalse,
          reason: '命令行传进来的数不是「这台机实测」');
    });

    test('c 只在建会话时传一次;start 幂等不重传', () {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final rt = ZeroArkitCaptureRuntime(
        platform: platform,
        machineIdentifier: 'iPhone15,2',
      );
      rt.start();
      rt.start();
      expect(platform.sessionTimeOffsets, hasLength(1));
      expect(rt.lastStart!.cameraTimeOffset.provenance, FieldProvenance.measured);
    });

    test('失败路径的回执也带 c 与来源(没起成也得说清打算用哪个 c)', () {
      final platform = _FakePlatform(
        cameraRc: kZeroArkitCameraBusy,
        intrinsicsValue: _capturedK(),
      );
      final r = ZeroArkitCaptureRuntime(
        platform: platform,
        machineIdentifier: 'iPhone15,2',
      ).start();
      expect(r.ok, isFalse);
      expect(platform.sessionTimeOffsets, isEmpty,
          reason: '没建会话就不该有 c 传出去');
      expect(r.cameraTimeOffset.provenance, FieldProvenance.measured);
      expect(r.cameraTimeOffset.seconds, closeTo(0.003, 1e-12));
    });
  });

  group('(E) 照片', () {
    test('按签名调对方接口,结果按 requestId 配对(不按到达顺序)', () async {
      final photo = _FakePhotoApi();
      final provider = VioArPoseProvider(
        photoApi: photo,
        pollInterval: const Duration(hours: 1),
      );
      final r = await provider.requestPhoto();
      expect(photo.requests, hasLength(1));
      expect(r, isNotNull);
      expect(r!.requestId, photo.requests.single);
      expect(r.path, contains('zero_arkit_'));
      expect(r.width, 1920);
      expect(r.exposureSeconds, closeTo(0.00833, 1e-9));
      await provider.dispose();
    });

    test('🔴 接口不可用 ⇒ saveCurrentFrame 如实 unsupported,不假装成功', () async {
      final provider = VioArPoseProvider(
        photoApi: _FakePhotoApi(available: false),
        pollInterval: const Duration(hours: 1),
      );
      final res = await provider.saveCurrentFrame(
        const ARFrameSaveSpec(
          frameID: 'f1',
          cellIndex: 0,
          slotIndex: 0,
          jpegPath: '/tmp/a.jpg',
          metadataPath: '/tmp/a.json',
        ),
      );
      expect(res.saved, isFalse);
      expect(res.status, 'unsupported');
      await provider.dispose();
    });

    test('🔴 拍成了也**不报 saved** —— 路径是原生选的,不是 spec 里那个', () async {
      final provider = VioArPoseProvider(
        photoApi: _FakePhotoApi(),
        pollInterval: const Duration(hours: 1),
      );
      final res = await provider.saveCurrentFrame(
        const ARFrameSaveSpec(
          frameID: 'f1',
          cellIndex: 0,
          slotIndex: 0,
          jpegPath: '/tmp/spec_path.jpg',
          metadataPath: '/tmp/spec_path.json',
        ),
      );
      expect(res.status, 'saved_elsewhere');
      expect(res.saved, isFalse);
      expect(res.message, contains('/tmp/zero_arkit_'));
      await provider.dispose();
    });
  });
}
