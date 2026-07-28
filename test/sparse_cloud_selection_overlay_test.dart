import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

void main() {
  test('selectionBoxCorners:轴对齐盒 8 角', () {
    const b = SelectionBox(cx: 1, cy: 2, cz: 3, sx: 2, sy: 4, sz: 6, yawDeg: 0);
    final c = selectionBoxCorners(b);
    expect(c, hasLength(8));
    // index 0 = (-,-,-):世界 (1-1, 2-2, 3-3) = (0,0,0)
    expect(c[0][0], closeTo(0, 1e-9));
    expect(c[0][1], closeTo(0, 1e-9));
    expect(c[0][2], closeTo(0, 1e-9));
    // index 7 = (+,+,+):世界 (2,4,6)
    expect(c[7][0], closeTo(2, 1e-9));
    expect(c[7][1], closeTo(4, 1e-9));
    expect(c[7][2], closeTo(6, 1e-9));
  });

  test('selectionBoxCorners:yaw 旋转绕中心', () {
    const b = SelectionBox(
      cx: 0,
      cy: 0,
      cz: 0,
      sx: 2,
      sy: 2,
      sz: 2,
      yawDeg: 90,
    );
    final c = selectionBoxCorners(b);
    // 局部 (+1,·,0±):yaw90° 后局部 +x → 世界 -z(与 contains 逆变换互逆)
    // 所有角到中心距离不变
    for (final p in c) {
      expect(
        math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]),
        closeTo(math.sqrt(3), 1e-9),
      );
    }
  });

  // [2026-07-28 用户签决] SparseCloudView 的只读选区回显已移除(预览模式
  // 不显示框外红,红色只属于编辑页 SelectionCloudView)—— 原'带 selectionBox
  // 渲染不崩'widget 用例随参数删除;selectionBoxCorners 纯函数(编辑页框线
  // 仍在用)保留在上方两个用例中。
}
