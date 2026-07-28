// [2026-07-27 controller 修订] testWidgets 体默认跑在 FakeAsync zone;
// SparseCloudViewerPage._load() 里的 compute() + SelectionBox.loadFrom 都是
// 真实 dart:io/isolate Future,在 FakeAsync 里不会自己完成 —— 必须用
// tester.runAsync 切回真实事件循环让它落地,再 tester.pump() 消化随之而来
// 的 setState。brief 原始测试代码没处理这点,会在 pumpAndSettle 上死等
// (Step 1 新增用例实测复现:第 3 个用例挂满 10 分钟框架超时才炸)。
//
// 根因排查(2026-07-27):挂死不是 helper 本身(helper 恒有界),是新增
// 用例把 `Directory.systemTemp.createTemp(...)` 写成裸 `await`、留在
// tester.runAsync(...) 外面 —— testWidgets 默认在 FakeAsync zone 里跑,
// 裸 await 一个真实 dart:io Future 永远等不到它完成(FakeAsync 不会驱动
// 真实事件循环),于是死等到框架 10 分钟超时。本文件前两个既有用例、
// 以及 test/selection_page_test.dart 的用例全部把「所有」真实 IO(含
// createTemp 本身)包进 tester.runAsync —— 新增四个用例已改成同一模式。
// helper 复制自 test/selection_page_test.dart 的 _pumpUntilRealAsyncSettles
// (done 谓词版:超时会 fail 带诊断,不会像"跑满轮直接返回"那样掩盖真实
// 卡死)。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_page.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart';

/// 反复 runAsync(短真实延时)+pump,直到 [done] 为真;超时 fail 带诊断,
/// 绝不无限挂死。
Future<void> _pumpUntilRealAsyncSettles(
  WidgetTester tester,
  bool Function() done, {
  int maxIters = 40,
  Duration step = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < maxIters; i++) {
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(step));
    // ⚠️ pump 必须带 duration:等"路由退场/入场"这类谓词时,无参 pump()
    // 不推进动画时钟 —— pop 已发生但页面永远不从树上移除,谓词恒假超时
    // (实测踩过)。50ms/轮 × 40 轮足够覆盖 300ms 转场。
    await tester.pump(const Duration(milliseconds: 50));
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
  testWidgets('加载成功:底部出现 保存草稿|下一步 双按钮', (tester) async {
    late Directory dir;
    late String ply;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer3');
      ply = await _writePly(dir);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: ply)),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.text('保存草稿').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('保存草稿'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
  });

  testWidgets('加载失败:无双按钮', (tester) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer4');
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: '${dir.path}/nope.ply')),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.text('点云文件读取失败').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('点云文件读取失败'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
  });

  testWidgets('下一步 push SelectionPage;返回后回到干净查看态', (tester) async {
    late Directory dir;
    late String ply;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer5');
      ply = await _writePly(dir);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: ply)),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.text('下一步').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一步'));
    await tester.pump();
    // 等到返回键出现 —— 即 SelectionPage 的 _load()(真实 IO)已完成、
    // 离开 _loading 分支。只等页面类型出现是不够的:loading 态没有返回键,
    // tap 会打空,后面的 pop 永远等不到(实测踩过)。
    await _pumpUntilRealAsyncSettles(
      tester,
      () => tester.any(find.byKey(const ValueKey('selection-back'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SelectionPage), findsOneWidget);

    // SelectionPage 初始化会建初始盒;点其返回键 → flush 落盘 → pop 回查看器
    await tester.tap(find.byKey(const ValueKey('selection-back')));
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => !tester.any(find.byType(SelectionPage)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SelectionPage), findsNothing);
    expect(find.byType(SparseCloudViewerPage), findsOneWidget);
    // [2026-07-28 用户签决] 预览模式不显示选区回显(框外红只属于编辑页),
    // 返回后只需回到干净的点云查看态。
  });

  testWidgets('保存草稿 = pop 查看器', (tester) async {
    late Directory dir;
    late String ply;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer6');
      ply = await _writePly(dir);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(
              MaterialPageRoute<void>(
                builder: (_) => SparseCloudViewerPage(plyPath: ply),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.text('保存草稿').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(find.byType(SparseCloudViewerPage), findsNothing);
  });
}
