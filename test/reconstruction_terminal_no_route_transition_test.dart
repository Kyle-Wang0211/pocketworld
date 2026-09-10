// 重建到终态时**不许再 pop 整条采集 route**(用户 2026-09-10 令)。
//
// 用户原话:"在最后一刻整个页面都会有一个滚动或者说刷新的动画,这个才从
// 『生成中』变成『已完成』。删除这个动画,只保留卡片状态的变化。"
//
// 那个"动画"不是一段动画代码 —— 我把 me_page / 卡片 / 徽章 / 缩略图 / app_shell
// 全读过,一处 Animated* 都没有。它是**整条采集 route 的 pop 转场**:重建期
// 用户看到的作品页其实是采集 route 里嵌的 MePage,终态时旧逻辑自动 pop 掉整条
// route,落到**真正的**作品页 —— 两者长得一样,所以看起来就是整屏刷新一遍。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/reconstruction_draft_route_state.dart';

void main() {
  final page = File('lib/ui/official_capture/ar_capture_page.dart');

  late String code;

  setUpAll(() {
    expect(page.existsSync(), isTrue);
    code = page
        .readAsStringSync()
        .split('\n')
        .where(
          (l) =>
              !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
        )
        .join('\n');
  });

  test('① 终态自动退出那条路上不再有 pop', () {
    expect(
      code.contains(
        '_sfmPendingPop = true;\n      unawaited(_onSfmPreviewDone());',
      ),
      isFalse,
      reason: '这是旧写法 —— 它会 pop 整条 route,产生整屏转场',
    );
    expect(
      code.contains('bool _draftsPinnedAfterTerminal = false;'),
      isTrue,
      reason: '终态后页面要留在原地',
    );
  });

  test('② 资源仍然释放(不是把 pop 连同释放一起删了)', () {
    expect(
      code.contains('releaseResources: _releaseLiveReconstructionResources'),
      isTrue,
      reason: '重建资源必须释放 —— 只删转场,不删释放',
    );
  });

  test('③ 终态后拦截跟着解除(别留一句过时的「正在重建」)', () {
    // 2026-09-11 更正:原判据钉的是 build 142 那种"只解一处"的写法,而那正是
    // 未命名(6) 点不进去的原因 —— 现在四个出口整套由 intercepts 给出,
    // 详细判据见 reconstruction_terminal_intercepts_release_test.dart。
    expect(
      code.contains('blockedMessage: intercepts.blockedMessage'),
      isTrue,
      reason: '页面不动了,但拍摄按钮不能一直被过时的提示挡着',
    );
    expect(
      code.contains(
        '_showDraftsWhileReconstructing &&\n        (_sfmPhase != null || _draftsPinnedAfterTerminal)',
      ),
      isTrue,
      reason: '_sfmPhase 清空之后草稿视图仍要留着,否则会闪回相机 —— 那还是整屏变化',
    );
  });

  test('④ 用户主动退出这条路没被动(阳性对照:别把人关在里面)', () {
    expect(code.contains('void _exitToDrafts()'), isTrue);
    expect(code.contains('Navigator.of(context).pop(true)'), isTrue);
    // 🔴 2026-09-11 补强:原来这条只证明"函数还在",没证明**有人调它**。
    // build 142 终态之后真的没人调 —— 这一页没有返回图标、右滑被 PopScope
    // 吞掉、拍摄按钮挂在一个会静默 return 的回调上,用户被关在里面,而这条
    // 测试是绿的。判据必须打到"钉住之后那个唯一出口"。
    expect(
      code.contains(': _exitToDrafts,'),
      isTrue,
      reason: '终态钉住后,拍摄按钮必须接到真的退出上',
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
