// vio_thermal_test.dart — ThermalGovernor / 视觉降频调度器 / 降频归因 的单测。
//
// 负向对照:tool 侧另有一份 mutation 脚本(见报告),这里的每组断言都被
// 实际破坏过一次并确认变红。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/thermal/proc_cpu_probe.dart';
import 'package:pocketworld_flutter/vio/thermal/slowdown_attribution.dart';
import 'package:pocketworld_flutter/vio/thermal/thermal_governor.dart';
import 'package:pocketworld_flutter/vio/thermal/thermal_signal.dart';
import 'package:pocketworld_flutter/vio/thermal/thermal_tier.dart';
import 'package:pocketworld_flutter/vio/thermal/vio_frame_scheduler.dart';
import 'package:pocketworld_flutter/vio/thermal/vio_thermal_telemetry.dart';

ThermalSignal iosSignal(
  int tsUs,
  int rawState, {
  CameraStreamState camera = CameraStreamState.running,
  int? interruptionReason,
}) => ThermalSignal(
  platform: VioPlatform.ios,
  timestampUs: tsUs,
  rawStatus: rawState,
  cameraStream: camera,
  interruptionReason: interruptionReason,
);

ThermalSignal androidSignal(
  int tsUs,
  int status, {
  double? headroom,
  int? lastCpuIndex,
  List<int?> maxFreq = const <int?>[],
}) => ThermalSignal(
  platform: VioPlatform.android,
  timestampUs: tsUs,
  rawStatus: status,
  headroom: headroom,
  lastCpuIndex: lastCpuIndex,
  cpuMaxFreqKhz: maxFreq,
  cameraStream: CameraStreamState.running,
);

