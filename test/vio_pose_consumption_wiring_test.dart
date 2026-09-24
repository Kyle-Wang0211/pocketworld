// vio_pose_consumption_wiring_test.dart —— 消费层接线的三组判据。
//
//   (b) 开关 ON:VIO 源的位姿**真的到达** `CaptureSession` 的消费点,
//       而且可信度字段非空;
//   (c) `capture_session` 新分支:`_poseSourceCarriesCameraGeometry` 的
//       每一档 + 未知源**显式报错**(不是静默丢);
//   (d) 开关本身的解析(默认空 = ARKit;打错字回落 ARKit 而不是抛)。
//
// (a) 「开关 OFF 与改前逐位相同」在 `vio_pose_source_switch_off_parity_test.dart`。
//
// 🔴 这里**不等真实定时器**:`VioArPoseProvider.pollInterval` 传一个长到不会
//    触发的值,然后手工调 `tick()`。理由是既有教训 ——「真机测试单场必须有
//    硬上限」的同一条:让测试去等墙钟,只会把「异常」伪装成「很慢」。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/capture_session.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_bindings.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/engine_pose_poller.dart';
import 'package:pocketworld_flutter/vio/pose/vio_ar_pose_provider.dart';
import 'package:pocketworld_flutter/vio/pose/vio_pose_source_switch.dart';
import 'package:pocketworld_flutter/vio/quality/pose_confidence.dart';

/// 一个自报未知标签的 provider。用来证明未知源**报错**而不是被当成 ARKit。
class _BogusLabelProvider implements ARPoseProvider, ARPoseSourceLabel {
  @override
  String get poseSourceLabel => 'martian_vio';

  @override
  ARPose? get lastPose => null;

  @override
  Stream<ARPose> start() => const Stream<ARPose>.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async => null;

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async => false;

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async =>
      ARFrameSaveResult(spec: spec, status: 'unsupported');

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
    bool feedSfm = false,
    bool deriveAuxiliary = true,
    bool stagePhotoFeedback = false,
    String? transactionId,
    String? cardTexturePath,
    double? maxTimestampDelta,
  }) async => null;
}

/// 引擎在跟踪的假快照。四元数是单位四元数(w 在**第 4 位**)。
EngineSnapshot _tracking(double t) => EngineSnapshot(
  state: XRSLAMState.XRSLAM_STATE_TRACKING_SUCCESS.value,
  quaternionXyzw: const <double>[0.0, 0.0, 0.0, 1.0],
  translationXyz: <double>[0.1 * t, 0.2 * t, 0.3 * t],
  timestampSeconds: t,
);

