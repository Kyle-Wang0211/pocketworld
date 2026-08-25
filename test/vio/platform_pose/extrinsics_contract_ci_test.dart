// extrinsics_contract_ci_test.dart — 把外参契约断言真正落到**磁盘上的 xrslam 树**。
//
// 跑法:
//   flutter test lib/vio/platform_pose/extrinsics_contract_ci_test.dart
// 定位 xrslam 树的顺序:环境变量 XRSLAM_ROOT → <pocketworld>/../xrslam。
//
// ── 关于"跳过"的纪律 ──────────────────────────────────────────────────
// 🔴 树不存在时本测试会 skip。**skip 不是通过** —— 如果 CI 里这条一直在
//    skip,那它一行代码都没保护到。所以:
//      • 树存在时,断言"确实找到了 ≥3 份 slam yaml",防止 glob 写错导致
//        "找到 0 份 ⇒ 没有 offending ⇒ 绿灯"这种空转假绿(08-22 吃过的亏:
//        判据没跑却报通过)。
//      • 找到了 manager 源文件但里面一处 camera_to_body 都没有,判红而不是
//        判"契约没变" —— 见 extrinsics_contract.dart 的成对断言说明。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/vio/platform_pose/extrinsics_contract.dart';

/// slam yaml 的判别:含顶层 `output:` 块的才是 slam 侧配置;
/// sensor 侧(imu/cam0)的 yaml 不参与本契约。
bool _looksLikeSlamYaml(String src) {
  final stripped = stripYamlComments(src);
  return RegExp(r'^output\s*:', multiLine: true).hasMatch(stripped);
}

/// 🔴 XRSLAM_ROOT **设了但不存在 = 硬失败**,不许静默回退到兄弟目录。
/// 静默回退正是"配错了却一路绿灯"的经典成因:第一版本文件就是这么写的,
/// 结果拿一个不存在的路径去跑,它偷偷用了兄弟目录并报通过 —— 那次"通过"
/// 什么都没证明。
Directory _locateXrslamRoot() {
  final env = Platform.environment['XRSLAM_ROOT'];
  if (env != null && env.isNotEmpty) {
    final d = Directory(env);
    if (!d.existsSync()) {
      throw StateError('XRSLAM_ROOT is set to "$env" but that path does not '
          'exist; refusing to silently fall back');
    }
    return d;
  }
  final here = Directory.current.absolute.path;
  return Directory('$here/../xrslam');
}

void main() {
  test('xrslam 树:相机外参恰好被应用一次', () {
    final root = _locateXrslamRoot();
    if (!root.existsSync()) {
      // 树不在(例如只 checkout 了产品仓)。skip 不是通过 —— 日志里必须
      // 看得见,否则 CI 上一条永远 skip 的断言会被误当成保护。
      // ignore: avoid_print
      print('[extrinsics-contract] SKIPPED: no xrslam tree at ${root.path}');
      markTestSkipped('xrslam tree not found at ${root.path}');
      return;
    }

    // 1) 收集 slam yaml。排除 build*/ 产物目录与 .git。
    final yamls = <String, String>{};
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final p = e.path;
      if (!p.endsWith('.yaml')) continue;
      final rel = p.substring(root.path.length + 1);
      if (rel.startsWith('.git/')) continue;
      if (RegExp(r'(^|/)build[^/]*/').hasMatch('/$rel')) continue;
      final src = e.readAsStringSync();
      if (!_looksLikeSlamYaml(src)) continue;
      yamls[rel] = src;
    }

    // 2) 找 XRSLAMManager 源。
    final managerFile = File(
      '${root.path}/xrslam-interface/src/XRSLAMManager.cpp',
    );
    expect(
      managerFile.existsSync(),
      isTrue,
      reason:
          'XRSLAMManager.cpp not found at the expected path; the contract '
          'check cannot be evaluated, which is a failure, not a pass',
    );

    // 3) 防空转假绿:必须真的找到了 slam yaml。
    //    2026-08-23 实测树里有 3 份(configs/iphone_slam.yaml、
    //    configs/euroc_slam.yaml、xrslam-ios/visualizer/configs/slam_params.yaml)。
    expect(
      yamls.length,
      greaterThanOrEqualTo(3),
      reason:
          'found only ${yamls.length} slam yaml(s) -> the scan is broken; a '
          'vacuous scan would report "no offenders" and go green',
    );

    // 非空转的**可见**证据:把实际扫到的东西打进日志。
    // ignore: avoid_print
    print('[extrinsics-contract] root=${root.resolveSymbolicLinksSync()} '
        'slamYamls=${yamls.length} ${(yamls.keys.toList()..sort())}');

    final result = auditExtrinsicsSingleApplication(
      slamYamlSources: yamls,
      managerCppSource: managerFile.readAsStringSync(),
    );

    expect(
      result.passes,
      isTrue,
      reason:
          'scanned ${yamls.length} slam yaml(s): ${yamls.keys.toList()..sort()}\n'
          '${result.failures.join('\n')}',
    );
  });
}
