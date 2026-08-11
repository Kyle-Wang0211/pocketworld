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

  test('initialSquareFace = 三边等长(每个面看到的都是正方形)', () {
    // [2026-08-09 用户签决(第三轮)] "只需要让用户每个面看到的初始框是正方形
    // 就行,内部的点云可以自适应大小" —— 三边取调用方传入的最长半边。
    final b = SelectionBox.initialSquareFace(
      cx: 1,
      cy: 2,
      cz: 3,
      halfExtent: 5,
    );
    expect(b.cx, 1);
    expect(b.sx, closeTo(10, 1e-9));
    expect(b.sy, b.sx, reason: '面不是正方形:sy≠sx');
    expect(b.sz, b.sx, reason: '面不是正方形:sz≠sx');
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

  test('当前版本存档:只有 yawDeg 也能读,且与 withYaw 等价', () {
    final legacy = SelectionBox.fromJson(<String, dynamic>{
      'v': kSelectionBoxSchemaVersion,
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

  test('旧版本存档一律作废(算法变更后必须按当前算法重算初始框)', () {
    // [2026-07-29 用户实机指认"覆盖率明显不是 97%"] 根因不是判据不准,而是
    // 老草稿里存着上一版(MAD 判据)算出的小框,isSaneFor 判它"可用"就直接
    // 复用了 —— 新算法根本没跑。版本号是这条的结构性防线。
    const body = {
      'cx': 0.0,
      'cy': 0.0,
      'cz': 0.0,
      'sx': 1.0,
      'sy': 1.0,
      'sz': 1.0,
      'yawDeg': 0.0,
    };
    expect(SelectionBox.fromJson(body), isNull, reason: '无版本号 = 旧档');
    expect(
      SelectionBox.fromJson({...body, 'v': kSelectionBoxSchemaVersion - 1}),
      isNull,
    );
    expect(
      SelectionBox.fromJson({...body, 'v': kSelectionBoxSchemaVersion}),
      isNotNull,
    );
    // 自己写出来的一定读得回来。
    const b = SelectionBox(cx: 1, cy: 2, cz: 3, sx: 4, sy: 5, sz: 6);
    expect(SelectionBox.fromJson(b.toJson()), isNotNull);
  });
}
