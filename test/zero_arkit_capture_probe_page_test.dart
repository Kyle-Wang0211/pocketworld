// zero_arkit_capture_probe_page_test.dart —— 台架端到端拍摄探针页的桌面级判据。
//
// 五组:
//   (A) 机型直读:`benchReadHwMachine()` 在 macOS 宿主上回非空(`arm64`/`x86_64`),
//       证明 dart:ffi 那条 `sysctlbyname("hw.machine")` 调用形状是对的
//       (真机上回 `iPhone15,2`,只有真机能证);
//   (B) run 目录名:`zeroarkit_run_<yyyyMMdd_HHmmss>`,拉取脚本按这个前缀列;
//   (C) manifest:键齐、照片 saved 计数对、c 的 provenance 原样进去;
//   (D) 台架平台:符号不在时 `startCamera` 回 −101(**不抛**,与租约闸同码),
//       `cameraOwnedBySelfVio` 恒 false、`stopCamera` 不抛;
//   (E) 源码级:本页**没有** `ARSession` / `ZeroArkitCameraGate.` 调用 /
//       `PwZeroArkitGate` / `NativeZeroArkitPlatform(` 构造;`PwCameraSlot.start(`
//       与 `PwCameraSlot.stop(` 各恰在 `BenchZeroArkitPlatform` 里出现。
//
// 🔴 不 pump 页面:它内部是 `ZeroArkitCameraPreview`(ViewerWidget),单测
//    环境没有 Filament;`getApplicationDocumentsDirectory` 也没有平台通道。
//    页面「跑起来」只有真机能证。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/capture/camera_time_offset.dart';
import 'package:pocketworld_flutter/vio/capture/focus_self_heal.dart';
import 'package:pocketworld_flutter/vio/capture/zero_arkit_capture_runtime.dart';
import 'package:pocketworld_flutter/vio/ffi/pw_focus_ffi.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/zero_arkit_camera_gate.dart';
import 'package:pocketworld_flutter/vio/render/zero_arkit_capture_probe_page.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('(A) hw.machine 直读', () {
    test('macOS 宿主上 sysctlbyname(hw.machine) 回非空', () {
      final String? m = benchReadHwMachine();
      if (Platform.isMacOS) {
        expect(m, isNotNull);
        expect(m!.trim(), isNotEmpty);
        expect(m, isNot(contains('\u0000')));
      } else {
        // 非 Darwin 宿主没有 sysctlbyname ⇒ 如实 null,不抛。
        expect(m, isNull);
      }
    });
  });

  group('(B) run 目录名', () {
    test('zeroarkit_run_<yyyyMMdd_HHmmss>,个位补零', () {
      expect(
        zeroArkitRunDirName(DateTime(2026, 9, 22, 18, 5, 7)),
        'zeroarkit_run_20260922_180507',
      );
      expect(
        zeroArkitRunDirName(DateTime(2026, 12, 1, 0, 0, 0)),
        'zeroarkit_run_20261201_000000',
      );
      expect(
        RegExp(r'^zeroarkit_run_\d{8}_\d{6}$')
            .hasMatch(zeroArkitRunDirName(DateTime.now())),
        isTrue,
      );
    });
  });

  group('(C) manifest', () {
    test('键齐、计数对、c provenance 原样', () {
      const CameraTimeOffset c = CameraTimeOffset(
        seconds: 0.003,
        provenance: FieldProvenance.measured,
        machine: 'iPhone15,2',
        note: '单测',
      );
      const ZeroArkitStartResult start = ZeroArkitStartResult(
        cameraRc: 0,
        sessionStarted: true,
        intrinsics: CameraIntrinsics(
          fx: 453.1,
          fy: 453.1,
          cx: 320,
          cy: 240,
          resolutionWidth: 640,
          resolutionHeight: 480,
          provenance: FieldProvenance.deviceApi,
        ),
        cameraTimeOffset: c,
        error: null,
      );
      final List<ZeroArkitProbeShot> shots = <ZeroArkitProbeShot>[
        const ZeroArkitProbeShot(
          index: 1,
          jpegPath: '/x/photo_1.jpg',
          metadataPath: '/x/photo_1.json',
          targetTimestamp: 12.5,
          status: 'saved',
          message: null,
          elapsedMs: 210,
          trackingStateAtTrigger: 'normal',
          isTrackingAtTrigger: true,
        ),
        const ZeroArkitProbeShot(
          index: 2,
          jpegPath: '/x/photo_2.jpg',
          metadataPath: '/x/photo_2.json',
          targetTimestamp: null,
          status: 'unsupported',
          message: '接口不可用',
          elapsedMs: 3001,
          trackingStateAtTrigger: 'limited_initializing',
          isTrackingAtTrigger: false,
        ),
      ];
      final Map<String, Object?> m = buildZeroArkitProbeManifest(
        runDir: '/x',
        hwMachine: 'iPhone15,2',
        primedMachine: null,
        runtimeStart: start,
        cameraRc: 0,
        cameraOwnedBySelfVio: true,
        cameraSymbolFailure: null,
        intrinsicsWaitMs: 312,
        capturedIntrinsics: const PinholeIntrinsics(
          fx: 1359.37,
          fy: 1359.37,
          cx: 960,
          cy: 720,
          imageWidth: 1920,
          imageHeight: 1440,
        ),
        shots: shots,
        trackingStateCounts: <String, int>{'normal': 100, 'limited_initializing': 20},
        trackingFrames: 100,
        notTrackingFrames: 20,
        confidenceTierCounts: <String, int>{'poseOnly': 100, 'none': 20},
        poseFrames: 120,
        pageDuration: const Duration(seconds: 42),
        startedAtUtc: DateTime.utc(2026, 9, 22, 10),
        finishedAtUtc: DateTime.utc(2026, 9, 22, 10, 0, 42),
        engineUnavailableReason: null,
        focusAvailable: false,
        focusStateAtFinish: null,
        focusNativeReportJson: null,
        focusSeries: const <PwFocusSample>[],
        focusSelfHeal: null,
      );

      for (final String key in <String>[
        'schema',
        'bundle',
        'run_dir',
        'started_at_utc',
        'finished_at_utc',
        'page_duration_s',
        'machine',
        'camera_time_offset',
        'camera',
        'session',
        'engine_unavailable_reason',
        'pose_frames',
        'tracking_frames',
        'not_tracking_frames',
        'tracking_state_counts',
        'confidence_tier_counts',
        'photos_requested',
        'photos_saved',
        'photos',
        'focus',
        'focus_acceptance_tables',
      ]) {
        expect(m.containsKey(key), isTrue, reason: '缺键 $key');
      }
      expect(m['schema'], kZeroArkitProbeManifestSchema);
      expect(m['bundle'], 'com.kyle.arloopbench');
      expect(m['photos_requested'], 2);
      expect(m['photos_saved'], 1);
      expect(m['pose_frames'], 120);
      expect(m['page_duration_s'], 42.0);

      final Map<String, Object?> cm = m['camera_time_offset']! as Map<String, Object?>;
      expect(cm['milliseconds'], closeTo(3.0, 1e-9));
      expect(cm['provenance'], FieldProvenance.measured.label);
      expect(cm['machine'], 'iPhone15,2');
      expect(cm['is_measured_for_this_device'], isTrue);

      final Map<String, Object?> mach = m['machine']! as Map<String, Object?>;
      expect(mach['hw_machine'], 'iPhone15,2');
      expect(mach['device_machine_prime'], isNull);

      final Map<String, Object?> sess = m['session']! as Map<String, Object?>;
      expect(sess['ok'], isTrue);
      expect(sess['blocked_by_arkit'], isFalse);
      final Map<String, Object?> fk = sess['feed_intrinsics']! as Map<String, Object?>;
      expect(fk['w'], 640);
      expect(fk['provenance'], FieldProvenance.deviceApi.label);

      final Map<String, Object?> cam = m['camera']! as Map<String, Object?>;
      expect(cam['intrinsics_wait_ms'], 312);
      expect((cam['captured_intrinsics']! as Map<String, Object?>)['image_w'], 1920);

      final List<Object?> photos = m['photos']! as List<Object?>;
      expect(photos.length, 2);
      expect((photos[0]! as Map<String, Object?>)['status'], 'saved');
      expect((photos[1]! as Map<String, Object?>)['message'], '接口不可用');
      expect((photos[1]! as Map<String, Object?>)['is_tracking_at_trigger'], isFalse);
    });

    test('runtimeStart 为 null(相机没起成)时 c / session 如实 null', () {
      final Map<String, Object?> m = buildZeroArkitProbeManifest(
        runDir: '/x',
        hwMachine: null,
        primedMachine: null,
        runtimeStart: null,
        cameraRc: -1,
        cameraOwnedBySelfVio: false,
        cameraSymbolFailure: null,
        intrinsicsWaitMs: null,
        capturedIntrinsics: null,
        shots: const <ZeroArkitProbeShot>[],
        trackingStateCounts: const <String, int>{},
        trackingFrames: 0,
        notTrackingFrames: 0,
        confidenceTierCounts: const <String, int>{},
        poseFrames: 0,
        pageDuration: Duration.zero,
        startedAtUtc: DateTime.utc(2026),
        finishedAtUtc: DateTime.utc(2026),
        engineUnavailableReason: 'x',
        focusAvailable: false,
        focusStateAtFinish: null,
        focusNativeReportJson: null,
        focusSeries: const <PwFocusSample>[],
        focusSelfHeal: null,
      );
      expect(m['camera_time_offset'], isNull);
      expect(m['session'], isNull);
      expect(m['photos_saved'], 0);
      expect((m['camera']! as Map<String, Object?>)['start_rc'], -1);
      expect(m['engine_unavailable_reason'], 'x');
    });
  });

  group('(D) 台架平台在没有原生符号的宿主上', () {
    test('startCamera 回 −101 不抛;owned 恒 false;stopCamera 不抛', () {
      final BenchZeroArkitPlatform p = BenchZeroArkitPlatform();
      final int rc = p.startCamera(
        width: 1920,
        height: 1440,
        fps: 30,
        lensPosition: 0.835,
      );
      expect(rc, kZeroArkitCameraSymbolMissing);
      expect(rc, isNot(kZeroArkitCameraBusy));
      expect(p.lastCameraRc, kZeroArkitCameraSymbolMissing);
      expect(p.symbolFailure, isNotNull);
      expect(p.cameraOwnedBySelfVio(), isFalse);
      expect(p.stopCamera, returnsNormally);
      expect(p.cameraOwnedBySelfVio(), isFalse);
    });

    test('runtime 用它起:相机失败 ⇒ 不建会话、如实 error', () async {
      final BenchZeroArkitPlatform p = BenchZeroArkitPlatform();
      final ZeroArkitCaptureRuntime rt = ZeroArkitCaptureRuntime(
        platform: p,
        machineIdentifier: 'iPhone15,2',
      );
      // 相机没起来这条路上没有 await(不等内参),`start()` 返回时就已完成。
      final ZeroArkitStartResult r = await rt.start();
      expect(r.ok, isFalse);
      expect(r.sessionStarted, isFalse);
      expect(r.cameraRc, kZeroArkitCameraSymbolMissing);
      expect(r.blockedByArkit, isFalse);
      // 机型显式传入 ⇒ c 仍按表解析,与页面上「c 预解析」那行同源。
      expect(r.cameraTimeOffset.provenance, FieldProvenance.measured);
      expect(r.cameraTimeOffset.milliseconds, closeTo(3.0, 1e-9));
    });
  });

  group('(E) 源码级', () {
    final String raw = File(
      'lib/vio/render/zero_arkit_capture_probe_page.dart',
    ).readAsStringSync();
    // 只看代码,不看注释:文件头**要**解释为什么没有 ARSession,
    // 那句话本身不是调用。
    final String src = raw
        .split('\n')
        .where((String l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('没有 ARSession / 租约闸调用 / Native 平台构造', () {
      expect(src, isNot(contains('ARSession')));
      expect(src, isNot(contains('ZeroArkitCameraGate.')));
      expect(src, isNot(contains('PwZeroArkitGate')));
      expect(src, isNot(contains('NativeZeroArkitPlatform(')));
      expect(src, isNot(contains('import \'package:arkit')));
    });

    test('相机起停直接打 PwCameraSlot,各恰一次', () {
      expect('PwCameraSlot.start('.allMatches(src).length, 1);
      expect('PwCameraSlot.stop('.allMatches(src).length, 1);
    });

    test('日志前缀与 --dart-define 键名钉住', () {
      expect(kZeroArkitProbeLogTag, '[zero-arkit-probe]');
      expect(src, contains("'[zero-arkit-probe]'"));
    });
  });

  // ══ (F) 对焦三臂 ═══════════════════════════════════════════════════════
  // 三组:臂的解析、时间序列的降采样、manifest 里那两张表是**分开**的。
  group('(F) 对焦三臂', () {
    test('臂解析:a/b/c 与别名;认不出来回 null(不猜)', () {
      expect(PwFocusArm.parse('a'), PwFocusArm.a);
      expect(PwFocusArm.parse('B'), PwFocusArm.b);
      expect(PwFocusArm.parse(' c '), PwFocusArm.c);
      expect(PwFocusArm.parse('apple'), PwFocusArm.b);
      expect(PwFocusArm.parse('pw_af'), PwFocusArm.c);
      expect(PwFocusArm.parse('d'), isNull);
      expect(PwFocusArm.parse(''), isNull);
      // rawValue 是冻结的(Swift 侧按同样的数字)。
      expect(PwFocusArm.a.rawValue, 0);
      expect(PwFocusArm.b.rawValue, 1);
      expect(PwFocusArm.c.rawValue, 2);
    });

    test('🔴 换默认臂:Swift 的默认初值是 .b,A 臂降为阴性对照', () {
      // 这条测试守的是**用户拍板的那件事**(2026-09-23「换掉锁定,照生产那套
      // 来」)。Dart 侧查不到原生的默认值,所以直接读 Swift 源码那一行 ——
      // 它要是被谁改回 `.a`,这条当场红。
      final String swift =
          File('${Directory.current.path}/ios/Runner/PwFocusArms.swift')
              .readAsStringSync();
      expect(swift, contains('private(set) var arm: PwFocusArm = .b'));
      expect(swift, isNot(contains('private(set) var arm: PwFocusArm = .a')));
      // 生产那两句必须在(逐句对照 OfficialAetherARKitPlugin.swift:2653-2661)。
      expect(swift, contains('device.isSmoothAutoFocusEnabled = true'));
      expect(swift, contains('device.focusMode = .continuousAutoFocus'));
      // 🔴 生产 :2189-2191 的警告原文必须留在代码里。
      expect(swift,
          contains('do not later flip'));
      expect(swift, contains('stuck at a near lens distance'));
      // A 臂那三行锁焦**没被删**(它是阴性对照)。
      final String slot =
          File('${Directory.current.path}/ios/Runner/PwCameraSlot.swift')
              .readAsStringSync();
      expect(slot, contains('device.setFocusModeLocked('));
      expect(slot, contains('focusArm == .a'));
    });

    test('标签跟着换了:b 不再叫 apple_af,叫 production_af', () {
      expect(PwFocusArm.b.label, 'b_production_af');
      expect(PwFocusArm.a.label, 'a_locked_baseline');
      expect(PwFocusArm.c.label, 'c_pw_af_cdaf');
    });

    test('manifest 里有自愈环那一块,且 nudge 事件按序记全', () {
      final FocusSelfHeal heal =
          FocusSelfHeal(nudger: const NoopFocusNudger('单测'));
      int t = 100000;
      void feed(double fm, int n) {
        for (int i = 0; i < n; i++) {
          heal.onSample(
            nowMs: t,
            focusMeasure: fm,
            isAdjustingFocus: false,
            position: Vector3.zero(),
            orientation: Quaternion.identity(),
          );
          t += 33;
        }
      }

      feed(1000, 10);
      feed(500, 60); // 够 1.8 s ⇒ 一脚
      feed(1400, 70); // 观察窗关闭

      final Map<String, Object?> m = buildZeroArkitProbeManifest(
        runDir: '/x',
        hwMachine: null,
        primedMachine: null,
        runtimeStart: null,
        cameraRc: 0,
        cameraOwnedBySelfVio: true,
        cameraSymbolFailure: null,
        intrinsicsWaitMs: null,
        capturedIntrinsics: null,
        shots: const <ZeroArkitProbeShot>[],
        trackingStateCounts: const <String, int>{},
        trackingFrames: 0,
        notTrackingFrames: 0,
        confidenceTierCounts: const <String, int>{},
        poseFrames: 0,
        pageDuration: Duration.zero,
        startedAtUtc: DateTime.utc(2026),
        finishedAtUtc: DateTime.utc(2026),
        engineUnavailableReason: null,
        focusAvailable: true,
        focusStateAtFinish: null,
        focusNativeReportJson: null,
        focusSeries: const <PwFocusSample>[],
        focusSelfHeal: heal,
      );
      final Map<String, Object?> focus = m['focus']! as Map<String, Object?>;
      final Map<String, Object?> sh =
          focus['self_heal']! as Map<String, Object?>;
      expect(sh['nudges'], 1);
      expect(sh['nudges_dispatched'], 0); // noop 执行器
      final Map<String, Object?> ev0 =
          (sh['events']! as List<Object?>).first! as Map<String, Object?>;
      expect(ev0['index'], 1);
      expect(ev0['measure_at_trigger'], 500);
      expect(ev0['reference_at_trigger'], 1000);
      expect(ev0['measure_peak_after'], 1400);
      expect(ev0['measure_after_ms'], greaterThanOrEqualTo(2000));
      // 换默认臂那句话也要出现在 manifest 里(回放时不用去翻 git log)。
      expect(focus['arm_launch_argument'], contains('默认 b'));
      expect(focus['default_arm_change_note'], contains('2653-2661'));
    });

    test('prepare 状态:只有 running 不是终态', () {
      for (final PwFocusPrepareState s in PwFocusPrepareState.values) {
        expect(s.isTerminal, s != PwFocusPrepareState.running,
            reason: '\$s 的终态判定不对');
      }
      expect(PwFocusPrepareState.fromRaw(5), PwFocusPrepareState.unsupported);
      // 认不出来的码一律当 error,不静默当成功。
      expect(PwFocusPrepareState.fromRaw(99), PwFocusPrepareState.error);
    });

    test('降采样:不超过上限、等间隔、必留最后一条、不造数', () {
      List<PwFocusSample> make(int n) => List<PwFocusSample>.generate(
            n,
            (int i) => PwFocusSample(
              t: i.toDouble(),
              lensPosition: 0.5,
              focusMeasure: i.toDouble(),
              isAdjustingFocus: false,
              armState: 0,
              meanLuma: 120,
            ),
          );

      // 不够上限 ⇒ 原样。
      final List<PwFocusSample> small = make(10);
      expect(downsampleFocusSeries(small, maxPoints: 2000).length, 10);
      expect(focusSeriesStride(10), 1);

      // 超上限 ⇒ 点数 <= 上限,且第一条与最后一条都在。
      final List<PwFocusSample> big = make(9973);
      final List<PwFocusSample> kept = downsampleFocusSeries(big);
      expect(kept.length, lessThanOrEqualTo(kZeroArkitProbeFocusSeriesMaxPoints));
      expect(kept.first.t, 0.0);
      expect(kept.last.t, 9972.0);
      // 等间隔:相邻两点的间隔恒为 stride(最后一条可能更近)。
      final int stride = focusSeriesStride(big.length);
      expect(stride, 5);
      for (int i = 1; i < kept.length - 1; i++) {
        expect(kept[i].t - kept[i - 1].t, stride.toDouble());
      }
      // 🔴 不做平均 ⇒ 每个留下的点都必须是原始点之一(值没被改过)。
      final Set<double> original = big.map((PwFocusSample x) => x.t).toSet();
      for (final PwFocusSample x in kept) {
        expect(original.contains(x.t), isTrue);
      }

      expect(downsampleFocusSeries(big, maxPoints: 0), isEmpty);
    });

    test('manifest:两张验收表分开记,且 focus 块把 series 降采样了', () {
      final List<PwFocusSample> series = List<PwFocusSample>.generate(
        5000,
        (int i) => PwFocusSample(
          t: i / 30.0,
          lensPosition: 0.8,
          focusMeasure: 1000.0 + i,
          isAdjustingFocus: i.isEven,
          armState: 2,
          meanLuma: 118,
        ),
      );
      final Map<String, Object?> m = buildZeroArkitProbeManifest(
        runDir: '/x',
        hwMachine: 'iPhone15,2',
        primedMachine: null,
        runtimeStart: null,
        cameraRc: 0,
        cameraOwnedBySelfVio: true,
        cameraSymbolFailure: null,
        intrinsicsWaitMs: 100,
        capturedIntrinsics: null,
        shots: <ZeroArkitProbeShot>[
          const ZeroArkitProbeShot(
            index: 1,
            jpegPath: '/x/photo_1.jpg',
            metadataPath: '/x/photo_1.json',
            targetTimestamp: 1.0,
            status: 'saved',
            message: null,
            elapsedMs: 120,
            trackingStateAtTrigger: 'normal',
            isTrackingAtTrigger: true,
            focusPrepareState: 'done_ok',
            focusPrepareMs: 812,
            lensPositionAtShutter: 0.37,
            focusMeasureAtShutter: 2048.5,
            armStateAtShutter: 2,
            isAdjustingFocusAtShutter: false,
          ),
        ],
        trackingStateCounts: const <String, int>{'normal': 1},
        trackingFrames: 1,
        notTrackingFrames: 0,
        confidenceTierCounts: const <String, int>{},
        poseFrames: 1,
        pageDuration: const Duration(seconds: 1),
        startedAtUtc: DateTime.utc(2026),
        finishedAtUtc: DateTime.utc(2026),
        engineUnavailableReason: null,
        focusAvailable: true,
        focusStateAtFinish: null,
        focusNativeReportJson: '{"arm":2,"arm_label":"c_pw_af_cdaf"}',
        focusSeries: series,
        focusSelfHeal: null,
      );

      final Map<String, Object?> focus = m['focus']! as Map<String, Object?>;
      expect(focus['available'], isTrue);
      expect(focus['unavailable_note'], isNull);
      // 原生 report 是 JSON 原文 ⇒ 必须被解开,不是当字符串塞进去。
      expect((focus['native_report']! as Map<String, Object?>)['arm_label'],
          'c_pw_af_cdaf');

      final Map<String, Object?> b =
          focus['video_stream_series']! as Map<String, Object?>;
      expect(b['captured'], 5000);
      expect(b['max_points'], kZeroArkitProbeFocusSeriesMaxPoints);
      expect(b['downsample_stride'], 3);
      final List<Object?> samples = b['samples']! as List<Object?>;
      expect(samples.length, lessThanOrEqualTo(2000));
      expect((samples.first! as Map<String, Object?>).keys.toSet(),
          <String>{'t', 'lens', 'fm', 'adj', 'st', 'luma'});

      // 🔴 两张表必须分开:表 A 是每张照片一行,表 B 只放一个指针。
      final Map<String, Object?> tables =
          m['focus_acceptance_tables']! as Map<String, Object?>;
      final Map<String, Object?> tableA =
          tables['table_a_shutter_instant']! as Map<String, Object?>;
      final Map<String, Object?> tableB =
          tables['table_b_video_stream']! as Map<String, Object?>;
      final List<Object?> rows = tableA['rows']! as List<Object?>;
      expect(rows.length, 1);
      final Map<String, Object?> row0 = rows.first! as Map<String, Object?>;
      expect(row0['focus_prepare_state'], 'done_ok');
      expect(row0['focus_prepare_ms'], 812);
      expect(row0['lens_position_at_shutter'], 0.37);
      expect(row0['focus_measure_at_shutter'], 2048.5);
      // 表 A 里不许混进整场的时间序列。
      expect(tableA.containsKey('samples'), isFalse);
      expect(tableB['series_ref'], 'focus.video_stream_series');
      expect(tableB['self_heal_ref'], contains('focus.self_heal'));

      // 每张照片自己那条记录里也带着同样六项(拉回来对账用)。
      final Map<String, Object?> p0 =
          (m['photos']! as List<Object?>).first! as Map<String, Object?>;
      expect(p0['focus_prepare_state'], 'done_ok');
      expect(p0['arm_state_at_shutter'], 2);
    });

    test('符号不在时 focus 块如实写明,不假装有数据', () {
      final Map<String, Object?> m = buildZeroArkitProbeManifest(
        runDir: '/x',
        hwMachine: null,
        primedMachine: null,
        runtimeStart: null,
        cameraRc: -101,
        cameraOwnedBySelfVio: false,
        cameraSymbolFailure: null,
        intrinsicsWaitMs: null,
        capturedIntrinsics: null,
        shots: const <ZeroArkitProbeShot>[],
        trackingStateCounts: const <String, int>{},
        trackingFrames: 0,
        notTrackingFrames: 0,
        confidenceTierCounts: const <String, int>{},
        poseFrames: 0,
        pageDuration: Duration.zero,
        startedAtUtc: DateTime.utc(2026),
        finishedAtUtc: DateTime.utc(2026),
        engineUnavailableReason: null,
        focusAvailable: false,
        focusStateAtFinish: null,
        focusNativeReportJson: null,
        focusSeries: const <PwFocusSample>[],
        focusSelfHeal: null,
      );
      final Map<String, Object?> focus = m['focus']! as Map<String, Object?>;
      expect(focus['available'], isFalse);
      expect(focus['unavailable_note'], contains('没全查到'));
      expect(focus['native_report'], isNull);
      expect(focus['minimum_focus_distance_mm'], isNull);
      expect(
        (focus['video_stream_series']! as Map<String, Object?>)['captured'],
        0,
      );
    });

    test('坏 JSON 不吞:解不开就把原文与原因都留着', () {
      final Map<String, Object?> m = buildZeroArkitProbeManifest(
        runDir: '/x',
        hwMachine: null,
        primedMachine: null,
        runtimeStart: null,
        cameraRc: 0,
        cameraOwnedBySelfVio: true,
        cameraSymbolFailure: null,
        intrinsicsWaitMs: null,
        capturedIntrinsics: null,
        shots: const <ZeroArkitProbeShot>[],
        trackingStateCounts: const <String, int>{},
        trackingFrames: 0,
        notTrackingFrames: 0,
        confidenceTierCounts: const <String, int>{},
        poseFrames: 0,
        pageDuration: Duration.zero,
        startedAtUtc: DateTime.utc(2026),
        finishedAtUtc: DateTime.utc(2026),
        engineUnavailableReason: null,
        focusAvailable: true,
        focusStateAtFinish: null,
        focusNativeReportJson: '{不是 JSON',
        focusSeries: const <PwFocusSample>[],
        focusSelfHeal: null,
      );
      final Map<String, Object?> nr =
          (m['focus']! as Map<String, Object?>)['native_report']!
              as Map<String, Object?>;
      expect(nr['raw'], '{不是 JSON');
      expect(nr['decode_error'], isNotNull);
    });
  });
}
