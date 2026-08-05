// 滑轨"一圈"的口径:读数、像素、框的真实旋转角三者必须 1:1。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/ruler_scrubber.dart';

void main() {
  testWidgets('读数与像素:一整圈 = 360 × kRulerPxPerDeg', (tester) async {
    double v = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 60,
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
      await tester.drag(r, Offset(-360 * kRulerPxPerDeg / 4, 0));
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
  test('指针不许压住最长的黄色刻度(实机指认过一次)', () {
    // [2026-08-03] 旧实现指针 y 和刻度高度各算各的:pin 底 18.7 落在黄标顶
    // 7.2 之下 ⇒ 盖住 11.5px。现在顶部固定留 kRulerPinZone 给指针。
    expect(
      rulerPinBottom(kRulerHeight),
      lessThanOrEqualTo(rulerOriginTickTop(kRulerHeight)),
      reason:
          '指针尖脚(${rulerPinBottom(kRulerHeight)})压住了黄标顶端'
          '(${rulerOriginTickTop(kRulerHeight)})',
    );
    // 黄标仍要显著长于大刻度,否则"初始刻度更长"这条签决就没了。
    final originH = kRulerHeight - kRulerPinZone;
    expect(originH / 1.34, lessThan(originH));
    expect(originH, greaterThan(40), reason: '留给刻度的高度太少,黄标会变短');
  });

  test('滑行阈值必须低到真实手指也能触发', () {
    // [2026-08-03] 原值 30 度/s 对真人太高 —— 拨完减速再抬手就低于它,当场
    // 停住,用户实机指认"不是慢慢减速停下,而是立刻停"。
    expect(
      kRulerFlingMinDegPerSec,
      lessThanOrEqualTo(8.0),
      reason: '阈值又被提高了,慢速拨动会失去滑行',
    );
    expect(kRulerFlingMinDegPerSec, greaterThan(0), reason: '纯点按不该触发滑行');
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
}
