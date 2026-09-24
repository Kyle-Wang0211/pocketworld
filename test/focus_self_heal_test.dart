// focus_self_heal_test.dart —— 对焦自愈环判定循环的单测。
//
// ══ 这条测试在防什么 ═══════════════════════════════════════════════════════
// 自愈环是**移植**:三个判据里两个逐字抄生产
// (`lib/ui/official_capture/ar_capture_page.dart:512-563`),第三个(「糊」怎么
// 判)因为换了裁判而必须重定阈值。移植最容易出的两种错:
//   ① 抄错数(1800/5000/0.06/0.10 抄成别的);
//   ② 换阈值换成了一个**永远不会报警**或**永远在报警**的东西。
// ⇒ 下面每一条都成对写:一条证明它在该踢的时候踢,一条证明它在不该踢的时候
//    闭嘴(feedback_verify_with_a_metric_that_can_fail)。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/capture/focus_self_heal.dart';
import 'package:vector_math/vector_math_64.dart';

/// 记账用的执行器:只数「被踢了几次」,不碰任何平台。
class _CountingNudger implements FocusNudger {
  int calls = 0;
  bool accept = true;

  @override
  bool nudge() {
    calls++;
    return accept;
  }

  @override
  String get describe => '_CountingNudger(单测)';
}

/// 30 Hz 喂样的小跑台。位姿默认不动(= 静止),度量由调用方给。
class _Rig {
  _Rig({this.accept = true}) : nudger = (_CountingNudger()..accept = accept);

  final bool accept;
  final _CountingNudger nudger;
  late final FocusSelfHeal heal = FocusSelfHeal(nudger: nudger);

  /// 🔴 从一个够大的时刻起步:`_prevPoseMs` 初值 0,而位姿采样的刷新条件是
  /// `now - _prevPoseMs > 400`(生产 `:539`)⇒ 起点必须 > 400,否则第一帧
  /// 不会记下前一次位姿,静止判据在前 400 ms 里恒假。
  int t = 100000;

  int fired = 0;

  void feed(
    double measure, {
    int frames = 1,
    int stepMs = 33,
    bool adjusting = false,
    Vector3? position,
    Quaternion? orientation,
  }) {
    for (int i = 0; i < frames; i++) {
      if (heal.onSample(
        nowMs: t,
        focusMeasure: measure,
        isAdjustingFocus: adjusting,
        position: position ?? Vector3.zero(),
        orientation: orientation ?? Quaternion.identity(),
      )) {
        fired++;
      }
      t += stepMs;
    }
  }
}

