import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';

/// 默认参数 = "一切正常、刚到 tick、完全没动"。各测试只覆盖它关心的那一项。
AutoCaptureDecision decide({
  bool trackingNormal = true,
  int capturedCount = 10,
  double elapsedSec = 30,
  double sinceLastTickSec = 1.0,
  double tickIntervalSec = 1.0,
  double parallaxDeg = 0,
  double turnDeg = 0,
  double? centerShift = 0,
}) {
  return autoCaptureDecide(
    trackingNormal: trackingNormal,
    capturedCount: capturedCount,
    elapsedSec: elapsedSec,
    sinceLastTickSec: sinceLastTickSec,
    tickIntervalSec: tickIntervalSec,
    parallaxDeg: parallaxDeg,
    turnDeg: turnDeg,
    centerShift: centerShift,
  );
}

void main() {
  test('standing still never fires', () {
    expect(decide(), AutoCaptureDecision.skipNotMoved);
  });

  test('parallax at or above 5 deg fires on a tick', () {
    expect(decide(parallaxDeg: 4.99), AutoCaptureDecision.skipNotMoved);
    expect(decide(parallaxDeg: 5.0), AutoCaptureDecision.fire);
  });

  test('pure rotation fires via the turn threshold', () {
    expect(decide(turnDeg: 9.99), AutoCaptureDecision.skipNotMoved);
    expect(decide(turnDeg: 10.0), AutoCaptureDecision.fire);
  });

  test('below the tick interval nothing fires on the lower bound', () {
    expect(
      decide(sinceLastTickSec: 0.5, parallaxDeg: 90),
      AutoCaptureDecision.skipPaced,
    );
  });

  test('the overlap upper bound fires immediately, ignoring the tick', () {
    expect(
      decide(sinceLastTickSec: 0.01, centerShift: 0.30),
      AutoCaptureDecision.fire,
    );
    expect(
      decide(sinceLastTickSec: 0.01, centerShift: 0.29),
      AutoCaptureDecision.skipPaced,
    );
  });

  test('non-normal tracking blocks every path including the upper bound', () {
    expect(
      decide(trackingNormal: false, centerShift: 10.0, parallaxDeg: 90),
      AutoCaptureDecision.skipTracking,
    );
  });

  test('the 300-frame cap beats the overlap bound, and 299 still fires', () {
    expect(
      decide(capturedCount: 300, centerShift: 10.0),
      AutoCaptureDecision.skipCapped,
    );
    expect(decide(capturedCount: 299, parallaxDeg: 90),
        AutoCaptureDecision.fire);
  });

  test('the five-minute limit beats the overlap bound, and 299.9 s still '
      'fires', () {
    expect(
      decide(elapsedSec: 300.0, centerShift: 10.0),
      AutoCaptureDecision.skipTimeLimit,
    );
    expect(decide(elapsedSec: 299.9, parallaxDeg: 90),
        AutoCaptureDecision.fire);
  });

  test('tick interval stretches with shutter pace', () {
    expect(autoCaptureTickInterval(ShutterPace.normal).inMilliseconds, 1000);
    expect(autoCaptureTickInterval(ShutterPace.soft).inMilliseconds, 2000);
    expect(autoCaptureTickInterval(ShutterPace.hard).inMilliseconds, 3000);
  });

  // ————————————————————————————————————————————————————————————————
  // 以下为 brief 的 9 个之外补的覆盖。每一条都由一个**实测存活的变异**
  // 逼出来(见 task-2-report.md 的变异表),不是凭感觉加的。
  // ————————————————————————————————————————————————————————————————

  // —— 优先级链:每一对相邻条件都必须有一个"两者同时成立"的用例 ——
  // 只喂一个条件的测试**测不出重排**:brief 的 9 个里 cap/timeLimit 与
  // timeLimit/tracking 这两对从未同时成立过,两处对调实测全绿存活。

  test('the frame cap wins over the time limit', () {
    expect(
      decide(capturedCount: 300, elapsedSec: 300.0),
      AutoCaptureDecision.skipCapped,
    );
  });

  test('the time limit wins over tracking loss', () {
    expect(
      decide(elapsedSec: 300.0, trackingNormal: false),
      AutoCaptureDecision.skipTimeLimit,
    );
  });

  test('the frame cap wins over tracking loss', () {
    // 非相邻对。缺了它,把 tracking 整块提到最顶上的重排会全绿存活。
    expect(
      decide(capturedCount: 300, trackingNormal: false),
      AutoCaptureDecision.skipCapped,
    );
  });

  test('tracking loss wins over the paced skip', () {
    // 重叠上限不成立时,tracking 仍必须排在 tick 闸之前。
    expect(
      decide(trackingNormal: false, sinceLastTickSec: 0.01),
      AutoCaptureDecision.skipTracking,
    );
  });

  test('the whole priority chain resolves top-down when all six conditions '
      'hold at once', () {
    // 一次把整条链钉死:每一步只松开当前最高优先级的那一条,
    // 结果必须恰好降到下一级。
    AutoCaptureDecision chain({
      int capturedCount = 300,
      double elapsedSec = 300.0,
      bool trackingNormal = false,
      double centerShift = 10.0,
      double sinceLastTickSec = 0.01,
    }) {
      return decide(
        capturedCount: capturedCount,
        elapsedSec: elapsedSec,
        trackingNormal: trackingNormal,
        centerShift: centerShift,
        sinceLastTickSec: sinceLastTickSec,
        parallaxDeg: 90,
        turnDeg: 90,
      );
    }

    expect(chain(), AutoCaptureDecision.skipCapped);
    expect(chain(capturedCount: 299), AutoCaptureDecision.skipTimeLimit);
    expect(
      chain(capturedCount: 299, elapsedSec: 299.0),
      AutoCaptureDecision.skipTracking,
    );
    expect(
      chain(capturedCount: 299, elapsedSec: 299.0, trackingNormal: true),
      AutoCaptureDecision.fire, // 重叠上限,不等 tick
    );
    expect(
      chain(
        capturedCount: 299,
        elapsedSec: 299.0,
        trackingNormal: true,
        centerShift: 0.0,
      ),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      chain(
        capturedCount: 299,
        elapsedSec: 299.0,
        trackingNormal: true,
        centerShift: 0.0,
        sinceLastTickSec: 1.0,
      ),
      AutoCaptureDecision.fire, // 位移下限
    );
  });

  // —— tick 闸必须用传进来的那个间隔 ——
  // brief 的 9 个用例里 tickIntervalSec 恒为 1.0,把这行写死成 `< 1.0`
  // 实测全绿存活 —— 那等于 D7 的自适应节奏**整条静默失效**。

  test('the tick gate measures against the interval it is given', () {
    // 间隔被拉长到 3 s:2 s 还不到 tick(写死 1.0 的实现会在这里开火)。
    expect(
      decide(sinceLastTickSec: 2.0, tickIntervalSec: 3.0, parallaxDeg: 90),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      decide(sinceLastTickSec: 3.0, tickIntervalSec: 3.0, parallaxDeg: 90),
      AutoCaptureDecision.fire,
    );
    // 反方向:间隔缩到 0.5 s,0.6 s 已经过了 tick。
    expect(
      decide(sinceLastTickSec: 0.6, tickIntervalSec: 0.5, parallaxDeg: 90),
      AutoCaptureDecision.fire,
    );
    expect(
      decide(sinceLastTickSec: 0.4, tickIntervalSec: 0.5, parallaxDeg: 90),
      AutoCaptureDecision.skipPaced,
    );
  });

  test('a stretched shutter pace really does stretch the gate the governor '
      'applies', () {
    // 把 autoCaptureTickInterval 的输出真的喂回 autoCaptureDecide ——
    // spec §10 的第 6 条(队列深 → 间隔 1s→2s→3s)只有这样才算被验到。
    for (final (pace, seconds) in <(ShutterPace, double)>[
      (ShutterPace.normal, 1.0),
      (ShutterPace.soft, 2.0),
      (ShutterPace.hard, 3.0),
    ]) {
      final interval = autoCaptureTickInterval(pace).inMilliseconds / 1000.0;
      expect(interval, seconds, reason: '$pace');
      expect(
        decide(
          sinceLastTickSec: seconds - 0.1,
          tickIntervalSec: interval,
          parallaxDeg: 90,
        ),
        AutoCaptureDecision.skipPaced,
        reason: '$pace: 差 0.1 s 到 tick',
      );
      expect(
        decide(
          sinceLastTickSec: seconds,
          tickIntervalSec: interval,
          parallaxDeg: 90,
        ),
        AutoCaptureDecision.fire,
        reason: '$pace: 刚到 tick',
      );
    }
  });

  test('exactly at the tick interval already counts as a tick', () {
    expect(
      decide(sinceLastTickSec: 1.0, tickIntervalSec: 1.0, parallaxDeg: 5.0),
      AutoCaptureDecision.fire,
    );
    expect(
      decide(sinceLastTickSec: 0.999, tickIntervalSec: 1.0, parallaxDeg: 5.0),
      AutoCaptureDecision.skipPaced,
    );
  });

  // —— 阈值的第三个点:显著超过。只测"刚好等于 + 差一点"钉不住 `>=`→`==` ——

  test('thresholds are lower bounds, not equalities', () {
    expect(
      decide(capturedCount: 301, centerShift: 10.0),
      AutoCaptureDecision.skipCapped,
    );
    expect(
      decide(elapsedSec: 400.0, centerShift: 10.0),
      AutoCaptureDecision.skipTimeLimit,
    );
    expect(
      decide(sinceLastTickSec: 0.01, centerShift: 0.5),
      AutoCaptureDecision.fire,
    );
    expect(decide(parallaxDeg: 90), AutoCaptureDecision.fire);
    expect(decide(turnDeg: 90), AutoCaptureDecision.fire);
  });

  // —— 与 Task 1 几何层的交接契约 ——

  test('an infinite shift is "definitely past the bound" and fires at once',
      () {
    // normalizedCenterShift 在目标跑到相机背后时返回 +inf(spec §5.2)。
    expect(
      decide(sinceLastTickSec: 0.01, centerShift: double.infinity),
      AutoCaptureDecision.fire,
    );
  });

  test('a shift of 0 is an ordinary small shift and short-circuits nothing',
      () {
    // 0 只是"目标还在画面正中",没有任何特殊含义:上限判据不成立,
    // 于是照常由 tick 闸与下限判据接手。
    expect(
      decide(centerShift: 0.0, sinceLastTickSec: 0.01),
      AutoCaptureDecision.skipPaced,
    );
    expect(decide(centerShift: 0.0, parallaxDeg: 5.0), AutoCaptureDecision.fire);
    expect(decide(centerShift: 0.0, turnDeg: 10.0), AutoCaptureDecision.fire);
    expect(
      decide(centerShift: 0.0, parallaxDeg: 4.99, turnDeg: 9.99),
      AutoCaptureDecision.skipNotMoved,
    );
  });

  test('the overlap bound is an upper bound only: a sub-threshold shift never '
      'fires by itself', () {
    expect(
      decide(centerShift: 0.29, sinceLastTickSec: 1.0),
      AutoCaptureDecision.skipNotMoved,
    );
  });

  test('both movement criteria just below their thresholds does not fire', () {
    expect(
      decide(parallaxDeg: 4.99, turnDeg: 9.99),
      AutoCaptureDecision.skipNotMoved,
    );
  });

  // —— 上限判据求不出来时(centerShift == null)——
  // T1 刻意让 normalizedCenterShift 在内参/画幅不可用时返回 **null** 而不是
  // +inf,就是为了不让"不知道"被读成"马上开火"。这一层必须把那个区分守住:
  // null ⇒ **跳过** R2,由下限判据决定(spec §7 最后一行"只用下限判据决定")。

  test('an unavailable upper bound (null) is skipped, leaving the lower bound '
      'in charge', () {
    expect(decide(centerShift: null), AutoCaptureDecision.skipNotMoved);
    expect(
      decide(centerShift: null, sinceLastTickSec: 0.01),
      AutoCaptureDecision.skipPaced,
    );
    // spec §7:"只用下限判据决定" —— 两个下限判据都还得管用。
    expect(
      decide(centerShift: null, parallaxDeg: 5.0),
      AutoCaptureDecision.fire,
    );
    expect(decide(centerShift: null, turnDeg: 10.0), AutoCaptureDecision.fire);
    expect(
      decide(centerShift: null, parallaxDeg: 4.99, turnDeg: 9.99),
      AutoCaptureDecision.skipNotMoved,
    );
  });

  test('null and infinity are opposite verdicts, never the same one', () {
    // 同一个"还没到 tick"的情形:不知道 ⇒ 不拍;确定越过上限 ⇒ 立刻拍。
    expect(
      decide(centerShift: null, sinceLastTickSec: 0.01),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      decide(centerShift: double.infinity, sinceLastTickSec: 0.01),
      AutoCaptureDecision.fire,
    );
  });

  test('an unavailable upper bound does not leak past the gates above it', () {
    // null 只免掉 R2 这一道,不改变它上面三道的优先级。
    expect(
      decide(centerShift: null, capturedCount: 300),
      AutoCaptureDecision.skipCapped,
    );
    expect(
      decide(centerShift: null, elapsedSec: 300.0),
      AutoCaptureDecision.skipTimeLimit,
    );
    expect(
      decide(centerShift: null, trackingNormal: false),
      AutoCaptureDecision.skipTracking,
    );
  });
}
