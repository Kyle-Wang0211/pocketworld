// auto_capture_telemetry_test.dart — T5「遥测」的守门。
//
// 分两层:
//
//  ① 聚合器本体(auto_capture_telemetry.dart,纯 Dart,可以真跑):计数、
//     时长、三档停留、提前触发、5 秒节流。每一条都对应 spec §11 的一项
//     待实测量 —— 这些数算错了,真机跑一整场也只是拿回一堆错数,而且
//     **不会有任何东西报错**。
//
//  ② 源码契约(ar_capture_page.dart 逐段 grep):页面在 HEAD 上就编译不过
//     (8 个与本功能无关的 undefined_method/undefined_class),widget test
//     起不来,所以页面那半只能靠源码断言钉住。这一层的每一条都对应一条
//     "跑起来什么都不报错、只是数据静默为空/为错"的路径。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_telemetry.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';

String _pageSource() =>
    File('lib/ui/official_capture/ar_capture_page.dart').readAsStringSync();

/// 取 [open] 之后、[close] 之前的那一段源码。两个锚点都必须存在且有序,
/// 否则断言的是空串 —— 那是最经典的假守门。
String _section(String source, String open, String close) {
  final start = source.indexOf(open);
  expect(start, greaterThanOrEqualTo(0), reason: 'anchor not found: $open');
  final end = source.indexOf(close, start + open.length);
  expect(
    end,
    greaterThan(start),
    reason: 'anchor not found after $open: $close',
  );
  return source.substring(start, end);
}

/// 去掉行注释。**只对"不该出现"的断言用**:一句解释"为什么不能用
/// DateTime.now()"的注释本身就含有那个字面量,不剥注释的话守门会被
/// 自己的解释判红,而为了让它变绿去删注释才是真正的损失。
/// (这几段源码里没有含 `//` 的字符串字面量,所以这么剥是安全的。)
String _codeOnly(String source) => source
    .split('\n')
    .map((line) {
      final at = line.indexOf('//');
      return at < 0 ? line : line.substring(0, at);
    })
    .join('\n');

Map<String, int> _counts(AutoCaptureTelemetry t) =>
    t.snapshot()['decision_counts']! as Map<String, int>;

Map<String, double> _paceSec(AutoCaptureTelemetry t) =>
    t.snapshot()['pace_sec']! as Map<String, double>;

double _num(Map<String, Object> snap, String key) =>
    (snap[key]! as num).toDouble();

int _int(AutoCaptureTelemetry t, String key) => t.snapshot()[key]! as int;

/// 开一轮、喂 [n] 个 [d] 判定(1 秒一个,normal 档),不关。
AutoCaptureTelemetry _openWith(AutoCaptureDecision d, int n) {
  final t = AutoCaptureTelemetry()..recordSessionStart(0);
  for (var i = 1; i <= n; i++) {
    t.recordDecision(d, tSec: i.toDouble(), pace: ShutterPace.normal);
  }
  return t;
}