void main() {
  group('统一档位映射(两端共用一份判定)', () {
    test('iOS NSProcessInfoThermalState 0..3 直映四档', () {
      expect(tierFromIosThermalState(0), ThermalTier.nominal);
      expect(tierFromIosThermalState(1), ThermalTier.fair);
      expect(tierFromIosThermalState(2), ThermalTier.serious);
      expect(tierFromIosThermalState(3), ThermalTier.critical);
      // 越界按 Apple 文档语义回落 nominal
      expect(tierFromIosThermalState(9), ThermalTier.nominal);
    });

    test('Android THERMAL_STATUS 七级折叠成四档,SEVERE 是 serious 起点', () {
      expect(tierFromAndroidThermalStatus(-1), ThermalTier.nominal); // ERROR
      expect(tierFromAndroidThermalStatus(0), ThermalTier.nominal); // NONE
      expect(tierFromAndroidThermalStatus(1), ThermalTier.fair); // LIGHT
      expect(tierFromAndroidThermalStatus(2), ThermalTier.fair); // MODERATE
      expect(tierFromAndroidThermalStatus(3), ThermalTier.serious); // SEVERE
      expect(tierFromAndroidThermalStatus(4), ThermalTier.critical);
      expect(tierFromAndroidThermalStatus(5), ThermalTier.critical);
      expect(tierFromAndroidThermalStatus(6), ThermalTier.critical);
    });

    test('两端在"性能已被显著影响"这一点上必须给出同一档', () {
      // iOS serious 与 Android SEVERE 是同一语义锚点。
      expect(tierFromIosThermalState(2), tierFromAndroidThermalStatus(3));
      // iOS nominal 与 Android NONE。
      expect(tierFromIosThermalState(0), tierFromAndroidThermalStatus(0));
    });

    test('headroom 只能向上抬档,不能把 status 的热档压下去', () {
      expect(
        escalateWithHeadroom(ThermalTier.nominal, 0.5),
        ThermalTier.nominal,
      );
      expect(escalateWithHeadroom(ThermalTier.nominal, 0.90), ThermalTier.fair);
      expect(
        escalateWithHeadroom(ThermalTier.nominal, 0.96),
        ThermalTier.serious,
      );
      // status 已经是 critical,低 headroom 不得把它压回去
      expect(
        escalateWithHeadroom(ThermalTier.critical, 0.1),
        ThermalTier.critical,
      );
      // NaN / null == 读不到,原样返回
      expect(escalateWithHeadroom(ThermalTier.fair, null), ThermalTier.fair);
      expect(
        escalateWithHeadroom(ThermalTier.fair, double.nan),
        ThermalTier.fair,
      );
    });

    test('nominal 档视觉率就是 10Hz(ARCore 的设计点,是上限不是满血档)', () {
      expect(visualHzForTier(ThermalTier.nominal), 10.0);
      expect(visualHzForTier(ThermalTier.critical), lessThan(10.0));
      // 档位越热速率单调不增
      final hz = ThermalTier.values.map(visualHzForTier).toList();
      for (var i = 1; i < hz.length; i++) {
        expect(hz[i], lessThan(hz[i - 1]));
      }
    });
  });

  group('ThermalGovernor 迟滞', () {
    test('升温立即生效', () {
      final g = ThermalGovernor();
      expect(
        g.update(iosSignal(0, 0), initialized: true).tier,
        ThermalTier.nominal,
      );
      final b = g.update(iosSignal(100000, 3), initialized: true);
      expect(b.tier, ThermalTier.critical);
      expect(b.cameraShutdownAdvised, isTrue);
    });

    test('降温必须驻留满 15s 才生效', () {
      final g = ThermalGovernor();
      g.update(iosSignal(0, 3), initialized: true);
      // 立刻报凉:不生效
      expect(
        g.update(iosSignal(1000000, 0), initialized: true).tier,
        ThermalTier.critical,
      );
      // 14s:仍不生效
      expect(
        g.update(iosSignal(14000000, 0), initialized: true).tier,
        ThermalTier.critical,
      );
      // 16s:生效
      expect(
        g.update(iosSignal(16000000, 0), initialized: true).tier,
        ThermalTier.nominal,
      );
    });

    test('降档窗口内抖动取最热候选,且计时不被抖动重置', () {
      final g = ThermalGovernor();
      g.update(iosSignal(0, 3), initialized: true); // critical
      g.update(iosSignal(1000000, 0), initialized: true); // 候选 nominal
      g.update(iosSignal(5000000, 2), initialized: true); // 候选抬到 serious
      g.update(iosSignal(9000000, 0), initialized: true); // 仍是 serious
      // 计时从 1s 起算,16s 时已满 15s ⇒ 落到最热候选 serious,而不是 nominal
      final b = g.update(iosSignal(16000001, 0), initialized: true);
      expect(b.tier, ThermalTier.serious);
    });

    test('相机被系统压力断流是断流不是降帧,且重捕获标志会锁存', () {
      final g = ThermalGovernor();
      final cut = iosSignal(
        0,
        2,
        camera: CameraStreamState.interrupted,
        interruptionReason: kIosInterruptionReasonSystemPressure,
      );
      expect(cut.cameraCutBySystemPressure, isTrue);
      var b = g.update(cut, initialized: true);
      expect(b.visualSuspended, isTrue);
      expect(b.requiresVisualReacquire, isFalse); // 还没超过 2s

      b = g.update(
        iosSignal(
          3000000,
          2,
          camera: CameraStreamState.interrupted,
          interruptionReason: kIosInterruptionReasonSystemPressure,
        ),
        initialized: true,
      );
      expect(b.requiresVisualReacquire, isTrue);

      // 相机恢复出帧 ≠ 重捕获完成:标志必须仍然是 true(锁存)
      b = g.update(iosSignal(3100000, 2), initialized: true);
      expect(b.visualSuspended, isFalse);
      expect(
        b.requiresVisualReacquire,
        isTrue,
        reason: '相机恢复出帧不等于状态重新定住,不能自动清标志',
      );

      g.noteVisualReacquired();
      b = g.update(iosSignal(3200000, 2), initialized: true);
      expect(b.requiresVisualReacquire, isFalse);
    });

    test('Android headroom 越 0.95 立即进 serious,即使 status 还是 NONE', () {
      final g = ThermalGovernor();
      final b = g.update(
        androidSignal(0, 0, headroom: 0.97),
        initialized: true,
      );
      expect(b.tier, ThermalTier.serious);
      expect(b.visualHz, kVisualHzSerious);
    });
  });

  group('视觉降频调度器', () {
    VioBudget budget(double hz, {bool suspended = false}) => VioBudget(
      tier: ThermalTier.nominal,
      visualHz: hz,
      visualSuspended: suspended,
      cameraShutdownAdvised: false,
      requiresVisualReacquire: false,
      statusReadable: true,
    );

    test('30fps 输入 / 10Hz 目标 ⇒ 精确 3:1 抽帧', () {
      final s = VioFrameScheduler();
      final b = budget(10.0);
      var visual = 0;
      for (var i = 0; i < 90; i++) {
        final ts = (i * 1000000 / 30).round();
        final plan = s.onImageFrame(frameId: i, timestampUs: ts, budget: b);
        if (plan.isVisualUpdate) {
          visual++;
          s.onVisualUpdateComplete();
        }
      }
      // 3 秒 30fps = 90 帧,10Hz ⇒ 30 次视觉更新(首帧即更新,允许 ±1)
      expect(visual, inInclusiveRange(29, 31));
      expect(s.framesSeen, 90);
    });

    test('铁律:每一帧都被归入两类之一,一帧不丢', () {
      final s = VioFrameScheduler();
      final hzSeq = <double>[10.0, 7.5, 5.0, 3.0];
      for (var i = 0; i < 400; i++) {
        final b = budget(hzSeq[(i ~/ 50) % hzSeq.length]);
        final plan = s.onImageFrame(
          frameId: i,
          timestampUs: (i * 33333),
          budget: b,
        );
        expect(plan.preserved, isTrue, reason: '帧永远被保全');
        if (plan.isVisualUpdate && i % 3 != 0) {
          s.onVisualUpdateComplete();
        }
      }
      expect(s.accountingBalanced, isTrue);
      expect(s.framesSeen, s.visualUpdates + s.imuPropagateOnly);
      expect(s.framesSeen, 400);
    });

    test('求解器忙 ⇒ 推迟(deadline 不推进),不是跳过一个周期', () {
      final s = VioFrameScheduler();
      final b = budget(10.0);
      // frame0 进 VIO,不 complete ⇒ 求解器一直忙
      expect(
        s.onImageFrame(frameId: 0, timestampUs: 0, budget: b).isVisualUpdate,
        isTrue,
      );
      // 100ms 后 deadline 到,但忙 ⇒ solverBusy 跳过
      final p1 = s.onImageFrame(frameId: 1, timestampUs: 100000, budget: b);
      expect(p1.isVisualUpdate, isFalse);
      expect(p1.reason, SkipReason.solverBusy);
      final p2 = s.onImageFrame(frameId: 2, timestampUs: 133333, budget: b);
      expect(p2.reason, SkipReason.solverBusy);
      // 求解器空出来 ⇒ 下一帧立刻进,不用等到下一个 100ms 边界
      s.onVisualUpdateComplete();
      final p3 = s.onImageFrame(frameId: 3, timestampUs: 140000, budget: b);
      expect(p3.isVisualUpdate, isTrue, reason: '推迟的更新应尽快补上');
      expect(s.solverBusyDeferrals, 2);
    });

    test('长时间停顿后不补课:恢复时只出一次视觉更新,不连开', () {
      final s = VioFrameScheduler();
      final b = budget(10.0);
      s.onImageFrame(frameId: 0, timestampUs: 0, budget: b);
      s.onVisualUpdateComplete();
      // 2 秒断档(相当于错过 20 个周期)
      final p = s.onImageFrame(frameId: 1, timestampUs: 2000000, budget: b);
      expect(p.isVisualUpdate, isTrue);
      s.onVisualUpdateComplete();
      // 紧接着的一帧(33ms 后)绝不能因为"欠了 19 次"而再次触发
      final q = s.onImageFrame(frameId: 2, timestampUs: 2033333, budget: b);
      expect(q.isVisualUpdate, isFalse, reason: '补课=在最热的时候突然加倍工作量,必须禁止');
      expect(q.reason, SkipReason.scheduledCadence);
    });

    test('视觉挂起时帧仍然保全,只是不进 VIO', () {
      final s = VioFrameScheduler();
      final b = budget(10.0, suspended: true);
      for (var i = 0; i < 10; i++) {
        final plan = s.onImageFrame(
          frameId: i,
          timestampUs: i * 33333,
          budget: b,
        );
        expect(plan.isVisualUpdate, isFalse);
        expect(plan.reason, SkipReason.visualSuspended);
        expect(plan.preserved, isTrue);
      }
      expect(s.accountingBalanced, isTrue);
      expect(s.imuPropagateOnly, 10);
    });

    test('IMU 传播永远全速,不受热档位影响', () {
      final s = VioFrameScheduler();
      expect(s.shouldPropagateImu(), isTrue);
    });

    test('视觉断档超阈标记 stale', () {
      final s = VioFrameScheduler();
      final b = budget(10.0);
      s.onImageFrame(frameId: 0, timestampUs: 0, budget: b);
      s.onVisualUpdateComplete();
      final p = s.onImageFrame(frameId: 1, timestampUs: 700000, budget: b);
      expect(p.visualStale, isTrue);
    });
  });

  group('降频归因', () {
    test('小核簇识别(big.LITTLE 4+3+1)', () {
      // cpu0..3 = 1.8GHz 小核,cpu4..6 = 2.4GHz,cpu7 = 2.84GHz
      final cluster = identifyLittleCluster(<int?>[
        1800000,
        1800000,
        1800000,
        1800000,
        2400000,
        2400000,
        2400000,
        2840000,
      ]);
      expect(cluster, <int>{0, 1, 2, 3});
    });

    test('同构 SoC / 全读不到 ⇒ 空集(空集不等于"没被降级")', () {
      expect(identifyLittleCluster(<int?>[2000000, 2000000]), isEmpty);
      expect(identifyLittleCluster(<int?>[null, null]), isEmpty);
      expect(identifyLittleCluster(const <int?>[]), isEmpty);
    });

    SlowdownAttributor primed() {
      final a = SlowdownAttributor(baselineSamples: 10);
      for (var i = 0; i < 10; i++) {
        a.ingest(
          FrameCost(
            frameId: i,
            wallMs: 20.0,
            cpuMs: 20.0,
            workUnits: 200,
            tier: ThermalTier.nominal,
          ),
        );
      }
      return a;
    }

    test('基线未建立前一律 unknown,不假装健康', () {
      final a = SlowdownAttributor(baselineSamples: 10);
      final v = a.ingest(
        FrameCost(
          frameId: 0,
          wallMs: 100,
          cpuMs: 10,
          workUnits: 200,
          tier: ThermalTier.nominal,
        ),
      );
      expect(v.cause, SlowdownCause.unknown);
      expect(v.baselineEstablished, isFalse);
    });

    test('拿不到 CPU ⇒ cpuStarvation,归因到平台', () {
      final a = primed();
      final v = a.ingest(
        FrameCost(
          frameId: 99,
          wallMs: 100.0,
          cpuMs: 20.0, // duty 0.2
          workUnits: 200,
          tier: ThermalTier.serious,
        ),
      );
      expect(v.cause, SlowdownCause.cpuStarvation);
      expect(v.platformAttributed, isTrue);
      expect(v.onlyWorkload, isFalse);
    });

    test('工作量不变但单位工作更慢 ⇒ clockThrottle,不是算法问题', () {
      final a = primed();
      final v = a.ingest(
        FrameCost(
          frameId: 99,
          wallMs: 40.0,
          cpuMs: 40.0, // duty 1.0,拿满了 CPU
          workUnits: 200, // 工作量与基线一致
          tier: ThermalTier.serious,
        ),
      );
      // 每单位 200us→400us,ratio 2.0
      expect(v.cause, SlowdownCause.clockThrottle);
      expect(v.platformAttributed, isTrue);
      expect(v.nsPerUnitRatio, closeTo(2.0, 1e-9));
      expect(v.workRatio, closeTo(1.0, 1e-9));
    });

    test('单位工作耗时不变但工作量翻倍 ⇒ workloadGrowth,才是算法在多干活', () {
      final a = primed();
      final v = a.ingest(
        FrameCost(
          frameId: 99,
          wallMs: 60.0,
          cpuMs: 60.0,
          workUnits: 600, // 3 倍工作量,单位耗时仍是 100us...
          tier: ThermalTier.nominal,
        ),
      );
      expect(v.workRatio, closeTo(3.0, 1e-9));
      expect(v.cause, SlowdownCause.workloadGrowth);
      expect(v.onlyWorkload, isTrue);
      expect(v.platformAttributed, isFalse, reason: '只有这一档才值得去动 RD-VIO 参数');
    });

    test('被钉在小核上会被独立标出(ComputerBase 那个现象)', () {
      final a = primed()
        ..setLittleCluster(
          identifyLittleCluster(<int?>[
            1800000,
            1800000,
            1800000,
            1800000,
            2840000,
          ]),
        );
      final v = a.ingest(
        FrameCost(
          frameId: 99,
          wallMs: 40.0,
          cpuMs: 40.0,
          workUnits: 200,
          tier: ThermalTier.nominal,
          lastCpuIndex: 2,
          onlineCpuCount: 4,
          presentCpuCount: 5,
        ),
      );
      expect(v.coreDemotionSuspected, isTrue);
      expect(v.coresOfflined, isTrue);
      // 热档位是 nominal 却在小核上变慢 ⇒ 这正是"没进白名单"的指纹
      expect(v.cause, SlowdownCause.clockThrottle);
    });

    test('平台正常时不冤枉任何一方', () {
      final a = primed();
      final v = a.ingest(
        FrameCost(
          frameId: 99,
          wallMs: 21.0,
          cpuMs: 20.5,
          workUnits: 205,
          tier: ThermalTier.nominal,
        ),
      );
      expect(v.cause, SlowdownCause.none);
    });
  });

  group('平台 map 解码 + 遥测', () {
    test('两端 map 走同一个解码器', () {
      final ios = decodeThermalSignal(<Object?, Object?>{
        'platform': 'ios',
        'tsUs': 12345,
        'rawStatus': 2,
        'cameraStream': 'interrupted',
        'interruptionReason': 5,
        'systemPressureLevel': 'AVCaptureSystemPressureLevelSerious',
        'systemPressureFactors': 1,
        'lowPowerMode': true,
        'activeProcessorCount': 6,
      });
      expect(ios.platform, VioPlatform.ios);
      expect(ios.tier, ThermalTier.serious);
      expect(ios.cameraCutBySystemPressure, isTrue);
      expect(ios.headroom, isNull);

      final android = decodeThermalSignal(<Object?, Object?>{
        'platform': 'android',
        'tsUs': 999,
        'rawStatus': 3,
        'headroom': 0.9,
        'lastCpuIndex': 1,
        'cpuMaxFreqKhz': <Object?>[1800000, 2840000],
        'cameraStream': 'running',
      });
      expect(android.platform, VioPlatform.android);
      expect(android.tier, ThermalTier.serious);
      expect(android.lastCpuIndex, 1);
    });

    test('NaN headroom 与缺字段都解成 null,不解成 0', () {
      final s = decodeThermalSignal(<Object?, Object?>{
        'platform': 'android',
        'rawStatus': 0,
        'headroom': double.nan,
      });
      expect(s.headroom, isNull);
      expect(s.lowPowerMode, isNull);
      expect(s.onlineCpuCount, isNull);
      expect(s.tier, ThermalTier.nominal);
    });

    test('读不到热等级时 statusReadable=false,不能当成健康', () {
      final s = decodeThermalSignal(<Object?, Object?>{'platform': 'ios'});
      expect(s.statusReadable, isFalse);
    });

    test('垃圾输入不抛异常(遥测通道不能把采集打挂)', () {
      expect(
        () => decodeThermalSignal(<Object?, Object?>{
          'platform': 42,
          'tsUs': 'nope',
          'rawStatus': <int>[1],
          'cpuMaxFreqKhz': 'not-a-list',
        }),
        returnsNormally,
      );
    });

    test('实测速率明显低于目标 ⇒ shortfall', () {
      expect(
        observedVisualHzOver(visualUpdates: 100, windowUs: 10000000),
        10.0,
      );
      expect(visualRateShortfall(targetHz: 10.0, observedHz: 9.0), isFalse);
      expect(visualRateShortfall(targetHz: 10.0, observedHz: 6.0), isTrue);
    });

    test('遥测行同时带目标速率与实测速率,两者可分离', () {
      final signal = androidSignal(0, 3, headroom: 0.9, lastCpuIndex: 0);
      final budget = ThermalGovernor().update(signal, initialized: true);
      final sample = VioThermalSample(
        tsUs: 0,
        signal: signal,
        budget: budget,
        verdict: null,
        observedVisualHz: 2.0,
        framesSeen: 300,
        visualUpdates: 20,
        imuOnlyFrames: 280,
        solverBusyDeferrals: 5,
        frameWallMsP50: 30,
        frameWallMsP95: 90,
      );
      final json = sample.toJson();
      expect(json['targetVisualHz'], kVisualHzSerious);
      expect(json['observedVisualHz'], 2.0);
      expect(json['accountingBalanced'], isTrue);
      expect(sample.toJsonLine(), contains('"slowdownCause":"unknown"'));
    });
  });

  procTests();
}

