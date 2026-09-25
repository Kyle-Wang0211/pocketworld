// 台架回放编排的纯 Dart 单测(不需要原生库)。
// 原生那一半:Swift 单测 tool/bench/replay_swift_tests/,Mac 等价核对 tool/bench/replay_mac/。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';
import 'package:pocketworld_flutter/vio/replay/bench_replay_controller.dart';

BenchReplayRecording _rec({
  String dir = 'run-6e2d4b99-896b-4372-ae47-ac0b4679cf18',
  String id = '6e2d4b99-896b-4372-ae47-ac0b4679cf18',
  int w = 1920,
  int h = 1440,
  String? model = 'iPhone15,2',
  bool ok = true,
}) =>
    BenchReplayRecording(
      dirName: dir,
      path: '/x/$dir',
      inspect: <String, Object?>{
        'ok': ok,
        if (!ok) 'error': 'boom',
        'recording_id': id,
        'camera': <String, Object?>{'width': w, 'height': h},
        'frame_count': 1702,
        'loss_count': 0,
        'device_model': ?model,
        'manifest_intrinsics': <String, Object?>{
          'fx': 1279.01953125,
          'fy': 1279.01953125,
          'cx': 957.751708984375,
          'cy': 719.0894775390625,
        },
      },
    );

void main() {
  group('BenchReplayArgs.fromLaunchJson', () {
    test('无参数 ⇒ 默认值,不自动开跑', () {
      final BenchReplayArgs a = BenchReplayArgs.fromLaunchJson(<String, Object?>{});
      expect(a.recording, isNull);
      expect(a.autoStart, isFalse);
      expect(a.pace, 'paced');
      expect(a.perFrameIntrinsicsEnabled, isTrue); // 与原生默认 on 一致
      expect(a.problems, isEmpty);
    });

    test('有录制参数 ⇒ 默认自动开跑;开关原样取自原生解析结果', () {
      final BenchReplayArgs a = BenchReplayArgs.fromLaunchJson(<String, Object?>{
        'PWBenchReplayRecording': '6e2d4b99',
        'PWBenchReplayPace': 'max',
        'PWBenchReplayLimitFrames': '300',
        'PWBenchReplayAllowLossy': 'on',
        'PWBenchReplayCameraTimeOffsetMs': '0',
        'PWPerFrameIntrinsics': <String, Object?>{'enabled': false, 'source': 1, 'raw': 'off'},
      });
      expect(a.recording, '6e2d4b99');
      expect(a.autoStart, isTrue);
      expect(a.pace, 'max');
      expect(a.limitFrames, 300);
      expect(a.allowLossy, isTrue);
      expect(a.cameraTimeOffsetMsRaw, '0');
      expect(a.perFrameIntrinsicsEnabled, isFalse);
      expect(a.perFrameArmLabel, 'pfk-off');
    });

    test('解析不了的值不静默吞:进 problems 并落回默认', () {
      final BenchReplayArgs a = BenchReplayArgs.fromLaunchJson(<String, Object?>{
        'PWBenchReplayRecording': 'x',
        'PWBenchReplayAutoStart': 'maybe',
        'PWBenchReplayPace': 'fast',
        'PWBenchReplayLimitFrames': '-3',
      });
      expect(a.autoStart, isTrue);
      expect(a.pace, 'paced');
      expect(a.limitFrames, 0);
      expect(a.problems, hasLength(3));
    });

    test('布尔表与原生 PwPerFrameIntrinsicsSwitch 同一张', () {
      for (final String s in <String>['on', '1', 'true', 'YES']) {
        expect(BenchReplayArgs.parseBool(s), isTrue, reason: s);
      }
      for (final String s in <String>['off', '0', 'false', 'No']) {
        expect(BenchReplayArgs.parseBool(s), isFalse, reason: s);
      }
      expect(BenchReplayArgs.parseBool('2'), isNull);
    });
  });

  group('resolve', () {
    final List<BenchReplayRecording> all = <BenchReplayRecording>[
      _rec(),
      _rec(dir: 'run-5966aec0-cbf1-4abc-af0e-c1fc559da44c', id: '5966aec0-cbf1-4abc-af0e-c1fc559da44c'),
      _rec(dir: 'run-59aa0000-0000-0000-0000-000000000000', id: '59aa0000-0000-0000-0000-000000000000'),
    ];
    test('目录名全等', () {
      expect(BenchReplayController.resolve(all, 'run-5966aec0-cbf1-4abc-af0e-c1fc559da44c')?.shortId,
          '5966aec0');
    });
    test('录制 id 前缀(带不带 run- 都行)', () {
      expect(BenchReplayController.resolve(all, '6e2d4b99')?.shortId, '6e2d4b99');
      expect(BenchReplayController.resolve(all, 'run-6e2d')?.shortId, '6e2d4b99');
    });
    test('多个命中 / 没命中 ⇒ null 并说明,不猜', () {
      final List<String> why = <String>[];
      expect(BenchReplayController.resolve(all, '59', why: why), isNull);
      expect(BenchReplayController.resolve(all, 'ffff', why: why), isNull);
      expect(why, hasLength(2));
    });
  });

  test('输出目录名:录制前 8 位 + 臂 + 节拍 + 时间 + 标签(非法字符换 -)', () {
    const BenchReplayArgs a = BenchReplayArgs(pace: 'max', tag: 'ab/c d', perFrameIntrinsicsEnabled: false);
    expect(BenchReplayController.runDirName(_rec(), a, DateTime(2026, 9, 23, 7, 5, 9)),
        'replay_6e2d4b99_pfk-off_max_20260923_070509_ab-c-d');
  });

  group('planReplay', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bench_replay_plan'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('yaml = 产品生成器 + 录制 K/尺寸 + 查表外参;c 查表', () {
      final BenchReplayPlan p = BenchReplayController.planReplay(
        runsRoot: tmp,
        recording: _rec(),
        args: const BenchReplayArgs(),
        now: DateTime(2026, 9, 23),
      );
      final String dev = File(p.deviceConfigPath).readAsStringSync();
      final String slam = File(p.slamConfigPath).readAsStringSync();
      // 与直接用产品生成器写出来的逐字节相同 —— 本页不另写 yaml。
      final XrslamConfigBuilder same = XrslamConfigBuilder(
        intrinsics: const CameraIntrinsics(
          fx: 1279.01953125,
          fy: 1279.01953125,
          cx: 957.751708984375,
          cy: 719.0894775390625,
          resolutionWidth: 1920,
          resolutionHeight: 1440,
          provenance: FieldProvenance.deviceApi,
        ),
        extrinsic: CameraImuExtrinsic.forIosMachine('iPhone15,2'),
      );
      expect(dev, same.buildDeviceConfigYaml());
      expect(slam, same.buildSlamConfigYaml());
      expect(dev, contains('resolution: [ 1920, 1440 ]'));
      expect(dev, contains('intrinsics: [ 1279.01953125, 1279.01953125, 957.751708984375, 719.0894775390625 ]'));
      // 上游 iPhone 标定表里 iPhone15,2 那一行(与 Mac 宿主回放 yaml 的 q_bc/p_bc 相同)。
      expect(dev, contains('q_bc: [ -0.7071068, 0.7071068, 0.0, 0.0 ]'));
      expect(dev, contains('p_bc: [ 0.03290364, -0.00696553, -0.00286231 ]'));
      expect(p.cameraTimeOffset.seconds, 0.003);
      expect(p.cameraTimeOffset.provenance, FieldProvenance.measured);
      final Map<String, Object?> cfg = p.nativeConfig();
      expect(cfg['camera_time_offset_s'], 0.003);
      expect(cfg['pace'], 'paced');
    });

    test('[2026-09-25] 曝光中点默认 on ⇒ c 查表;off ⇒ 官方 0;-PWBenchReplayCameraTimeOffsetMs 两种都能覆盖', () {
      // 旧原生没有这个键 ⇒ 按台架默认 on。
      expect(BenchReplayArgs.fromLaunchJson(<String, Object?>{}).exposureMidEnabled, isTrue);
      final BenchReplayArgs on = BenchReplayArgs.fromLaunchJson(<String, Object?>{
        'PWXrslamExposureMid': <String, Object?>{'enabled': true, 'source': 'default', 'raw': ''},
      });
      expect(on.exposureMidEnabled, isTrue);
      expect(on.exposureMidSource, 'default');
      final BenchReplayPlan pOn = BenchReplayController.planReplay(
        runsRoot: tmp, recording: _rec(), args: on, now: DateTime(2026, 9, 25, 1));
      expect(pOn.cameraTimeOffset.seconds, 0.003);
      expect(pOn.cameraTimeOffset.provenance, FieldProvenance.measured);
      expect(pOn.nativeConfig()['camera_time_offset_s'], 0.003);

      final BenchReplayArgs off = BenchReplayArgs.fromLaunchJson(<String, Object?>{
        'PWXrslamExposureMid': <String, Object?>{
          'enabled': false, 'source': 'launch_argument', 'raw': 'off'},
      });
      expect(off.exposureMidEnabled, isFalse);
      final BenchReplayPlan pOff = BenchReplayController.planReplay(
        runsRoot: tmp, recording: _rec(), args: off, now: DateTime(2026, 9, 25, 2));
      expect(pOff.cameraTimeOffset.seconds, 0.0);
      expect(pOff.cameraTimeOffset.provenance, FieldProvenance.sharedDefault);

      final BenchReplayArgs offOvr = BenchReplayArgs.fromLaunchJson(<String, Object?>{
        'PWXrslamExposureMid': <String, Object?>{
          'enabled': false, 'source': 'launch_argument', 'raw': 'off'},
        'PWBenchReplayCameraTimeOffsetMs': '2.65',
      });
      final BenchReplayPlan pOffOvr = BenchReplayController.planReplay(
        runsRoot: tmp, recording: _rec(), args: offOvr, now: DateTime(2026, 9, 25, 3));
      expect(pOffOvr.cameraTimeOffset.seconds, closeTo(0.00265, 1e-12));
      expect(pOffOvr.cameraTimeOffset.provenance, FieldProvenance.devOverride);
      // copyWith 不丢开关。
      expect(off.copyWith(pace: 'max').exposureMidEnabled, isFalse);
    });

    test('c 覆盖 "0" ⇒ devOverride 0;未知机型 ⇒ 外参中位数回退 + c=0 placeholder', () {
      final BenchReplayPlan a = BenchReplayController.planReplay(
        runsRoot: tmp,
        recording: _rec(),
        args: const BenchReplayArgs(cameraTimeOffsetMsRaw: '0'),
        now: DateTime(2026, 9, 23, 1),
      );
      expect(a.cameraTimeOffset.seconds, 0.0);
      expect(a.cameraTimeOffset.provenance, FieldProvenance.devOverride);
      final BenchReplayPlan b = BenchReplayController.planReplay(
        runsRoot: tmp,
        recording: _rec(model: null, dir: 'run-u', id: 'uuuuuuuu'),
        args: const BenchReplayArgs(),
        now: DateTime(2026, 9, 23, 2),
      );
      expect(b.builder.extrinsic.provenance, FieldProvenance.sharedDefault);
      expect(b.cameraTimeOffset.seconds, 0.0);
      expect(b.cameraTimeOffset.provenance, FieldProvenance.placeholder);
    });

    test('录制 inspect 失败 ⇒ 拒绝建 plan', () {
      expect(
        () => BenchReplayController.planReplay(
          runsRoot: tmp,
          recording: _rec(ok: false),
          args: const BenchReplayArgs(),
          now: DateTime(2026),
        ),
        throwsStateError,
      );
    });
  });

  group('buildReceipt', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bench_replay_receipt'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('原生汇总原样进回执;逐帧 K 账按产品 XrslamLiveIntrinsics 解析;640 如实标', () {
      final BenchReplayPlan p = BenchReplayController.planReplay(
        runsRoot: tmp,
        recording: _rec(w: 640, h: 480),
        args: const BenchReplayArgs(perFrameIntrinsicsEnabled: false, tag: 't'),
        now: DateTime(2026, 9, 23),
      );
      final List<double> wire = List<double>.filled(31, 0)
        ..[0] = 0
        ..[1] = 1
        ..[2] = 100
        ..[4] = 100
        ..[9] = 100
        ..[8] = -1;
      final Map<String, Object?> r = BenchReplayController.buildReceipt(
        p,
        <String, Object?>{
          'phase': 'done',
          'summary': <String, Object?>{
            'config': <String, Object?>{'effective_config_sha256': 'abc'},
            'intrinsics_report_rc': 0,
            'intrinsics_report': wire,
            'per_frame_intrinsics_switch': <String, Object?>{
              'enabled': false,
              'source': 1,
              'raw': 'off',
              'parse_failed': false,
            },
            'engine_identity_info_plist': <String, Object?>{'PWXrslamEngineArm': 'gpufenothread_pfk'},
            'invariants': <String, Object?>{'passed': true, 'failed': <String>[]},
            'outputs': <String, Object?>{'poses_camera.tum': <String, Object?>{'rows': 1}},
          },
        },
        startedAt: DateTime.utc(2026, 9, 23),
        endedAt: DateTime.utc(2026, 9, 23, 0, 1),
      );
      expect(r['schema'], kBenchReplayReceiptSchema);
      expect(r['marker'], kBenchReplayMarker);
      expect((r['switches']! as Map<String, Object?>)['arm_label'], 'pfk-off');
      final Map<String, Object?> feed = r['feed_resolution']! as Map<String, Object?>;
      expect(feed['at_or_above_1920x1440'], isFalse);
      expect(feed['downscaled'], isFalse);
      expect((r['config']! as Map<String, Object?>)['effective_config_sha256'], 'abc');
      final Map<String, Object?> ik = r['per_frame_intrinsics']! as Map<String, Object?>;
      expect(ik['arm'], 'per_frame_k_off');
      expect((r['invariants']! as Map<String, Object?>)['passed'], isTrue);
      // 回执必须能 JSON 化。
      expect(() => jsonEncode(r), returnsNormally);
    });

    test('原生没交汇总(失败)⇒ invariants 判不过', () {
      final BenchReplayPlan p = BenchReplayController.planReplay(
        runsRoot: tmp,
        recording: _rec(),
        args: const BenchReplayArgs(),
        now: DateTime(2026, 9, 23),
      );
      final Map<String, Object?> r = BenchReplayController.buildReceipt(
        p,
        <String, Object?>{'phase': 'failed', 'error': 'x'},
        startedAt: DateTime.utc(2026),
        endedAt: DateTime.utc(2026),
      );
      expect((r['invariants']! as Map<String, Object?>)['passed'], isFalse);
      expect(r['error'], 'x');
    });
  });

  group('applyYamlOverrides(抄 BasaltVIOBench BenchmarkRunPreparation.swift:153-211)', () {
    final String slam = const XrslamConfigBuilder(
      intrinsics: CameraIntrinsics(
        fx: 1, fy: 1, cx: 1, cy: 1, resolutionWidth: 4, resolutionHeight: 4,
        provenance: FieldProvenance.placeholder,
      ),
    ).buildSlamConfigYaml();

    test('已有键:整行替换,保留缩进', () {
      final YamlOverrideResult r =
          applyYamlOverrides(slam, <String>['solver.time_limit=0.05', 'sliding_window.size=8']);
      expect(r.errors, isEmpty);
      expect(r.text, contains('\n  time_limit: 0.05\n'));
      expect(r.text, contains('\n  size: 8\n'));
      expect(r.applied.map((Map<String, Object?> m) => m['action']), <String>['replaced', 'replaced']);
    });

    test('时间预算两键:生成器里没有 ⇒ 插到 solver 节下;引擎读到的是这个值', () {
      final YamlOverrideResult r = applyYamlOverrides(
          slam, <String>['solver.frame_time_budget=0.02', 'solver.min_iterations=2']);
      expect(r.errors, isEmpty);
      expect(r.applied.map((Map<String, Object?> m) => m['action']), <String>['inserted', 'inserted']);
      final Map<String, Object?> b = solverBudgetSummary(r.text);
      expect(b['frame_time_budget'], '0.02');
      expect(b['min_iterations'], '2');
      expect(b['budget_on'], isTrue);
      // 插入的行必须落在 solver 节里(不然 yaml 的 solver.frame_time_budget 读不到)。
      final List<String> lines = r.text.split('\n');
      final int head = lines.indexOf('solver:');
      expect(lines[head + 1].trim().startsWith('min_iterations:') ||
          lines[head + 1].trim().startsWith('frame_time_budget:'), isTrue);
    });

    test('不在白名单的节 / 找不到又不可插入的键 / 格式不对 ⇒ 记错误,不崩', () {
      final YamlOverrideResult r = applyYamlOverrides(slam, <String>[
        'imu.cov_g=1',
        'solver.no_such_key=1',
        'garbage',
      ]);
      expect(r.errors, hasLength(3));
      expect(r.text, slam);
    });

    test('没有覆盖 ⇒ 原文不动;预算键缺 ⇒ 关', () {
      final YamlOverrideResult r = applyYamlOverrides(slam, const <String>[]);
      expect(r.text, slam);
      final Map<String, Object?> b = solverBudgetSummary(slam);
      expect(b['budget_on'], isFalse);
      expect(b['frame_time_budget_effective_s'], -1.0);
    });

    test('启动参数里的 PWYamlOverride 列表原样进 args;plan 写进 yaml 与回执', () {
      final BenchReplayArgs a = BenchReplayArgs.fromLaunchJson(<String, Object?>{
        'PWYamlOverride': <Object?>['solver.frame_time_budget=0.02', ''],
      });
      expect(a.yamlOverrides, <String>['solver.frame_time_budget=0.02']);
      final Directory tmp = Directory.systemTemp.createTempSync('bench_replay_ovr');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final BenchReplayPlan p = BenchReplayController.planReplay(
          runsRoot: tmp, recording: _rec(), args: a, now: DateTime(2026));
      expect(File(p.slamConfigPath).readAsStringSync(), contains('  frame_time_budget: 0.02'));
      final Map<String, Object?> r = BenchReplayController.buildReceipt(
          p, <String, Object?>{'phase': 'done'},
          startedAt: DateTime.utc(2026), endedAt: DateTime.utc(2026));
      final Map<String, Object?> cfg = r['config']! as Map<String, Object?>;
      expect((cfg['solver_time_budget']! as Map<String, Object?>)['budget_on'], isTrue);
      expect((cfg['yaml_overrides']! as List<Object?>), hasLength(1));
    });

    test('覆盖被拒 ⇒ plan 拒绝且不留半个输出目录', () {
      final Directory tmp = Directory.systemTemp.createTempSync('bench_replay_ovr2');
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(
          () => BenchReplayController.planReplay(
              runsRoot: tmp,
              recording: _rec(),
              args: const BenchReplayArgs(yamlOverrides: <String>['imu.x=1']),
              now: DateTime(2026)),
          throwsStateError);
      expect(tmp.listSync(), isEmpty);
    });
  });
}
