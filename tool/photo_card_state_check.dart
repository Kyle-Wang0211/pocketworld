// photo_card_state_check.dart — AR 照片卡片四态边框判定函数的纯 Dart 断言。
//
// 运行(纯 Dart VM;photo_card_state.dart 本身零 Flutter 依赖,package:
// 前缀只走本仓 .dart_tool/package_config.json 解析,repo 根目录下执行):
//   dart tool/photo_card_state_check.dart
//
// 验证 lib/capture/photo_card_state.dart 的状态机(用户签决,白→黄反序
// 修复版):
//   黑 = 帧不在最新快照 posesPacked 里,**或已注册但真值视差未到达**
//       (处理中 —— 判黄只用真值,视锥近似已彻底退出卡片判定);
//   白 = 在且 registered==1 且真值视差充分;
//   黄 = 在且 registered==1 但真值低视差;
//   红 = 在但 registered==0(断联,不需要视差证据)。
// 优先级:红 > 黄 > 白 > 黑。
// 滞回(消 白1↔黄3 抖动,2026-07-11 阈值校准 8/7/9 → 5/4/6):首判 <5°
// 判黄;已白 → <4° 且**连续 2 次真值采样**都 <4° 才转黄(白态粘性,防
// 动态污染);已黄 → ≥6° 才转白;4..6° 带内保持原判。
//
// 假快照构造:posesPacked 契约 = 9 double/帧
// [frameId, registered, qw,qx,qy,qz, tx,ty,tz](本判定只读前两位)。

import 'dart:io';
import 'dart:typed_data';

// [2026-08-09] 改指出货栈:lib/capture/ 是退役旧栈的平行副本,采集页
// (ar_capture_page)实际 import 的是 official_capture/ 这份 —— 测错树
// 等于没测(平行同名实现老坑,见记忆 feedback_parallel_trees)。
import 'package:pocketworld_flutter/official_capture/photo_card_state.dart';

int _failures = 0;

void check(String name, Object? actual, Object? expected) {
  final ok = actual == expected;
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name'
      '${ok ? '' : '  (expected $expected, got $actual)'}');
  if (!ok) _failures++;
}

/// 造一份假快照 posesPacked:entries = [(frameId, registered)]。
Float64List fakePoses(List<(int, bool)> entries) {
  final out = Float64List(entries.length * 9);
  for (var i = 0; i < entries.length; i++) {
    out[i * 9] = entries[i].$1.toDouble();
    out[i * 9 + 1] = entries[i].$2 ? 1 : 0;
    // 其余 7 位(四元数/平移)保持 0 —— 与 worker 合成连通性 poses 一致。
  }
  return out;
}

