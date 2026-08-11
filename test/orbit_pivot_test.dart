// 环绕 pivot = 范围中心(转盘感),不是密度中心。
//
// [2026-08-09 用户实机指认] 未命名(2)"围绕着最边的一个点转,转180度整体在右"。
// 低视差云沿深度拖不对称长尾:密度中心(fitOf,median±8MAD 内点均值)贴着密集
// 端;绕它转 180°,实测该 PLY 可见团横跳自身宽度 61%。绕范围中心(sceneAabbOf
// 的 P0.5–P99.5 中点,与初始 3D 框同源)= 0%。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

/// 密集团(0 附近 900 点)+ 单侧长尾(x∈[1,5] 稀疏 100 点)——
/// 密度中心贴在 0,范围中心在尾巴中段。
(Float32List, Uint8List) tailedCloud() {
  const n = 1000;
  final xyz = Float32List(n * 3);
  final rgb = Uint8List(n * 3)..fillRange(0, n * 3, 255);
  final rnd = math.Random(3);
  for (var i = 0; i < 900; i++) {
    xyz[i * 3] = rnd.nextDouble() * 0.4 - 0.2;
    xyz[i * 3 + 1] = rnd.nextDouble() * 0.4 - 0.2;
    xyz[i * 3 + 2] = rnd.nextDouble() * 0.4 - 0.2;
  }
  for (var i = 900; i < 1000; i++) {
    xyz[i * 3] = 1 + rnd.nextDouble() * 4; // 单侧尾
    xyz[i * 3 + 1] = rnd.nextDouble() * 0.4 - 0.2;
    xyz[i * 3 + 2] = rnd.nextDouble() * 0.4 - 0.2;
  }
  return (xyz, rgb);
}

void main() {
  testWidgets('不对称长尾云:初始 pivot = 范围中心,绕密度中心立刻红', (tester) async {
    final (xyz, rgb) = tailedCloud();
    await tester.pumpWidget(
      MaterialApp(
        home: SparseCloudView(xyz: xyz, rgb: rgb),
      ),
    );
    await tester.pump();
    final pivot =
        ((tester.state(find.byType(SparseCloudView)) as dynamic).debugPivot
            as List<double>);
    final aabb = SparseCloudPainter.sceneAabbOf(xyz);
    final fit = SparseCloudPainter.fitOf(xyz);
    // 前提:这朵云两种中心确实分得开(否则本用例测不到东西)。
    expect(
      (aabb.cx - fit.cx).abs(),
      greaterThan(0.5),
      reason: 'fixture 的尾巴不够长,两种中心重合,守门失去判别力',
    );
    expect(
      pivot[0],
      closeTo(aabb.cx, 1e-6),
      reason:
          '初始 pivot 不是范围中心(=${pivot[0].toStringAsFixed(2)},'
          ' 范围中心=${aabb.cx.toStringAsFixed(2)},密度中心=${fit.cx.toStringAsFixed(2)})'
          ' ⇒ 长尾云转 180° 会整体横跳(用户:"围绕最边的一个点转")',
    );
    expect(pivot[1], closeTo(aabb.cy, 1e-6));
    expect(pivot[2], closeTo(aabb.cz, 1e-6));
  });
}
