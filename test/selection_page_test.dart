// [2026-07-27 controller 修订] testWidgets 体默认跑在 FakeAsync zone;
// SelectionBox.loadFrom/saveTo 是真实 dart:io Future,在 FakeAsync 里永远
// 不会自己完成 —— 必须用 tester.runAsync 切回真实事件循环让它落地,再
// tester.pump() 消化随之而来的 setState/延续。brief 原始测试代码没处理这
// 点,会在 pumpAndSettle 上死等(中央转圈是不确定态动画,更是雪上加霜)。
// 逐层排查过程中还挖出一个 selection_page.dart 的真 bug(非测试专属):
// `late final _presetAnim = AnimationController(...)` 是惰性初始化,若
// 用户全程没碰朝向立方体就直接返回,_presetAnim 会拖到 dispose() 里
// `_presetAnim.dispose()` 首次访问才构造 —— 此时 vsync(this) 要向上找
// TickerMode 祖先,但 element 树已在 deactivate,真机同样会炸。已在
// selection_page.dart 里改成 initState 显式构造修复,是本次唯一动到的
// 生产代码。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart'
    show axisAngleOf, mulTransposed;
import 'package:pocketworld_flutter/ui/official_capture/selection_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/ruler_scrubber.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_page.dart';
import 'package:pocketworld_flutter/ui/official_capture/view_cube.dart';

Future<(Directory, Float32List, Uint8List)> _fixture() async {
  final dir = await Directory.systemTemp.createTemp('selpage');
  final xyz = Float32List.fromList([
    for (var i = 0; i < 300; i++) (i % 17) * 0.1 - 0.8,
  ]);
  final rgb = Uint8List(300);
  return (dir, xyz, rgb);
}

/// 反复 runAsync(短真实延时)+pump,直到 [done] 为真。真实 dart:io Future
/// 完成后,它的延续要经过好几层 await(saveTo → _flush/_load 自身的
/// Future → 调用方的 await)才能逐层冒泡回 FakeAsync 队列,实测单次
/// runAsync+pump 不够、需要循环几轮 —— 这比固定延时更抗 CI 抖动。
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

/// 等 SelectionPage 挂载且完成 SelectionBox.loadFrom 落地(debugBox !=
/// null)。挂载判定同一循环里做,因为 push 转场后页面不一定在下一帧就已
/// 建树。
Future<void> _pumpUntilLoaded(WidgetTester tester) async {
  final finder = find.byType(SelectionPage);
  await _pumpUntilRealAsyncSettles(tester, () {
    if (!tester.any(finder)) return false;
    final dynamic state = tester.state(finder);
    return state.debugBox != null;
  });
}

/// 立方体改 TextPainter 绘制后 find.text 找不到面标签 —— 语义断言读 state。
String _facingLabel(WidgetTester tester) {
  final dynamic st = tester.state(find.byType(SelectionPage));
  return st.debugFacingLabel as String;
}

