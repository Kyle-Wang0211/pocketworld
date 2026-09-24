// vio_pose_source_test.dart — 四档状态机的迁移,逐条对着 OpenXR 语义查。
//
// 这里每一条都是"以前压成一种、现在必须分开"的那三种情况之一。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/gravity_attitude.dart';
import 'package:pocketworld_flutter/vio/pose/tracked_pose.dart';
import 'package:pocketworld_flutter/vio/pose/vio_pose_source.dart';

EnginePoseSample okSample(double t) => EnginePoseSample(
      ok: true,
      quaternionXyzw: const <double>[0, 0, 0, 1],
      translationXyz: <double>[t, 0, 0],
      timestampSeconds: t,
    );

/// 引擎在跟踪器初始化前会 `setZero()` 四元数,却配一个合法时间戳存下来。
/// `XRSLAMTryGetLatestPose` 承诺挡掉它 —— 这条测的是"万一没挡掉"。
const EnginePoseSample degenerateButOk = EnginePoseSample(
  ok: true,
  quaternionXyzw: <double>[0, 0, 0, 0],
  translationXyz: <double>[0, 0, 0],
  timestampSeconds: 1.0,
);

StationaryAttitude flatAttitude() => GravityAttitude.solve(
      List<ImuSample>.generate(
        50,
        (int i) => ImuSample(
          timestampSeconds: i * 0.01,
          ax: 0,
          ay: 0,
          az: GravityAttitude.nominalGravity,
          gx: 0,
          gy: 0,
          gz: 0,
        ),
      ),
    )!;

void main() {
  test('(a) 什么都没有:四位全不置', () {
    final VioPoseSource s = VioPoseSource();
    final TrackedPose p = s.update(
      sample: EnginePoseSample.empty,
      nowSeconds: 0,
    );
    expect(p.orientationValid, isFalse);
    expect(p.positionValid, isFalse);
    expect(s.stage, VioPoseStage.none);
    expect(s.hasEverTracked, isFalse);
  });

  test('(b) 未初始化 + 静止姿态 ⇒ 只有朝向,位置读不到', () {
    final VioPoseSource s = VioPoseSource();
    final TrackedPose p = s.update(
      sample: EnginePoseSample.empty,
      stationaryAttitude: flatAttitude(),
      nowSeconds: 0.5,
    );
    expect(s.stage, VioPoseStage.orientationOnly);
    expect(p.orientationValid, isTrue);
    expect(p.orientationTracked, isTrue);
    expect(p.positionValid, isFalse);
    expect(p.position, isNull, reason: '位置不可观 ⇒ 必须读不到');
    expect(s.hasEverTracked, isFalse);
  });

  test('OK ⇒ 6DOF,四位全置', () {
    final VioPoseSource s = VioPoseSource();
    final TrackedPose p = s.update(sample: okSample(1.0), nowSeconds: 1.0);
    expect(s.stage, VioPoseStage.tracking);
    expect(p.isSixDegreeOfFreedom, isTrue);
    expect(p.position!.x, 1.0);
    expect(s.hasEverTracked, isTrue);
  });

  test('(c) 跟上过之后跟丢 ⇒ 位置 VALID 但不 TRACKED', () {
    final VioPoseSource s = VioPoseSource();
    s.update(sample: okSample(1.0), nowSeconds: 1.0);
    final TrackedPose p = s.update(
      sample: EnginePoseSample.empty,
      nowSeconds: 2.0,
    );
    expect(s.stage, VioPoseStage.lastKnown);
    expect(p.positionValid, isTrue, reason: '最后已知位置仍然有意义');
    expect(p.positionTracked, isFalse, reason: '但不能宣称在跟踪');
    expect(p.orientationTracked, isTrue, reason: '有 IMU,朝向仍在跟踪');
    expect(p.position!.x, 1.0);
    expect(p.timestampSeconds, 1.0, reason: '时间戳必须是那个位姿的,不是现在');
  });

  test('(c) 超过保持窗口 ⇒ 退回什么都没有', () {
    final VioPoseSource s = VioPoseSource(lastKnownHoldSeconds: 1.0);
    s.update(sample: okSample(1.0), nowSeconds: 1.0);
    final TrackedPose p = s.update(
      sample: EnginePoseSample.empty,
      nowSeconds: 10.0,
    );
    expect(s.stage, VioPoseStage.none);
    expect(p.positionValid, isFalse);
  });

  test('跟上过之后,静止姿态不再覆盖最后已知位姿', () {
    final VioPoseSource s = VioPoseSource();
    s.update(sample: okSample(1.0), nowSeconds: 1.0);
    final TrackedPose p = s.update(
      sample: EnginePoseSample.empty,
      stationaryAttitude: flatAttitude(),
      nowSeconds: 1.5,
    );
    expect(s.stage, VioPoseStage.lastKnown,
        reason: '有 6DOF 历史时,3DOF 不该把位置抹掉');
    expect(p.positionValid, isTrue);
  });

  test('🔴 OK 但四元数退化 ⇒ 绝不当成位姿往上送', () {
    final VioPoseSource s = VioPoseSource();
    final TrackedPose p =
        s.update(sample: degenerateButOk, nowSeconds: 1.0);
    expect(s.stage, VioPoseStage.none);
    expect(p.orientationValid, isFalse);
    expect(s.hasEverTracked, isFalse, reason: '退化位姿不能算"跟上过"');
  });

  test('reset 必须清掉最后已知位姿', () {
    final VioPoseSource s = VioPoseSource();
    s.update(sample: okSample(1.0), nowSeconds: 1.0);
    expect(s.hasEverTracked, isTrue);
    s.reset();
    expect(s.hasEverTracked, isFalse);
    final TrackedPose p = s.update(
      sample: EnginePoseSample.empty,
      nowSeconds: 1.5,
    );
    expect(p.positionValid, isFalse, reason: '上一场的位姿不能漏进新一场');
  });
}
