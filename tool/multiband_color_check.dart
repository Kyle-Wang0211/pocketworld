// multiband_color_check.dart — [RS-MULTIBAND 2026-08-14] Multi-band 顶点上色
// 的性质断言(纯 Dart VM):
//   cd <仓根> && dart run tool/multiband_color_check.dart
// 全部通过输出 "ALL PASS" 并 exit 0;任一断言失败 exit 1。
//
// 断言的是**性质**而非某个魔数,因为这一步按设计会改变输出(它就是要抹掉
// 低频斑块),没有"逐位不变"可对拍。四条性质来自 RS 原文的频段分工:
//   ① 常色云:不引入任何变化(无副作用);
//   ② 纯低频差异(两半亮度不同、各自内部均匀):被拉平 ⇒ 协调;
//   ③ 高频细节:单点尖峰必须**保住**(高频只来自单一观测,不被邻域抹平);
//   ④ 值域安全:输出恒在 0-255。

import 'dart:io';
import 'dart:typed_data';

import 'package:pocketworld_flutter/official_capture/multiband_color.dart';

int _failures = 0;
void _check(String name, bool cond, [String? detail]) {
  if (cond) {
    stdout.writeln('  ok   $name');
  } else {
    _failures++;
    stdout.writeln('  FAIL $name${detail == null ? '' : ' — $detail'}');
  }
}

void main() {
  stdout.writeln('multi-band 顶点上色性质断言');

  // 8×8×2 的板状点云(128 点),间距 1.0。
  const nx = 8, ny = 8, nz = 2;
  final n = nx * ny * nz;
  final xyz = Float32List(n * 3);
  var idx = 0;
  for (var x = 0; x < nx; x++) {
    for (var y = 0; y < ny; y++) {
      for (var z = 0; z < nz; z++) {
        xyz[idx * 3] = x.toDouble();
        xyz[idx * 3 + 1] = y.toDouble();
        xyz[idx * 3 + 2] = z.toDouble();
        idx++;
      }
    }
  }

  // ① 常色:selected≡linear≡128 ⇒ 输出必须还是 128。
  final flat = Float32List(n * 3)..fillRange(0, n * 3, 128.0);
  final o1 = multiBandBlend(xyz: xyz, selected: flat, linear: flat, radius: 2.5);
  var ok1 = true;
  for (var k = 0; k < n * 3; k++) {
    if (o1[k] != 128) {
      ok1 = false;
      break;
    }
  }
  _check('①常色云:输出不变(无副作用)', ok1);

  // ② 低频斑块:selected 左右两半差 40 级(模拟"相邻点挑了不同曝光的帧"),
  //    linear 是无斑的真值 ⇒ 输出应显著向真值收敛(斑块被抹掉 >50%)。
  final sel2 = Float32List(n * 3);
  final lin2 = Float32List(n * 3)..fillRange(0, n * 3, 120.0);
  for (var i = 0; i < n; i++) {
    final v = xyz[i * 3] < 4 ? 100.0 : 140.0; // 左暗右亮 = 纯低频斑
    sel2[i * 3] = v;
    sel2[i * 3 + 1] = v;
    sel2[i * 3 + 2] = v;
  }
  final o2 = multiBandBlend(xyz: xyz, selected: sel2, linear: lin2, radius: 2.5);
  var before = 0.0, after = 0.0;
  for (var i = 0; i < n; i++) {
    before += (sel2[i * 3] - 120.0).abs();
    after += (o2[i * 3] - 120).abs();
  }
  _check('②低频斑块被抹平 >50%', after < before * 0.5,
      'before=${before.toStringAsFixed(0)} after=${after.toStringAsFixed(0)}');

  // ③ 高频细节:在均匀场里给单点 +60,输出必须保住大部分跃变(>50%)。
  final sel3 = Float32List(n * 3)..fillRange(0, n * 3, 120.0);
  final lin3 = Float32List(n * 3)..fillRange(0, n * 3, 120.0);
  const spike = 40; // 任取一个内部点
  sel3[spike * 3] = 180.0;
  sel3[spike * 3 + 1] = 180.0;
  sel3[spike * 3 + 2] = 180.0;
  final o3 = multiBandBlend(xyz: xyz, selected: sel3, linear: lin3, radius: 2.5);
  // 邻域均值(近似 120 + 60/邻居数),尖峰点应仍显著高于它
  final delta = o3[spike * 3] - 120;
  _check('③高频尖峰保住 >50%', delta > 30, 'delta=$delta');

  // ④ 值域安全:极端输入不越界。
  final selX = Float32List(n * 3)..fillRange(0, n * 3, 250.0);
  final linX = Float32List(n * 3)..fillRange(0, n * 3, 250.0);
  selX[0] = 255.0;
  final o4 = multiBandBlend(xyz: xyz, selected: selX, linear: linX, radius: 2.5);
  var ok4 = true;
  for (var k = 0; k < n * 3; k++) {
    if (o4[k] < 0 || o4[k] > 255) {
      ok4 = false;
      break;
    }
  }
  _check('④值域恒在 0-255', ok4);

  stdout.writeln(_failures == 0 ? 'ALL PASS' : '$_failures FAILURE(S)');
  exit(_failures == 0 ? 0 : 1);
}