void main() {
  test('朝向预设表:六面 + Top 是 -90° 俯视', () {
    expect(kOrientationPresets, hasLength(6));
    expect(kOrientationPresets.first.label, 'Top');
    expect(kOrientationPresets.first.pitch, closeTo(-math.pi / 2, 1e-9));
  });

  testWidgets('返回键 pop save_draft 并已写盘', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    String? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(ctx).push<String>(
                MaterialPageRoute(
                  builder: (_) =>
                      SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    // 中央转圈是不确定态动画(CircularProgressIndicator 无 value),
    // pumpAndSettle 在它消失前永远不会 settle —— 先 pump() 让页面挂载,
    // 用 _pumpUntilLoaded 等真实 IO 落地把 spinner 换成正式内容,再
    // pumpAndSettle 消化转场动画。
    await tester.pump();
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('selection-back')));
    await tester.pump();
    // _onBackPressed 里的 _flush() 是真实 saveTo IO —— 等它的延续(含
    // Navigator.pop)冒泡回来,再消化 pop 转场动画。
    await _pumpUntilRealAsyncSettles(tester, () => popped != null);
    await tester.pumpAndSettle();

    expect(popped, 'save_draft');
    expect(
      File('${dir.path}/$kSelectionBoxFileName').existsSync(),
      isTrue, // 返回时兜底 flush
    );
  });

  testWidgets('Android 系统返回键经 maybePop 转发到 save_draft 链路', (tester) async {
    // 回归覆盖:SelectionPage 曾经整页无 PopScope,系统返回会被 Navigator
    // 直接 pop(null) 绕过 —— 跳过 _flush() 丢最后一次改动,且
    // ar_capture_page.dart 的 `result == 'save_draft'` 判断不成立,用户
    // 会落回等待页(违反"选区页返回不回等待页"签决)。这里用
    // flutter_test 模拟系统返回的标准手法(WidgetsApp.didPopRoute,对应
    // Android 系统返回键经 maybePop 触发 PopScope)驱动页面的 PopScope,
    // 而不是点击左上角按钮(那条路径已被上面那条用例覆盖)。注:
    // canPop:false 下 iOS 侧滑手势被框架直接禁用(popGestureEnabled →
    // false,手势 inert),不会走到这条 didPopRoute 路径 —— iOS 上返回
    // 的唯一出口是左上角返回按钮,这条用例不覆盖也不代表 iOS 侧滑。
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    String? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(ctx).push<String>(
                MaterialPageRoute(
                  builder: (_) =>
                      SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();

    final dynamic widgetsAppState = tester.state(find.byType(WidgetsApp));
    await widgetsAppState.didPopRoute();
    await tester.pump();
    // _onBackPressed 里的 _flush() 是真实 saveTo IO —— 等它的延续(含
    // Navigator.pop)冒泡回来,再消化 pop 转场动画。
    await _pumpUntilRealAsyncSettles(tester, () => popped != null);
    await tester.pumpAndSettle();

    expect(popped, 'save_draft');
    expect(
      File('${dir.path}/$kSelectionBoxFileName').existsSync(),
      isTrue, // 系统返回(Android)同样兜底 flush
    );
  });

  testWidgets('Ready to Process:轻提示,不 pop', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ready to Process'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('稠密化处理即将上线'), findsOneWidget);
    expect(find.byType(SelectionPage), findsOneWidget); // 没退出
  });

  testWidgets('已有 JSON 时恢复上次的框', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    const saved = SelectionBox(
      cx: 9,
      cy: 9,
      cz: 9,
      sx: 1,
      sy: 1,
      sz: 1,
      yawDeg: 45,
    );
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
      await saved.saveTo(dir.path);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();

    final page = tester.state(find.byType(SelectionPage)) as dynamic;
    expect((page.debugBox as SelectionBox).yawDeg, 45);
  });

  testWidgets('滑杆改 yawDeg,且 viewYaw 跟随(滑杆↔相机联动)', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();

    final slider = find.byType(RulerScrubber);
    expect(slider, findsOneWidget);
    await tester.drag(slider, const Offset(60, 0));
    await tester.pumpAndSettle();
    final page = tester.state(find.byType(SelectionPage)) as dynamic;
    final yaw = (page.debugBox as SelectionBox).yawDeg;
    expect(yaw, isNot(0));
    // 相机联动:SelectionCloudView 收到的 viewYaw 含滑杆分量
    final view = tester.widget<SelectionCloudView>(
      find.byType(SelectionCloudView),
    );
    final preset = kOrientationPresets.first; // 初始 Top
    expect(view.viewYaw, closeTo(preset.yaw + yaw * math.pi / 180, 1e-9));
  });

  testWidgets('旋转刻度尺:无端点 360° 循环,连续值不吸附刻度', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();
    final ruler = find.byType(RulerScrubber);
    dynamic page() => tester.state(find.byType(SelectionPage));
    double yaw() => ((page() as dynamic).debugBox as SelectionBox).yawDeg;

    // [2026-07-28 用户签决] 1) 没有尽头:累计拖过 360° 也不 clamp,值环向
    // 归一化到 (-180,180],绝不停在端点。
    for (var i = 0; i < 12; i++) {
      await tester.drag(ruler, const Offset(-100, 0)); // 每次 ≈ +45.5°
      await tester.pump();
    }
    expect(yaw().abs(), lessThanOrEqualTo(180.0));
    // 拖了 ≈546°,若被 clamp 在端点会恰为 ±180;环向 wrap 后必不在端点。
    expect(yaw().abs(), isNot(closeTo(180.0, 1.0)));

    // 2) 连续不吸附:小步 7px ≈ 3.18°,落点不该是 5° 刻度的整数倍。
    final before = yaw();
    await tester.drag(ruler, const Offset(-7, 0));
    await tester.pump();
    final delta = yaw() - before;
    expect(delta.abs(), greaterThan(0.5));
    expect((yaw() % 5.0).abs(), isNot(closeTo(0.0, 1e-6)));
  });

  testWidgets('朝向立方体上下箭头 = 三层移动:Top↕水平↕Bottom', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await _pumpUntilRealAsyncSettles(
      tester,
      () => tester.any(find.byKey(const ValueKey('cube-down'))),
    );
    await tester.pumpAndSettle();
    // [2026-07-28 骰子机制] 初始 Top;每按一次绕屏幕水平轴滚 90°。
    expect(_facingLabel(tester), 'Top');
    await tester.tap(find.byKey(const ValueKey('cube-down')));
    await tester.pumpAndSettle();
    expect(_facingLabel(tester), 'Front');
    await tester.tap(find.byKey(const ValueKey('cube-down')));
    await tester.pumpAndSettle();
    expect(_facingLabel(tester), 'Bottom');
    // 继续下滚过极:Bottom → Back(骰子翻过去,背面倒置显示,不回正)。
    await tester.tap(find.byKey(const ValueKey('cube-down')));
    await tester.pumpAndSettle();
    expect(_facingLabel(tester), 'Back');
    // 反向 = 严格原路倒放:上→Bottom,再上→Front。
    await tester.tap(find.byKey(const ValueKey('cube-up')));
    await tester.pumpAndSettle();
    expect(_facingLabel(tester), 'Bottom');
    await tester.tap(find.byKey(const ValueKey('cube-up')));
    await tester.pumpAndSettle();
    expect(_facingLabel(tester), 'Front');
  });

  testWidgets('连续下箭头 = 大圆绕圈走全四面(含 Top,无 bottom-back 震荡)', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();
    expect(_facingLabel(tester), 'Top');
    // [2026-07-28 用户实机指认] 修复前一直按下 = bottom-back-bottom-front
    // 震荡,永远经过不了 Top。骰子机制下连续同向 = 绕同一屏幕轴一直滚,
    // 四面全经过并循环,每步严格 90°。
    const expected = [
      'Front', 'Bottom', 'Back', 'Top', //
      'Front', 'Bottom', 'Back', 'Top',
    ];
    final seen = <String>[];
    for (var i = 0; i < expected.length; i++) {
      await tester.tap(find.byKey(const ValueKey('cube-down')));
      await tester.pumpAndSettle();
      seen.add(_facingLabel(tester));
    }
    expect(seen, expected);
    // 接着连续上箭头 = 严格倒放:反向循环。
    const expectedUp = [
      'Back', 'Bottom', 'Front', 'Top', //
      'Back', 'Bottom', 'Front', 'Top',
    ];
    final seenUp = <String>[];
    for (var i = 0; i < expectedUp.length; i++) {
      await tester.tap(find.byKey(const ValueKey('cube-up')));
      await tester.pumpAndSettle();
      seenUp.add(_facingLabel(tester));
    }
    expect(seenUp, expectedUp);
  });

  testWidgets('Top 视角左右箭头 = 翻到相邻水平面(永远翻面,无原地转)', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();
    expect(_facingLabel(tester), 'Top');

    // [2026-07-28 用户签决二轮] Top 点右箭头 = 翻面到 lastH(Front)的
    // 右邻水平面 Right —— 不再原地转。
    await tester.tap(find.byKey(const ValueKey('cube-right')));
    await tester.pumpAndSettle();
    expect(_facingLabel(tester), 'Right');

    // 立方体是语义指示器:不吃滑杆分量。拖滑杆后 ViewCube.viewYaw 不变,
    // SelectionCloudView.viewYaw(点云)跟随变化。
    final cubeYawBefore = tester
        .widget<ViewCube>(find.byType(ViewCube))
        .viewYaw;
    await tester.drag(find.byType(RulerScrubber), const Offset(60, 0));
    await tester.pumpAndSettle();
    final cubeYawAfter = tester.widget<ViewCube>(find.byType(ViewCube)).viewYaw;
    expect(cubeYawAfter, closeTo(cubeYawBefore, 1e-9));
    final page = tester.state(find.byType(SelectionPage)) as dynamic;
    final yawDeg = (page.debugBox as SelectionBox).yawDeg;
    expect(yawDeg, isNot(0));
    final cloud = tester.widget<SelectionCloudView>(
      find.byType(SelectionCloudView),
    );
    expect(cloud.viewYaw, closeTo(cubeYawAfter + yawDeg * math.pi / 180, 1e-9));
  });

  testWidgets('骰子守门:任意箭头序列每步落定姿态相对上一步严格 90°', (tester) async {
    late Directory dir;
    late Float32List xyz;
    late Uint8List rgb;
    await tester.runAsync(() async {
      (dir, xyz, rgb) = await _fixture();
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await _pumpUntilLoaded(tester);
    await tester.pumpAndSettle();
    // [2026-07-28 用户签决三轮] "必须只转 90°,像现实扔骰子" —— 混合序列
    // (含过极、含左右、含反向)逐步断言相对旋转角恒为 π/2,无任何 120°
    // 斜转或 180° 合成。
    const keys = [
      'cube-down', 'cube-right', 'cube-up', 'cube-up', //
      'cube-left', 'cube-down', 'cube-down', 'cube-right',
    ];
    dynamic page() => tester.state(find.byType(SelectionPage));
    var prev = (page() as dynamic).debugPose as List<double>;
    for (final k in keys) {
      await tester.tap(find.byKey(ValueKey(k)));
      await tester.pumpAndSettle();
      final cur = (page() as dynamic).debugPose as List<double>;
      final (_, angle) = axisAngleOf(mulTransposed(cur, prev));
      expect(angle, closeTo(math.pi / 2, 1e-9), reason: 'step $k 不是 90°');
      prev = cur;
    }
  });
}
