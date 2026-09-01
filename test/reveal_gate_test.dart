// [RevealGate] 的**行为**测试 —— 特别是超时兜底。
//
// [2026-08-24] 这个文件的存在理由是一次没咬住的变异:我原来把揭幕逻辑留在
// _VaultPageState 里,只能写成源码文本断言(`expect(code, contains('Timer('))`),
// 结果变异测试删掉两处 cancel() 它照样全绿。抽成纯类之后,可以用 testWidgets
// 的假时钟把时间真推过去,看它到底放不放行。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/community/reveal_gate.dart';

void main() {
  const d = Duration(milliseconds: 2500);

  RevealGate make() => RevealGate(groupSize: 3, deadline: d);

  testWidgets('一组全就绪 ⇒ 立刻一起揭幕', (t) async {
    final g = make();
    addTearDown(g.dispose);
    g.setWorks(['a', 'b', 'c', 'd']);
    expect(g.revealed, isFalse);

    g.markReady('a');
    expect(g.revealed, isFalse, reason: '还差 b、c');
    g.markReady('b');
    expect(g.revealed, isFalse, reason: '还差 c');
    g.markReady('c');
    expect(g.revealed, isTrue);
  });

  testWidgets('只等首屏这一组 —— 第 4 张不在等待名单里', (t) async {
    final g = make();
    addTearDown(g.dispose);
    g.setWorks(['a', 'b', 'c', 'd', 'e']);
    g.markReady('a');
    g.markReady('b');
    g.markReady('c');
    expect(g.revealed, isTrue, reason: 'd/e 用户此刻根本看不到,等它们只会让整页白等');
  });

  testWidgets('一张卡永远起不来 ⇒ 到点无条件放行', (t) async {
    final g = make();
    addTearDown(g.dispose);
    var notified = 0;
    g.addListener(() => notified++);

    g.setWorks(['a', 'b', 'c']);
    g.markReady('a'); // b、c 永远不报

    await t.pump(d - const Duration(milliseconds: 1));
    expect(g.revealed, isFalse, reason: '还没到点,不能提前放行');

    await t.pump(const Duration(milliseconds: 2));
    expect(g.revealed, isTrue, reason: '到点必须放行 —— 否则整页永远灰着');
    expect(notified, 1, reason: '放行要通知页面重建');
  });

  testWidgets('提前全就绪后,兜底计时器不会再翻一次', (t) async {
    final g = make();
    addTearDown(g.dispose);
    var notified = 0;
    g.addListener(() => notified++);

    g.setWorks(['a', 'b']);
    g.markReady('a');
    g.markReady('b');
    expect(g.revealed, isTrue);
    expect(notified, 1);

    await t.pump(d * 2);
    expect(notified, 1, reason: '计时器应当已被 cancel,不能再通知一次');
  });

  testWidgets('同一组重复 setWorks 是 no-op —— 否则每次 build 打回加载态', (t) async {
    final g = make();
    addTearDown(g.dispose);
    g.setWorks(['a', 'b', 'c']);
    g.markReady('a');
    g.markReady('b');
    g.markReady('c');
    expect(g.revealed, isTrue);

    g.setWorks(['a', 'b', 'c']); // build 又跑了一遍
    expect(g.revealed, isTrue, reason: '同一组不该把页面打回加载态');

    g.setWorks(['x', 'y', 'z']); // 真换了一批(下拉刷新 / 换过滤)
    expect(g.revealed, isFalse, reason: '换批就该重新等');

    // ⚠️ testWidgets 在**测试体结束时**就查悬挂计时器,比 addTearDown 更早。
    // 上面这次 setWorks 起的兜底计时器还挂着,不推过去会报 "Pending timers"。
    await t.pump(d * 2);
    expect(g.revealed, isTrue);
  });

  testWidgets('空 feed 直接算已揭幕 —— 不然空态被幕布盖着', (t) async {
    final g = make();
    addTearDown(g.dispose);
    g.setWorks(const []);
    expect(g.revealed, isTrue);
  });

  testWidgets('dispose 之后计时器不再回调', (t) async {
    final g = make();
    var notified = 0;
    g.addListener(() => notified++);
    g.setWorks(['a', 'b', 'c']);
    g.dispose();
    await t.pump(d * 2);
    expect(notified, 0);
  });
}
