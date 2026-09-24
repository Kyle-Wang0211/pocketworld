// engine_pose_poller_test.dart
//
// 🔴 本文件存在的首要理由是**一次真机事故**(2026-09-19):
//    台架 app 没链 XRSLAM ⇒ 第一次 poll 解析符号时抛异常 ⇒ 那次 poll 在
//    `requestFrame` 的 hook 里 ⇒ 异常把**整条渲染回路**打断,页面停在"运行中",
//    一帧不跑、日志里连异常都没有(被 hook 链吞了)。
//    ⇒ 「缺符号」必须是**降级**,不能是**崩溃**。下面第一组就钉这条。
//
// 其次钉住上游的判据:先查 STATE == TRACKING_SUCCESS 再读位姿,四元数 w 在第 4 位。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/engine_pose_poller.dart';
import 'package:pocketworld_flutter/vio/pose/vio_pose_source.dart';

void main() {
  group('🔴 缺符号是降级,不是崩溃', () {
    test('解析符号就抛 ⇒ poll 照常返回 ok:false,**不上抛**', () {
      final EnginePosePoller p = EnginePosePoller(
        readEngine: () =>
            throw ArgumentError('Failed to lookup symbol XRSLAMGetResult'),
      );
      addTearDown(p.dispose);

      late EnginePoseSample s;
      expect(() => s = p.poll(nowSeconds: 1.0), returnsNormally,
          reason: '🔴 一旦这里抛出去,渲染回路就会被打断 —— 事故原样复现');
      expect(s.ok, isFalse);
      expect(p.isAvailable, isFalse);
      expect(p.unavailableReason, isNotNull);
    });

    test('失败是**粘性**的:后续不再重试,也一直不抛', () {
      int calls = 0;
      final EnginePosePoller p = EnginePosePoller(readEngine: () {
        calls++;
        throw StateError('boom');
      });
      addTearDown(p.dispose);

      for (int i = 0; i < 5; i++) {
        expect(() => p.poll(nowSeconds: i.toDouble()), returnsNormally);
      }
      expect(calls, 1, reason: '每帧都去调一个会炸的符号是纯浪费');
    });

    test('dispose 之后再 poll 也不炸(用后即弃的页面会这样)', () {
      final EnginePosePoller p = EnginePosePoller(
        readEngine: () => const EngineSnapshot(
            state: 1,
            quaternionXyzw: <double>[0, 0, 0, 1],
            translationXyz: <double>[0, 0, 0],
            timestampSeconds: 0),
      );
      p.dispose();
      expect(() => p.poll(nowSeconds: 1.0), returnsNormally);
      expect(p.poll(nowSeconds: 1.0).ok, isFalse);
    });
  });

  group('口径:抄上游 XRSLAM_iOS.mm:168-184', () {
    test('🔴 实部 w 在第 4 位,不是第 0 位', () {
      expect(EnginePose7.qw, 3);
      expect(EnginePose7.qx, 0);
    });

    test('TRACKING_SUCCESS(=1)才算有位姿,按 [x,y,z,w] 取', () {
      final EnginePosePoller p = EnginePosePoller(
        readEngine: () => const EngineSnapshot(
          state: 1, // XRSLAM_STATE_TRACKING_SUCCESS
          quaternionXyzw: <double>[0.1, 0.2, 0.3, 0.9],
          translationXyz: <double>[11.0, 22.0, 33.0],
          timestampSeconds: 7.5,
        ),
      );
      addTearDown(p.dispose);
      final EnginePoseSample s = p.poll(nowSeconds: 999.0);
      expect(s.ok, isTrue);
      expect(s.quaternionXyzw, <double>[0.1, 0.2, 0.3, 0.9]);
      expect(s.translationXyz, <double>[11.0, 22.0, 33.0]);
      expect(s.timestampSeconds, 7.5,
          reason: '时间戳取引擎给的图像时刻,不是 nowSeconds');
      expect(p.lastState, 1);
    });

    test('🔴 INITIALIZING(0) / TRACKING_FAIL(2) 一律当没有位姿', () {
      // 上游的 if 就是只认 TRACKING_SUCCESS —— 其余分支根本不去读 pose。
      for (final int st in <int>[0, 2]) {
        final EnginePosePoller p = EnginePosePoller(
          readEngine: () => EngineSnapshot(
            state: st,
            quaternionXyzw: const <double>[9, 9, 9, 9], // 故意放脏数据
            translationXyz: const <double>[9, 9, 9],
            timestampSeconds: 1,
          ),
        );
        final EnginePoseSample s = p.poll(nowSeconds: 1.0);
        expect(s.ok, isFalse, reason: 'state=$st');
        expect(s.quaternionXyzw, <double>[0, 0, 0, 0],
            reason: '不得把脏数据透出去');
        expect(p.lastState, st);
        p.dispose();
      }
    });
  });

  group('接进链:引擎不可用时链仍然工作', () {
    test('缺符号 ⇒ VioPoseSource 走 none/orientationOnly,不是异常', () {
      final EnginePosePoller p = EnginePosePoller(
        readEngine: () => throw StateError('no symbol'),
      );
      addTearDown(p.dispose);
      final VioPoseSource src = VioPoseSource();

      // 没有静止姿态可用时应当是 none —— 而不是把异常抛给渲染回路。
      final pose = src.update(
        sample: p.poll(nowSeconds: 1.0),
        stationaryAttitude: null,
        nowSeconds: 1.0,
      );
      expect(src.stage, VioPoseStage.none);
      expect(pose.orientation, isNull);
      expect(pose.position, isNull);
    });
  });
}
