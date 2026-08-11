// 初始选区框的范围判定:只包场景本体,飞点留在框外。
//
// [2026-07-29 用户签决] "初始 3D 框的范围就变成只包括场景就好,外围的浮点
// 噪点可以直接在框外"。判据与取景 fitOf 同源(median ± 8·MAD + 99.5 分位)。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

/// [2026-08-09] 生产初始框已换成 initialTight(严丝合缝逐轴贴合,用户签决
/// "所有初始方框同一个大小同一个位置"),不再由 sceneAabbOf 直接建框。但
/// sceneAabbOf 仍是**环绕 pivot**(orbitPivotOf)的中心来源,其"密集核心 +
/// 稀疏外围不误伤"的判据教训(07-29 床架/地板整片误杀)必须继续守 ——
/// 这里用"贴合 AABB 的手工盒"直接检验判据本身。
SelectionBox _boxFromAabb(
  ({double cx, double cy, double cz, double hx, double hy, double hz}) a,
) => SelectionBox(
  cx: a.cx,
  cy: a.cy,
  cz: a.cz,
  sx: a.hx * 2 * 1.12,
  sy: a.hy * 2 * 1.12,
  sz: a.hz * 2 * 1.12,
);

/// 中心 1×1×1 均匀密集立方体 + 若干远处飞点。
Float32List _sceneWithStrays({
  int dense = 4000,
  List<List<double>> strays = const [],
}) {
  final rnd = math.Random(11);
  final out = Float32List((dense + strays.length) * 3);
  for (var i = 0; i < dense; i++) {
    out[i * 3] = rnd.nextDouble() - 0.5;
    out[i * 3 + 1] = rnd.nextDouble() - 0.5;
    out[i * 3 + 2] = rnd.nextDouble() - 0.5;
  }
  for (var k = 0; k < strays.length; k++) {
    final i = dense + k;
    out[i * 3] = strays[k][0];
    out[i * 3 + 1] = strays[k][1];
    out[i * 3 + 2] = strays[k][2];
  }
  return out;
}

void main() {
  test('飞点不撑大初始框:框仍贴合场景本体', () {
    final clean = _sceneWithStrays();
    final withStrays = _sceneWithStrays(
      strays: const [
        [12.0, 0.3, -0.2],
        [-9.0, 8.0, 5.0],
        [0.1, -20.0, 0.4],
        [4.0, 4.0, 4.0],
      ],
    );
    final a = SparseCloudPainter.sceneAabbOf(clean);
    final b = SparseCloudPainter.sceneAabbOf(withStrays);
    // 半边长几乎不受飞点影响(纯 min/max 会被撑到 10+ 倍)。
    expect(b.hx, closeTo(a.hx, a.hx * 0.15));
    expect(b.hy, closeTo(a.hy, a.hy * 0.15));
    expect(b.hz, closeTo(a.hz, a.hz * 0.15));
    // 场景本体的半宽应在 0.5 附近(±0.5 的均匀分布)。
    expect(b.hx, greaterThan(0.40));
    expect(b.hx, lessThan(0.55));
  });

  test('由该包围盒建的初始框:场景点全在框内,飞点全在框外', () {
    const strays = [
      [12.0, 0.3, -0.2],
      [-9.0, 8.0, 5.0],
      [0.1, -20.0, 0.4],
    ];
    final xyz = _sceneWithStrays(strays: strays);
    final aabb = SparseCloudPainter.sceneAabbOf(xyz);
    final box = _boxFromAabb(aabb);
    for (final s in strays) {
      expect(box.contains(s[0], s[1], s[2]), isFalse, reason: '飞点 $s 不该在框内');
    }
    // 场景点(前 4000 个)绝大多数在框内 —— 分位裁剪只削掉最外 1%。
    var inside = 0;
    for (var i = 0; i < 4000; i++) {
      if (box.contains(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2])) inside++;
    }
    expect(inside / 4000, greaterThan(0.97));
  });

  test('无飞点时不误伤:框覆盖 ≥97% 的点', () {
    final xyz = _sceneWithStrays(dense: 3000);
    final aabb = SparseCloudPainter.sceneAabbOf(xyz);
    final box = _boxFromAabb(aabb);
    var inside = 0;
    for (var i = 0; i < 3000; i++) {
      if (box.contains(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2])) inside++;
    }
    expect(inside / 3000, greaterThan(0.97));
  });

  test('空点云不炸', () {
    final e = SparseCloudPainter.sceneAabbOf(Float32List(0));
    expect(e.hx, greaterThan(0));
  });

  test('密集核心 + 稀疏外围:外围(床架/地板类)不得被判到框外', () {
    // [2026-07-29 用户实机指认"一打开删了这么多"] 病灶复现:床垫这类密集
    // 核心占了绝大多数点,MAD 被压到极小,8·MAD 只框住核心,床架与地板
    // 整片变红。分位判据不受密度分布影响。
    const core = 20000; // 密集核心,半宽 0.3
    const shell = 4000; // 稀疏外围,半宽 1.5
    final rnd = math.Random(3);
    final xyz = Float32List((core + shell) * 3);
    for (var i = 0; i < core; i++) {
      xyz[i * 3] = (rnd.nextDouble() - 0.5) * 0.6;
      xyz[i * 3 + 1] = (rnd.nextDouble() - 0.5) * 0.6;
      xyz[i * 3 + 2] = (rnd.nextDouble() - 0.5) * 0.6;
    }
    for (var k = 0; k < shell; k++) {
      final i = core + k;
      xyz[i * 3] = (rnd.nextDouble() - 0.5) * 3.0;
      xyz[i * 3 + 1] = (rnd.nextDouble() - 0.5) * 3.0;
      xyz[i * 3 + 2] = (rnd.nextDouble() - 0.5) * 3.0;
    }
    final aabb = SparseCloudPainter.sceneAabbOf(xyz);
    final box = _boxFromAabb(aabb);
    var inside = 0;
    final total = core + shell;
    for (var i = 0; i < total; i++) {
      if (box.contains(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2])) inside++;
    }
    // MAD 判据在这里只能覆盖 ~83%;分位判据必须 ≥97%。
    expect(inside / total, greaterThan(0.97));
    // 框要真的把稀疏外围包进去(半宽接近 1.5,而不是核心的 0.3)。
    expect(aabb.hx, greaterThan(1.2));
  });
}
