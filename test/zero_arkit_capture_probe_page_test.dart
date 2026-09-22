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
import 'package:pocketworld_flutter/vio/capture/zero_arkit_capture_runtime.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/zero_arkit_camera_gate.dart';
import 'package:pocketworld_flutter/vio/render/zero_arkit_capture_probe_page.dart';

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

    test('runtime 用它起:相机失败 ⇒ 不建会话、如实 error', () {
      final BenchZeroArkitPlatform p = BenchZeroArkitPlatform();
      final ZeroArkitCaptureRuntime rt = ZeroArkitCaptureRuntime(
        platform: p,
        machineIdentifier: 'iPhone15,2',
      );
      final ZeroArkitStartResult r = rt.start();
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
}