// ---------------------------------------------------------------------------
// /proc 解析(Android 归因探针)—— 这些解析器的陷阱只能靠单测钉死。
// ---------------------------------------------------------------------------

void procTests() {
  group('/proc/<pid>/stat 解析', () {
    String buildStat({
      required String comm,
      required int utime,
      required int stime,
      required int processor,
    }) {
      // field 3..52。tokens[0] = field3。
      final t = List<String>.filled(50, '0');
      t[0] = 'R'; // field3 state
      t[14 - 3] = '$utime';
      t[15 - 3] = '$stime';
      t[39 - 3] = '$processor';
      return '1234 ($comm) ${t.join(' ')}';
    }

    test('普通进程名', () {
      final s = parseProcStat(
        buildStat(comm: 'pocketworld', utime: 700, stime: 300, processor: 5),
      );
      expect(s, isNotNull);
      expect(s!.utimeTicks, 700);
      expect(s.stimeTicks, 300);
      expect(s.processor, 5);
      expect(ticksToMillis(s.totalTicks), 10000.0);
    });

    test('进程名含空格与右括号也必须解对(经典静默错位陷阱)', () {
      final s = parseProcStat(
        buildStat(comm: 'pw vio) worker', utime: 11, stime: 22, processor: 0),
      );
      expect(s, isNotNull, reason: '必须从最后一个 ) 之后切分');
      expect(s!.utimeTicks, 11);
      expect(s.stimeTicks, 22);
      expect(s.processor, 0);
    });

    test('字段不足 / 格式不符返回 null,不猜', () {
      expect(parseProcStat('1234 (x) R 0 0 0'), isNull);
      expect(parseProcStat('garbage'), isNull);
      expect(parseProcStat(''), isNull);
    });
  });

  group('最忙线程选取', () {
    ProcStat st(int total, int cpu) =>
        ProcStat(utimeTicks: total, stimeTicks: 0, processor: cpu);

    test('按区间增量选,而不是按累计值(否则永远选中最老的线程)', () {
      final prev = <int, ProcStat>{101: st(10000, 7), 102: st(5, 1)};
      final cur = <int, ProcStat>{101: st(10001, 7), 102: st(905, 1)};
      final b = busiestThread(cur, previous: prev);
      expect(b, isNotNull);
      expect(b!.key, 102, reason: 'tid102 增量 900 >> tid101 增量 1');
      expect(b.value.processor, 1);
    });

    test('首拍无 previous ⇒ 退化成按累计值取', () {
      final b = busiestThread(<int, ProcStat>{1: st(5, 0), 2: st(50, 3)});
      expect(b!.key, 2);
      expect(b.value.processor, 3);
    });

    test('空输入返回 null', () {
      expect(busiestThread(const <int, ProcStat>{}), isNull);
    });
  });

  group('/sys cpu 区间解析', () {
    test('单值 / 区间 / 多段', () {
      expect(parseCpuRangeList('0'), <int>{0});
      expect(parseCpuRangeList('0-7'), <int>{0, 1, 2, 3, 4, 5, 6, 7});
      expect(parseCpuRangeList('0-3,6-7'), <int>{0, 1, 2, 3, 6, 7});
      expect(parseCpuRangeList(' 0-1 \n'), <int>{0, 1});
    });

    test('非法输入返回空集(空集 = 读不到,不是 0 个核)', () {
      expect(parseCpuRangeList('abc'), isEmpty);
      expect(parseCpuRangeList('5-1'), isEmpty);
      // 判别性用例:倒序区间必须让**整条**解析作废,而不是只跳过这一段。
      // 只写 '5-1' 是测不出来的 —— 循环本来就跑不起来,有没有校验都返回空集。
      expect(parseCpuRangeList('5-1,0-1'), isEmpty);
      expect(parseCpuRangeList(''), isEmpty);
    });

    test('频率读不到 ⇒ null,不是 0', () {
      expect(parseFreqKhz(null), isNull);
      expect(parseFreqKhz(''), isNull);
      expect(parseFreqKhz('   '), isNull);
      expect(parseFreqKhz('2840000\n'), 2840000);
    });
  });
}
