// 开关 OFF 的**逐位不变**对照。
//
// ══ 这个测试证明什么 ═══════════════════════════════════════════════════════
// `PW_VIO_POSE_SOURCE` 默认空 ⇒ 生产走 ARKit,与接线之前**一行行为都不变**。
// 「不变」不靠读代码判断,靠一个**录制回放 → 位姿序列哈希**的对照:
//
//   ① `_ReplayPoseProvider` 回放一段写死的 ARPose 脚本(覆盖 ARKit normal /
//      limited 无锚 / limited 有锚三条支路,也就是 `_resolveHybridPose` 的
//      全部分支);
//   ② 把 `CaptureSession.poseStream` 交出的**混合解算后**位姿逐字段规范化
//      序列化,取 sha256;
//   ③ 与写死的金值比。
//
// 🔴 金值是在**接线之前**的 HEAD(`f0b3a40`)上跑这同一个文件算出来的,不是
//    改完代码再回填的。步骤记在 agentA 报告里:先在 pristine worktree 上跑
//    一遍打印出哈希 → 再动 lib/ → 重跑必须相同。
//
// 🔴 为什么哈希的是 poseStream 而不是 `_onPoseTick` 的落盘产物:
//    `_onPoseTick` 的 origin-settle 闸读的是 `_clock.elapsedMicroseconds`
//    (真实墙钟),同一份输入两次跑不出同一个结果 —— 拿它做金值只会得到
//    一个随机失败的测试。位姿序列是这条链上**确定性的**那一段,也正是
//    「换位姿源会动什么」的那一段。

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/capture_session.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

/// 回放固定脚本的 provider。没有相机、没有平台通道 —— 纯数据。
class _ReplayPoseProvider implements ARPoseProvider {
  _ReplayPoseProvider(this._script);

  final List<ARPose> _script;
  ARPose? _last;

  @override
  ARPose? get lastPose => _last;

  @override
  Stream<ARPose> start() async* {
    for (final p in _script) {
      _last = p;
      yield p;
    }
  }

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

/// 固定脚本。12 帧,覆盖 `_resolveHybridPose` 的每一条支路。
List<ARPose> _buildScript() {
  final poses = <ARPose>[];
  for (var i = 0; i < 12; i++) {
    final t = i * 0.1;
    // 前 2 帧 pre-lock(hasOrigin=false);
    // 第 3-6 帧 ARKit normal(建立 hybrid anchor);
    // 第 7-9 帧 ARKit limited(有锚 ⇒ 走 IMU 代入支路);
    // 第 10-12 帧 ARKit normal(走 IMU→ARKit 过渡 ramp 支路)。
    final hasOrigin = i >= 2;
    final isTracking = !(i >= 6 && i <= 8);
    poses.add(
      ARPose(
        position: Vector3(0.1 * i, 0.02 * i, 1.0 - 0.03 * i),
        orientation: Quaternion(0.0, 0.0, 0.0, 1.0),
        azimuth: 0.05 * i,
        elevation: 0.01 * i,
        isTracking: isTracking,
        timestamp: t,
        hasOrigin: hasOrigin,
        worldOrigin: hasOrigin ? Vector3(0, 0, 0) : Vector3.zero(),
        worldYaw: hasOrigin ? 0.25 : 0.0,
        extrinsic4x4: List<double>.generate(16, (k) => k.toDouble()),
        intrinsicFxFyCxCy: const <double>[1000.0, 1000.0, 640.0, 480.0],
        imageWidth: 1280,
        imageHeight: 960,
        scaleAlignAnchorCount: 24,
        scaleAlignDepthSpanM: 0.8,
        scaleAlignReliabilityPrior: 0.6,
        trackingStateName: isTracking ? 'normal' : 'limited_excessive_motion',
      ),
    );
  }
  return poses;
}

String _canonical(ARPose p) => <String>[
  p.position.x.toString(),
  p.position.y.toString(),
  p.position.z.toString(),
  p.orientation.x.toString(),
  p.orientation.y.toString(),
  p.orientation.z.toString(),
  p.orientation.w.toString(),
  p.azimuth.toString(),
  p.elevation.toString(),
  p.isTracking.toString(),
  p.timestamp.toString(),
  p.hasOrigin.toString(),
  p.worldOrigin.x.toString(),
  p.worldOrigin.y.toString(),
  p.worldOrigin.z.toString(),
  p.worldYaw.toString(),
  p.extrinsic4x4.length.toString(),
  p.extrinsic4x4.join(','),
  p.intrinsicFxFyCxCy.join(','),
  p.imageWidth.toString(),
  p.imageHeight.toString(),
  p.scaleAlignAnchorCount.toString(),
  p.scaleAlignDepthSpanM.toString(),
  p.scaleAlignReliabilityPrior.toString(),
  p.trackingStateName ?? 'null',
].join('|');

/// 🔴 接线前的 HEAD(`f0b3a40`)上算出的金值。改动 lib/ 之后必须仍是这个数。
const String kOffParityPoseSequenceSha256 =
    'b3362fb59f7793e18facfb6d84a6b5bf7104088bb379a6b84711340ae8f905ad';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorsMethodChannel = MethodChannel(
    'dev.fluttercommunity.plus/sensors/method',
  );

  test('开关 OFF:回放脚本的位姿序列哈希与接线前逐位相同', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, (_) async => null);
    final tmp = await Directory.systemTemp.createTemp('vio-off-parity-');
    final session = CaptureSession(
      poseProvider: _ReplayPoseProvider(_buildScript()),
      captureDirectoryFactory: () async => Directory('${tmp.path}/capture'),
    );
    addTearDown(() async {
      await session.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sensorsMethodChannel, null);
    });

    final seen = <String>[];
    final done = session.poseStream.listen((p) => seen.add(_canonical(p)));
    addTearDown(done.cancel);

    await session.attach();
    // 🔴 **不用固定 sleep 等事件循环**。固定 50ms 在单文件下够、在全量套件
    //    并发下不够 —— 那会变成一个「机器忙就红」的假失败。改成有界轮询:
    //    收满 12 帧就走,超时 10 秒判死(教训同「真机测试单场必须有硬上限」)。
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (seen.length < 12 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(seen.length, 12, reason: '12 帧脚本必须一帧不少地穿过混合解算');
    final digest = sha256.convert(seen.join('\n').codeUnits).toString();
    // ignore: avoid_print
    print('[OFF-PARITY] poseStream sha256 = $digest');
    expect(digest, kOffParityPoseSequenceSha256);
  });
}
