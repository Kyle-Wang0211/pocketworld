import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';

void main() {
  test('JSON round-trip 保真', () {
    final b = SelectionBox.withYaw(
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
    expect(back.yawDeg, closeTo(30, 1e-9));
  });

  test('损坏 JSON → null,不抛', () {
    expect(SelectionBox.fromJson(null), isNull);
    expect(SelectionBox.fromJson('garbage'), isNull);
    expect(SelectionBox.fromJson(<String, dynamic>{'cx': 'nan?'}), isNull);
    expect(SelectionBox.fromJson(<String, dynamic>{'cx': 1}), isNull); // 缺字段
  });

  test('contains:轴对齐盒', () {
    final b = SelectionBox.withYaw(
      cx: 0,
      cy: 0,
      cz: 0,
      sx: 2,
      sy: 4,
      sz: 6,
      yawDeg: 0,
    );
    expect(b.contains(0.99, 1.99, 2.99), isTrue);
    expect(b.contains(1.01, 0, 0), isFalse);
    expect(b.contains(0, 2.01, 0), isFalse);
    expect(b.contains(0, 0, -3.01), isFalse);
  });

  test('contains:yaw=90° 时 x/z 半尺寸互换', () {
    // 盒局部 x 半尺寸 1、z 半尺寸 3;绕 Y 转 90° 后世界 x 方向的可容纳
    // 范围由局部 z 决定。
    final b = SelectionBox.withYaw(
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
    final b = SelectionBox.withYaw(
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
    expect(back!.yawDeg, closeTo(-15, 1e-9));
  });

  test('initialFor = 点云 AABB + 2% 余量(不再是外接球的外接立方)', () {
    final b = SelectionBox.initialFor(cx: 1, cy: 2, cz: 3, hx: 5, hy: 4, hz: 2);
    expect(b.cx, 1);
    // [2026-07-28] 贴合 AABB:边长 = 2·半边 ×1.02。原先取 2×外接球半径,
    // 框比相机取景大 40%,整个跑到屏幕外(用户实机指认"3D 框直接消失了")。
    expect(b.sx, closeTo(10.2, 1e-9));
    expect(b.sy, closeTo(8.16, 1e-9));
    expect(b.sz, closeTo(4.08, 1e-9));
    expect(b.yawDeg, closeTo(0, 1e-9));
  });

  test('绕任意世界轴旋转:正对面为底 ⇒ 转轴 = 该面法向', () {
    // [2026-07-29 用户签决] "按那个面为底开始旋转":正对 Front 时绕世界 Z、
    // 正对 Right 时绕世界 X —— 单一 yawDeg 表示不了,故升级为 rot 矩阵。
    const b = SelectionBox(cx: 0, cy: 0, cz: 0, sx: 2, sy: 1, sz: 4);
    // 绕世界 Z 转 90°:局部 x 轴(半长 1)应转到世界 ±y。
    final rz = b.rotatedAroundAxis(
      axis: const [0, 0, 1],
      deltaDeg: 90,
      pivotX: 0,
      pivotY: 0,
      pivotZ: 0,
    );
    expect(rz.contains(0, 0.99, 0), isTrue); // 原本 x 方向的半宽 1 转到了 y
    expect(rz.contains(0.99, 0, 0), isFalse); // 原 x 方向现在只剩 sy/2=0.5
    // 绕世界 X 转 90°:局部 z 轴(半长 2)应转到世界 ±y。
    final rx = b.rotatedAroundAxis(
      axis: const [1, 0, 0],
      deltaDeg: 90,
      pivotX: 0,
      pivotY: 0,
      pivotZ: 0,
    );
    expect(rx.contains(0, 1.9, 0), isTrue);
    expect(rx.contains(0, 0, 1.9), isFalse);
    // 尺寸与体积不变(刚性)。
    for (final r in [rz, rx]) {
      expect(r.sx, b.sx);
      expect(r.sy, b.sy);
      expect(r.sz, b.sz);
    }
  });

  test('旧存档(只有 yawDeg)仍能读,且与 withYaw 等价', () {
    final legacy = SelectionBox.fromJson(<String, dynamic>{
      'cx': 1.0,
      'cy': 2.0,
      'cz': 3.0,
      'sx': 2.0,
      'sy': 2.0,
      'sz': 2.0,
      'yawDeg': 37.0,
    });
    expect(legacy, isNotNull);
    final direct = SelectionBox.withYaw(
      cx: 1,
      cy: 2,
      cz: 3,
      sx: 2,
      sy: 2,
      sz: 2,
      yawDeg: 37,
    );
    for (var i = 0; i < 9; i++) {
      expect(legacy!.rot[i], closeTo(direct.rot[i], 1e-12));
    }
  });
}
