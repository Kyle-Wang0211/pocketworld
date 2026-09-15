// [LIVE-WAIT 2026-09-15] 点「完成拍摄」之后,等待页要**继续看到点云长大**。
//
// 产品决策(2026-09-15):收尾等待页不再是一张静止的黑页 —— 排空期的每帧
// preview 和 phase-1 落地那一刻的 live recon 都要推出去。
//
// 此前的行为(本测试就是钉死它不许回退的):
//   ① worker 的喂帧分支里,`finishPending` 一置位就把 `previewTracked()`
//      整个短路掉(`(finishPending || !nativeCaptureActive()) ? null : ...`),
//      于是排空期一帧 preview 都不发;
//   ② `finalizeCase` 里 phase-1 落地只写了一行日志,什么都不发布,
//      用户要一直等到 phase-2 全局 BA 出 refined 才第一次看到东西。
//
// 两处改动都必须是**隔离**的:被砍掉 9.5s 空转的那条 interim 全局 BA
// (SPRINT-MODE / cap_1785070530166049)**仍然**要被 finish/capture-active
// 关死 —— 所以守卫从 `beforeGlobal != null` 换成了 `captureLive &&`,
// 拿点云的动作和跑 BA 的动作被拆成了两件事。
//
// 判据全部是**源码锚点**(非注释行),配阳性对照:锚点本身必须存在,
// 否则就是有人改了名字而不是行为回退。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;
  late List<String> lines;

  setUpAll(() {
    final f = File('lib/official_capture/sfm_live_recon.dart');
    expect(f.existsSync(), isTrue);
    // 只看非注释行 —— 本次改动往这两处塞了大段中英文注释,注释里出现的
    // 'streaming_local_ba' / finishPending 等字样会把裸 contains 判据全带偏。
    lines = f
        .readAsStringSync()
        .split('\n')
        .where(
          (l) =>
              !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
        )
        .toList();
    src = lines.join('\n');
  });

  int at(String pat) => lines.indexWhere((l) => l.contains(pat));

  test('阳性对照:三个锚点在非注释行里都还在', () {
    // 锚点没了 = 结构被重构过,下面的顺序判据会静默全绿,必须先在这里炸。
    expect(at('final beforeGlobal ='), greaterThanOrEqualTo(0),
        reason: 'beforeGlobal 改名了 —— 先修锚,别改判据');
    expect(at('publishPolicy.shouldRunGlobalBa('), greaterThanOrEqualTo(0),
        reason: 'interim 全局 BA 的守卫改名了 —— 先修锚');
    expect(at("'phase-1 done ("), greaterThanOrEqualTo(0),
        reason: 'phase-1 日志改词了 —— 先修锚');
    expect(at('Timer.periodic(const Duration(milliseconds: 250)'),
        greaterThanOrEqualTo(0),
        reason: 'phase-2 轮询改了 —— 先修锚');
  });

  test('🔴 ① 排空期每帧 preview 不再被 finishPending 掐断', () {
    // 旧形态:拿点云这一步本身被 finish 关死 ⇒ 排空期零 preview。
    expect(
      src.contains('(finishPending || !nativeCaptureActive())'),
      isFalse,
      reason: '回退了:finishPending 又把 previewTracked() 整个短路掉了,'
          '等待页会重新变成静止黑页',
    );
    // 新形态:capture 活着**或**每帧推送开着,就一定去拿点云。
    final capture = at('final captureLive = !finishPending && nativeCaptureActive();');
    final ternary = at('final beforeGlobal = (captureLive || boot.arEveryFrame)');
    expect(capture, greaterThanOrEqualTo(0),
        reason: 'captureLive 必须是独立的一个量 —— 拿点云与跑 BA 要能分开判');
    expect(ternary, greaterThan(capture));
    expect(lines[ternary + 1].contains('? session!.previewTracked()'), isTrue,
        reason: '真分支必须是真的去拿点云');
    expect(lines[ternary + 2].contains(': null'), isTrue);
  });

  test('🔴 ② interim 全局 BA 仍被 captureLive 关死(9.5s 空转不许回来)', () {
    final guard = at('if (captureLive &&');
    expect(guard, greaterThanOrEqualTo(0),
        reason: 'SPRINT-MODE 的 9.5s 回来了:finish 之后又会跑 interim 全局 BA');
    expect(lines[guard + 1].contains('beforeGlobal != null &&'), isTrue);
    expect(lines[guard + 2].contains('publishPolicy.shouldRunGlobalBa('), isTrue,
        reason: 'captureLive 必须直接串在 shouldRunGlobalBa 这个守卫上');
    // 拿点云排在守卫之前 —— 顺序反了就是又把两件事绑回一起。
    expect(at('final beforeGlobal = (captureLive || boot.arEveryFrame)'),
        lessThan(guard));
  });

  test('拍摄期每帧推送那条(streaming_local_ba_live)原样保留', () {
    // 它现在**同时**承担排空期的每帧 preview —— 被顺手删掉/改门,①就空了。
    final push = at("'source': 'streaming_local_ba_live',");
    expect(push, greaterThanOrEqualTo(0));
    expect(src.contains('if (boot.arEveryFrame &&'), isTrue,
        reason: '这条的门仍是 arEveryFrame,不是 captureLive');
  });

  test('🔴 ③ phase-1 落地就发布 live recon(在 phase-1 日志之后、轮询之前)', () {
    final done = at("'phase-1 done (");
    final publish = at("'source': 'finalize_local_live',");
    final poll = at('Timer.periodic(const Duration(milliseconds: 250)');
    expect(done, greaterThanOrEqualTo(0));
    expect(publish, greaterThanOrEqualTo(0),
        reason: 'phase-1 落地不发布 ⇒ 用户要一直等到 refined 才第一次看到点云');
    expect(publish, greaterThan(done),
        reason: '必须等 phase-1 真的 ok 之后才发 —— 提前发的是上一轮的旧云');
    expect(publish, lessThan(poll),
        reason: '必须排在 phase-2 轮询之前,否则 refined 都到了才发就没意义了');
  });

  test('phase-1 那份 preview 是非终态、且复用已取的点(不二次拷贝)', () {
    final publish = at("'source': 'finalize_local_live',");
    expect(publish, greaterThanOrEqualTo(0));
    final block = lines.sublist(publish - 8, publish + 12).join('\n');
    expect(block.contains("'terminal': false,"), isTrue,
        reason: 'terminal=true 会让 UI 把 phase-1 的粗云当拍完的终态云弹出去');
    expect(block.contains('final p1 = s.previewTracked();'), isTrue);
    expect(block.contains('prefetched: p1,'), isTrue,
        reason: '已经在手的点必须复用,否则 finalize 路上白拷一份全量点云');
    expect(block.contains('preview: true,'), isTrue,
        reason: '走 previewTracked(live recon),不是 pointsTracked(finalize recon,'
            '此刻还是空的)');
    expect(block.contains('if (p1.count > 0)'), isTrue,
        reason: '空云不许发 —— resume 路径没有内存 live recon');
  });

  test('phase-1 发布失败必须吞掉(不许把 finalize 带崩)', () {
    final publish = at("'source': 'finalize_local_live',");
    final block = lines.sublist(publish - 8, publish + 16).join('\n');
    expect(block.contains("wlog('phase-1 preview failed (non-fatal): \$e');"),
        isTrue,
        reason: '一份可有可无的中间预览,绝不许让唯一用户可见成果 refined 丢掉');
  });

  test('finishPending 没有在别处重新挡住 preview', () {
    // 改完之后 finishPending 只允许出现在:声明、captureLive、finish_pending
    // 置位、quad-prepay 门。多一处就要人工复核是不是又把 preview 关了。
    final uses = lines
        .where((l) => l.contains('finishPending'))
        .map((l) => l.trim())
        .toList();
    expect(uses.length, 4, reason: 'finishPending 的使用点变了:$uses');
    expect(uses.any((l) => l.startsWith('var finishPending = false;')), isTrue);
    expect(uses.any((l) => l.contains('final captureLive =')), isTrue);
    expect(uses.any((l) => l.startsWith('finishPending = true;')), isTrue);
    expect(uses.any((l) => l.contains('if (!finishPending && session != null)')),
        isTrue);
  });
}
