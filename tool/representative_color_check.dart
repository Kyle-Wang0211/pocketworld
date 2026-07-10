// 代表色纯逻辑单测(纯 Dart VM 可跑,不依赖 Flutter):
//   dart run tool/representative_color_check.dart
// 全部断言通过打印 PASS 并 exit 0;任一失败 exit 1。
//
// 核心回归用例:白床单变粉 bug 的最小复现——
// 样本 [白,白,白,红],旧算术平均会输出粉(255,191,191),
// 新代表色必须输出真实观测过的白(255,255,255)。

import 'dart:io';
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/representative_color.dart';

int _failures = 0;

void _check(String name, bool cond, [String? detail]) {
  if (cond) {
    stdout.writeln('  ok   $name');
  } else {
    _failures++;
    stdout.writeln('  FAIL $name${detail == null ? '' : ' — $detail'}');
  }
}

/// 把样本列表灌进收集器并归约出点 0 的 RGB。
List<int> _reduce(List<List<double>> obs) {
  final store = RepresentativeColorSamples(Int32List.fromList([obs.length]));
  for (final s in obs) {
    store.add(0, s[0], s[1], s[2]);
  }
  final out = Uint8List(3);
  final ok = store.selectInto(0, out);
  if (!ok) return const [-1, -1, -1];
  return [out[0], out[1], out[2]];
}

void main() {
  stdout.writeln('representative_color 断言脚本');

  // ① 白床单回归:白×3 + 红×1 → 必须是白(平均=粉 255,191,191 即旧 bug)。
  final sheet = _reduce([
    [255, 255, 255],
    [255, 255, 255],
    [255, 255, 255],
    [255, 0, 0],
  ]);
  _check('白×3+红×1 → 白(非粉)', sheet[0] == 255 && sheet[1] == 255 && sheet[2] == 255,
      'got $sheet(旧平均会是 [255,191,191])');

  // ② 单样本 → 就是它自己(含双线性浮点样本的 round)。
  final single = _reduce([
    [10.4, 200.6, 99.5],
  ]);
  _check('单样本 → 自身(round)', single[0] == 10 && single[1] == 201 && single[2] == 100,
      'got $single');

  // ③ 双样本 → 下中位数=更暗者(两个调用方共享此规则,保持一致)。
  final two = _reduce([
    [200, 200, 200],
    [50, 50, 50],
  ]);
  _check('双样本 → 更暗者', two[0] == 50 && two[1] == 50 && two[2] == 50, 'got $two');

  // ④ 奇数样本 → 亮度中位的那个真实样本(完整 RGB,不合成)。
  final odd = _reduce([
    [0, 0, 0],
    [120, 60, 30], // 亮度中位
    [255, 255, 255],
  ]);
  _check('奇数样本 → 中位真实样本', odd[0] == 120 && odd[1] == 60 && odd[2] == 30,
      'got $odd');

  // ⑤ 等亮度并列 → 取靠前者(确定性)。
  final idx = selectRepresentativeSample(
    Float32List.fromList([100, 100, 100, 100, 100, 100]),
    0,
    2,
  );
  _check('等亮度并列 → 靠前者', idx == 0, 'got $idx');

  // ⑥ 无样本 → selectInto 返回 false(调用方涂灰)。
  final empty = RepresentativeColorSamples(Int32List.fromList([0]));
  _check('无样本 → false', !empty.selectInto(0, Uint8List(3)));

  // ⑦ 多点 CSR 隔离:点间样本互不串门。
  final multi = RepresentativeColorSamples(Int32List.fromList([1, 2]));
  multi.add(0, 10, 20, 30);
  multi.add(1, 200, 0, 0);
  multi.add(1, 40, 40, 40);
  final out = Uint8List(6);
  multi.selectInto(0, out);
  multi.selectInto(1, out);
  _check('CSR 点间隔离', out[0] == 10 && out[1] == 20 && out[2] == 30,
      'p0=${out.sublist(0, 3)}');
  // 点 1 双样本:亮度 200*0.299=59.8 vs 40 → 更暗者=[40,40,40]。
  _check('CSR 点1 双样本取更暗', out[3] == 40 && out[4] == 40 && out[5] == 40,
      'p1=${out.sublist(3)}');

  // ⑧ 超容量静默丢弃,不越界污染邻点。
  final cap = RepresentativeColorSamples(Int32List.fromList([1, 1]));
  cap.add(0, 1, 1, 1);
  cap.add(0, 99, 99, 99); // 超容量,应被丢弃
  cap.add(1, 7, 7, 7);
  final capOut = Uint8List(6);
  cap.selectInto(0, capOut);
  cap.selectInto(1, capOut);
  _check('超容量丢弃+邻点无污染',
      capOut[0] == 1 && capOut[3] == 7 && cap.hitCount(0) == 1,
      'got $capOut hit0=${cap.hitCount(0)}');

  if (_failures > 0) {
    stdout.writeln('FAILED: $_failures 个断言未过');
    exit(1);
  }
  stdout.writeln('PASS: 全部断言通过');
}
