// 滑轨"一圈"的口径:读数、像素、框的真实旋转角三者必须 1:1。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/ruler_scrubber.dart';

void main() {
  testWidgets('读数与像素:一整圈 = 360 × rulerPxPerDeg(宽)', (tester) async {
    double v = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: kRulerHeight,
              child: StatefulBuilder(
                builder: (ctx, ss) => RulerScrubber(
                  value: v,
                  onChanged: (nv) => ss(() => v = nv),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final r = find.byType(RulerScrubber);
    // 连续 4 段拖动,累计 -(360×pxPerDeg)px(负号 = 读数增大方向)。
    for (var i = 0; i < 4; i++) {
      await tester.drag(r, Offset(-360 * rulerPxPerDeg(400) / 4, 0));
      await tester.pump();
    }
    // 实测:合成拖动全额到账,无 slop 损耗 ⇒ 一圈像素精确等于 360.0°。
    expect(v, closeTo(360.0, 0.01));
  });

  test('框的旋转:读数增量 1:1 转成角度,累计 360° 精确回到原点', () {
    const axis = [0.0, 1.0, 0.0];
    var box = const SelectionBox(cx: 0, cy: 0, cz: 0, sx: 2, sy: 1, sz: 3);
    final before = [...box.rot];
    // 模拟滑轨:每次 +12°,共 30 次 = 360°。
    for (var i = 0; i < 30; i++) {
      box = box.rotatedAroundAxis(
        axis: axis,
        deltaDeg: 12,
        pivotX: 0,
        pivotY: 0,
        pivotZ: 0,
      );
    }
    for (var i = 0; i < 9; i++) {
      expect(box.rot[i], closeTo(before[i], 1e-9), reason: '一圈必须精确闭合');
    }
  });

  test('半圈 = 180°:局部 x 轴指向反向', () {
    var box = const SelectionBox(cx: 0, cy: 0, cz: 0, sx: 2, sy: 1, sz: 3);
    for (var i = 0; i < 15; i++) {
      box = box.rotatedAroundAxis(
        axis: const [0, 1, 0],
        deltaDeg: 12,
        pivotX: 0,
        pivotY: 0,
        pivotZ: 0,
      );
    }
    // 局部 x 轴(rot 第 0 列)应从 (1,0,0) 转到 (-1,0,0)。
    expect(box.rot[0], closeTo(-1, 1e-9));
    expect(box.rot[6], closeTo(0, 1e-9));
  });
  // ── [2026-08-07 用户签决] 横轴 → 弧形刻度盘(汽车仪表盘式)────────────
  //
  // 旧的"指针不许压住黄色刻度"那条几何守门整章作废:横轴时代指针和刻度各算
  // 各的 y,才需要那条;弧形版所有部件都由弧心 + 半径导出,指针的位置是算出来
  // 的而不是摆出来的。换成下面这几条弧形几何的不变量。
  const wRef = 390.0; // iPhone 逻辑宽,几何断言的基准

  test('弧心必须在面板下方(屏幕外)—— 收起旋转靠这一点成立', () {
    // 收起 = 整个盘绕弧心转 180°。弧心若落在面板内,转过去后弧线仍在屏幕上,
    // "从右侧消失"就不成立了。
    expect(
      rulerArcCenterY(wRef),
      greaterThan(kRulerHeight),
      reason: '弧心在面板内 ⇒ 转 180° 后弧线不会移出屏幕',
    );
    // 弧顶在面板内,否则升起态看不到刻度盘。
    expect(rulerArcApexY(), greaterThan(0));
    expect(rulerArcApexY(), lessThan(kRulerHeight));
  });

  test('指针有自己的枢轴,且恒定在面板底部 —— 收起只让它原地自转', () {
    // [2026-08-07 用户签决] "不管什么时候,指针永远在编辑页面的底部,不能消失。
    // 指针是绕中间的圆圈原地转圈。指针和刻度不是一个圆心。"
    final pivot = rulerPinPivotY(kRulerHeight);
    // 枢轴在面板下部,而且留得下圆圈。
    expect(pivot, greaterThan(kRulerHeight * 0.6), reason: '指针不在底部');
    expect(
      pivot + kRulerPinRadius,
      lessThan(kRulerHeight),
      reason: '指针圆圈被面板底边裁掉',
    );
    // 两个旋转中心必须分开:弧心在屏幕外,指针枢轴在面板内。差得越远越好,
    // 一旦有人把它们又合到一起,指针就会跟着弧一起转出屏幕(改前的 bug)。
    expect(
      (rulerArcCenterY(wRef) - pivot).abs(),
      greaterThan(kRulerHeight),
      reason: '指针枢轴与弧心太近 ⇒ 指针会跟着弧线一起消失',
    );
  });

  test('刻度朝内(朝弧心),不朝外', () {
    // 向内 ⇒ 最长那根的内端 y 比弧顶**大**(屏幕坐标向下为正)。
    expect(rulerTickInnerY(), greaterThan(rulerArcApexY()), reason: '刻度朝外伸了');
    // 刻度内端与指针杆顶之间要留间隙,不能戳在一起。
    expect(
      rulerPinTipY(kRulerHeight) - rulerTickInnerY(),
      greaterThan(6),
      reason: '刻度与指针挤在一起了',
    );
  });

  test('可见张角固定 45°,半径由屏幕宽反算 ⇒ 各机型弯度一致', () {
    // [2026-08-07 用户签决] "漏出的滑轴部分有 45 度就行,曲面要平缓一些"。
    expect(kRulerVisibleSpanDeg, 45);
    // 反算关系:width/2 = R·sin(半张角)。换个宽度,张角必须还是 45°。
    for (final w in [320.0, 390.0, 430.0]) {
      final r = rulerArcRadius(w);
      final span = 2 * math.asin((w / 2) / r) * 180 / math.pi;
      expect(span, closeTo(45, 1e-6), reason: '宽 $w 上张角不是 45°');
    }
    // 平缓度:45° 张角下高差约为半径的 7.6%,在 390 宽上 ≈ 39pt。
    final drop = rulerArcDrop(wRef);
    expect(drop, greaterThan(25), reason: '弧太平,看不出曲轴');
    expect(drop, lessThan(55), reason: '弧太弯,不像仪表盘');
    // 必须比旧的固定 R=420 更平缓(那时张角 55°、高差 48pt)。
    expect(drop, lessThan(48), reason: '没有比改之前更平缓');
  });

  test('最小一格 = 1 度,可见范围 = 45 格,两者锁在一起', () {
    // [2026-08-07 用户签决] "对应点云的转动是一小格一度……可见范围可以转动 45
    // 度就行(就是 45 个刻度就行)"。
    expect(kRulerMinorStepDeg, 1);
    // 密度由半径导出:弧上 1° 的几何角 = 1° 的读数 ⇒ 可见张角 45° 天然等于 45 格。
    final ppd = rulerPxPerDeg(wRef);
    final visibleArc =
        rulerArcRadius(wRef) * kRulerVisibleSpanDeg * math.pi / 180;
    expect(
      visibleArc / ppd,
      closeTo(kRulerVisibleSpanDeg, 1e-6),
      reason:
          '可见格数 ${(visibleArc / ppd).toStringAsFixed(1)} ≠ 45 ⇒ '
          '密度和张角脱钩了(我犯过:把 45° 当几何张角、密度另设 3.0 ⇒ 133 格)',
    );
    // 一格间距要够看清:线宽 1pt 的刻度,间距低于 6pt 就开始发糊。
    final gap = kRulerMinorStepDeg * ppd;
    expect(gap, greaterThanOrEqualTo(6), reason: '1° 一格太密,会糊成实心带');
    expect(gap, lessThan(16), reason: '一格太宽,可见范围装不下 45 格');
    // 四级层次都要在:1° / 5° / 30° / 原点。
    expect(kRulerMediumEveryDeg, greaterThan(kRulerMinorStepDeg));
    expect(kRulerMajorEveryDeg, greaterThan(kRulerMediumEveryDeg));
    expect(kRulerMinorTickLen, lessThan(kRulerMediumTickLen));
    expect(kRulerMediumTickLen, lessThan(kRulerMajorTickLen));
    expect(kRulerMajorTickLen, lessThan(kRulerOriginTickLen));
  });

  test('可见范围必须小于一整圈 —— 否则原点刻度会同屏出现两次', () {
    // 改 1° 一格前实测:可见弧长 400pt vs 一圈 396pt = 1.011 圈,两端各露出一点
    // 重复的刻度带,原点那根会同屏出现两次。提高 pxPerDeg 后顺带解决。
    final visibleArc =
        rulerArcRadius(wRef) * kRulerVisibleSpanDeg * math.pi / 180;
    final oneTurn = 360 * rulerPxPerDeg(wRef);
    expect(
      visibleArc,
      lessThan(oneTurn),
      reason:
          '可见弧长 ${visibleArc.toStringAsFixed(0)}pt ≥ 一圈 '
          '${oneTurn.toStringAsFixed(0)}pt ⇒ 会看到两个原点刻度',
    );
  });

  test('震动节流:间隔不得短于系统 haptic engine 能跟上的下限', () {
    // 每 1° 一格,快速拨动时一秒可能跨上百格;不节流会撞上系统节流、表现为
    // 整体卡顿。
    expect(kRulerHapticMinGap.inMilliseconds, greaterThanOrEqualTo(20));
    expect(
      kRulerHapticMinGap.inMilliseconds,
      lessThanOrEqualTo(50),
      reason: '节流太狠,慢慢拨时会漏掉刻度的触感',
    );
  });

  testWidgets('默认升起;点指针切换收起,再点切回', (tester) async {
    var deployed = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: StatefulBuilder(
              builder: (ctx, ss) => RulerScrubber(
                value: 0,
                onChanged: (_) {},
                deployed: deployed,
                onDeployedChanged: (v) => ss(() => deployed = v),
              ),
            ),
          ),
        ),
      ),
    );
    // [2026-08-07 用户签决] "升起模式(打开后默认升起)"。
    expect(deployed, isTrue, reason: '默认不是升起');

    final pin = find.byKey(const ValueKey('ruler-pin'));
    expect(pin, findsOneWidget, reason: '指针命中区不在,收起就没有入口');
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(deployed, isFalse, reason: '点指针没能收起');

    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(deployed, isTrue, reason: '再点指针没能升起');
  });

  testWidgets('抬手前减速(真实手指动作)松手后仍要滑行', (tester) async {
    // [2026-08-03 用户实机三次指认"没有触发任何惯性"] 根因不是惯性动画,也不是
    // 阈值本身,而是**只信 DragEndDetails.velocity**:实机上它常拿不到可用值。
    // 现在 _releaseVelocity 会用自己的样本窗口兜底,所以这条终于测得出来 ——
    // ⚠️ 必须显式递增 timeStamp,否则 sourceTimeStamp 全为 0,样本窗口算不出
    // 速度(第一版就是这么写成假红的)。
    double v = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: kRulerHeight,
              child: StatefulBuilder(
                builder: (ctx, ss) => RulerScrubber(
                  value: v,
                  onChanged: (nv) => ss(() => v = nv),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    var ts = Duration.zero;
    final g = await tester.startGesture(
      tester.getCenter(find.byType(RulerScrubber)),
    );
    // 快速拨过去。
    for (var i = 0; i < 8; i++) {
      ts += const Duration(milliseconds: 16);
      await g.moveBy(const Offset(-20, 0), timeStamp: ts);
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 抬手前自然减速 —— 这一段让框架的 velocity 掉到阈值以下。
    for (final px in [-6.0, -3.0, -1.5, -0.8, -0.5, -0.4]) {
      ts += const Duration(milliseconds: 16);
      await g.moveBy(Offset(px, 0), timeStamp: ts);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    final atRelease = v;
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (v - atRelease).abs(),
      greaterThan(1.0),
      reason: '抬手前减速就完全没有滑行 ⇒ 实机"没有任何惯性"的根因回来了',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('落定角度只能是正上或正下 —— 动画中途连点也不许卡在斜位', (tester) async {
    var deployed = true;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: StatefulBuilder(
              builder: (ctx, ss) {
                setOuter = ss;
                return RulerScrubber(
                  value: 0,
                  onChanged: (_) {},
                  deployed: deployed,
                  onDeployedChanged: (v) => ss(() => deployed = v),
                );
              },
            ),
          ),
        ),
      ),
    );

    // State 类是私有的,拿不到具体类型 ⇒ 走 dynamic 读那两个 @visibleForTesting
    // 的 getter。
    double rotNow() =>
        (tester.state(find.byType(RulerScrubber)) as dynamic).debugRotation
            as double;

    // [2026-08-07 用户实机指认"为什么角度会卡!只有在正上和正下才能停下呀"]
    // 根因:目标角写成"当前角 + π"。动画**中途**再点时当前角是非 π 倍数,加 π
    // 后永远落不回正上/正下,连点几次越偏。现在目标吸附到 π 的整数倍。
    void expectSettledOnAxis(String where) {
      final rot = rotNow();
      final k = rot / math.pi;
      expect(
        (k - k.roundToDouble()).abs(),
        lessThan(1e-6),
        reason:
            '$where:落定角 ${(rot * 180 / math.pi).toStringAsFixed(1)}° '
            '不是 180° 的整数倍 ⇒ 指针卡在斜位',
      );
    }

    // 单次切换:跑完必须落在轴上。
    setOuter(() => deployed = false);
    await tester.pumpAndSettle();
    expectSettledOnAxis('单次收起');

    setOuter(() => deployed = true);
    await tester.pumpAndSettle();
    expectSettledOnAxis('单次升起');

    // 关键场景:动画**中途**再点。第一次只跑 1/3,立刻反向再点。
    setOuter(() => deployed = false);
    // ⚠️ 先空 pump 一帧让 didUpdateWidget 启动动画:pump(duration) 是**先推时钟
    // 再 build**,直接给时长会把取样点落在动画的第 0 帧(实测 rot 恒为 0)。
    await tester.pump();
    await tester.pump(kRulerDeployDuration ~/ 3);
    final mid = rotNow();
    expect(
      (mid / math.pi - (mid / math.pi).roundToDouble()).abs(),
      greaterThan(0.05),
      reason: '中途取样没取到非轴角度,这个用例就没测到东西',
    );
    setOuter(() => deployed = true);
    await tester.pumpAndSettle();
    expectSettledOnAxis('中途连点');

    // 连点三次,依然只能停在轴上。
    for (var i = 0; i < 3; i++) {
      setOuter(() => deployed = !deployed);
      await tester.pump();
      await tester.pump(kRulerDeployDuration ~/ 4);
    }
    await tester.pumpAndSettle();
    expectSettledOnAxis('连点三次');
  });

  testWidgets('明暗与朝向严格对应:朝上亮、朝下暗', (tester) async {
    var deployed = true;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: StatefulBuilder(
              builder: (ctx, ss) {
                setOuter = ss;
                return RulerScrubber(
                  value: 0,
                  onChanged: (_) {},
                  deployed: deployed,
                  onDeployedChanged: (v) => ss(() => deployed = v),
                );
              },
            ),
          ),
        ),
      ),
    );
    dynamic st() => tester.state(find.byType(RulerScrubber));

    // [2026-08-07 用户实机指认"指针向上是暗,向下是亮,你做反了"] 探针实测代码
    // 侧一直是"朝上亮、朝下暗"(与用户原始规格一致)。那个现象是**卡角度 bug 的
    // 副作用**:旧算法下 rot 卡在 60°/240° 这类非 π 倍数,而 dim 每次都跑到位
    // ⇒ 偏上那次恰好是暗的、偏下那次恰好是亮的。角度吸附修好后二者重新锁死。
    // 这条守门把"朝向 ↔ 明暗"钉住,防止有人照着那次误判反向改。
    void expectPaired(String where) {
      final rot = st().debugRotation as double;
      final dim = st().debugDim as double;
      final up = math.cos(rot) > 0.9;
      final down = math.cos(rot) < -0.9;
      expect(up || down, isTrue, reason: '$where:落定角不在正上/正下');
      if (up) {
        expect(dim, closeTo(1.0, 1e-6), reason: '$where:朝上却是暗的');
      } else {
        expect(dim, closeTo(kRulerCollapsedDim, 1e-6), reason: '$where:朝下却是亮的');
      }
    }

    expectPaired('初始(升起)');
    for (var i = 0; i < 4; i++) {
      setOuter(() => deployed = !deployed);
      await tester.pump();
      await tester.pumpAndSettle();
      expectPaired('第 ${i + 1} 次点击后');
    }
  });

  testWidgets('连点 N 次要累积 N 个半圈 —— 不能卡在同一个目标只变色', (tester) async {
    var deployed = true;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: StatefulBuilder(
              builder: (ctx, ss) {
                setOuter = ss;
                return RulerScrubber(
                  value: 0,
                  onChanged: (_) {},
                  deployed: deployed,
                  onDeployedChanged: (v) => ss(() => deployed = v),
                );
              },
            ),
          ),
        ),
      ),
    );
    dynamic st() => tester.state(find.byType(RulerScrubber));

    // [2026-08-07 用户实机指认"快速多次按动不应该快速转吗,为什么现在只变色不
    // 转了"] 根因:目标写成 floor(当前角/π)·π + π,当前角在 (0,π) 之间时算出来
    // 还是 π ⇒ 第 2、3 次点击没有新增旋转,角度卡住而 dim 照常翻转。
    // 现在目标累加 π,所以连点 N 次总目标必须是 N·π。
    for (var n = 1; n <= 4; n++) {
      setOuter(() => deployed = !deployed);
      await tester.pump();
      // 只推进一小段就再点 —— 复现"快速连点"。
      await tester.pump(kRulerDeployDuration ~/ 5);
      expect(
        (st().debugRotationTarget as double) / math.pi,
        closeTo(n, 1e-9),
        reason:
            '第 $n 次连点后目标应是 ${n}π,实际 '
            '${((st().debugRotationTarget as double) / math.pi).toStringAsFixed(2)}π '
            '⇒ 卡在同一个目标,只会变色不会转',
      );
    }
    // 落定后仍在轴上,且确实转了 4 个半圈。
    await tester.pumpAndSettle();
    final rot = st().debugRotation as double;
    expect(rot / math.pi, closeTo(4, 1e-6), reason: '总旋转不是 4 个半圈');
  });
}