VioArPoseProvider _providerWithScriptedEngine(List<EngineSnapshot> script) {
  var i = 0;
  return VioArPoseProvider(
    // 长到本测试生命周期内绝不触发 —— 由 tick() 手工驱动。
    pollInterval: const Duration(hours: 1),
    poller: EnginePosePoller(
      readEngine: () => i < script.length ? script[i++] : script.last,
    ),
    // 单测里 `pw_camera_slot_intrinsics` 这个符号不存在,给一个固定值,
    // 好让「内参确实被带出去了」这条可判。
    intrinsicsReader: () => const PinholeIntrinsics(
      fx: 448.97,
      fy: 448.97,
      cx: 320.0,
      cy: 240.0,
      imageWidth: 640,
      imageHeight: 480,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorsMethodChannel = MethodChannel(
    'dev.fluttercommunity.plus/sensors/method',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, (_) async => null);
  });
  tearDown(() {
    PwVioPoseSourceSwitch.debugOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, null);
  });

  // ══ (d) 开关 ══════════════════════════════════════════════════════════
  group('PW_VIO_POSE_SOURCE 开关', () {
    test('🔴 默认(空字符串)= ARKit —— 生产行为不变', () {
      expect(PwVioPoseSourceSwitch.parse(''), PwVioPoseSource.arkit);
      expect(kPwVioPoseSourceRaw, '', reason: '本仓的编译期默认必须是空');
      expect(PwVioPoseSourceSwitch.current, PwVioPoseSource.arkit);
      expect(PwVioPoseSourceSwitch.isSelfVio, isFalse);
    });

    test('xrslam / selfvio 打开自研臂;arkit / platform 明确关闭', () {
      expect(PwVioPoseSourceSwitch.parse('xrslam'), PwVioPoseSource.xrslam);
      expect(PwVioPoseSourceSwitch.parse('SelfVio'), PwVioPoseSource.xrslam);
      expect(PwVioPoseSourceSwitch.parse('arkit'), PwVioPoseSource.arkit);
      expect(PwVioPoseSourceSwitch.parse('platform'), PwVioPoseSource.arkit);
      expect(PwVioPoseSourceSwitch.parse('  XRSLAM '), PwVioPoseSource.xrslam);
    });

    test('🔴 打错字回落 ARKit,**不抛** —— 构建命令行的错别字不该把用户切到研究臂', () {
      expect(PwVioPoseSourceSwitch.parse('xrslm'), PwVioPoseSource.arkit);
      expect(PwVioPoseSourceSwitch.parse('true'), PwVioPoseSource.arkit);
    });

    test('标签是落盘契约的一部分,取值封闭', () {
      expect(PwVioPoseSourceSwitch.labelOf(PwVioPoseSource.arkit), 'arkit');
      expect(PwVioPoseSourceSwitch.labelOf(PwVioPoseSource.xrslam), 'xrslam');
    });
  });

  // ══ (c) capture_session 的新分支 ═══════════════════════════════════════
  group('CaptureSession 位姿源闸:显式 switch,不是隐式 == arkit', () {
    test('arkit / xrslam 带相机几何;imu 不带', () {
      expect(
        CaptureSession.debugPoseSourceCarriesCameraGeometry('arkit'),
        isTrue,
      );
      expect(
        CaptureSession.debugPoseSourceCarriesCameraGeometry('xrslam'),
        isTrue,
        reason: '🔴 这一条正是旧的 `== \'arkit\'` 闸会静默丢掉的那个源',
      );
      expect(
        CaptureSession.debugPoseSourceCarriesCameraGeometry('imu'),
        isFalse,
        reason: 'IMU 推算出来的外参属于一个 ARKit 已经放弃的帧,必须丢',
      );
    });

    test('🔴 未知源 **抛 StateError**,不静默当成 ARKit 也不静默丢', () {
      expect(
        () => CaptureSession.debugPoseSourceCarriesCameraGeometry('who_knows'),
        throwsA(isA<StateError>()),
      );
    });

    test('provider 自报未知标签 ⇒ 会话一用就炸,而不是拍到一半才发现丢了外参', () async {
      final tmp = await Directory.systemTemp.createTemp('vio-bogus-label-');
      final session = CaptureSession(
        poseProvider: _BogusLabelProvider(),
        captureDirectoryFactory: () async => Directory('${tmp.path}/capture'),
      );
      addTearDown(() async {
        await session.dispose();
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      expect(
        () => session.debugPlatformPoseSourceLabel,
        throwsA(isA<StateError>()),
      );
    });

    test('不实现 ARPoseSourceLabel 的 provider(既有 mock / 平台臂)= arkit', () async {
      final tmp = await Directory.systemTemp.createTemp('vio-default-label-');
      final session = CaptureSession(
        poseProvider: _PlainProvider(),
        captureDirectoryFactory: () async => Directory('${tmp.path}/capture'),
      );
      addTearDown(() async {
        await session.dispose();
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      expect(session.debugPlatformPoseSourceLabel, 'arkit');
      expect(session.debugLastPoseSource, 'arkit');
    });
  });

  // ══ (b) 开关 ON:位姿到达消费点 ═════════════════════════════════════════
  group('开关 ON:XRSLAM 位姿到达 CaptureSession 的消费点', () {
    test('位姿 + 外参 + 内参 + 可信度全部穿过去,且源标签是 xrslam', () async {
      PwVioPoseSourceSwitch.debugOverride = PwVioPoseSource.xrslam;
      expect(PwVioPoseSourceSwitch.isSelfVio, isTrue);

      final provider = _providerWithScriptedEngine(<EngineSnapshot>[
        _tracking(1.0),
        _tracking(2.0),
        _tracking(3.0),
      ]);
      final tmp = await Directory.systemTemp.createTemp('vio-on-');
      final session = CaptureSession(
        poseProvider: provider,
        captureDirectoryFactory: () async => Directory('${tmp.path}/capture'),
      );
      addTearDown(() async {
        await session.dispose();
        await provider.dispose();
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      expect(session.debugPlatformPoseSourceLabel, 'xrslam');

      final received = <ARPose>[];
      final sub = session.poseStream.listen(received.add);
      addTearDown(sub.cancel);

      final confidences = <VioPoseConfidence>[];
      final confSub = provider.confidenceStream.listen(confidences.add);
      addTearDown(confSub.cancel);

      await session.attach();
      // 手工驱动三帧。不依赖真实定时器。
      provider.tick();
      provider.tick();
      provider.tick();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received.length, 3, reason: '三帧必须一帧不少地到达消费点');
      final last = received.last;
      expect(last.isTracking, isTrue, reason: 'TRACKING_SUCCESS + 合法四元数 ⇒ 6DOF');
      expect(last.extrinsic4x4.length, 16, reason: 'camera→world 列主序 4×4');
      expect(last.intrinsicFxFyCxCy, <double>[448.97, 448.97, 320.0, 240.0]);
      expect(last.imageWidth, 640);
      expect(last.imageHeight, 480);
      expect(last.trackingStateName, 'normal');
      // 🔴 [pw 2026-09-22 零 ARKit 那一刀改了这三行] 原断言是「位置逐位等于
      //    引擎给的三元组,证明没有偷偷换轴」。现在**故意换轴了** ——
      //    见 `xrslam_world_axis.dart`:x_A=−y_X / y_A=+z_X / z_A=−x_X。
      //    这里改成按那张表逐位断言,所以它仍然是「没有第二个隐藏变换」的
      //    判据,只是真值换成了那张表。
      final double ex = 0.1 * 3.0, ey = 0.2 * 3.0, ez = 0.3 * 3.0;
      expect(last.position.x, closeTo(-ey, 1e-12));
      expect(last.position.y, closeTo(ez, 1e-12));
      expect(last.position.z, closeTo(-ex, 1e-12));

      // 落盘标签走的是新分支。
      expect(session.debugLastPoseSource, 'xrslam');
      expect(
        CaptureSession.debugPoseSourceCarriesCameraGeometry(
          session.debugLastPoseSource,
        ),
        isTrue,
      );

      // 可信度:非空,且每个字段都有值。
      expect(confidences.length, 3);
      final c = provider.confidence;
      expect(c, isNotNull);
      expect(confidences.last.tier, c.tier);
      expect(c.poseStage, isNotNull);
      expect(c.scaleVerdict, isNotNull);
      expect(c.initPhase, isNotNull);
      expect(c.toleranceRelative, kPwEstimatedDimensionToleranceRelative);
      expect(c.toJson()['tolerance_provenance'], 'product_decision_2026_09_22');
      // 🔴 尺度可观测性没有样本 ⇒ 绝不许报绝对尺寸。fail-safe 方向。
      expect(c.mayReportAbsoluteDimensions, isFalse);
      expect(c.tier, isNot(VioPoseTrustTier.metric));
    });

    test('引擎没出位姿 ⇒ 优雅降级:isTracking=false、tier=none、不抛', () async {
      final provider = _providerWithScriptedEngine(<EngineSnapshot>[
        EngineSnapshot(
          state: XRSLAMState.XRSLAM_STATE_INITIALIZING.value,
          quaternionXyzw: const <double>[0, 0, 0, 0],
          translationXyz: const <double>[0, 0, 0],
          timestampSeconds: 0,
        ),
      ]);
      addTearDown(provider.dispose);

      final poses = <ARPose>[];
      final sub = provider.start().listen(poses.add);
      addTearDown(sub.cancel);
      expect(provider.tick, returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(poses.length, 1);
      expect(poses.single.isTracking, isFalse);
      expect(poses.single.extrinsic4x4, isEmpty);
      expect(
        poses.single.scaleAlignAnchorCount,
        0,
        reason: '🔴 GetResultFeatures 是空实现 ⇒ 锚点数只能是 0,不许编一个填上',
      );
      expect(provider.confidence.tier, VioPoseTrustTier.none);
      expect(provider.confidence.mayReportAbsoluteDimensions, isFalse);
    });

    test('🔴 XRSLAM 臂成片接口不可用(单测无原生符号)⇒ 帧保存如实返回 unsupported,不假装成功', () async {
      final provider = _providerWithScriptedEngine(<EngineSnapshot>[
        _tracking(1.0),
      ]);
      addTearDown(provider.dispose);
      // [pw 2026-09-22 成片提升] saveCurrentFrame 先要位姿再拍(没位姿是
      // no_pose,不进接口那一层);tick 一次给它一条 6DOF 位姿。
      provider.tick();
      final result = await provider.saveCurrentFrame(
        const ARFrameSaveSpec(
          frameID: 'cap-1',
          cellIndex: 0,
          slotIndex: 0,
          jpegPath: '/tmp/x.jpg',
          metadataPath: '/tmp/x.json',
        ),
      );
      expect(result.saved, isFalse);
      expect(result.status, 'unsupported');
      expect(await provider.saveCurrentFrameAsJpeg(
        jpegPath: '/tmp/x.jpg',
        metadataPath: '/tmp/x.json',
      ), isFalse);
    });
  });
}

/// 既有形状:不实现 `ARPoseSourceLabel` ⇒ 默认 `'arkit'`。
class _PlainProvider implements ARPoseProvider {
  @override
  ARPose? get lastPose => null;

  @override
  Stream<ARPose> start() => const Stream<ARPose>.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async => null;

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async => false;

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async =>
      ARFrameSaveResult(spec: spec, status: 'unsupported');

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
    bool feedSfm = false,
    bool deriveAuxiliary = true,
    bool stagePhotoFeedback = false,
    String? transactionId,
    String? cardTexturePath,
    double? maxTimestampDelta,
  }) async => null;
}
