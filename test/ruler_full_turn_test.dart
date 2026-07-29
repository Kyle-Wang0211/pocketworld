// 滑轨"一圈"的口径:读数、像素、框的真实旋转角三者必须 1:1。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/ruler_scrubber.dart';

void main() {
  testWidgets('读数与像素:1.1 px/度 ⇒ 一整圈 = 396px', (tester) async {
    double v = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 60,
              child: StatefulBuilder(
                builder: (ctx, ss) => RulerScrubber(
                  value: v,
                  onChanged: (nv) => ss(() => v = nv),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final r = find.byType(RulerScrubber);
    // 连续 4 段拖动,累计 -396px(负号 = 读数增大方向)。
    for (var i = 0; i < 4; i++) {
      await tester.drag(r, const Offset(-99, 0));
      await tester.pump();
    }
    // 实测:合成拖动全额到账,无 slop 损耗 ⇒ 396px 精确等于 360.0°。
    expect(v, closeTo(360.0, 0.01));
  });

  test('框的旋转:读数增量 1:1 转成角度,累计 360° 精确回到原点', () {
    const axis = [0.0, 1.0, 0.0];
    var box = const SelectionBox(cx: 0, cy: 0, cz: 0, sx: 2, sy: 1, sz: 3);
    final before = [...box.rot];
    // 模拟滑轨:每次 +12°,共 30 次 = 360°。
    for (var i = 0; i < 30; i++) {
      box = box.rotatedAroundAxis(
        axis: axis,
        deltaDeg: 12,
        pivotX: 0,
        pivotY: 0,
        pivotZ: 0,
      );
    }
    for (var i = 0; i < 9; i++) {
      expect(box.rot[i], closeTo(before[i], 1e-9), reason: '一圈必须精确闭合');
    }
  });

  test('半圈 = 180°:局部 x 轴指向反向', () {
    var box = const SelectionBox(cx: 0, cy: 0, cz: 0, sx: 2, sy: 1, sz: 3);
    for (var i = 0; i < 15; i++) {
      box = box.rotatedAroundAxis(
        axis: const [0, 1, 0],
        deltaDeg: 12,
        pivotX: 0,
        pivotY: 0,
        pivotZ: 0,
      );
    }
    // 局部 x 轴(rot 第 0 列)应从 (1,0,0) 转到 (-1,0,0)。
    expect(box.rot[0], closeTo(-1, 1e-9));
    expect(box.rot[6], closeTo(0, 1e-9));
  });
}
