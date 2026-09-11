// 重建到终态时**不许有整屏转场动画**(用户 2026-09-10 令)。
//
// 用户原话:"在最后一刻整个页面都会有一个滚动或者说刷新的动画,这个才从
// 『生成中』变成『已完成』。删除这个动画,只保留卡片状态的变化。"
//
// 那个"动画"不是一段动画代码 —— me_page / 卡片 / 徽章 / 缩略图 / app_shell
// 全读过,一处 Animated* 都没有。它是**采集 route 的 pop 转场**:重建期用户
// 看到的作品页其实是采集 route 里嵌的临时 MePage,终态时 route 自动 pop,落到
// 长得几乎一样的真作品页 —— 所以看起来像整屏刷新一遍。
//
// 🔴 2026-09-11 修法更正。build 142 的解法是"终态不 pop、页面钉在原地",
// 代价是把那张**临时**作品页变成常驻页,而它穿的是早已退役的 MeRootPage
// 那套壳(右下角 "+" FAB、没有底部导航栏)—— 用户一眼认出来了。连带三个
// 缺陷:刚拍完那张卡点不动、拍摄按钮死键、没有返回图标出不去。
// 现在的解法:**照常 pop,但把这条 route 退出方向的转场时长设为 0**。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/reconstruction_draft_route_state.dart';

void main() {
  late String page;
  late String shell;

  String stripComments(String src) => src
      .split('\n')
      .where(
        (l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
      )
      .join('\n');

  setUpAll(() {
    final p = File('lib/ui/official_capture/ar_capture_page.dart');
    final s = File('lib/ui/app_shell.dart');
    expect(p.existsSync(), isTrue);
    expect(s.existsSync(), isTrue);
    page = stripComments(p.readAsStringSync());
    shell = stripComments(s.readAsStringSync());
  });

  test('锚点自身可读(阳性对照:锚没了要报锚没了,不是报回归)', () {
    expect(shell.contains('OfficialARCapturePage()'), isTrue);
    expect(page.contains('_scheduleDraftTerminalExitIfNeeded'), isTrue);
  });

  test('① 退出方向零转场 —— 这就是被删掉的那个"整屏刷新"', () {
    expect(
      shell.contains('reverseTransitionDuration: Duration.zero'),
      isTrue,
      reason: '终态 pop 必须零帧',
    );
    expect(
      shell.contains(
        'MaterialPageRoute<bool>(builder: (_) => const OfficialARCapturePage())',
      ),
      isFalse,
      reason: 'MaterialPageRoute 的默认 300 ms 下滑正是那个动画',
    );
  });

  test('② 终态照常 pop(不许再钉住临时页)', () {
    expect(page.contains('_sfmPendingPop = true;'), isTrue);
    expect(
      page.contains('_draftsPinnedAfterTerminal'),
      isFalse,
      reason: 'build 142 的钉住写法 —— 它把临时页变成常驻页',
    );
  });

  test('③ 资源仍然释放(不是把 pop 连同释放一起改没了)', () {
    expect(
      page.contains('releaseResources: _releaseLiveReconstructionResources'),
      isTrue,
    );
  });

  test('④ 完成震动发在终态这一刻,不靠徽章边沿', () {
    expect(page.contains('_triggerCompletionHaptic();'), isTrue);
    expect(
      page.contains('HapticFeedback.heavyImpact()'),
      isTrue,
      reason: '与快门同一种强度,全仓不引入第二种口径',
    );
  });

  test('⑤ 纯函数判据本身没改(它还被别处用着)', () {
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: true,
        reconstructionTerminal: true,
        recordActionInProgress: false,
      ),
      isTrue,
    );
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: true,
        reconstructionTerminal: true,
        recordActionInProgress: true,
      ),
      isFalse,
      reason: '记录操作进行中仍然不该触发 —— 这条语义没变',
    );
  });
}