void main() {
  group('自愈环:逐字抄生产的那两个判据', () {
    test('阈值就是生产那几个数,一个没改', () {
      // 生产 ar_capture_page.dart:551 / :539 / :527 / :537。
      expect(FocusSelfHeal.kBlurHoldMs, 1800);
      expect(FocusSelfHeal.kThrottleMs, 5000);
      expect(FocusSelfHeal.kPoseRefreshMs, 400);
      expect(FocusSelfHeal.kPoseMaxAgeMs, 900);
      expect(FocusSelfHeal.kStationaryMoveM, 0.06);
      expect(FocusSelfHeal.kStationaryAngleRad, 0.10);
    });

    test('换掉的那个阈值来自 libcamera 的 retriggerRatio,不是我随手定的', () {
      // vendor/pw_af/af_scan.cpp:77(libcamera af.h:97,normal 档官方值)。
      expect(FocusSelfHeal.kRetriggerRatio, 0.8);
    });
  });

  group('自愈环:该踢的时候踢', () {
    test('持续糊 1.8s + 静止 ⇒ 踢一脚,并记下触发现场', () {
      final _Rig r = _Rig();
      r.feed(1000, frames: 10); // 先建参考值
      expect(r.heal.sceneReference, 1000);
      expect(r.fired, 0);

      // 500 + 1 < 0.8 × 1000 = 800 ⇒ 判糊。1.8 s ≈ 55 帧 @30 Hz。
      r.feed(500, frames: 60);
      expect(r.fired, 1);
      expect(r.nudger.calls, 1);

      final FocusNudgeEvent ev = r.heal.events.single;
      expect(ev.index, 1);
      expect(ev.measureAtTrigger, 500);
      expect(ev.referenceAtTrigger, 1000);
      expect(ev.blurHeldMs, greaterThanOrEqualTo(FocusSelfHeal.kBlurHoldMs));
      expect(ev.dispatched, isTrue);
    });

    test('动作后 2 s 的观察窗会关闭,并记下峰值与窗口末值', () {
      final _Rig r = _Rig();
      r.feed(1000, frames: 10);
      r.feed(500, frames: 60);
      expect(r.heal.events.single.closed, isFalse);

      // 踢完之后镜头扫到位,度量回到 1400(峰值),再落到 1200。
      r.feed(1400, frames: 30);
      r.feed(1200, frames: 45); // 合计 > 2000 ms
      final FocusNudgeEvent ev = r.heal.events.single;
      expect(ev.closed, isTrue);
      expect(ev.measurePeakAfter, 1400);
      expect(ev.measureAfter, 1200);
      expect(ev.measureAfterMs, greaterThanOrEqualTo(2000));
      expect(ev.gainPeak, closeTo(2.8, 1e-9)); // 1400 / 500
    });
  });

  group('自愈环:不该踢的时候闭嘴(阴性对照)', () {
    test('没有参考值(相机没起 / 度量恒 0)⇒ 永远不踢', () {
      final _Rig r = _Rig();
      r.feed(0, frames: 300); // 10 秒
      expect(r.fired, 0);
      expect(r.heal.sceneReference, 0);
      expect(r.heal.lastBlurred, isFalse);
    });

    test('一直清晰 ⇒ 不踢,且参考值跟着抬高', () {
      final _Rig r = _Rig();
      r.feed(1000, frames: 60);
      r.feed(1500, frames: 60);
      expect(r.fired, 0);
      expect(r.heal.sceneReference, 1500);
    });

    test('糊但在动 ⇒ 不踢(那是运动模糊,生产 :549 同款)', () {
      final _Rig r = _Rig();
      r.feed(1000, frames: 10);
      // 每帧挪 10 cm > 0.06 m ⇒ 判不静止。
      for (int i = 0; i < 120; i++) {
        r.heal.onSample(
          nowMs: r.t,
          focusMeasure: 500,
          isAdjustingFocus: false,
          position: Vector3(0.1 * i, 0, 0),
          orientation: Quaternion.identity(),
        );
        r.t += 33;
      }
      expect(r.nudger.calls, 0);
      expect(r.heal.lastBlurred, isTrue); // 判据确实判出糊了
      expect(r.heal.lastStationary, isFalse); // 只是被静止那一闸拦下
    });

    test('刚跌破 0.8 那条线之下一点点也算糊;刚好在线上不算', () {
      final _Rig a = _Rig()..feed(1000, frames: 5);
      a.feed(798, frames: 1); // 798 + 1 = 799 < 800 ⇒ 糊
      expect(a.heal.lastBlurred, isTrue);

      final _Rig b = _Rig()..feed(1000, frames: 5);
      b.feed(799, frames: 1); // 799 + 1 = 800,不小于 800 ⇒ 不糊
      expect(b.heal.lastBlurred, isFalse);
    });

    test('节流:5 s 内不会踢第二脚,超过 5 s 才允许', () {
      final _Rig r = _Rig();
      r.feed(1000, frames: 10);
      r.feed(500, frames: 60); // 第一脚
      expect(r.fired, 1);
      // 继续糊 4 秒(约 120 帧)⇒ 持续糊够了,但节流没到。
      r.feed(500, frames: 120);
      expect(r.fired, 1);
      // 再糊 2 秒 ⇒ 节流到点,第二脚。
      r.feed(500, frames: 60);
      expect(r.fired, 2);
    });

    test('糊一下又好了 ⇒ 计时清零,不会攒够 1.8 s', () {
      final _Rig r = _Rig();
      r.feed(1000, frames: 10);
      for (int i = 0; i < 20; i++) {
        r.feed(500, frames: 30); // 糊 ~1 s
        r.feed(1000, frames: 2); // 清晰一下 ⇒ _blurSinceMs 清零
      }
      expect(r.fired, 0);
    });
  });

  group('自愈环:参考值的两处偏离', () {
    test('isAdjustingFocus 真→假(苹果宣布落定)⇒ 参考值重置到落定值', () {
      final _Rig r = _Rig();
      r.feed(1000, frames: 10);
      expect(r.heal.sceneReference, 1000);
      // 镜头在动
      r.feed(400, frames: 5, adjusting: true);
      expect(r.heal.sceneReference, 1000); // 动的时候不重置
      // 落定在 400 ⇒ 参考值跟着下来,自愈环随之闭嘴(不做踢腿机)
      r.feed(400, frames: 1);
      expect(r.heal.sceneReference, 400);
      r.feed(400, frames: 200);
      expect(r.fired, 0);
    });

    test('度量比参考还高 ⇒ 抬高参考(上游双向重触发的那一侧折叠成抬参考)', () {
      final _Rig r = _Rig();
      r.feed(100, frames: 3);
      expect(r.heal.sceneReference, 100);
      r.feed(5000, frames: 3);
      expect(r.heal.sceneReference, 5000);
      expect(r.fired, 0);
    });
  });

  group('自愈环:执行器', () {
    test('执行器拒了也照样记事件,dispatched=false(别把判了当成踢了)', () {
      final _Rig r = _Rig(accept: false);
      r.feed(1000, frames: 10);
      r.feed(500, frames: 60);
      expect(r.heal.nudgeCount, 1);
      expect(r.heal.dispatchedCount, 0);
      expect(r.heal.events.single.dispatched, isFalse);
    });

    test('NoopFocusNudger 永不下发', () {
      const FocusNudger n = NoopFocusNudger('单测');
      expect(n.nudge(), isFalse);
      expect(n.describe, '单测');
    });

    test('manifest 块把「哪些是抄的、哪些是偏离」分开写', () {
      final _Rig r = _Rig();
      r.feed(1000, frames: 10);
      r.feed(500, frames: 60);
      final Map<String, Object?> j = r.heal.toJson();
      final Map<String, Object?> verbatim =
          j['verbatim_thresholds']! as Map<String, Object?>;
      expect(verbatim['blur_hold_ms'], 1800);
      expect(verbatim['throttle_ms'], 5000);
      final Map<String, Object?> dev =
          j['deviation_blur_criterion']! as Map<String, Object?>;
      // 偏离必须写清楚:生产用什么、我们用什么、为什么不能照搬阈值。
      expect(dev['production'], contains('sharpnessConsensus'));
      expect(dev['ours'], contains('Tenengrad'));
      expect(dev['why_threshold_cannot_be_copied'], contains('量纲'));
      expect(dev['ratio_source'], contains('af_scan.cpp:77'));
      expect(dev['form_source'], contains('af_scan.cpp:227'));
      expect(j['nudges'], 1);
      expect((j['events']! as List<Object?>).length, 1);
      expect((j['ported_from']! as Map<String, Object?>)['judge'],
          contains('ar_capture_page.dart:512-563'));
    });

    test('距上次 nudge / 持续糊 这两个读数给得出来(状态条要显示)', () {
      final _Rig r = _Rig();
      expect(r.heal.msSinceLastNudge(r.t), isNull); // 从没踢过 ⇒ null,不是 0
      expect(r.heal.blurHeldMs(r.t), 0);
      r.feed(1000, frames: 10);
      r.feed(500, frames: 60);
      final int at = r.heal.lastNudgeMs!;
      expect(r.heal.msSinceLastNudge(at + 1234), 1234);
    });
  });
}
