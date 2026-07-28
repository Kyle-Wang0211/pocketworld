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
// [2026-07-28 用户签决] 浏览与编辑是同一个页面 —— 本文件守门这件事:
// 点"下一步"前后 SparseCloudView 必须是**同一个 State 实例**(相机不重建
// ⇒ 角度/位置/缩放天然连续),工具层只是叠上来。
// helper 原型见旧 selection_page_test 的 _pumpUntilRealAsyncSettles
// (done 谓词版:超时会 fail 带诊断,不会像"跑满轮直接返回"那样掩盖真实
// 卡死)。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_tools_layer.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/view_cube.dart';
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
  Future<(Directory, String)> fixture(WidgetTester tester) async {
    late Directory dir;
    late String ply;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer_edit');
      ply = await _writePly(dir);
    });
    return (dir, ply);
  }

  Future<void> openViewer(WidgetTester tester, String ply) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: SparseCloudViewerPage(plyPath: ply),
      ),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.text('Next').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
  }

  SelectionBox? boxOf(WidgetTester tester) =>
      tester.widget<SparseCloudView>(find.byType(SparseCloudView)).selectionBox;

  testWidgets('下一步 = 工具层叠上来,点云视图仍是同一个 State(零重建)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);

    final before = tester.state(find.byType(SparseCloudView));
    expect(find.byType(SelectionToolsLayer), findsNothing);

    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    // 核心断言:同一个 State 实例 ⇒ 相机(yaw/pitch/zoom/pan/pivot)原地
    // 未动,不存在"两个画面"之间的跳变。
    expect(
      identical(tester.state(find.byType(SparseCloudView)), before),
      isTrue,
    );
    expect(find.byType(SelectionToolsLayer), findsOneWidget);
    expect(find.byType(ViewCube), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    expect(boxOf(tester), isNotNull);

    // 返回浏览态:同样不重建视图。
    await tester.tap(find.byKey(const ValueKey('selection-back')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      identical(tester.state(find.byType(SparseCloudView)), before),
      isTrue,
    );
    expect(find.text('Next'), findsOneWidget);
    expect(boxOf(tester), isNull); // 浏览态不显示框
  });

  testWidgets('编辑态:盒外单指转视角、盒内单指平移盒', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(SparseCloudView));
    double cubeYaw() => tester.widget<ViewCube>(find.byType(ViewCube)).viewYaw;

    // 盒外(左上角)拖 → 转视角,盒不动。
    final yaw0 = cubeYaw();
    final box0 = boxOf(tester)!;
    await tester.dragFrom(
      rect.topLeft + const Offset(6, 6),
      const Offset(70, 0),
    );
    await tester.pumpAndSettle();
    expect(cubeYaw(), isNot(closeTo(yaw0, 1e-6)));
    expect(boxOf(tester)!.cx, closeTo(box0.cx, 1e-12));

    // 盒内(避开手柄)拖 → 平移盒,视角不动。
    final yawAfterOrbit = cubeYaw();
    await tester.dragFrom(
      // 盒占屏幕大半,中心偏下 60px 稳在盒内,又离中心那颗面手柄(容差
      // 30px)足够远。
      rect.center + const Offset(0, 60),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();
    // 盒手势期间相机严格不动(此前 onScaleStart / 盒手势分派两处接线漏
    // 掉,盒内拖会变成转视角 —— 这条就是那次的回归守门)。
    expect(cubeYaw(), closeTo(yawAfterOrbit, 1e-12));
    final moved =
        (boxOf(tester)!.cx - box0.cx).abs() +
        (boxOf(tester)!.cz - box0.cz).abs();
    expect(moved, greaterThan(1e-6));
  });

  testWidgets('点击骰子的面 = 该面转到正对', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    // 先转到一个歪视角,再点骰子。
    final rect = tester.getRect(find.byType(SparseCloudView));
    await tester.dragFrom(
      rect.topLeft + const Offset(6, 6),
      const Offset(40, 25),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    final cube = tester.widget<ViewCube>(find.byType(ViewCube));
    final target = primaryViewCubeFace(cube.viewYaw, cube.viewPitch);
    await tester.tapAt(tester.getCenter(find.byType(ViewCube)));
    await tester.pumpAndSettle();

    final after = tester.widget<ViewCube>(find.byType(ViewCube));
    final preset = kOrientationPresets.firstWhere((p) => p.label == target);
    expect(after.viewPitch, closeTo(preset.pitch, 1e-6));
    expect(primaryViewCubeFace(after.viewYaw, after.viewPitch), target);
  });

  testWidgets('加载失败:无编辑入口', (tester) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer_fail');
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: SparseCloudViewerPage(plyPath: '${dir.path}/nope.ply'),
      ),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.text('Failed to load point cloud').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsNothing);
  });
}
