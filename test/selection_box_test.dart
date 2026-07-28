import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';

void main() {
  test('JSON round-trip 保真', () {
    const b = SelectionBox(
      cx: 1,
      cy: -2,
      cz: 3,
      sx: 4,
      sy: 5,
      sz: 6,
      yawDeg: 30,
    );
    final back = SelectionBox.fromJson(b.toJson());
    expect(back, isNotNull);
    expect(back!.cx, 1);
    expect(back.sy, 5);
    expect(back.yawDeg, 30);
  });

  test('损坏 JSON → null,不抛', () {
    expect(SelectionBox.fromJson(null), isNull);
    expect(SelectionBox.fromJson('garbage'), isNull);
    expect(SelectionBox.fromJson(<String, dynamic>{'cx': 'nan?'}), isNull);
    expect(SelectionBox.fromJson(<String, dynamic>{'cx': 1}), isNull); // 缺字段
  });

  test('contains:轴对齐盒', () {
    const b = SelectionBox(cx: 0, cy: 0, cz: 0, sx: 2, sy: 4, sz: 6, yawDeg: 0);
    expect(b.contains(0.99, 1.99, 2.99), isTrue);
    expect(b.contains(1.01, 0, 0), isFalse);
    expect(b.contains(0, 2.01, 0), isFalse);
    expect(b.contains(0, 0, -3.01), isFalse);
  });

  test('contains:yaw=90° 时 x/z 半尺寸互换', () {
    // 盒局部 x 半尺寸 1、z 半尺寸 3;绕 Y 转 90° 后世界 x 方向的可容纳
    // 范围由局部 z 决定。
    const b = SelectionBox(
      cx: 0,
      cy: 0,
      cz: 0,
      sx: 2,
      sy: 10,
      sz: 6,
      yawDeg: 90,
    );
    expect(b.contains(2.9, 0, 0), isTrue); // 世界 x=2.9 < 局部 z 半尺寸 3
    expect(b.contains(0, 0, 1.1), isFalse); // 世界 z=1.1 > 局部 x 半尺寸 1
  });

  test('文件存取 round-trip + 缺失→null', () async {
    final dir = await Directory.systemTemp.createTemp('selbox');
    addTearDown(() => dir.delete(recursive: true));
    expect(await SelectionBox.loadFrom(dir.path), isNull);
    const b = SelectionBox(
      cx: 1,
      cy: 2,
      cz: 3,
      sx: 4,
      sy: 5,
      sz: 6,
      yawDeg: -15,
    );
    await b.saveTo(dir.path);
    final back = await SelectionBox.loadFrom(dir.path);
    expect(back!.yawDeg, -15);
  });

  test('initialFor = 点云 AABB + 2% 余量(不再是外接球的外接立方)', () {
    final b = SelectionBox.initialFor(cx: 1, cy: 2, cz: 3, hx: 5, hy: 4, hz: 2);
    expect(b.cx, 1);
    // [2026-07-28] 贴合 AABB:边长 = 2·半边 ×1.02。原先取 2×外接球半径,
    // 框比相机取景大 40%,整个跑到屏幕外(用户实机指认"3D 框直接消失了")。
    expect(b.sx, closeTo(10.2, 1e-9));
    expect(b.sy, closeTo(8.16, 1e-9));
    expect(b.sz, closeTo(4.08, 1e-9));
    expect(b.yawDeg, 0);
  });
}
