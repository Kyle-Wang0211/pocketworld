// [WAIT-BUDGET 2026-07-29] 「用户等待预算」三点埋点的契约。
//
// 用户签决:「我可以忍受手机变热,但是我不能忍受用户的等待时间变长」。这把
// 候选预算(K12 vs K30)的验收口径从**热**换成了**吞吐**,而吞吐由三个量决定:
//
//   1. shutter.gap_ms      用户实际按快门的间隔 —— 整笔账的分母,此前从未量过
//   2. queue_drain.backlog 完成动作那一刻欠了多少帧 —— 欠债即等待
//   3. finalize_wall.ms    finalize 墙钟 —— 等待的第二个分量
//
// 三者缺一不可:只有 1 没有 2,不知道有没有欠债;只有 2 没有 1,不知道欠债是
// 因为算得慢还是用户拍得快;只有 3,把两种等待混成一个数。
//
// 判决必须来自真机:host 上同一 fixture 两次重跑的 finalize 墙钟摆动
// 36.3s ↔ 66.3s(83%),单次 host 计时对这三个量全部不可信。
// 依据见 ~/Documents/progecttwo/M5_RU_VERDICT_2026-07-29.md。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'shutter telemetry carries gap_ms (the denominator of the whole ledger)',
    () {
      final src = File(
        'lib/ui/official_capture/ar_capture_page.dart',
      ).readAsStringSync();
      expect(src, contains("'gap_ms': gapMs"));
      // 必须记成一等字段而不是靠事件 `t` 事后差分。队列执行时间会包含
      // backlog，不能冒充用户真实点击间隔；失败 ticket 也必须在相邻 tap
      // 时间轴里占一个位置。
      expect(src, contains('_lastShutterMs'));
      expect(src, contains('ticket.tapTimestampMicros ~/ 1000'));
      expect(src, contains('_lastShutterMs > 0 ? tapMs - _lastShutterMs : -1'));
      expect(src, contains('_lastShutterMs = tapMs'));
      final executor = src.substring(
        src.indexOf('Future<void> _executeShutterTicket('),
        src.indexOf('void _onShutterTicketError('),
      );
      expect(
        executor.indexOf('final tapMs = ticket.tapTimestampMicros ~/ 1000'),
        lessThan(executor.indexOf('await session.captureSinglePhoto(')),
        reason: 'gap must be admission-time, not queue execution-time',
      );
    },
  );

  test('queue_drain carries the backlog snapshot taken at the finish tap', () {
    final src = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    expect(src, contains("'backlog': _finalizeBacklog"));
    expect(src, contains("'in_flight': _finalizeInFlight"));
    // 快照必须在 finalize() 里取:_pump() 一跑 _spool 就缩,到
    // _maybeSendFinalize 时永远是 0,埋点会恒等于零而看不出问题。
    final finalizeBody = src.substring(src.indexOf('  void finalize() {'));
    final assignIdx = finalizeBody.indexOf('_finalizeBacklog = _spool.length');
    // 找**调用点**而不是裸 `_pump()`:后者会命中上方解释这条约束的注释本身。
    final pumpIdx = finalizeBody.indexOf('unawaited(_pump())');
    expect(
      assignIdx,
      greaterThan(-1),
      reason: 'backlog snapshot must live inside finalize()',
    );
    expect(
      pumpIdx,
      greaterThan(-1),
      reason: 'finalize() must still kick the drain pump',
    );
    expect(
      assignIdx,
      lessThan(pumpIdx),
      reason: 'backlog must be sampled BEFORE the drain pump starts',
    );
  });

  test('finalize wall clock is written to telemetry, not only Dart events', () {
    final src = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    expect(src, contains("TelemetryWriter.instance.event('finalize_wall'"));
    expect(src, contains("'phase': 'local_ready'"));
    expect(src, contains("'phase': 'refined'"));
  });

  test('spatial-first candidate selector is OFF (device-measured net loss)', () {
    final src = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    // 这一臂被**真机单变量 A/B 判负**(提取器库已回滚且两臂相同、配对数完全
    // 相同 11.5、场景密度相近 extract 1156→1267):
    //   纯时序 170 帧  逐帧 2827ms  GPU每对  79ms  等待 209s
    //   几何   160 帧  逐帧 5088ms  GPU每对 245ms  等待 520s
    // 配对数不变、匹配数仅 +11%,而每对成本 ×3.1 —— 成本不在描述子比较本身。
    // ⚠️ 被推翻的只是"零代价",不是质量收益(三把独立尺子的改善来自逐位确定性
    // 重放,未被推翻)。故这是**质量 vs 吞吐的取舍**,复活前须先解决描述子驻留。
    // 逐行判活代码:注释里留有该 setenv 的原文(装机/回滚说明),纯 contains 会误命中。
    final live = src
        .split('\n')
        .map((l) => l.trim())
        .where((l) => !l.startsWith('//'))
        .where((l) => l.contains('OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY'));
    expect(
      live.length,
      1,
      reason:
          'exactly one LIVE kill-switch setenv must be present: the device '
          'A/B measured GPU match cost x3.1 per pair at identical pair count, '
          'and the wait went 209s -> 520s. Found: ${live.join(" | ")}',
    );
    expect(src, contains('SPATIAL-CAND 真机判负'));
  });

  test('AR splat radius stays at the signed value of 6', () {
    final src = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    // 用户签决 2026-07-29:点径保持 6。它不是变慢的原因(真凶见上),但用户
    // 决定不再动它。⚠️ 代价已知:饱和色标当初与点径 12 同批判,停在 6 会让 AR
    // 分层偏"椒盐";要拿回读感须走"减少 AR 绘制点数",不是把上限调回 12。
    //
    // [2026-08-22] 原断言写死 overwrite=1,而 c1f193b(08-10 DEVICE-AB-UNBLOCK)
    // 把 register() 内的 setenv 整块 1→0 以放行真机 A/B,于是长期红。
    // 改为语义断言,并把**读取端**一起钉死 —— 只钉写入端时,读取端的兜底
    // 被改成 12 是没人会响的。
    //
    // 逐行判活:注释里留有该 setenv 的回滚原文,纯 contains 会误命中。
    final live = src
        .split('\n')
        .map((l) => l.trim())
        .where((l) => !l.startsWith('//'))
        .where((l) => l.contains('OFFICIAL_AETHER_AR_SPLAT_MAX_PX'))
        .toList();

    // 1) 出货默认 = 6。overwrite 位刻意不锁(见上,c1f193b 的既定语义)。
    expect(
      live.singleWhere((l) => l.startsWith('setenv(')),
      matches(
        RegExp(r'^setenv\("OFFICIAL_AETHER_AR_SPLAT_MAX_PX", "6", [01]\)$'),
      ),
      reason: '签决点径=6;历史上 aca2142 改成 12,实测 queue_drain 23s→208s→451s',
    );

    // 2) 读取端兜底也必须是 6 —— static let 惰性求值可能早于 register()。
    expect(src, contains('return 6\n  }()'));

    // 3) clamp 区间不得放宽(唯一挡住 20/50 档重演回归的闸)。
    expect(src, contains('v >= 2, v <= 200'));
  });

  test('no shipped config presets the AR splat radius', () {
    // [2026-08-22] c1f193b 把 overwrite 改成 0 之后,"出货点径 = 6"就只剩
    // 这一道护栏了:release 版 main.dart 无条件跑 AetherEnvFile.applyFrom,
    // 对任意 OFFICIAL_ 前缀键以 overwrite=1 注入,而 Info.plist 开着
    // UIFileSharingEnabled ⇒ Documents/official_env.json 是**出货可达**的注入面。
    // 仓库内任何随包配置都不得预置本键。
    //
    // (2026-08-22 实测真机 Documents:无 env 文件,该注入面当前未被使用。)
    for (final p in const [
      'ios/Runner/Info.plist',
      'ios/Runner.xcodeproj/project.pbxproj',
    ]) {
      final f = File(p);
      if (!f.existsSync()) continue;
      expect(
        f.readAsStringSync(),
        isNot(contains('OFFICIAL_AETHER_AR_SPLAT_MAX_PX')),
        reason: p,
      );
    }
    expect(
      File('ios/Runner/Info.plist').readAsStringSync(),
      isNot(contains('LSEnvironment')),
    );
  });
}
