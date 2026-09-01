// feed_live_card_test.dart — 社区 feed 焦点卡真实时自转(方案 B)的七道压热闸。
//
// 真机验收("连续滚动 10 分钟,.serious 不出现")测不了逻辑对错,只能测热的
// 结果;这里守的是**闸门本身的状态机**,尤其是两个容易写反的地方:
//   • 闸 4 的滞回(停在 serious、恢复要回 nominal)—— 写成同阈值就会横跳
//   • 闸 5 的 settle(滚动停下 300ms 才放行)—— 忘了作废旧定时器就会提前起转
//
// [2026-08-23] 闸 2(八叉树降点)那组用例随 live_card_cloud.dart 一起删除 ——
// 那个文件是死代码:gate `!isPointCloudFormat` 从未被撤,所以它从未被实例化过。
// 详见该次提交的说明。本文件保留的是**真在跑**的那几道闸:
// 下标算错就会把 rgb 和 xyz 错位,而那在真机上表现为"颜色乱了",很难倒查。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/community/card_live_governor.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/auto_rotating_cloud_view.dart';


void main() {
  group('闸 4 — thermalState 滞回', () {
    test('nominal / fair 不停转', () {
      expect(cardThermalStopFor(thermal: 0, stopped: false), isFalse);
      expect(cardThermalStopFor(thermal: 1, stopped: false), isFalse);
    });

    test('serious 与 critical 停转', () {
      expect(cardThermalStopFor(thermal: 2, stopped: false), isTrue);
      expect(cardThermalStopFor(thermal: 3, stopped: false), isTrue);
    });

    test('停了之后 fair 不足以恢复 —— 必须回到 nominal', () {
      expect(cardThermalStopFor(thermal: 1, stopped: true), isTrue);
      expect(cardThermalStopFor(thermal: 0, stopped: true), isFalse);
    });

    test('探针不可用(-1,模拟器)按 nominal 走', () {
      expect(cardThermalStopFor(thermal: -1, stopped: false), isFalse);
      expect(cardThermalStopFor(thermal: -1, stopped: true), isFalse);
    });
  });

  group('闸 3/5/7 — CardLiveGovernor', () {
    late CardLiveGovernor g;
    // 轮询周期拉长,免得测试期间 FFI 探针(真机上有值)自己插进来改状态。
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      g = CardLiveGovernor(pollInterval: const Duration(hours: 1));
    });
    tearDown(() => g.dispose());

    test('闸 3:默认 24fps 封顶,不是 60', () {
      expect(g.fpsCap, 24);
      expect(kCardFpsNominal, 24);
      expect(kCardFpsFair, 15);
    });

    test('静止时放行', () {
      expect(g.liveAllowed, isTrue);
    });

    test('闸 5:滚动一开始就停转', () {
      g.onScrollStart();
      expect(g.liveAllowed, isFalse);
    });

    testWidgets('闸 5:滚动停下后要等满 settle 才放行', (tester) async {
      g.onScrollStart();
      g.onScrollEnd();
      expect(g.liveAllowed, isFalse, reason: '刚松手不该立刻起转');
      await tester.pump(kCardSettleDelay - const Duration(milliseconds: 50));
      expect(g.liveAllowed, isFalse, reason: 'settle 还没满');
      await tester.pump(const Duration(milliseconds: 100));
      expect(g.liveAllowed, isTrue);
    });

    testWidgets('闸 5:静止期内又划走 → 重新计时,不提前起转', (tester) async {
      g.onScrollStart();
      g.onScrollEnd();
      await tester.pump(const Duration(milliseconds: 200));
      g.onScrollStart(); // 又划了
      expect(g.liveAllowed, isFalse);
      // 若旧定时器没被作废,它会在这一拍到期并错误放行。
      await tester.pump(const Duration(milliseconds: 200));
      expect(g.liveAllowed, isFalse, reason: '仍在滚动中');
      g.onScrollEnd();
      await tester.pump(kCardSettleDelay + const Duration(milliseconds: 20));
      expect(g.liveAllowed, isTrue);
    });

    testWidgets('闸 7:内存告警只记录 —— 不停自转、也不动实例上限', (tester) async {
      // [2026-08-17] 这条断言改了四次,每次都是真机把上一版打回来:
      //   v1 "单向闸不恢复"      → 自转被永久关死
      //   v2 "45s 后恢复"        → 从详情页退回来撞进退避窗口,僵 78 秒
      //   v3 "收紧 cap 到 1"     → cap < 同时可见卡数 ⇒ thrashing,
      //                            41s 内 18 次挂载,内存反升到 2132MB
      //   v4 什么都不做:cap 固定 3(五月的值),这里只守住"别再自作聪明"。
      final capBefore = CardViewerRegistry.cap;
      expect(g.liveAllowed, isTrue);
      g.didHaveMemoryPressure();
      expect(g.liveAllowed, isTrue, reason: '内存告警不该停自转');
      expect(CardViewerRegistry.cap, capBefore,
          reason: 'cap 被动了 —— 收紧到小于可见卡数就是在制造 mount/evict 循环');
      expect(CardViewerRegistry.cap, CardViewerRegistry.normalCap);
      // 走完去重退避,免得留 pending timer。
      await tester.pump(CardLiveGovernor.memoryBackoff +
          const Duration(seconds: 1));
    });

    test('实例上限:要装得下滚动范围内的整个 feed,让 3D 持久存在', () {
      // [2026-08-17 用户签决] "ply 不能持久存在吗?还需要反复加载吗?"
      //
      // 这个值我调错过三次,每次都是往**小**了调,以为能省内存:
      //   3 → 五月原值,峰值 1685MB
      //   1 → 41 秒 18 次挂载,内存反升 2132MB(cap < 同屏可见数)
      //   2 → 60 秒 13 次挂载,内存 424 → 1752MB(cap < feed 卡片数)
      //
      // 真相:evict 之后 GPU 资源不立即回收,**卸载-重载循环本身就是内存增长
      // 的来源**。卡片一直挂着反而是稳态开销。所以要大到装得下用户滚动范围
      // 内的全部卡片。
      expect(CardViewerRegistry.normalCap, greaterThanOrEqualTo(5),
          reason: '小于 feed 卡片数 ⇒ 同一张卡被反复加载,内存只会更高');
    });

    test('releaseAll:进详情页时清空,计数归零', () {
      for (var i = 0; i < 2; i++) {
        CardViewerRegistry.register(() {});
      }
      expect(CardViewerRegistry.aliveCount, greaterThan(0));
      CardViewerRegistry.releaseAll('测试');
      expect(CardViewerRegistry.aliveCount, 0,
          reason: '详情页开全质量 viewer 时,feed 这两份必须先放掉');
    });

    test('后台不转', () {
      g.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(g.liveAllowed, isFalse);
      g.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(g.liveAllowed, isTrue);
    });

    test('闸门变化会通知(VaultPage 靠它重算谁能 live)', () {
      var n = 0;
      g.addListener(() => n++);
      g.onScrollStart();
      expect(n, greaterThan(0));
    });
  });

  group('自转机制 — moveTo 每帧硬置位真的驱动渲染', () {
    // [2026-08-17 补] 这是方案 B 设计时标"⚠️ 待验"的那一条,此前只靠读代码
    // 确认(_onControllerTarget 直接 setState 置位,不走 _animateTo 缓动),
    // 从未在运行时证明过。真机首轮没看到自转时,它是第一个该被排除的嫌疑,
    // 却排除不掉 —— 因为没有任何测试压着它。补上。

    (Float32List, Uint8List) cube() {
      final xyz = Float32List(3 * 8 * 8 * 8);
      final rgb = Uint8List(3 * 8 * 8 * 8);
      var i = 0;
      for (var x = 0; x < 8; x++) {
        for (var y = 0; y < 8; y++) {
          for (var z = 0; z < 8; z++) {
            xyz[i] = x.toDouble();
            xyz[i + 1] = y.toDouble();
            xyz[i + 2] = z.toDouble();
            rgb[i] = 200;
            rgb[i + 1] = 180;
            rgb[i + 2] = 160;
            i += 3;
          }
        }
      }
      return (xyz, rgb);
    }

    /// 当前挂在树上的 painter —— 它的 yaw 是"真的会被画出来"的那个值。
    SparseCloudPainter painterOf(WidgetTester t) =>
        t.widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((c) => c.painter)
            .whereType<SparseCloudPainter>()
            .first;

    testWidgets('连续 moveTo 累加的 yaw 不会被 re-target 缓动吞掉', (tester) async {
      final (xyz, rgb) = cube();
      final controller = CloudViewController();
      await tester.pumpWidget(MaterialApp(
        home: SparseCloudView(
          xyz: xyz,
          rgb: rgb,
          controller: controller,
          showControls: false,
        ),
      ));
      await tester.pump();
      final st = tester.state(find.byType(SparseCloudView)) as dynamic;
      final base = st.debugCamera as CloudViewCamera;

      // 按 24 帧 = 1 秒 @24fps 推进(原文照 LiveCardCloud._onTick 写,
      // 该类已于 2026-08-23 删除;这里测的是 CloudViewController 本身)。
      const step = kCardRotateRadPerSec / kCardFpsNominal;
      var yaw = base.yaw;
      for (var f = 0; f < kCardFpsNominal; f++) {
        yaw += step;
        controller.moveTo((
          yaw: yaw,
          pitch: base.pitch,
          roll: base.roll,
          zoom: base.zoom,
          panX: base.panX,
          panY: base.panY,
          pivotX: base.pivotX,
          pivotY: base.pivotY,
          pivotZ: base.pivotZ,
        ));
        await tester.pump(const Duration(milliseconds: 42));
      }

      final after = st.debugCamera as CloudViewCamera;
      expect(
        after.yaw - base.yaw,
        closeTo(kCardRotateRadPerSec, 1e-6),
        reason: '1 秒该正好转过 kCardRotateRadPerSec;差很多就说明 moveTo '
            '走了缓动(每帧重启 280ms tween,永远到不了目标)',
      );
    });

    testWidgets('yaw 一路传到 painter —— 画面真的会变,不是只改了 State', (tester) async {
      final (xyz, rgb) = cube();
      final controller = CloudViewController();
      await tester.pumpWidget(MaterialApp(
        home: SparseCloudView(
          xyz: xyz,
          rgb: rgb,
          controller: controller,
          showControls: false,
        ),
      ));
      await tester.pump();
      final st = tester.state(find.byType(SparseCloudView)) as dynamic;
      final base = st.debugCamera as CloudViewCamera;
      final before = painterOf(tester);
      final yawBefore = before.yaw;

      controller.moveTo((
        yaw: base.yaw + 1.0,
        pitch: base.pitch,
        roll: base.roll,
        zoom: base.zoom,
        panX: base.panX,
        panY: base.panY,
        pivotX: base.pivotX,
        pivotY: base.pivotY,
        pivotZ: base.pivotZ,
      ));
      await tester.pump();

      final after = painterOf(tester);
      expect(after.yaw, closeTo(yawBefore + 1.0, 1e-6),
          reason: 'painter 还拿着旧 yaw ⇒ 相机动了但画面不会重绘');
      expect(after.shouldRepaint(before), isTrue,
          reason: 'shouldRepaint 说不用重画 ⇒ 屏幕上什么都不会发生');
    });
  });

  _autoRotateTests();

  group('自转速度', () {
    test('角速度与帧率解耦 —— 24fps 与 15fps 转一圈一样久', () {
      const turn = 2 * 3.141592653589793;
      final at24 = turn / kCardRotateRadPerSec;
      expect(at24, closeTo(15.0, 0.001), reason: '15 秒一圈');
      // 降级只改帧数,不改角速度:同样 15 秒,只是步进从 1/24 变成 1/15。
      expect(kCardRotateRadPerSec * (1 / kCardFpsNominal) * kCardFpsNominal,
          closeTo(kCardRotateRadPerSec * (1 / kCardFpsFair) * kCardFpsFair,
              1e-9));
    });
  });
}