void main() {
  // ─── ① 聚合器本体 ───────────────────────────────────────────────────

  group('decision counts (spec §11「视差下限触发率」)', () {
    test('counts each kind and leaves untouched kinds at zero', () {
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 1,
        pace: ShutterPace.normal,
      );
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 2,
        pace: ShutterPace.normal,
      );
      t.recordDecision(
        AutoCaptureDecision.skipNotMoved,
        tSec: 3,
        pace: ShutterPace.normal,
      );

      final counts = _counts(t);
      expect(counts['fire'], 2);
      expect(counts['skipNotMoved'], 1);
      // 零必须是**写出来的零**,不是缺键 —— 缺键在 JSONL 里读起来
      // 与"这一档从没发生过"无法区分,而后者正是本任务要回答的问题。
      expect(counts['skipPaced'], 0);
      expect(counts['skipTracking'], 0);
      expect(counts['skipCapped'], 0);
      expect(counts['skipTimeLimit'], 0);
      expect(counts.keys.toSet(), {
        for (final d in AutoCaptureDecision.values) d.name,
      });
    });

    test('decisions total equals the sum of the six counts', () {
      // `decisions` 是占比的分母。它与六个分档分开算,算错了整张表的
      // 比例全错,而每一个单独的数看上去都对。
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      var tick = 0.0;
      void feed(AutoCaptureDecision d, int n) {
        for (var i = 0; i < n; i++) {
          t.recordDecision(d, tSec: tick += 0.03, pace: ShutterPace.normal);
        }
      }

      feed(AutoCaptureDecision.skipPaced, 27);
      feed(AutoCaptureDecision.skipNotMoved, 9);
      feed(AutoCaptureDecision.fire, 3);
      feed(AutoCaptureDecision.skipTracking, 1);

      expect(_int(t, 'decisions'), 40);
      expect(
        _counts(t).values.fold<int>(0, (a, b) => a + b),
        _int(t, 'decisions'),
      );
      // §9 差异1 要的就是这个比例:下限门实际拦下了多少。
      expect(_counts(t)['skipNotMoved']! / _int(t, 'decisions'), 9 / 40);
    });

    test('decisions before a session starts are dropped', () {
      final t = AutoCaptureTelemetry();
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 1,
        pace: ShutterPace.normal,
      );
      expect(_counts(t)['fire'], 0);
      expect(_int(t, 'decisions'), 0);
    });

    test('decisions after a session ends are dropped', () {
      // 对照上一条。判定只归属于**它所在的那一轮**;记进一轮已经关掉的
      // 会话会把那一行的比例悄悄改掉,而那一行早就写出去了。
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 1,
        pace: ShutterPace.normal,
      );
      t.recordSessionEnd();
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 2,
        pace: ShutterPace.normal,
      );
      expect(_counts(t)['fire'], 1);
      expect(_int(t, 'decisions'), 1);
    });
  });

  group('session duration (spec §11「采集时长 vs 5 分钟上限」)', () {
    test('duration is the span of the decisions, on the ARFrame clock', () {
      final t = AutoCaptureTelemetry()..recordSessionStart(10.0);
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 40.0,
        pace: ShutterPace.normal,
      );
      t.recordDecision(
        AutoCaptureDecision.skipPaced,
        tSec: 75.5,
        pace: ShutterPace.normal,
      );
      expect(_num(t.snapshot(), 'session_duration_sec'), closeTo(65.5, 1e-9));
    });

    test('duration is zero before any decision arrives', () {
      final t = AutoCaptureTelemetry()..recordSessionStart(10.0);
      expect(_num(t.snapshot(), 'session_duration_sec'), 0.0);
    });

    test('duration keeps growing while the session is still open', () {
      // 中途 roll-up 行必须带**当时**的已跑时长:App 被杀 / 用户强退时,
      // 最后一行 roll-up 就是我们唯一能拿回来的东西。若时长只在关会话时
      // 才算,这一行会恒为 0 —— 正好在最需要它的那种收场里为 0。
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordDecision(
        AutoCaptureDecision.skipPaced,
        tSec: 12.0,
        pace: ShutterPace.normal,
      );
      expect(t.snapshot()['closed'], isFalse);
      expect(_num(t.snapshot(), 'session_duration_sec'), 12.0);
    });

    test('a new session inherits nothing from the previous one', () {
      // 一次采集里用户可以停了再开。第二轮带着第一轮的计数 = 两轮的比例
      // 全是错的,而且看不出来。
      final t = _openWith(AutoCaptureDecision.fire, 3);
      t.recordFireOutcome(enqueued: true);
      t.recordSessionEnd();

      t.recordSessionStart(100.0);
      expect(_int(t, 'decisions'), 0);
      expect(_counts(t)['fire'], 0);
      expect(_int(t, 'fire_enqueued'), 0);
      expect(_int(t, 'fire_before_tick'), 0);
      expect(_num(t.snapshot(), 'session_duration_sec'), 0.0);
      expect(_paceSec(t)['normal'], 0.0);
      expect(t.snapshot()['closed'], isFalse);

      // 第二轮的**第一发**必须以第二轮的起跑为参照。上一轮的开火时刻若
      // 留着,这一发的间隔会被算成 97.4 秒 —— 计数错了,而两轮的数字
      // 各自看上去都很正常。
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 100.4,
        pace: ShutterPace.normal,
      );
      expect(_int(t, 'fire_before_tick'), 1);
    });

    test('a telemetry that never ran reports zeros and is not closed', () {
      // `closed` 的语义是"这一轮结束了",不是"现在没在跑"。一个从没跑过
      // 的对象报 closed=true,读日志的人会以为有一轮跑完了且什么都没发生。
      final snap = AutoCaptureTelemetry().snapshot();
      expect(snap['closed'], isFalse);
      expect(snap['decisions'], 0);
      expect(_num(snap, 'session_duration_sec'), 0.0);
    });
  });

  group('fire outcomes (spec §7「入队失败 + 记遥测」)', () {
    test('enqueued and failed are counted apart', () {
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordFireOutcome(enqueued: true);
      t.recordFireOutcome(enqueued: false);
      t.recordFireOutcome(enqueued: true);
      expect(_int(t, 'fire_enqueued'), 2);
      expect(_int(t, 'fire_enqueue_failed'), 1);
    });

    test('a failed enqueue is never counted as a success', () {
      // 对照上一条的反向:入队失败与成功是两件不同的事(spec §7),
      // 把失败并进成功 = 遥测显示 300 张齐活,盘上只有 250 张。
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordFireOutcome(enqueued: false);
      t.recordFireOutcome(enqueued: false);
      expect(_int(t, 'fire_enqueued'), 0);
      expect(_int(t, 'fire_enqueue_failed'), 2);
    });

    test('outcomes reconcile with the fire decisions', () {
      // 这条不变式是整行数据的自检:页面接线漏了任何一侧,
      // fire_enqueued + fire_enqueue_failed 就对不上 decision_counts.fire。
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      for (var i = 1; i <= 5; i++) {
        t.recordFireOutcome(enqueued: i != 3);
        t.recordDecision(
          AutoCaptureDecision.fire,
          tSec: i.toDouble(),
          pace: ShutterPace.normal,
        );
      }
      expect(
        _int(t, 'fire_enqueued') + _int(t, 'fire_enqueue_failed'),
        _counts(t)['fire'],
      );
      expect(_int(t, 'fire_enqueue_failed'), 1);
    });

    test('fire outcomes outside a session are dropped', () {
      final t = AutoCaptureTelemetry();
      t.recordFireOutcome(enqueued: true);
      t.recordSessionStart(0);
      t.recordSessionEnd();
      t.recordFireOutcome(enqueued: false);
      expect(_int(t, 'fire_enqueued'), 0);
      expect(_int(t, 'fire_enqueue_failed'), 0);
    });
  });

  group('fire_before_tick (R2 上限判据的提前触发)', () {
    // 判据:开火时距上一次开火 **严格短于**当前档的 tick 间隔 ⇒ 只可能是
    // R2(重叠上限)打的,因为 tick 闸在 governor 里就是
    // `sinceLastTickSec < tickIntervalSec -> skipPaced`。等于间隔时 tick 闸
    // 已经放行,归因就不唯一了 —— 那一发不算。
    AutoCaptureTelemetry fireAt(
      double t, {
      ShutterPace pace = ShutterPace.normal,
    }) {
      final tel = AutoCaptureTelemetry()..recordSessionStart(0);
      tel.recordDecision(AutoCaptureDecision.fire, tSec: t, pace: pace);
      return tel;
    }

    test('just below the tick interval counts as early', () {
      expect(_int(fireAt(0.999), 'fire_before_tick'), 1);
    });

    test('exactly at the tick interval does not count', () {
      expect(_int(fireAt(1.0), 'fire_before_tick'), 0);
    });

    test('after the tick interval does not count', () {
      expect(_int(fireAt(1.001), 'fire_before_tick'), 0);
    });

    test('the first fire is measured from the session start', () {
      // controller 的 `_lastTickSec` 在 start() 那一帧就被置成起跑时间戳,
      // 所以第一发的参照点是起跑,不是 0、也不是"没有参照就不算"。
      final t = AutoCaptureTelemetry()..recordSessionStart(100.0);
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 100.4,
        pace: ShutterPace.normal,
      );
      expect(_int(t, 'fire_before_tick'), 1);
    });

    test('later fires are measured from the previous fire', () {
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      // 1.5s:距起跑够远,不算早。
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 1.5,
        pace: ShutterPace.normal,
      );
      // 2.0s:距**上一发**只有 0.5s ⇒ 早。若参照点错记成起跑(2.0s),
      // 这一发会被漏掉。
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 2.0,
        pace: ShutterPace.normal,
      );
      expect(_int(t, 'fire_before_tick'), 1);
      expect(_counts(t)['fire'], 2);
    });

    test('non-fire decisions do not move the reference point', () {
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordDecision(
        AutoCaptureDecision.skipPaced,
        tSec: 1.4,
        pace: ShutterPace.normal,
      );
      // 距起跑 1.5s ⇒ 不早。若 skipPaced 也挪了参照点,这一发会被误判成早。
      t.recordDecision(
        AutoCaptureDecision.fire,
        tSec: 1.5,
        pace: ShutterPace.normal,
      );
      expect(_int(t, 'fire_before_tick'), 0);
    });

    test('the interval comes from the pace, not a hardcoded 1s', () {
      // soft 档 tick = 2s(autoCaptureTickInterval)。1.5s 的间隔在 normal 档
      // 不算早,在 soft 档就是早 —— 写死 1.0 会把这一发漏掉。
      expect(_int(fireAt(1.5), 'fire_before_tick'), 0);
      expect(_int(fireAt(1.5, pace: ShutterPace.soft), 'fire_before_tick'), 1);
      expect(_int(fireAt(2.5, pace: ShutterPace.hard), 'fire_before_tick'), 1);
      expect(_int(fireAt(3.5, pace: ShutterPace.hard), 'fire_before_tick'), 0);
    });
  });

  group('pace dwell (spec §11「ShutterPace 三档间隔」)', () {
    test(
      'dwell is attributed to the pace seen at the start of the interval',
      () {
        // 判定 @0 normal, @2 normal, @3 soft, @5 soft
        //   0→2 记 normal(2s);2→3 记 normal(1s,因为 t=2 那一刻还是 normal);
        //   3→5 记 soft(2s)。左端点归属 —— 右端点归属会把 2→3 记成 soft。
        final t = AutoCaptureTelemetry()..recordSessionStart(0);
        t.recordDecision(
          AutoCaptureDecision.skipPaced,
          tSec: 0,
          pace: ShutterPace.normal,
        );
        t.recordDecision(
          AutoCaptureDecision.skipPaced,
          tSec: 2,
          pace: ShutterPace.normal,
        );
        t.recordDecision(
          AutoCaptureDecision.skipPaced,
          tSec: 3,
          pace: ShutterPace.soft,
        );
        t.recordDecision(
          AutoCaptureDecision.skipPaced,
          tSec: 5,
          pace: ShutterPace.soft,
        );

        final pace = _paceSec(t);
        expect(pace['normal'], closeTo(3.0, 1e-9));
        expect(pace['soft'], closeTo(2.0, 1e-9));
        expect(pace['hard'], 0.0);
        expect(pace.keys.toSet(), {for (final p in ShutterPace.values) p.name});
      },
    );

    test('dwell sums to the span between first and last decision', () {
      // 三档之和 == 首末判定之差,是这张直方图唯一的自检:少记一段、
      // 重复记一段,都会在这里露出来。
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      const paces = <ShutterPace>[
        ShutterPace.normal,
        ShutterPace.soft,
        ShutterPace.hard,
        ShutterPace.soft,
        ShutterPace.normal,
      ];
      for (var i = 0; i < paces.length; i++) {
        t.recordDecision(
          AutoCaptureDecision.skipPaced,
          tSec: 10.0 + i * 1.5,
          pace: paces[i],
        );
      }
      final total = _paceSec(t).values.fold<double>(0, (a, b) => a + b);
      expect(total, closeTo(4 * 1.5, 1e-9));
    });

    test('a single decision accumulates no dwell', () {
      final t = _openWith(AutoCaptureDecision.skipPaced, 1);
      expect(_paceSec(t).values.fold<double>(0, (a, b) => a + b), 0.0);
    });

    test('a backwards timestamp never subtracts time', () {
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordDecision(
        AutoCaptureDecision.skipPaced,
        tSec: 5.0,
        pace: ShutterPace.normal,
      );
      t.recordDecision(
        AutoCaptureDecision.skipPaced,
        tSec: 3.0,
        pace: ShutterPace.normal,
      );
      expect(_paceSec(t)['normal'], 0.0);
    });
  });

  group('flush throttle (pose 流 20–60 Hz,绝不许每帧一行)', () {
    AutoCaptureTelemetry open() {
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordDecision(
        AutoCaptureDecision.skipPaced,
        tSec: 0.1,
        pace: ShutterPace.normal,
      );
      return t;
    }

    test('just below the flush interval yields nothing', () {
      expect(open().snapshotIfDue(4.999), isNull);
    });

    test('exactly at the flush interval yields a line', () {
      expect(open().snapshotIfDue(5.0), isNotNull);
    });

    test('past the flush interval yields a line', () {
      expect(open().snapshotIfDue(5.001), isNotNull);
    });

    test('the flush clock restarts after each line', () {
      final t = open();
      expect(t.snapshotIfDue(5.0), isNotNull);
      expect(t.snapshotIfDue(9.99), isNull);
      expect(t.snapshotIfDue(10.0), isNotNull);
    });

    test('the flush clock starts at the session start, not at zero', () {
      // 起跑时间戳是 ARFrame 时钟(开机以来的秒数),开机跑几小时后
      // 它是个几万的数。若节流从 0 起算,第一帧就"到点"了 ⇒ 每帧一行。
      final t = AutoCaptureTelemetry()..recordSessionStart(87400.0);
      expect(t.snapshotIfDue(87400.5), isNull);
      expect(t.snapshotIfDue(87405.0), isNotNull);
    });

    test('no line outside a session', () {
      final t = AutoCaptureTelemetry();
      expect(t.snapshotIfDue(999.0), isNull);
      t.recordSessionStart(0);
      t.recordSessionEnd();
      expect(t.snapshotIfDue(999.0), isNull);
    });

    test('roll-up lines are open, the end line is closed', () {
      final t = open();
      expect(t.snapshotIfDue(5.0)!['closed'], isFalse);
      expect(t.recordSessionEnd()!['closed'], isTrue);
    });

    test('ending twice writes one line', () {
      // 页面有三条收场路径(用户停 / controller 自停 / dispose),它们会
      // 互相重叠。幂等是这三条能各自无脑调用的前提。
      final t = open();
      expect(t.recordSessionEnd(), isNotNull);
      expect(t.recordSessionEnd(), isNull);
    });

    test('ending a session that never started writes nothing', () {
      expect(AutoCaptureTelemetry().recordSessionEnd(), isNull);
    });
  });

  group('snapshot shape', () {
    test('exactly the eight documented keys, nothing more', () {
      // 「少而准」是本任务的显式要求。多一个字段就多一份要维护的口径,
      // 而 JSONL 的读者只会读文档里写了的那几个。
      final t = _openWith(AutoCaptureDecision.fire, 1);
      expect(t.snapshot().keys.toSet(), {
        'closed',
        'session_duration_sec',
        'decisions',
        'decision_counts',
        'fire_enqueued',
        'fire_enqueue_failed',
        'fire_before_tick',
        'pace_sec',
      });
    });

    test('seconds are rounded to milliseconds, not truncated', () {
      final t = AutoCaptureTelemetry()..recordSessionStart(0);
      t.recordDecision(
        AutoCaptureDecision.skipPaced,
        tSec: 1.23456,
        pace: ShutterPace.normal,
      );
      t.recordDecision(
        AutoCaptureDecision.skipPaced,
        tSec: 2.46912,
        pace: ShutterPace.normal,
      );
      expect(_num(t.snapshot(), 'session_duration_sec'), 2.469);
      expect(_paceSec(t)['normal'], 1.235);
    });
  });

  // ─── ② 源码契约(页面编译不过,只能这么钉)───────────────────────────

  group('ar_capture_page telemetry wiring', () {
    test('there is exactly one auto_capture telemetry outlet', () {
      // 「不另起一条遥测通道」—— 多一条出口就多一处会漏采的地方。
      // 也钉住它走的是既有的 TelemetryWriter(落 Documents 的 JSONL,
      // 拔线跑完 devicectl 一次拉走),不是 print/DeviceLog。
      final page = _pageSource();
      expect(
        RegExp(r"event\('auto_capture'").allMatches(page).length,
        1,
        reason: 'auto_capture 只能有一个落盘出口',
      );
      expect(page, contains('TelemetryWriter.instance.event('));
      final outlet = _section(
        page,
        'void _emitAutoTelemetry(',
        'void _startAutoCapture(',
      );
      expect(outlet, contains("TelemetryWriter.instance.event('auto_capture'"));
    });

    test('every decision is recorded before the setState short-circuit', () {
      // 页面在判定没变化时会提前 return(20–60 Hz 下不重建整页)。
      // 打点若落在那条 return 之后,占大多数的稳定态判定
      // (skipPaced / skipNotMoved)会**一条都采不到** —— 而
      // skipNotMoved 的占比正是本任务存在的理由。
      final page = _pageSource();
      final drive = _section(
        page,
        'void _driveAutoCapture(ARPose pose)',
        'void _emitAutoTelemetry(',
      );
      final record = drive.indexOf('_autoTelemetry.recordDecision(');
      final shortCircuit = drive.indexOf('decision == _lastAutoDecision');
      expect(record, greaterThanOrEqualTo(0));
      expect(shortCircuit, greaterThan(0));
      expect(record, lessThan(shortCircuit), reason: '打点必须在提前 return 之前');
    });

    test('the decision clock is the ARFrame clock, and the pace is the '
        'controller\'s own', () {
      // 两个静默错法:① 用 DateTime.now()(另一个纪元,时长直接是天文数字);
      // ② 传一个与 controller 的 paceProvider 不同源的档位(停留直方图
      // 与 governor 实际用的间隔对不上)。
      final page = _pageSource();
      final drive = _section(
        page,
        'void _driveAutoCapture(ARPose pose)',
        'void _emitAutoTelemetry(',
      );
      expect(drive, contains('tSec: pose.timestamp'));
      expect(drive, contains('pace: _shutterPace'));
      expect(_codeOnly(drive), isNot(contains('DateTime.now()')));
      expect(page, contains('paceProvider: () => _shutterPace'));
    });

    test('the self-stop path closes the session', () {
      // controller 撞 300 张 / 5 分钟会**自己**停(_running=false),这条路
      // 根本不经过 _stopAutoCapture(它开头就 `if (!isRunning) return;`)。
      // 漏了这条,恰恰是最该被记下来的那两种收场一行都写不出来。
      final page = _pageSource();
      final drive = _section(
        page,
        'void _driveAutoCapture(ARPose pose)',
        'void _emitAutoTelemetry(',
      );
      expect(drive, contains('_autoTelemetry.recordSessionEnd()'));
      expect(drive, contains('_autoTelemetry.snapshotIfDue('));
    });

    test('the user-stop and teardown paths close the session too', () {
      final page = _pageSource();
      final stop = _section(
        page,
        'void _stopAutoCapture()',
        'void _setCaptureMode(',
      );
      expect(stop, contains('_autoTelemetry.recordSessionEnd()'));
      final dispose = _section(page, 'void dispose() {', 'Widget build(');
      expect(dispose, contains('_autoTelemetry.recordSessionEnd()'));
    });

    test('the session starts on the seed pose timestamp', () {
      final page = _pageSource();
      final start = _section(
        page,
        'void _startAutoCapture(ARPose seed)',
        'void _stopAutoCapture()',
      );
      expect(start, contains('recordSessionStart(seed.timestamp)'));
      expect(_codeOnly(start), isNot(contains('DateTime.now()')));
    });

    test('both enqueue outcomes are recorded at the fire hook', () {
      // spec §7 明写"入队失败 ⇒ 记遥测"。onFire 的真返回值在这里,
      // 这是**唯一**能把成功与失败分开的地方。
      final page = _pageSource();
      final fire = _section(
        page,
        'bool _onAutoCaptureFire()',
        'void _onShutterTap()',
      );
      expect(
        RegExp(r'_autoTelemetry\.recordFireOutcome\(').allMatches(fire).length,
        2,
        reason: 'try 与 catch 两条路各记一次',
      );
      expect(fire, contains('recordFireOutcome(enqueued: false)'));
      // 恒真 = 把失败记成成功。
      expect(
        RegExp(r'recordFireOutcome\(enqueued: true\)').allMatches(fire).isEmpty,
        isTrue,
      );
      // T4 的既有契约不许被这次改动破坏。
      expect(fire, contains('_enqueueShutterCapture()'));
      expect(_codeOnly(fire), isNot(contains('return true;')));
    });
  });
}
