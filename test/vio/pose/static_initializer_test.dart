// static_initializer_test.dart —— 编排层的测试。
//
// 这一层不新增判据,所以测的是**编排本身**:
//   ① 姿态确实取自**老半窗**(用两半窗朝向不同的构造样本来证)
//   ② 决策为 refuse / dynamicInit 时**一定不给**姿态
//      —— 即「静止 ≠ 能初始化」,这是本层存在的主要理由
//   ③ 解不出来交 null,不退化成单位姿态
//   ④ 接到 VioPoseSource 之后,档位与 OpenXR 语义一致

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/gravity_attitude.dart';
import 'package:pocketworld_flutter/vio/pose/static_initializer.dart';
import 'package:pocketworld_flutter/vio/pose/stationarity_gate.dart';
import 'package:pocketworld_flutter/vio/pose/tracked_pose.dart';
import 'package:pocketworld_flutter/vio/pose/vio_pose_source.dart';

const double _g = GravityAttitude.nominalGravity;

ImuSample _s({
  required double t,
  required double ax,
  required double ay,
  required double az,
  double gyro = 0,
}) =>
    ImuSample(
        timestampSeconds: t, ax: ax, ay: ay, az: az, gx: gyro, gy: 0, gz: 0);

/// 喂满一个 2.2 秒的窗(2.0 窗 + 0.10 余量,再多一点确保 windowFull)。
/// [accelAt] 按时刻给比力,这样可以让**两半窗朝向不同**。
void _feed(
  StaticInitializer init, {
  required List<double> Function(double t) accelAt,
  double seconds = 2.2,
  double hz = 100,
}) {
  final int n = (seconds * hz).round();
  for (int i = 0; i < n; i++) {
    final double t = (i + 1) / hz;
    final List<double> a = accelAt(t);
    init.addImu(_s(t: t, ax: a[0], ay: a[1], az: a[2]));
  }
}

StationarityGate _gate({required bool zupt}) => StationarityGate(
      imuExcitationThreshold: 0.45, // tum_vi
      disparityThresholdPixels: 15.0, // tum_vi
      zeroVelocityUpdateEnabled: zupt,
      // 🔴 窗长这里用默认 2.0 而非 tum_vi 的 1.5,是为了让测试里的
      //    「两半各 1.0 秒」算起来干净;判据本身与窗长无关。
    );