// ── 详情页 3D viewer 自转(2026-08-17 用户:"就完成这一个功能")──────────
//
// 与 feed live 卡同源的机制,但服务的是"打开一个作品,它自己转"。用户一碰
// 就永久让位 —— 伸手去转说明想看某个角度,两秒后被拽走是最气人的交互。
void _autoRotateTests() {
  (Float32List, Uint8List) cube() {
    final xyz = Float32List(3 * 512);
    final rgb = Uint8List(3 * 512);
    var i = 0;
    for (var x = 0; x < 8; x++) {
      for (var y = 0; y < 8; y++) {
        for (var z = 0; z < 8; z++) {
          xyz[i] = x.toDouble();
          xyz[i + 1] = y.toDouble();
          xyz[i + 2] = z.toDouble();
          rgb[i] = 200;
          rgb[i + 1] = 180;
          rgb[i + 2] = 160;
          i += 3;
        }
      }
    }
    return (xyz, rgb);
  }

  double yawOf(WidgetTester t) =>
      ((t.state(find.byType(SparseCloudView)) as dynamic).debugCamera
              as CloudViewCamera)
          .yaw;

  group('详情页 viewer 自转', () {
    testWidgets('挂上去就自己转,不用碰它', (tester) async {
      final (xyz, rgb) = cube();
      await tester.pumpWidget(MaterialApp(
        home: AutoRotatingCloudView(xyz: xyz, rgb: rgb, showControls: false),
      ));
      await tester.pump();
      final start = yawOf(tester);
      for (var f = 0; f < 24; f++) {
        await tester.pump(const Duration(milliseconds: 42));
      }
      final after = yawOf(tester);
      // 下限只用来分辨"根本没动";精度交给下面的 closeTo。
      // (写成 >0.5 会比应有的 2π/15≈0.42 还大,永远失败 —— 第一版就是这么错的。)
      expect(after - start, greaterThan(0.1),
          reason: '1 秒该转过约 ${kCardRotateRadPerSec.toStringAsFixed(2)} rad;'
              '纹丝不动就是 ticker 没跑或 moveTo 没置位');
      expect(after - start, closeTo(kCardRotateRadPerSec, 0.15),
          reason: '转速该是 15 秒一圈');
    });

    testWidgets('用户一碰就永久让位,不再被拽走', (tester) async {
      final (xyz, rgb) = cube();
      await tester.pumpWidget(MaterialApp(
        home: AutoRotatingCloudView(xyz: xyz, rgb: rgb, showControls: false),
      ));
      await tester.pump();
      for (var f = 0; f < 6; f++) {
        await tester.pump(const Duration(milliseconds: 42));
      }
      // 碰一下。
      await tester.startGesture(tester.getCenter(find.byType(SparseCloudView)));
      await tester.pump();
      final atTakeover = yawOf(tester);
      for (var f = 0; f < 24; f++) {
        await tester.pump(const Duration(milliseconds: 42));
      }
      expect(yawOf(tester), closeTo(atTakeover, 1e-9),
          reason: '用户上手后自转还在推 yaw —— 他想看的角度会被拽走');
    });
  });

  group('点云不在 feed 里 live —— 规则守卫', () {
    test('live_card_cloud.dart 已删除,且无人再引用', () {
      expect(
        File('lib/ui/community/live_card_cloud.dart').existsSync(),
        isFalse,
        reason: '它 2026-08-23 被删:gate !isPointCloudFormat 从未被撤,'
            '所以那 299 行从未被任何代码路径执行过',
      );
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        // 只看代码行 —— 注释里说明"它已被删"是允许的。
        final code = src
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        expect(
          code,
          isNot(contains('LiveCardCloud')),
          reason: '${f.path} 又引用了它',
        );
      }
    });

    test('点云格式仍被挡在 feed 的 live 之外', () {
      final card = File('lib/ui/community/work_card.dart').readAsStringSync();
      expect(card, contains("fmt == 'spz' || fmt == 'gsplat' || fmt == 'ply'"));
      expect(card, contains('&& !isPointCloudFormat'));
    });

    test('那两条已被推翻的理由不许作为当前理由回来', () {
      // 钉的是**原句本身**,不是模糊关键词 —— 上一版按"含 1 GB 就算违规"写,
      // 结果把"吃满 1 GB 要 660 万 splat"这种解释性提及也误判了。
      //
      // ✗ 「每个约 1 GB」被本仓自己量的 1.4 MB 推翻(差三个数量级)
      // ✗ 「Polycam 就是这么处理的」—— Polycam 根本没有"点云"这种作品类型
      const refuted = [
        '在 iOS 上每个约 1 GB unified memory',
        '~1 GB unified memory each on iOS',
        'Polycam 就是这么处理的',
        'Polycam handles this the same way',
      ];
      for (final path in const [
        'lib/ui/community/work_card.dart',
        'lib/ui/community/post_card.dart',
      ]) {
        final src = File(path).readAsStringSync();
        for (final claim in refuted) {
          // 允许出现在标了 ✗ / REFUTED 的行里(那是在记录"它被推翻了")
          for (final line in src.split('\n')) {
            if (!line.contains(claim)) continue;
            expect(
              line.contains('✗') || line.contains('REFUTED'),
              isTrue,
              reason: '$path 又把已推翻的断言当理由写了:${line.trim()}',
            );
          }
        }
      }
    });
  });
}
