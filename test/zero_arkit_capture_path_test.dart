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
//   (G) 等第一帧内参(09-22 台架探针核实的必踩时序 bug):首帧晚到 200 ms
//       ⇒ 会话仍建成、`intrinsicsWaitMs` ≈ 200、相机没被停过;超时 ⇒ 失败关闭、
//       相机停、error 含等待时长;等的途中 start 幂等 / stop 叫停;provider 侧
//       起动过程中 `tick()` 不抛、位姿如实未跟踪。
//
// 🔴 全程**不等真实定时器**:`pollInterval` 传一个长到不会触发的值,手工 tick。
// 🔴 (G) 组要推进「等内参」的假时间:用 `testWidgets`(体默认跑在 FakeAsync
//    zone,`tester.pump(Duration)` 推假时钟 —— 与
//    `test/sparse_cloud_viewer_selection_test.dart` 文件头说的同一件事),
//    运行时的时钟注入 `TestWidgetsFlutterBinding.instance.clock.now`,
//    这样 `intrinsicsWaitMs` 也按假时钟算,能核到毫秒。

import 'dart:convert';
import 'dart:io';
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
    this.nullIntrinsicsCount = 0,
  });

  int cameraRc;
  PinholeIntrinsics? intrinsicsValue;
  String? sessionError;

  /// 前 k 次 [intrinsics] 返回 null(模拟「第一帧还没交付」),之后才给
  /// [intrinsicsValue]。运行时每 50 ms 问一次 ⇒ k=4 就是「首帧晚到 200 ms」。
  int nullIntrinsicsCount;
  int intrinsicsCalls = 0;

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
  }) {
    intrinsicsCalls++;
    if (intrinsicsCalls <= nullIntrinsicsCount) return null;
    return intrinsicsValue;
  }

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
  _FakePhotoApi({
    this.available = true,
    this.acceptCode = 0,
    this.photoDir = '/tmp',
  });

  final bool available;

  /// 受理码,**与真原生同口径**:`pw_camera_slot_capture_photo` 成功返回 **0**,
  /// 负数是失败码(`pw_camera_photo_ffi.dart`:「返回 0 已受理;负数是原生失败码」)。
  /// 🔴 以前替身返回 requestId,把 provider 里「拿受理码去比 requestId」的 bug
  ///    盖住了(09-22 真机 13 次快门全部 3 s 超时 unsupported,原生其实每张都写好了)。
  final int acceptCode;

  /// 成片落在哪个目录(要测 saved 时传一个真实临时目录)。
  final String photoDir;

  final List<int> requests = <int>[];
  ZeroArkitPhotoResult? pending;

  @override
  int? capturePhoto(int requestId) {
    if (!available) return null;
    requests.add(requestId);
    if (acceptCode < 0) return acceptCode; // 原生拒了 ⇒ 不会有结果
    pending = ZeroArkitPhotoResult(
      requestId: requestId,
      path: '$photoDir/zero_arkit_$requestId.jpg',
      fx: 1400,
      fy: 1400,
      cx: 960,
      cy: 720,
      width: 1920,
      height: 1440,
      timestampSeconds: 12.5,
      exposureSeconds: 0.00833,
    );
    return acceptCode;
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
    test('起相机的参数 = 1920×1440 / 30fps / 锁镜头 0.835', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = await ZeroArkitCaptureRuntime(platform: platform).start();
      expect(r.ok, isTrue, reason: r.toString());
      expect(platform.startCameraCalls.single, <Object>[1920, 1440, 30.0, 0.835]);
    });

    test('🔴 租约拿不到(ARKit 还占着)⇒ 失败关闭,不建会话、不去抢', () async {
      final platform = _FakePlatform(
        cameraRc: kZeroArkitCameraBusy,
        intrinsicsValue: _capturedK(),
      );
      final r = await ZeroArkitCaptureRuntime(platform: platform).start();
      expect(r.ok, isFalse);
      expect(r.blockedByArkit, isTrue);
      expect(r.sessionStarted, isFalse);
      expect(platform.sessionIntrinsics, isEmpty);
      expect(r.error, contains('ARKit'));
      // 相机都没起来 ⇒ 没等过内参,如实 0。
      expect(r.intrinsicsWaitMs, 0);
      expect(platform.intrinsicsCalls, 0);
    });

    testWidgets('🔴 相机始终不自报内参 ⇒ 等满上限后不建会话(不拿 PLACEHOLDER 内参开跑)',
        (WidgetTester tester) async {
      // 新语义:不是「读一次为 null 就失败」,而是**等满 5 s** 仍没有才失败关闭。
      final platform = _FakePlatform(intrinsicsValue: null);
      final rt = ZeroArkitCaptureRuntime(
        platform: platform,
        now: TestWidgetsFlutterBinding.instance.clock.now,
      );
      final Future<ZeroArkitStartResult> f = rt.start();
      // 等的途中:相机在跑、没被停、会话没建、如实「正在起」。
      await tester.pump(const Duration(milliseconds: 100));
      expect(rt.starting, isTrue);
      expect(rt.started, isFalse);
      expect(platform.stopCameraCalls, 0);
      expect(platform.sessionIntrinsics, isEmpty);

      await tester.pump(kZeroArkitIntrinsicsTimeout);
      final ZeroArkitStartResult r = await f;
      expect(r.ok, isFalse);
      expect(r.sessionStarted, isFalse);
      expect(platform.sessionIntrinsics, isEmpty);
      // 失败路径要把相机停掉,否则相机开着而什么都没在跑。**恰一次**。
      expect(platform.stopCameraCalls, 1);
      expect(rt.started, isFalse);
      expect(rt.starting, isFalse);
      // error 写清等了多久与上限;回执里的等待时长 = 上限。
      expect(r.intrinsicsWaitMs, kZeroArkitIntrinsicsTimeout.inMilliseconds);
      expect(r.error, contains('${kZeroArkitIntrinsicsTimeout.inMilliseconds}ms'));
      expect(r.error, contains('PLACEHOLDER'));
      // t=0, 50, …, 4950 各问一次 = 5 s / 50 ms = 100 次;t=5000 到上限不再问
      // (台架页同款 `while (elapsed < timeout)`)。问够了才放弃。
      expect(
        platform.intrinsicsCalls,
        kZeroArkitIntrinsicsTimeout.inMilliseconds ~/
            kZeroArkitIntrinsicsPoll.inMilliseconds,
      );
      expect(rt.lastStart, same(r));
    });

    test('会话起不来 ⇒ 相机也停掉,不留一个空转的采集', () async {
      final platform = _FakePlatform(
        intrinsicsValue: _capturedK(),
        sessionError: 'IMU 起不来 rc=-4',
      );
      final r = await ZeroArkitCaptureRuntime(platform: platform).start();
      expect(r.ok, isFalse);
      expect(r.error, contains('IMU'));
      expect(platform.stopCameraCalls, 1);
    });

    test('start 幂等;stop 后相机与会话都停', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final rt = ZeroArkitCaptureRuntime(platform: platform);
      // 内参已在手 ⇒ 整条路在 start() 返回前同步完成(台架页先轮询后调的用法)。
      final Future<ZeroArkitStartResult> f1 = rt.start();
      expect(rt.started, isTrue);
      expect(rt.lastStart, isNotNull);
      final Future<ZeroArkitStartResult> f2 = rt.start();
      expect(platform.startCameraCalls, hasLength(1));
      expect(platform.sessionIntrinsics, hasLength(1));
      expect((await f1).ok, isTrue);
      expect(await f2, same(await f1));
      rt.stop();
      expect(platform.destroySessionCalls, 1);
      expect(platform.stopCameraCalls, 1);
      expect(rt.started, isFalse);
      rt.stop();
      expect(platform.destroySessionCalls, 1, reason: 'stop 幂等:会话只毁一次');
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
      // 内参已在手 ⇒ provider.start() 返回时回执就已经在。
      expect(provider.runtimeStart?.ok, isTrue);
      expect(provider.runtimeStarting, isFalse);
      await provider.stop();
      expect(platform.stopCameraCalls, 1);
      await provider.dispose();
    });
  });

  group('(G) 等第一帧内参', () {
    DateTime fakeNow() => TestWidgetsFlutterBinding.instance.clock.now();

    testWidgets('🔴 首帧晚到 200 ms ⇒ 会话仍建成、intrinsicsWaitMs ≈ 200、相机没被停过',
        (WidgetTester tester) async {
      // 这就是台架探针 09-22 核实的那个 bug:以前起完相机立刻读一次内参,
      // 第一帧没到 ⇒ null ⇒ 停相机、报「相机还没自报内参」。
      final platform = _FakePlatform(
        intrinsicsValue: _capturedK(),
        nullIntrinsicsCount: 4, // t=0/50/100/150 都是 null,t=200 才有
      );
      final rt = ZeroArkitCaptureRuntime(
        platform: platform,
        machineIdentifier: 'iPhone15,2',
        now: fakeNow,
      );
      final Future<ZeroArkitStartResult> f = rt.start();
      // start() 返回时相机已起、还在等:没建会话、没停相机、回执还没有。
      expect(platform.startCameraCalls, hasLength(1));
      expect(platform.sessionIntrinsics, isEmpty);
      expect(platform.stopCameraCalls, 0);
      expect(rt.starting, isTrue);
      expect(rt.lastStart, isNull);

      await tester.pump(const Duration(milliseconds: 200));
      final ZeroArkitStartResult r = await f;
      expect(r.ok, isTrue, reason: r.toString());
      expect(r.sessionStarted, isTrue);
      expect(r.intrinsicsWaitMs, inInclusiveRange(200, 250));
      expect(r.toString(), contains('intrinsicsWait=${r.intrinsicsWaitMs}ms'));
      expect(platform.intrinsicsCalls, 5);
      expect(platform.stopCameraCalls, 0, reason: '等的途中相机不能被停');
      expect(platform.startCameraCalls, hasLength(1), reason: '相机只起一次');
      // 建会话用的是等到的那组内参(默认不缩 ⇒ 就是采集内参),c 原样进去。
      expect(platform.sessionIntrinsics.single.fx, 1359.37);
      expect(platform.sessionIntrinsics.single.resolutionWidth, 1920);
      expect(platform.sessionTimeOffsets.single, closeTo(0.003, 1e-12));
      expect(rt.started, isTrue);
      expect(rt.starting, isFalse);
      expect(rt.lastStart, same(r));
    });

    testWidgets('等的途中再调 start ⇒ 同一个 Future、相机只起一次;建成后再调不重起',
        (WidgetTester tester) async {
      final platform = _FakePlatform(
        intrinsicsValue: _capturedK(),
        nullIntrinsicsCount: 4,
      );
      final rt = ZeroArkitCaptureRuntime(platform: platform, now: fakeNow);
      final Future<ZeroArkitStartResult> f1 = rt.start();
      await tester.pump(const Duration(milliseconds: 100));
      final Future<ZeroArkitStartResult> f2 = rt.start();
      expect(f2, same(f1));
      expect(platform.startCameraCalls, hasLength(1));

      await tester.pump(const Duration(milliseconds: 100));
      final ZeroArkitStartResult r1 = await f1;
      expect(r1.ok, isTrue, reason: r1.toString());
      expect(await f2, same(r1));
      expect(platform.sessionIntrinsics, hasLength(1));

      final ZeroArkitStartResult r3 = await rt.start();
      expect(r3, same(r1));
      expect(platform.startCameraCalls, hasLength(1));
      expect(platform.sessionIntrinsics, hasLength(1));
      expect(platform.intrinsicsCalls, 5, reason: '建成后 start 不再去问内参');
    });

    testWidgets('🔴 等的途中 stop ⇒ 相机停(恰一次)、醒来不建会话、如实「被叫停」',
        (WidgetTester tester) async {
      final platform = _FakePlatform(
        intrinsicsValue: _capturedK(),
        nullIntrinsicsCount: 4,
      );
      final rt = ZeroArkitCaptureRuntime(platform: platform, now: fakeNow);
      final Future<ZeroArkitStartResult> f = rt.start();
      await tester.pump(const Duration(milliseconds: 100));
      rt.stop();
      expect(platform.stopCameraCalls, 1);
      expect(platform.destroySessionCalls, 0, reason: '没建过会话就没有可毁的');

      // 下一次醒来(t=150)看到代数变了 ⇒ 退出;t=200 本来会有内参,但不能再建。
      await tester.pump(const Duration(milliseconds: 200));
      final ZeroArkitStartResult r = await f;
      expect(r.ok, isFalse);
      expect(r.sessionStarted, isFalse);
      expect(r.error, contains('stop()'));
      expect(r.intrinsicsWaitMs, inInclusiveRange(100, 150));
      expect(platform.sessionIntrinsics, isEmpty);
      expect(platform.stopCameraCalls, 1, reason: '不重复停');
      expect(rt.started, isFalse);
      expect(rt.starting, isFalse);
      // 之后再 start 是新的一次(相机再起一次)。替身此前被问过 3 次
      // (t=0/50/100),第 4 次仍 null ⇒ 再等一个轮询间隔才拿到内参。
      final Future<ZeroArkitStartResult> f2 = rt.start();
      expect(platform.startCameraCalls, hasLength(2));
      expect(rt.starting, isTrue);
      await tester.pump(kZeroArkitIntrinsicsPoll);
      final ZeroArkitStartResult r2 = await f2;
      expect(r2.ok, isTrue, reason: r2.toString());
      expect(r2.intrinsicsWaitMs, kZeroArkitIntrinsicsPoll.inMilliseconds);
      expect(platform.sessionIntrinsics, hasLength(1));
      rt.stop();
    });

    testWidgets('🔴 stop 后立刻再 start(旧的还没醒)⇒ 新的一次照常起相机,旧的醒来不盖新回执',
        (WidgetTester tester) async {
      // 离开采集页又立刻进来:旧尝试还睡在 50 ms 的轮询里。
      final platform = _FakePlatform(
        intrinsicsValue: _capturedK(),
        nullIntrinsicsCount: 4,
      );
      final rt = ZeroArkitCaptureRuntime(platform: platform, now: fakeNow);
      final Future<ZeroArkitStartResult> f1 = rt.start();
      await tester.pump(const Duration(milliseconds: 100)); // 问了 3 次,都 null
      rt.stop();
      expect(platform.stopCameraCalls, 1);
      // 旧的还没醒(t=150 才醒),新的这一次必须是新的:再起一次相机。
      final Future<ZeroArkitStartResult> f2 = rt.start();
      expect(f2, isNot(same(f1)));
      expect(platform.startCameraCalls, hasLength(2));
      expect(rt.starting, isTrue);
      // 第 4 次问仍 null ⇒ 新的也等一个间隔;t=150 两条一起醒。
      await tester.pump(kZeroArkitIntrinsicsPoll);
      final ZeroArkitStartResult r1 = await f1;
      final ZeroArkitStartResult r2 = await f2;
      expect(r1.ok, isFalse);
      expect(r1.error, contains('stop()'));
      expect(r2.ok, isTrue, reason: r2.toString());
      expect(r2.intrinsicsWaitMs, kZeroArkitIntrinsicsPoll.inMilliseconds);
      // 🔴 判据:回执是新的那次,旧的醒来没把它盖掉;会话只建了一次。
      expect(rt.lastStart, same(r2));
      expect(rt.started, isTrue);
      expect(platform.sessionIntrinsics, hasLength(1));
      expect(platform.stopCameraCalls, 1, reason: '旧的醒来不再碰相机');
      rt.stop();
      expect(platform.destroySessionCalls, 1);
      expect(platform.stopCameraCalls, 2);
    });

    testWidgets('🔴 provider 侧:起动过程中 tick() 不抛、位姿如实未跟踪;建成后回执到位',
        (WidgetTester tester) async {
      final platform = _FakePlatform(
        intrinsicsValue: _capturedK(),
        nullIntrinsicsCount: 4,
      );
      final provider = VioArPoseProvider(
        runtime: ZeroArkitCaptureRuntime(platform: platform, now: fakeNow),
        photoApi: _FakePhotoApi(),
        pollInterval: const Duration(hours: 1),
      );
      final List<ARPose> poses = <ARPose>[];
      provider.start().listen(poses.add);
      // `ARPoseProvider.start()` 是同步的:相机已起、会话还在等内参。
      expect(platform.startCameraCalls, hasLength(1));
      expect(provider.runtimeStart, isNull);
      expect(provider.runtimeStarting, isTrue);
      expect(arkitCalls, isNot(contains('startSession')));

      expect(provider.tick, returnsNormally);
      expect(provider.lastPose, isNotNull);
      expect(provider.lastPose!.isTracking, isFalse);
      expect(provider.lastPose!.trackingStateName, isNot('normal'));
      expect(provider.lastRendererPose, isNotNull);
      expect(provider.lastRendererPose!.isSixDegreeOfFreedom, isFalse);

      await tester.pump(const Duration(milliseconds: 200));
      expect(provider.runtimeStarting, isFalse);
      final ZeroArkitStartResult? r = provider.runtimeStart;
      expect(r, isNotNull);
      expect(r!.ok, isTrue, reason: r.toString());
      expect(r.intrinsicsWaitMs, inInclusiveRange(200, 250));
      expect(platform.stopCameraCalls, 0);
      expect(platform.sessionIntrinsics, hasLength(1));
      // 建成后 tick 仍正常(假平台没有引擎位姿 ⇒ 仍是未跟踪,如实)。
      expect(provider.tick, returnsNormally);
      await tester.pump();
      expect(poses, hasLength(2));
      expect(poses.every((ARPose p) => !p.isTracking), isTrue);

      await provider.dispose();
      expect(platform.destroySessionCalls, 1);
      expect(platform.stopCameraCalls, 1);
    });

    testWidgets('provider 侧:超时起不来 ⇒ 相机停、runtimeStart 如实 !ok、tick 仍不抛',
        (WidgetTester tester) async {
      final platform = _FakePlatform(intrinsicsValue: null);
      final provider = VioArPoseProvider(
        runtime: ZeroArkitCaptureRuntime(platform: platform, now: fakeNow),
        photoApi: _FakePhotoApi(),
        pollInterval: const Duration(hours: 1),
      );
      provider.start();
      await tester.pump(kZeroArkitIntrinsicsTimeout);
      final ZeroArkitStartResult? r = provider.runtimeStart;
      expect(r, isNotNull);
      expect(r!.ok, isFalse);
      expect(r.error, contains('${kZeroArkitIntrinsicsTimeout.inMilliseconds}ms'));
      expect(platform.stopCameraCalls, 1);
      expect(platform.sessionIntrinsics, isEmpty);
      expect(provider.tick, returnsNormally);
      expect(provider.lastPose!.isTracking, isFalse);
      await provider.dispose();
      expect(platform.destroySessionCalls, 0);
    });

    testWidgets('provider 等的途中 stop ⇒ 相机停、不建会话', (WidgetTester tester) async {
      final platform = _FakePlatform(
        intrinsicsValue: _capturedK(),
        nullIntrinsicsCount: 4,
      );
      final provider = VioArPoseProvider(
        runtime: ZeroArkitCaptureRuntime(platform: platform, now: fakeNow),
        photoApi: _FakePhotoApi(),
        pollInterval: const Duration(hours: 1),
      );
      provider.start();
      await tester.pump(const Duration(milliseconds: 100));
      await provider.stop();
      expect(platform.stopCameraCalls, 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(platform.sessionIntrinsics, isEmpty);
      expect(platform.destroySessionCalls, 0);
      expect(provider.runtimeStart?.ok, isFalse);
      expect(provider.runtimeStart?.error, contains('stop()'));
      await provider.dispose();
    });
  });

  group('(C) 内参换算', () {
    test('🔴 默认不缩:喂料内参 == 采集内参(用户铁律最低 1920×1440)', () async {
      // 采集页是 `ZeroArkitCaptureRuntime()` 裸构造 —— 这条对应它。
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final rt = ZeroArkitCaptureRuntime(platform: platform);
      expect(rt.feedWidth, rt.captureWidth);
      expect(rt.feedHeight, rt.captureHeight);
      expect(rt.feedWidth, 1920);
      expect(rt.feedHeight, 1440);
      expect(rt.feedDownscaled, isFalse);
      final r = await rt.start();
      expect(r.ok, isTrue, reason: r.toString());
      final CameraIntrinsics fed = platform.sessionIntrinsics.single;
      // 逐字段等于相机自报的采集内参 —— 一个数都没缩。
      expect(fed.fx, 1359.37);
      expect(fed.fy, 1359.37);
      expect(fed.cx, 960.0);
      expect(fed.cy, 720.0);
      expect(fed.resolutionWidth, 1920);
      expect(fed.resolutionHeight, 1440);
      expect(fed.provenance, FieldProvenance.deviceApi);
      expect(r.feedDownscaled, isFalse);
      expect(r.intrinsics, same(fed));
      expect(r.toString(), contains('feed=1920x1440(=采集)'));
    });

    test('显式传参才缩:feedWidth/feedHeight 传 640×480 ⇒ 缩,回执标 feedDownscaled', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final rt = ZeroArkitCaptureRuntime(
        platform: platform,
        feedWidth: 640,
        feedHeight: 480,
      );
      expect(rt.feedDownscaled, isTrue);
      final r = await rt.start();
      expect(r.ok, isTrue, reason: r.toString());
      final CameraIntrinsics fed = platform.sessionIntrinsics.single;
      expect(fed.fx, closeTo(1359.37 / 3, 1e-9));
      expect(fed.cx, closeTo(320.0, 1e-9));
      expect(fed.resolutionWidth, 640);
      expect(fed.resolutionHeight, 480);
      expect(r.feedDownscaled, isTrue);
      expect(r.toString(), contains('feed=640x480(显式降采样)'));
    });

    test('等尺寸时 scaleIntrinsicsForFeed 是恒等', () {
      final k = scaleIntrinsicsForFeed(
        captured: _capturedK(),
        feedWidth: 1920,
        feedHeight: 1440,
      );
      expect(k.fx, 1359.37);
      expect(k.fy, 1359.37);
      expect(k.cx, 960.0);
      expect(k.cy, 720.0);
      expect(k.resolutionWidth, 1920);
      expect(k.resolutionHeight, 1440);
    });

    test('1920×1440 → 640×480(显式传参):fx/fy/cx/cy 各按自己的方向比例缩,分辨率跟着改', () {
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

    test('🔴 fx 绝不为 0(安卓喂料链在这一步漏写过)', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      await ZeroArkitCaptureRuntime(platform: platform).start();
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

    test('查表命中:iPhone15,2 ⇒ startSession 收到 0.003 s,回执 measured', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = await ZeroArkitCaptureRuntime(
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

    test('🔴 未测机型 ⇒ startSession 收到 0,回执 PLACEHOLDER —— 不拿 3 ms 顶', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = await ZeroArkitCaptureRuntime(
        platform: platform,
        machineIdentifier: 'iPhone99,9',
      ).start();
      expect(r.ok, isTrue, reason: r.toString());
      expect(platform.sessionTimeOffsets.single, 0.0);
      expect(r.cameraTimeOffset.provenance, FieldProvenance.placeholder);
      expect(r.cameraTimeOffset.isMeasuredForThisDevice, isFalse);
      expect(r.cameraTimeOffset.machine, 'iPhone99,9');
    });

    test('机型还不知道(查表没回来)⇒ 0 / PLACEHOLDER(机型未知),与本刀之前逐位相同', () async {
      // 不传 machineIdentifier、没有 debugOverride;单测里 `pw_vio_timebase`
      // 通道不存在 ⇒ `PwDeviceMachine.cached` 为 null。这就是文件头写的
      // 「已知窗口」在单测里的样子。
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = await ZeroArkitCaptureRuntime(platform: platform).start();
      expect(r.ok, isTrue, reason: r.toString());
      expect(platform.sessionTimeOffsets.single, 0.0);
      expect(r.cameraTimeOffset.provenance, FieldProvenance.placeholder);
      expect(r.cameraTimeOffset.machine, isNull);
      expect(r.cameraTimeOffset.describe, contains('机型未知'));
    });

    test('机型缓存热了之后,不传参的运行时(采集页那种构造法)也查得到表', () async {
      // 采集页是 `ZeroArkitCaptureRuntime()` 裸构造 —— 这条对应它。
      PwDeviceMachine.debugOverride = 'iPhone15,2';
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = await ZeroArkitCaptureRuntime(platform: platform).start();
      expect(platform.sessionTimeOffsets.single, closeTo(0.003, 1e-12));
      expect(r.cameraTimeOffset.provenance, FieldProvenance.measured);
      expect(r.cameraTimeOffset.machine, 'iPhone15,2');
    });

    test('显式覆盖(dart-define 口径)优先于查表,原样进 startSession', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final r = await ZeroArkitCaptureRuntime(
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

    test('c 只在建会话时传一次;start 幂等不重传', () async {
      final platform = _FakePlatform(intrinsicsValue: _capturedK());
      final rt = ZeroArkitCaptureRuntime(
        platform: platform,
        machineIdentifier: 'iPhone15,2',
      );
      await rt.start();
      await rt.start();
      expect(platform.sessionTimeOffsets, hasLength(1));
      expect(rt.lastStart!.cameraTimeOffset.provenance, FieldProvenance.measured);
    });

    test('失败路径的回执也带 c 与来源(没起成也得说清打算用哪个 c)', () async {
      final platform = _FakePlatform(
        cameraRc: kZeroArkitCameraBusy,
        intrinsicsValue: _capturedK(),
      );
      final r = await ZeroArkitCaptureRuntime(
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
    test('🔴 按签名调对方接口,结果按 requestId 配对(不按到达顺序);受理码 0 ≠ requestId',
        () async {
      // 替身像真原生一样返回 0。旧代码拿 0 去比 requestId(=1)⇒ 永远不等 ⇒
      // 这里会等满 3 s 返回 null —— 就是 09-22 真机 13 次快门全超时那个 bug。
      final photo = _FakePhotoApi();
      final provider = VioArPoseProvider(
        photoApi: photo,
        pollInterval: const Duration(hours: 1),
      );
      final r = await provider.requestPhoto();
      expect(photo.requests, hasLength(1));
      expect(r, isNotNull, reason: '受理码 0 被当成 requestId 去配对 ⇒ 超时 null');
      expect(r!.requestId, photo.requests.single);
      expect(r.requestId, isNot(0), reason: 'requestId 从 1 起,受理码才是 0');
      expect(r.path, contains('zero_arkit_'));
      expect(r.width, 1920);
      expect(r.exposureSeconds, closeTo(0.00833, 1e-9));
      await provider.dispose();
    });

    test('🔴 阴性对照:替身返回 0(真原生口径)且文件在 ⇒ saveCurrentFrame 仍 saved', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('pw_zero_arkit_photo_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final photo = _FakePhotoApi(photoDir: dir.path);
      final provider = VioArPoseProvider(
        photoApi: photo,
        pollInterval: const Duration(hours: 1),
      );
      provider.tick();
      // 第一次快门的 requestId 是 1;原生会把 JPEG 写在自己的目录里。
      final File native = File('${dir.path}/zero_arkit_1.jpg')
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
      final String jpegPath = '${dir.path}/out/f1.jpg';
      final String metaPath = '${dir.path}/out/f1.json';
      final res = await provider.saveCurrentFrame(
        ARFrameSaveSpec(
          frameID: 'f1',
          cellIndex: 0,
          slotIndex: 0,
          jpegPath: jpegPath,
          metadataPath: metaPath,
        ),
      );
      expect(res.status, 'saved', reason: res.message);
      expect(res.saved, isTrue);
      expect(photo.requests, <int>[1]);
      expect(File(jpegPath).existsSync(), isTrue);
      expect(native.existsSync(), isFalse, reason: '原生那份被搬走,不留孤儿');
      final Map<String, Object?> sidecar =
          jsonDecode(File(metaPath).readAsStringSync()) as Map<String, Object?>;
      expect(sidecar['photo_request_id'], 1);
      expect(sidecar['poseSource'], 'xrslam');
      await provider.dispose();
    });

    test('🔴 原生受理码为负 ⇒ 不等结果、立刻 null;saveCurrentFrame 如实 unsupported', () async {
      final photo = _FakePhotoApi(acceptCode: -3); // 「同一个 requestId 还在飞」
      final provider = VioArPoseProvider(
        photoApi: photo,
        pollInterval: const Duration(hours: 1),
      );
      // 超时给 5 分钟:要是没有按负数短路而去轮询结果,这个用例会挂到测试超时。
      final r = await provider.requestPhoto(timeout: const Duration(minutes: 5));
      expect(r, isNull);
      expect(photo.requests, hasLength(1));
      provider.tick();
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
      expect(photo.requests, hasLength(2));
      await provider.dispose();
    });

    test('🔴 接口不可用 ⇒ saveCurrentFrame 如实 unsupported,不假装成功', () async {
      final provider = VioArPoseProvider(
        photoApi: _FakePhotoApi(available: false),
        pollInterval: const Duration(hours: 1),
      );
      // [pw 2026-09-22 成片提升] 先要有一条位姿(哪怕不在跟踪),否则
      // saveCurrentFrame 在拍之前就以 no_pose 退出,测不到接口那一层。
      provider.tick();
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

    test('🔴 没有位姿 ⇒ 不拍(capturePhoto 0 次)、如实 no_pose', () async {
      // [pw 2026-09-22 成片提升] 之前这里拍了一张再报 saved_elsewhere;
      // 现在 saveCurrentFrame 真正落到 spec 的两个路径(见
      // test/zero_arkit_photo_promotion_test.dart),而没有位姿的成片进不了库,
      // 拍了只是白曝光一次。
      final photo = _FakePhotoApi();
      final provider = VioArPoseProvider(
        photoApi: photo,
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
      expect(res.status, 'no_pose');
      expect(res.saved, isFalse);
      expect(photo.requests, isEmpty);
      await provider.dispose();
    });

    test('🔴 有位姿但原生回执指向不存在的文件 ⇒ jpeg_missing,不报 saved', () async {
      final photo = _FakePhotoApi();
      final provider = VioArPoseProvider(
        photoApi: photo,
        pollInterval: const Duration(hours: 1),
      );
      provider.tick();
      final res = await provider.saveCurrentFrame(
        const ARFrameSaveSpec(
          frameID: 'f1',
          cellIndex: 0,
          slotIndex: 0,
          jpegPath: '/tmp/spec_path.jpg',
          metadataPath: '/tmp/spec_path.json',
        ),
      );
      expect(photo.requests, hasLength(1));
      expect(res.status, 'jpeg_missing');
      expect(res.saved, isFalse);
      expect(res.message, contains('/tmp/zero_arkit_'));
      await provider.dispose();
    });
  });
}
