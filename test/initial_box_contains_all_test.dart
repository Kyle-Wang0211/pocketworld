// 初始框:严丝合缝贴住全部点,最长边屏幕尺寸恒定。
//
// [2026-08-09 用户签决(当日第三版,前两版:分位盒→正立方体)] "必须每个视角
// 都是严丝合缝顶着最上面和最下面的那个点云" —— 逐轴全量包围盒:
//   ① 包含全部点(一个都不漏);
//   ② 每对面都被某个点顶住(不留空框);
//   ③ 最长边 × zoom / radius 恒定 ⇒ 屏幕上最长边尺寸不变(短边按真实比例)。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

(Float32List, int) cloud({required double scale, int n = 1500, int seed = 5}) {
  final xyz = Float32List(n * 3);
  final rnd = math.Random(seed);
  for (var i = 0; i < n; i++) {
    xyz[i * 3] = (rnd.nextDouble() - 0.5) * scale;
    xyz[i * 3 + 1] = (rnd.nextDouble() - 0.5) * scale * 0.4;
    xyz[i * 3 + 2] = (rnd.nextDouble() - 0.5) * scale * 1.4;
  }
  return (xyz, n);
}

SelectionBox boxOf(Float32List xyz) {
  final f = editingFrameOf(xyz);
  return SelectionBox.initialSquareFace(
    cx: f.center[0],
    cy: f.center[1],
    cz: f.center[2],
    halfExtent: math.max(f.hx, math.max(f.hy, f.hz)),
  );
}

void main() {
  test('包含全部 + 每面正方形 + 最长轴两端被点顶住', () {
    // [2026-08-09 用户签决(第三轮收敛)] "每个面看到的初始框是正方形,内部
    // 的点云可以自适应大小" + "严丝合缝顶着最上面和最下面的那个点云"。
    final (xyz, n) = cloud(scale: 2, seed: 21);
    for (var i = 0; i < 5; i++) {
      xyz[i * 3 + 2] = -6 - i * 0.2; // 远飞点(<0.5%)
    }
    final f = editingFrameOf(xyz);
    final b = boxOf(xyz);
    // ① 每面正方形 ⟺ 三边等长。
    expect(b.sy, b.sx, reason: '面不是正方形:sy≠sx');
    expect(b.sz, b.sx, reason: '面不是正方形:sz≠sx');
    // ② 包含全部。
    var outside = 0;
    var loAxis = double.infinity, hiAxis = double.infinity;
    // 最长轴 = z(fixture 里 z 跨度最大,飞点也在 z)。
    for (var i = 0; i < n; i++) {
      if (!b.contains(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2])) outside++;
      final dz = xyz[i * 3 + 2] - f.center[2];
      final h = b.sz / 2;
      loAxis = math.min(loAxis, (h + dz).abs());
      hiAxis = math.min(hiAxis, (h - dz).abs());
    }
    expect(outside, 0, reason: '$outside 个点在初始框外');
    // ③ 最长轴两端严丝合缝(容差 = 半边 1%):"顶着最上面和最下面的那个点云"。
    expect(
      hiAxis,
      lessThan(b.sz / 2 * 0.01 + 1e-9),
      reason: '最长轴正端离最近的点还有 $hiAxis ⇒ 没顶住',
    );
    expect(
      loAxis,
      lessThan(b.sz / 2 * 0.01 + 1e-9),
      reason: '最长轴负端离最近的点还有 $loAxis ⇒ 没顶住',
    );
  });

  test('屏幕恒定:最长半边 × zoom / radius 对任意云同一常数', () {
    final (a, _) = cloud(scale: 2);
    final (b, _) = cloud(scale: 20, seed: 9);
    double normOf(Float32List xyz) {
      final f = editingFrameOf(xyz);
      final fit = SparseCloudPainter.fitOf(xyz);
      final hMax = math.max(f.hx, math.max(f.hy, f.hz));
      return hMax * f.zoom / fit.radius;
    }

    expect(
      normOf(a),
      closeTo(normOf(b), 1e-9),
      reason: '最长边的屏幕尺寸不恒定 ⇒ "初始框大小不变"被破坏',
    );
  });

  test('框中心 = 编辑相机 pivot(同源 ⇒ 框恒居中于屏幕)', () {
    final (xyz, _) = cloud(scale: 3, seed: 4);
    final f = editingFrameOf(xyz);
    final b = boxOf(xyz);
    expect(b.cx, f.center[0]);
    expect(b.cy, f.center[1]);
    expect(b.cz, f.center[2]);
  });

  test('两个页面的初始框都走 initialTight + editingFrameOf(源码钉子)', () {
    for (final fpath in [
      'lib/ui/official_capture/sparse_cloud_viewer_page.dart',
      'lib/ui/official_capture/ar_capture_page.dart',
    ]) {
      final src = File(fpath).readAsStringSync();
      expect(
        src.contains('SelectionBox.initialSquareFace('),
        isTrue,
        reason: '$fpath 的初始框不再是严丝合缝的 initialTight',
      );
      expect(
        src.contains('SelectionBox.initialCentered(') ||
            src.contains('SelectionBox.initialFor(') ||
            src.contains('SelectionBox.initialTight('),
        isFalse,
        reason: '$fpath 还在用旧初始框(正立方体/分位盒)',
      );
    }
  });
}