void main() {
  // 快照:帧 3、7 已注册,帧 5 未注册(断联),帧 9 根本不在快照里。
  final poses = fakePoses([(3, true), (5, false), (7, true)]);

  // ── [2026-08-09 用户签决] 两态契约:没算=黑,算完(已注册)=白 ─────
  check(
    '不在快照 → 黑(pending)',
    photoCardSfmState(frameId: 9, posesPacked: poses, lowParallax: null),
    PhotoCardSfmState.pending,
  );
  check(
    '已注册 → 白(真值视差不再参与边框裁决)',
    photoCardSfmState(frameId: 3, posesPacked: poses, lowParallax: false),
    PhotoCardSfmState.registered,
  );
  check(
    '在快照但 registered==0 → 黑(红态废除,"没算"即黑)',
    photoCardSfmState(frameId: 5, posesPacked: poses, lowParallax: null),
    PhotoCardSfmState.pending,
  );
  check(
    '空快照(拍摄刚开始)→ 黑',
    photoCardSfmState(
        frameId: 3, posesPacked: Float64List(0), lowParallax: null),
    PhotoCardSfmState.pending,
  );
  check(
    '已注册 + 真值未到达(null)→ 仍是白(不再等真值裁决)',
    photoCardSfmState(frameId: 3, posesPacked: poses, lowParallax: null),
    PhotoCardSfmState.registered,
  );
  check(
    '已注册 + 真值低视差 → 仍是白(黄态废除)',
    photoCardSfmState(frameId: 7, posesPacked: poses, lowParallax: true),
    PhotoCardSfmState.registered,
  );
  check(
    '未注册 + 低视差 → 黑(黄红皆废,没算即黑)',
    photoCardSfmState(frameId: 5, posesPacked: poses, lowParallax: true),
    PhotoCardSfmState.pending,
  );
  check(
    '未处理 + 低视差 → 黑',
    photoCardSfmState(frameId: 9, posesPacked: poses, lowParallax: true),
    PhotoCardSfmState.pending,
  );

  // ── channelValue 编码稳定性(Swift 哑渲染 switch 的契约)───────────
  check('channelValue 黑=0', PhotoCardSfmState.pending.channelValue, 0);
  check('channelValue 白=1', PhotoCardSfmState.registered.channelValue, 1);
  check('channelValue 红=2', PhotoCardSfmState.disconnected.channelValue, 2);
  check('channelValue 黄=3', PhotoCardSfmState.lowParallax.channelValue, 3);

  // ── frameLowParallaxTrue:真值唯一(null → null,卡片保持黑)──────
  check(
    '真值未到达 → null(不判黄也不判白,由 photoCardSfmState 落黑)',
    frameLowParallaxTrue(trueMedianDeg: null, wasLowParallax: null),
    null,
  );
  check(
    '真值未到达 + 曾判黄 → 仍 null(缺证据不延续旧判,落黑)',
    frameLowParallaxTrue(trueMedianDeg: null, wasLowParallax: true),
    null,
  );

  // ── 滞回常量契约(阈值改动必须过这里)──────────────────────────────
  // 2026-07-11 校准 8/7/9 → 5/4/6:帧真值中位分布 p50=8.75°,8° 扎在
  // 分布正中心 → 68% 判黄;金标 LAPa lt8=43.5% 无重影;厚区特征 5.2°。
  check('常量:首判锚 = 5°(与覆盖云 parallaxMinDeg 同源)',
      kFrameYellowInitialDeg, 5.0);
  check('常量:白→黄 = 4°', kFrameYellowEnterDeg, 4.0);
  check('常量:黄→白 = 6°', kFrameYellowExitDeg, 6.0);
  check('常量:白→黄粘性 = 连续 2 次采样', kFrameYellowEnterStreak, 2);

  // ── 滞回:首判(无白黄历史)用 5° 锚 ──────────────────────────────
  check('首判 4.9° < 5° → 黄',
      frameLowParallaxTrue(trueMedianDeg: 4.9, wasLowParallax: null), true);
  check('首判 5.1° ≥ 5° → 白',
      frameLowParallaxTrue(trueMedianDeg: 5.1, wasLowParallax: null), false);
  check('首判边界 5.0°(5.0 < 5.0 为假)→ 白',
      frameLowParallaxTrue(trueMedianDeg: 5.0, wasLowParallax: null), false);

  // ── 滞回:已白 → 转黄需 <4°(粘性满足时)─────────────────────────
  check('已白 + 4.5°(带内)→ 保持白',
      frameLowParallaxTrue(trueMedianDeg: 4.5, wasLowParallax: false), false);
  check('已白 + 4.0°(边界,4.0 < 4.0 为假)→ 保持白',
      frameLowParallaxTrue(trueMedianDeg: 4.0, wasLowParallax: false), false);
  check('已白 + 3.9° < 4° + 连续 2 次采样 → 转黄',
      frameLowParallaxTrue(
          trueMedianDeg: 3.9, wasLowParallax: false, belowEnterStreak: 2),
      true);

  // ── 白态粘性(防动态污染):单次跌破不改判,连续 2 次才转黄 ────────
  check('已白 + 3.9° 但仅 1 次采样(streak=1)→ 保持白(粘性拦截)',
      frameLowParallaxTrue(
          trueMedianDeg: 3.9, wasLowParallax: false, belowEnterStreak: 1),
      false);
  check('已白 + 3.9° + streak=0(理论下限)→ 保持白',
      frameLowParallaxTrue(
          trueMedianDeg: 3.9, wasLowParallax: false, belowEnterStreak: 0),
      false);
  check('粘性只管白→黄:首判 3.9° + streak=1 → 仍直判黄(首判无粘性)',
      frameLowParallaxTrue(
          trueMedianDeg: 3.9, wasLowParallax: null, belowEnterStreak: 1),
      true);
  check('粘性只管白→黄:已黄 + 3.9° + streak=0 → 保持黄(exit 阈独立)',
      frameLowParallaxTrue(
          trueMedianDeg: 3.9, wasLowParallax: true, belowEnterStreak: 0),
      true);
  // frameBelowEnterStreak 计数器纯函数:<4° 累加,≥4° 清零。
  check('计数器:3.9°(<4°)→ 0+1',
      frameBelowEnterStreak(sampleDeg: 3.9, prevStreak: 0), 1);
  check('计数器:3.5°(<4°)→ 1+1',
      frameBelowEnterStreak(sampleDeg: 3.5, prevStreak: 1), 2);
  check('计数器:4.0°(边界,≥4°)→ 清零',
      frameBelowEnterStreak(sampleDeg: 4.0, prevStreak: 1), 0);
  check('计数器:8.0°(≥4°)→ 清零',
      frameBelowEnterStreak(sampleDeg: 8.0, prevStreak: 5), 0);

  // ── 滞回:已黄 → 转白需 ≥6° ──────────────────────────────────────
  check('已黄 + 5.5°(带内)→ 保持黄',
      frameLowParallaxTrue(trueMedianDeg: 5.5, wasLowParallax: true), true);
  check('已黄 + 5.99°(带内)→ 保持黄',
      frameLowParallaxTrue(trueMedianDeg: 5.99, wasLowParallax: true), true);
  check('已黄 + 6.0°(边界,6.0 < 6.0 为假)→ 转白',
      frameLowParallaxTrue(trueMedianDeg: 6.0, wasLowParallax: true), false);

  // ── 滞回消抖:真值批次在 5° 附近抖动,颜色不再 1↔3 来回闪 ─────────
  {
    // 无滞回的单阈值(5°)下这串会黄白黄白闪四次;滞回后首判黄、全程黄。
    // streak 按接线方式维护:采样到达时更新一次,再传入判定。
    bool? was;
    var streak = 0;
    bool? step(double deg) {
      streak = frameBelowEnterStreak(sampleDeg: deg, prevStreak: streak);
      was = frameLowParallaxTrue(
          trueMedianDeg: deg, wasLowParallax: was, belowEnterStreak: streak);
      return was;
    }

    final states = <bool>[];
    for (final deg in [4.8, 5.2, 4.8, 5.2, 5.9]) {
      states.add(step(deg)!);
    }
    check('消抖:4.8/5.2 抖动序列 → 全程黄(零翻转)',
        states.every((s) => s), true);
    // 真正补拍后真值跨过 6° → 转白;随后带内回落不再变黄。
    check('消抖:补拍后 6.4° → 转白', step(6.4), false);
    check('消抖:转白后 5.0°(带内)→ 保持白', step(5.0), false);
    // 白态粘性:单次跌破 4° 不改判,连续第 2 次才转黄。
    check('消抖:第 1 次跌破 4°(3.5°)→ 粘性保持白', step(3.5), false);
    check('消抖:连续第 2 次跌破 4°(3.6°)→ 才重新判黄', step(3.6), true);
  }

  // ── 白态粘性端到端:抖动被吸收,持续低视差才转黄 ───────────────────
  {
    bool? was;
    var streak = 0;
    bool? step(double deg) {
      streak = frameBelowEnterStreak(sampleDeg: deg, prevStreak: streak);
      was = frameLowParallaxTrue(
          trueMedianDeg: deg, wasLowParallax: was, belowEnterStreak: streak);
      return was;
    }

    check('粘性端到端:首判 9° → 白', step(9.0), false);
    check('粘性端到端:单批新低视差点拉低到 3.2° → 保持白(单次抖动)',
        step(3.2), false);
    check('粘性端到端:下一批回到 7.5° → 白(streak 清零)', step(7.5), false);
    check('粘性端到端:再跌 3.8°(第 1 次)→ 仍白', step(3.8), false);
    check('粘性端到端:连续第 2 次 3.4° → 转黄(真低视差)',
        step(3.4), true);
  }

  // ── 端到端:滞回 + 状态机(黑 → 黄 → 带内保持 → 白)────────────────
  {
    final p = fakePoses([(1, true)]);
    bool? was; // 首判前无历史
    PhotoCardSfmState st(double? deg) {
      was = frameLowParallaxTrue(trueMedianDeg: deg, wasLowParallax: was);
      return photoCardSfmState(frameId: 1, posesPacked: p, lowParallax: was);
    }

    // [2026-08-09 两态] 真值/滞回仍在算(frameLowParallaxTrue 机件保留),
    // 但边框判定一律忽略 —— 已注册恒白。
    check('端到端:真值未到 → 白(两态:已注册即算完)',
        st(null), PhotoCardSfmState.registered);
    check('端到端:首个真值 3° → 仍白(黄态废除)',
        st(3.0), PhotoCardSfmState.registered);
    check('端到端:抖到 5.3° → 仍白',
        st(5.3), PhotoCardSfmState.registered);
    check('端到端:补拍后 8° → 白', st(8.0), PhotoCardSfmState.registered);
  }

  // ── medianOf(true_parallax 聚合依赖)────────────────────────────
  check('medianOf 空列表 → null', medianOf([]), null);
  check('medianOf 奇数个', medianOf([3.0, 1.0, 2.0]), 2.0);
  check('medianOf 偶数个', medianOf([4.0, 1.0, 2.0, 3.0]), 2.5);

  if (_failures > 0) {
    stdout.writeln('\n$_failures assertion(s) FAILED');
    exit(1);
  }
  stdout.writeln('\nALL PASS');
}
