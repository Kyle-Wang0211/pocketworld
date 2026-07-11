// parallax_banner_check.dart — "拍摄角度不足"横幅去抖/滞回门的纯 Dart 断言。
//
// 运行(纯 Dart VM,repo 根目录下执行;parallax_banner_gate.dart 零依赖):
//   dart tool/parallax_banner_check.dart
//
// 验收(任务书原文):构造计数序列,断言横幅出现/隐藏时机 ——
//   • 显示需连续 3 次采样 ≥20(去抖,单次尖峰/中断清零重计);
//   • 隐藏在采样 <10 时立即生效(滞回带 10..19 内保持,防闪烁);
//   • reset 归零;自定义阈值生效;常量契约钉死。
// 另断言完成把关(_onFinishTap)的**占比口径**:starved_true / true_vox
// > 40% 才弹(starvedFinishGateShouldPrompt;绝对数 >20 已废 —— 大场景
// 必弹;true_vox==0 不拦)。

import 'dart:io';

import 'package:pocketworld_flutter/capture/parallax_banner_gate.dart';

int _failures = 0;

void check(String name, Object? actual, Object? expected) {
  final ok = actual == expected;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'}  $name'
    '${ok ? '' : '  (expected $expected, got $actual)'}',
  );
  if (!ok) _failures++;
}

/// 依次喂入 [counts],返回每步后的可见性序列。
List<bool> run(StarvedParallaxBannerGate gate, List<int> counts) => [
  for (final c in counts) gate.onSample(c),
];

void main() {
  // ── 常量契约(阈值改动必须过这里)─────────────────────────────────
  check('常量:显示门槛 = 20', kParallaxStarvedShowThreshold, 20);
  check('常量:隐藏门槛 = 10', kParallaxStarvedHideThreshold, 10);
  check('常量:去抖采样数 = 3', kParallaxStarvedDebounceSamples, 3);
  check('常量:完成把关占比 = 0.40', kParallaxStarvedFinishRatio, 0.40);

  // ── 完成把关(占比口径,starved_true / true_vox > 40% 才弹)─────────
  check('把关:41/100 = 41% → 弹',
      starvedFinishGateShouldPrompt(starvedTrue: 41, trueVoxels: 100), true);
  check('把关:40/100 = 40%(严格大于,等于不算)→ 不拦',
      starvedFinishGateShouldPrompt(starvedTrue: 40, trueVoxels: 100), false);
  check('把关:大场景 1683/5997 ≈ 28% → 不拦(绝对数口径的病灶场景)',
      starvedFinishGateShouldPrompt(starvedTrue: 1683, trueVoxels: 5997),
      false);
  check('把关:小场景 5/10 = 50% → 弹(绝对数口径会漏掉它)',
      starvedFinishGateShouldPrompt(starvedTrue: 5, trueVoxels: 10), true);
  check('把关:true_vox = 0(真值未到达)→ 不拦',
      starvedFinishGateShouldPrompt(starvedTrue: 50, trueVoxels: 0), false);
  check('把关:全 starved(100/100)→ 弹',
      starvedFinishGateShouldPrompt(starvedTrue: 100, trueVoxels: 100), true);
  check('把关:0 starved → 不拦',
      starvedFinishGateShouldPrompt(starvedTrue: 0, trueVoxels: 100), false);
  check('把关:自定义占比 0.25,30/100 → 弹',
      starvedFinishGateShouldPrompt(
          starvedTrue: 30, trueVoxels: 100, ratio: 0.25),
      true);

  // ── 去抖:连续 3 次 ≥20 才显示 ────────────────────────────────────
  {
    final g = StarvedParallaxBannerGate();
    check('去抖:第 1 次 25 → 不显示', g.onSample(25), false);
    check('去抖:第 2 次 25 → 不显示', g.onSample(25), false);
    check('去抖:第 3 次 25 → 显示', g.onSample(25), true);
    check('  visible getter 同步', g.visible, true);
  }

  // ── 去抖:边界值 20 计入(≥ 语义)────────────────────────────────
  {
    final g = StarvedParallaxBannerGate();
    check('边界:20,20,20 → 显示', run(g, [20, 20, 20]).last, true);
  }
  {
    final g = StarvedParallaxBannerGate();
    check('边界:19,19,19 → 不显示(<20 不计)', run(g, [19, 19, 19]).last, false);
  }

  // ── 去抖:中断清零重计(单次回落打断连击)──────────────────────────
  {
    final g = StarvedParallaxBannerGate();
    final vis = run(g, [25, 25, 5, 25, 25]);
    check('中断:25,25,5,25,25 → 全程不显示', vis.any((v) => v), false);
    check('中断后再补 1 次 → 第 3 连击显示', g.onSample(25), true);
  }

  // ── 去抖:滞回带内(10..19)未显示时同样清零(<20 即不计)──────────
  {
    final g = StarvedParallaxBannerGate();
    final vis = run(g, [25, 25, 15, 25, 25]);
    check('带内中断:25,25,15,25,25 → 不显示', vis.any((v) => v), false);
    check('  再 1 次 25 → 显示', g.onSample(25), true);
  }

  // ── 滞回:显示后带内(≥10)保持,<10 立即隐藏 ────────────────────
  {
    final g = StarvedParallaxBannerGate();
    run(g, [25, 25, 25]); // 点亮
    check('滞回:回落到 15(带内)→ 保持显示', g.onSample(15), true);
    check('滞回:回落到 10(带下界)→ 保持显示', g.onSample(10), true);
    check('滞回:回落到 9(<10)→ 立即隐藏', g.onSample(9), false);
    // 隐藏后必须重新走完整去抖,不能沾旧连击的光。
    check('复亮:第 1 次 30 → 不显示', g.onSample(30), false);
    check('复亮:第 2 次 30 → 不显示', g.onSample(30), false);
    check('复亮:第 3 次 30 → 显示', g.onSample(30), true);
  }

  // ── 滞回:0 也触发隐藏(拍摄补齐后计数归零的常态路径)──────────────
  {
    final g = StarvedParallaxBannerGate();
    run(g, [25, 25, 25]);
    check('归零:starved=0 → 隐藏', g.onSample(0), false);
  }

  // ── reset:新一轮拍摄归零(可见性与连击都清)─────────────────────
  {
    final g = StarvedParallaxBannerGate();
    run(g, [25, 25, 25]);
    g.reset();
    check('reset:可见性归零', g.visible, false);
    check('reset:连击也归零(1 次 25 不显示)', g.onSample(25), false);
  }
  {
    final g = StarvedParallaxBannerGate();
    run(g, [25, 25]); // 连击 2,未点亮
    g.reset();
    final vis = run(g, [25, 25]);
    check('reset:半程连击清零(还差 1 次)', vis.last, false);
  }

  // ── 自定义阈值:构造参数生效 ─────────────────────────────────────
  {
    final g = StarvedParallaxBannerGate(
      showThreshold: 5,
      hideThreshold: 2,
      debounceSamples: 1,
    );
    check('自定义:debounce=1 一击点亮', g.onSample(5), true);
    check('自定义:回落 2(带内)保持', g.onSample(2), true);
    check('自定义:回落 1(<2)隐藏', g.onSample(1), false);
  }

  if (_failures > 0) {
    stdout.writeln('\n$_failures assertion(s) FAILED');
    exit(1);
  }
  stdout.writeln('\nALL PASS');
}