void main() {
  group('① 姿态取自老半窗,不是整窗、不是新半窗', () {
    test('老半窗 +z 朝上、新半窗翻到 +x —— 解出的重力方向必须跟**老**的那半',
        () {
      final StaticInitializer init =
          StaticInitializer(gate: _gate(zupt: true));
      // 老半窗 (0.20,1.20]:比力 = (0,0,+g) ⇒ 设备 z 轴朝上
      // 新半窗 (1.20,2.20]:比力 = (+g,0,0) ⇒ 设备 x 轴朝上
      _feed(init,
          accelAt: (double t) =>
              t > 1.2 ? <double>[_g, 0, 0] : <double>[0, 0, _g]);
      init.setDisparity(
          older: 0.1, newer: 0.1, featureCountOlder: 100, featureCountNewer: 100);

      final StaticInitAttempt a = init.attempt();
      expect(a.hasAttitude, isTrue, reason: a.blockedBy ?? '');
      expect(a.olderHalfSampleCount, 100);

      // 🔴 判别量必须能分辨两半窗。**零偏不行**:
      //    bias = mean_acc + local_gravity,而 local_gravity 是用**同一批
      //    样本**解出的姿态转出来的 ⇒ 无论用哪半窗,零偏都≈0。
      //    拿它断言等于断言代码等于它自己。
      //
      //    能分辨的是**姿态四元数本身**:
      //      老半窗 mean_acc=(0,0,g) ⇒ −mean_acc 归一化 =(0,0,−1)
      //        = globalGravityZUp 本身 ⇒ 对齐自己 ⇒ **单位四元数**(w≈1)
      //      新半窗 mean_acc=(g,0,0) ⇒ −mean_acc 归一化 =(−1,0,0)
      //        与 (0,0,−1) 夹角 90° ⇒ w≈cos45°≈0.707
      //    两者相差 0.29,远大于任何数值噪声。
      expect(a.attitude!.attitude.w.abs(), closeTo(1.0, 1e-9),
          reason: '用错成新半窗会是 ≈0.707');
      expect(a.attitude!.attitude.w.abs(), isNot(closeTo(math.sqrt1_2, 1e-3)),
          reason: '阴性对照:新半窗的答案必须被排除');
    });

    test('时间戳落在老半窗的最后一条上(OpenVINS StaticInitializer.cpp:134)', () {
      final StaticInitializer init =
          StaticInitializer(gate: _gate(zupt: true));
      _feed(init, accelAt: (_) => <double>[0, 0, _g]);
      init.setDisparity(
          older: 0.1, newer: 0.1, featureCountOlder: 100, featureCountNewer: 100);
      final StaticInitAttempt a = init.attempt();
      expect(a.hasAttitude, isTrue);
      // 老半窗是 (1.20−1.00, 1.20] = (0.20, 1.20],最后一条恰是 t=1.20。
      expect(a.attitude!.timestampSeconds, closeTo(1.20, 1e-9));
    });
  });

  group('🔴 ②「设备静止」不等于「可以初始化」', () {
    StaticInitializer stillWith({required bool zupt}) {
      final StaticInitializer init = StaticInitializer(gate: _gate(zupt: zupt));
      _feed(init, accelAt: (_) => <double>[0, 0, _g]);
      init.setDisparity(
          older: 0.1, newer: 0.1, featureCountOlder: 100, featureCountNewer: 100);
      return init;
    }

    test('try_zupt=false(上游 14 份里 12 份)⇒ 判静止,但**不给姿态**', () {
      final StaticInitAttempt a = stillWith(zupt: false).attempt();
      expect(a.verdict.state, Stationarity.stationary, reason: '它确实静止');
      expect(a.verdict.decision, InitDecision.refuse);
      expect(a.hasAttitude, isFalse, reason: '🔴 静止 ≠ 能初始化');
      expect(a.blockedBy, contains('wait_for_jerk'));
    });

    test('try_zupt=true ⇒ 同样的数据,这次给姿态', () {
      final StaticInitAttempt a = stillWith(zupt: true).attempt();
      expect(a.verdict.decision, InitDecision.staticWhileStationary);
      expect(a.hasAttitude, isTrue);
      expect(a.blockedBy, isNull);
    });

    test('数据不足(窗没满)⇒ unknown + 无姿态,且归因说得出是哪一环', () {
      final StaticInitializer init =
          StaticInitializer(gate: _gate(zupt: true));
      _feed(init, accelAt: (_) => <double>[0, 0, _g], seconds: 1.0);
      init.setDisparity(
          older: 0.1, newer: 0.1, featureCountOlder: 100, featureCountNewer: 100);
      final StaticInitAttempt a = init.attempt();
      expect(a.verdict.state, Stationarity.unknown);
      expect(a.hasAttitude, isFalse);
      expect(a.blockedBy, contains('窗未满'));
    });

    test('没有视差输入 ⇒ 无姿态(不拿 IMU 单方面下结论)', () {
      final StaticInitializer init =
          StaticInitializer(gate: _gate(zupt: true));
      _feed(init, accelAt: (_) => <double>[0, 0, _g]);
      init.setDisparity(older: null, newer: null);
      final StaticInitAttempt a = init.attempt();
      expect(a.hasAttitude, isFalse);
      expect(a.blockedBy, contains('无视差'));
    });
  });

  group('③ 解不出来交 null,不退化成单位姿态', () {
    test('老半窗样本数低于门槛 ⇒ null,且说出是几条', () {
      final StaticInitializer init = StaticInitializer(
        gate: _gate(zupt: true),
        minimumSamplesForAttitude: 500, // 故意调到拿不到
      );
      _feed(init, accelAt: (_) => <double>[0, 0, _g]);
      init.setDisparity(
          older: 0.1, newer: 0.1, featureCountOlder: 100, featureCountNewer: 100);
      final StaticInitAttempt a = init.attempt();
      expect(a.verdict.decision, InitDecision.staticWhileStationary,
          reason: '门是放行的');
      expect(a.hasAttitude, isFalse, reason: '但姿态解不出来');
      expect(a.blockedBy, contains('100'));
      expect(a.blockedBy, contains('500'));
    });
  });

  group('④ 接到 VioPoseSource:档位符合 OpenXR 语义', () {
    EnginePoseSample noData(double t) => EnginePoseSample(
          ok: false,
          quaternionXyzw: const <double>[0, 0, 0, 0],
          translationXyz: const <double>[0, 0, 0],
          timestampSeconds: t,
        );

    EnginePoseSample sixDof(double t) => EnginePoseSample(
          ok: true,
          quaternionXyzw: const <double>[0, 0, 0, 1],
          translationXyz: const <double>[1, 2, 3],
          timestampSeconds: t,
        );

    StaticInitPoseChain chainWith({required bool zupt}) {
      final StaticInitPoseChain c = StaticInitPoseChain(
        initializer: StaticInitializer(gate: _gate(zupt: zupt)),
      );
      _feedChain(c);
      c.setDisparity(
          older: 0.1, newer: 0.1, featureCountOlder: 100, featureCountNewer: 100);
      return c;
    }

    test('引擎没数据 + 静止 + try_zupt 开 ⇒ orientationOnly(3DOF)', () {
      final StaticInitPoseChain c = chainWith(zupt: true);
      final TrackedPose p =
          c.update(sample: noData(2.2), nowSeconds: 2.2);
      expect(c.source.stage, VioPoseStage.orientationOnly);
      expect(p.orientation, isNotNull);
      expect(p.position, isNull, reason: '位置不可观,故意不给');
      expect(c.lastAttempt!.hasAttitude, isTrue);
    });

    test('🔴 同样静止,try_zupt 关 ⇒ 降到 none,不是 3DOF', () {
      final StaticInitPoseChain c = chainWith(zupt: false);
      c.update(sample: noData(2.2), nowSeconds: 2.2);
      expect(c.source.stage, VioPoseStage.none);
      expect(c.lastAttempt!.hasAttitude, isFalse);
      // 这一条就是 try_zupt 这个开关对**产品**的全部后果:
      // 用户举着手机不动,默认配置下连 3DOF 都拿不到。
    });

    test('引擎给了 6DOF ⇒ 用引擎的,且**不再**去算静止姿态', () {
      final StaticInitPoseChain c = chainWith(zupt: true);
      final TrackedPose p = c.update(sample: sixDof(2.2), nowSeconds: 2.2);
      expect(c.source.stage, VioPoseStage.tracking);
      expect(p.position, isNotNull);
      expect(c.lastAttempt, isNull, reason: '跟踪期不该每帧解姿态');
    });

    test('跟过之后再丢 ⇒ lastKnown,不回退到静止姿态', () {
      final StaticInitPoseChain c = chainWith(zupt: true);
      c.update(sample: sixDof(2.2), nowSeconds: 2.2);
      c.update(sample: noData(2.5), nowSeconds: 2.5);
      expect(c.source.stage, VioPoseStage.lastKnown);
      expect(c.lastAttempt, isNull,
          reason: 'hasEverTracked 之后不再走静止初始化');
    });

    test('reset 之后回到初始态', () {
      final StaticInitPoseChain c = chainWith(zupt: true);
      c.update(sample: sixDof(2.2), nowSeconds: 2.2);
      c.reset();
      expect(c.source.hasEverTracked, isFalse);
      expect(c.source.stage, VioPoseStage.none);
      expect(c.initializer.gate.count, 0);
    });
  });
}

void _feedChain(StaticInitPoseChain c, {double seconds = 2.2, double hz = 100}) {
  final int n = (seconds * hz).round();
  for (int i = 0; i < n; i++) {
    final double t = (i + 1) / hz;
    c.addImu(_s(t: t, ax: 0, ay: 0, az: _g));
  }
}
