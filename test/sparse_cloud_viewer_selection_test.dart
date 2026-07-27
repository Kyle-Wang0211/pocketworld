// [2026-07-27 controller 修订] testWidgets 体默认跑在 FakeAsync zone;
// SparseCloudViewerPage._load() 里的 compute() + SelectionBox.loadFrom 都是
// 真实 dart:io/isolate Future,在 FakeAsync 里不会自己完成 —— 必须用
// tester.runAsync 切回真实事件循环让它落地,再 tester.pump() 消化随之而来
// 的 setState。brief 原始测试代码没处理这点,会在 pumpAndSettle 上死等。
// helper 复制自 test/selection_page_test.dart 的 _pumpUntilRealAsyncSettles。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart';

/// 反复 runAsync(短真实延时)+pump,直到 [done] 为真。
Future<void> _pumpUntilRealAsyncSettles(
  WidgetTester tester,
  bool Function() done, {
  int maxIters = 40,
  Duration step = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < maxIters; i++) {
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();
  }
  fail('真实 IO 延续在超时前未落地(done() 恒 false)');
}

/// 写一个最小合法 PLY(2 点)。
Future<String> _writePly(Directory dir) async {
  final head =
      'ply\nformat binary_little_endian 1.0\nelement vertex 2\n'
      'property float x\nproperty float y\nproperty float z\n'
      'property uchar red\nproperty uchar green\nproperty uchar blue\n'
      'end_header\n';
  final body = BytesBuilder();
  for (final p in [
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
  ]) {
    final bd = ByteData(15);
    bd.setFloat32(0, p[0], Endian.little);
    bd.setFloat32(4, p[1], Endian.little);
    bd.setFloat32(8, p[2], Endian.little);
    bd.setUint8(12, 10);
    body.add(bd.buffer.asUint8List());
  }
  final f = File('${dir.path}/official_sfm_sparse.ply');
  await f.writeAsBytes([...head.codeUnits, ...body.toBytes()]);
  return f.path;
}

void main() {
  testWidgets('有 JSON:SparseCloudView 收到 selectionBox', (tester) async {
    late Directory dir;
    late String ply;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer');
      ply = await _writePly(dir);
      const box = SelectionBox(
        cx: 0,
        cy: 0,
        cz: 0,
        sx: 1,
        sy: 1,
        sz: 1,
        yawDeg: 10,
      );
      await box.saveTo(dir.path);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: ply)),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => tester.any(find.byType(SparseCloudView)),
    );
    await tester.pumpAndSettle();
    final view = tester.widget<SparseCloudView>(find.byType(SparseCloudView));
    expect(view.selectionBox, isNotNull);
    expect(view.selectionBox!.yawDeg, 10);
  });

  testWidgets('无 JSON:selectionBox 为 null,页面正常', (tester) async {
    late Directory dir;
    late String ply;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer2');
      ply = await _writePly(dir);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: ply)),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => tester.any(find.byType(SparseCloudView)),
    );
    await tester.pumpAndSettle();
    final view = tester.widget<SparseCloudView>(find.byType(SparseCloudView));
    expect(view.selectionBox, isNull);
  });
}
