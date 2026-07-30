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
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/ruler_scrubber.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_handles_3d.dart';
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
    final rectBefore = tester.getRect(find.byType(SparseCloudView));
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
    // 视图矩形逐像素不变 —— 编辑态曾隐藏 AppBar 导致 body 变高、点云整体
    // 上移(用户实机指认"整个点云的位置应该完全不变")。UI 只能叠加。
    expect(tester.getRect(find.byType(SparseCloudView)), rectBefore);
    // 编辑态必须画出 3D 框手柄(painter 参数与手柄层曾漏接,框整个不见)。
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is BoxHandlesPainter,
      ),
      findsOneWidget,
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
    expect(tester.getRect(find.byType(SparseCloudView)), rectBefore);
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

  testWidgets('拖动骰子 = 点云跟着转,松手有惯性', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    double cubeYaw() => tester.widget<ViewCube>(find.byType(ViewCube)).viewYaw;
    // 点云视角与骰子同源(骰子读的就是相机 yaw),断言骰子即断言点云。
    final before = cubeYaw();
    final cube = find.byType(ViewCube);
    // [2026-07-28 用户签决] 立方体可自由拖动,点云跟着转,阻力要小:
    // 30px 拖动应转出 ≥0.3 rad(灵敏度 0.02 rad/px,扣掉手势 slop)。
    await tester.drag(cube, const Offset(-30, 0));
    await tester.pumpAndSettle();
    final afterDrag = cubeYaw();
    expect((afterDrag - before).abs(), greaterThan(0.3));

    // 甩动后松手继续滑行(惯性)。
    await tester.fling(cube, const Offset(-40, 0), 1000);
    await tester.pump();
    final atRelease = cubeYaw();
    await tester.pump(const Duration(milliseconds: 60));
    expect((cubeYaw() - atRelease).abs(), greaterThan(0.01));
    await tester.pumpAndSettle();
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

  testWidgets('滑轨拨出去再拨回初始刻度:框朝向精确复原', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    List<double> rot() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!
        .rot;

    final before = [...rot()];
    // [2026-07-29 用户实机指认"每次拨回初始刻度角度都不一样"] 转轴此前每次
    // 都拿被转过的框重算,增量不可逆。锁轴后来回等量拨动必须精确抵消。
    final ruler = find.byType(RulerScrubber);
    await tester.drag(ruler, const Offset(-60, 0));
    await tester.pumpAndSettle();
    var moved = 0.0;
    for (var i = 0; i < 9; i++) {
      moved += (rot()[i] - before[i]).abs();
    }
    expect(moved, greaterThan(0.1), reason: '先要真的转出去');

    await tester.drag(ruler, const Offset(60, 0));
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      expect(rot()[i], closeTo(before[i], 1e-9), reason: '回到 0 刻度必须复原');
    }
  });

  testWidgets('连拨一整圈(360°)回到黄色刻度:框朝向精确复原', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    List<double> rot() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!
        .rot;

    final before = [...rot()];
    // [2026-07-29 用户实机指认"转完一圈还是无法回到原点"] 一圈 = 396px
    // (1.1 px/度)。分 4 段拨完,中途框会转过很多角度 —— 转轴绝不能因此
    // 被重算,否则每段绕的是不同的轴,累计不闭合。
    // 慢速匀速拨(19.8 px/s < 甩动阈值),避免惯性多转一截让"整圈"失准。
    final ruler = find.byType(RulerScrubber);
    final g = await tester.startGesture(tester.getCenter(ruler));
    for (var i = 0; i < 50; i++) {
      await g.moveBy(const Offset(-7.92, 0));
      await tester.pump(const Duration(milliseconds: 400));
    }
    await g.up();
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      expect(rot()[i], closeTo(before[i], 1e-6), reason: '整圈必须闭合');
    }
  });

  testWidgets('拨滑轨 = 点云转、框在屏幕上不动、画面永不歪', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    ViewCube cube() => tester.widget<ViewCube>(find.byType(ViewCube));
    SelectionBox box() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!;

    final camYaw0 = cube().viewYaw;
    final boxYaw0 = box().yawDeg;
    await tester.drag(find.byType(RulerScrubber), const Offset(-70, 0));
    await tester.pumpAndSettle();

    // ① 点云真的转了(骰子读相机姿态,跟着点云一起转)。
    final dCam = cube().viewYaw - camYaw0;
    expect(dCam.abs(), greaterThan(0.1), reason: '点云没转');
    // ② 框在世界里等量反向旋转 ⇒ 屏幕上纹丝不动。
    //    注意符号:box.yawDeg 的旋向约定与相机 yaw 相反(withYaw 用负角
    //    构造矩阵),所以"抵消"在读数上表现为**两者相等**,不是相加为零。
    final dBox = (box().yawDeg - boxYaw0) * math.pi / 180.0;
    expect(dBox, closeTo(dCam, 1e-6), reason: '框在屏幕上动了');
    // ③ [2026-07-29 用户签决] 立方体永远正着放:相机滚转恒 0。
    expect(cube().viewRoll.abs(), lessThan(1e-9), reason: '立方体/文字歪了');
  });

  testWidgets('连续拨动不会中途把点云重置回初始角度', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    List<double> rot() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!
        .rot;

    // [2026-07-29 用户实机指认"开始调节时点云自动重置到初始角度"] 根因是
    // moveTo 同步回调把基准重新烘焙、读数归零。慢速连续拨动,框的朝向必须
    // 单调累积,不能中途跳回。
    final ruler = find.byType(RulerScrubber);
    final g = await tester.startGesture(tester.getCenter(ruler));
    var lastDev = 0.0;
    for (var i = 0; i < 12; i++) {
      await g.moveBy(const Offset(-6, 0));
      await tester.pump(const Duration(milliseconds: 400));
      var dev = 0.0;
      for (var k = 0; k < 9; k++) {
        dev += (rot()[k] - kIdentityRot[k]).abs();
      }
      // 单调不减(容差留给浮点);任何一次归零都说明被重置了。
      expect(dev, greaterThanOrEqualTo(lastDev - 1e-9), reason: '第 $i 步被重置');
      lastDev = dev;
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(lastDev, greaterThan(0.05), reason: '整段拨动应累积出可观的旋转');
  });

  testWidgets('⋯ 菜单:回到初始旋转角度 / 回到初始点云大小', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    SelectionBox box() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!;

    // 先把框转歪(拨滑轨),再用菜单还原。
    await tester.drag(find.byType(RulerScrubber), const Offset(-70, 0));
    await tester.pumpAndSettle();
    // 注意:转轴 = 当前正对面的法向,默认视角正对 Front ⇒ 绕世界 Z 转,
    // 绕 Y 的分量(yawDeg)并不会变 —— 断言矩阵整体偏离单位阵才对。
    var moved = 0.0;
    for (var i = 0; i < 9; i++) {
      moved += (box().rot[i] - kIdentityRot[i]).abs();
    }
    expect(moved, greaterThan(0.1), reason: '滑轨应已转动框');

    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    expect(find.text('Reset Rotation'), findsOneWidget);
    expect(find.text('Reset Zoom'), findsOneWidget);
    expect(find.text('Reset Box Size'), findsOneWidget);
    await tester.tap(find.text('Reset Rotation'));
    await tester.pumpAndSettle();
    // 朝向回到轴对齐(单位阵),尺寸不动。
    for (var i = 0; i < 9; i++) {
      expect(box().rot[i], closeTo(kIdentityRot[i], 1e-12));
    }

    // 缩放:菜单还原到默认取景(不崩、工具层仍在即达标 —— 相机重置的
    // 数值语义由 SparseCloudView 的 reframe 自身负责)。
    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Zoom'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectionToolsLayer), findsOneWidget);

    // 恢复原始框大小:先拨滑轨改朝向,再复位 —— 框必须回到按点云重算的初始
    // 框(朝向为轴对齐、尺寸等于场景包围盒)。
    await tester.drag(find.byType(RulerScrubber), const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(box().yawDeg.abs(), greaterThan(1.0));
    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Box Size'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      expect(box().rot[i], closeTo(kIdentityRot[i], 1e-12));
    }
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
