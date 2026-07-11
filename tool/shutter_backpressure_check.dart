// tool/shutter_backpressure_check.dart — ③ 快门背压闸纯 Dart VM 断言
// (host `dart tool/shutter_backpressure_check.dart`;flutter test 在此 host
// 跑不了,纯 VM 能跑 —— 项目惯例同 tool/parallax_banner_check.dart)。

import 'package:pocketworld_flutter/capture/shutter_backpressure_gate.dart';

void check(bool cond, String what) {
  if (!cond) {
    throw StateError('FAIL: $what');
  }
  // ignore: avoid_print
  print('ok: $what');
}

void main() {
  // 冷机低队列:normal。
  var p = ShutterPace.normal;
  p = shutterPaceNext(previous: p, queueDepth: 0, thermalState: 0);
  check(p == ShutterPace.normal, '冷机空队列 = normal');
  p = shutterPaceNext(previous: p, queueDepth: 5, thermalState: 0);
  check(p == ShutterPace.normal, '冷机队列5 = normal(soft 阈是 6)');

  // 冷机队列 6 → soft;滞回:5 仍 soft,4 回 normal。
  p = shutterPaceNext(previous: p, queueDepth: 6, thermalState: 0);
  check(p == ShutterPace.soft, '冷机队列6 = soft');
  p = shutterPaceNext(previous: p, queueDepth: 5, thermalState: 0);
  check(p == ShutterPace.soft, '冷机队列5(已 soft)滞回保持 soft');
  p = shutterPaceNext(previous: p, queueDepth: 4, thermalState: 0);
  check(p == ShutterPace.normal, '冷机队列4 回 normal');

  // 热机(serious=2):队列 4 即 soft;队列 3 仍 soft(热滞回);2 回 normal。
  p = shutterPaceNext(previous: p, queueDepth: 4, thermalState: 2);
  check(p == ShutterPace.soft, '热机队列4 = soft');
  p = shutterPaceNext(previous: p, queueDepth: 3, thermalState: 2);
  check(p == ShutterPace.soft, '热机队列3(已 soft)滞回保持 soft');
  p = shutterPaceNext(previous: p, queueDepth: 2, thermalState: 2);
  check(p == ShutterPace.normal, '热机队列2 回 normal');

  // 热机队列 4 但未曾 soft:critical(3)同样触发。
  p = shutterPaceNext(
    previous: ShutterPace.normal,
    queueDepth: 4,
    thermalState: 3,
  );
  check(p == ShutterPace.soft, 'critical 队列4 = soft');

  // hard:队列 10 进入;9 保持(滞回);8 退出落 soft(冷机 8 ≥ 6);
  // 一路回落到 4 才 normal。
  p = shutterPaceNext(previous: ShutterPace.soft, queueDepth: 10, thermalState: 0);
  check(p == ShutterPace.hard, '队列10 = hard');
  p = shutterPaceNext(previous: p, queueDepth: 9, thermalState: 0);
  check(p == ShutterPace.hard, '队列9(已 hard)滞回保持 hard');
  p = shutterPaceNext(previous: p, queueDepth: 8, thermalState: 0);
  check(p == ShutterPace.soft, '队列8 退出 hard 落 soft');
  p = shutterPaceNext(previous: p, queueDepth: 4, thermalState: 0);
  check(p == ShutterPace.normal, '队列4 回 normal');

  // 未知热态(-1)按冷处理。
  p = shutterPaceNext(
    previous: ShutterPace.normal,
    queueDepth: 4,
    thermalState: -1,
  );
  check(p == ShutterPace.normal, '未知热态队列4 = normal');

  // 点按判定。
  check(
    shutterTapAllowed(pace: ShutterPace.normal, sinceLastShutterMs: 0),
    'normal 档不设最小间隔',
  );
  check(
    !shutterTapAllowed(pace: ShutterPace.soft, sinceLastShutterMs: 3999),
    'soft 档 3999ms 拒',
  );
  check(
    shutterTapAllowed(pace: ShutterPace.soft, sinceLastShutterMs: 4000),
    'soft 档 4000ms 放行',
  );
  check(
    !shutterTapAllowed(pace: ShutterPace.hard, sinceLastShutterMs: 999999),
    'hard 档一律拒',
  );

  // ignore: avoid_print
  print('ALL PASS');
}
