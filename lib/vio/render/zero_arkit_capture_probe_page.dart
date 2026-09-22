// zero_arkit_capture_probe_page.dart — 台架页:零 ARKit 臂**端到端**拍摄探针
//     相机 → XRSLAM → 位姿 → 快门 → JPEG + sidecar 落到台架容器
// 控制台 grep `[zero-arkit-probe]` 就是全部现场证据;拉回 Mac 用
// `tool/bench/pull_zero_arkit_run.sh`。
//
// ══ 🔴 它会打开摄像头 ═══════════════════════════════════════════════════════
// 进页即起 [PwCameraSlot] 自己那个 AVCaptureSession(1920×1440 / 30 fps /
// 镜头锁 0.835,全部是 `ZeroArkitCaptureRuntime` 的默认值),并建 XRSLAM 会话。
//   * 要不要动手机:**要**。VIO 要平移才初始化得出尺度;静止摆着状态条会一直
//     停在 `limited_initializing` / tracking=false。建议缓慢平移 10–20 s,
//     看到 `tracking=true` 再按「拍一张」——不跟踪时快门照样按得下,但 sidecar
//     的 `extrinsic` 会如实是空表(生产的闸会拒),这也是要看的一档。
//   * 写多少数据:每按一次「拍一张」写一张全分辨率 JPEG(原生 activeFormat
//     的最大尺寸,几 MB)+ 一个 sidecar JSON;「完成」再写一个 `run_manifest.json`。
//     全部落在 `<Documents>/zeroarkit_run_<yyyyMMdd_HHmmss>/`。不按快门就只有
//     manifest。位姿流本身**不落盘**。
//   * 时长:由使用者决定;「完成」或离开本页即 `provider.stop()` ⇒ 会话销毁 +
//     相机关。
//
// ══ 为什么在台架而不是生产包上跑 ══════════════════════════════════════════
// 「没全面持平/超越 ARKit 之前绝不上生产」—— 手机上的 PocketWorld 是生产包,
// 一个字节不碰。台架是独立 bundle(com.kyle.arloopbench),`lib/vio/**` 是生产
// 的镜像(真源在 pocketworld,`sync_from_production.sh` 同步并自证逐字节一致)。
// 本文件本身也是生产仓的文件,镜像过去;它在生产里**没有任何 import 者**
// (与 `zero_arkit_preview_probe_page.dart` 同一处境)。
//
// ══ 抄的是什么,不是新发明 ═════════════════════════════════════════════════
//   * 页面骨架:`zero_arkit_preview_probe_page.dart`(上一刀,3:4 框 + 状态条 +
//     两个按钮)。
//   * 平台注入:[BenchZeroArkitPlatform] 逐方法对应
//     `zero_arkit_capture_runtime.dart` 的 `NativeZeroArkitPlatform`,只把
//     `ZeroArkitCameraGate.start/stop/ownedBySelfVio` 三处换成
//     `PwCameraSlot.start/stop` + 本地记账 —— 台架里没有 ARKit,没有租约可争,
//     `PwZeroArkitGate.swift` 也不在台架里。其余四个方法与 Native **逐字相同**。
//     符号不在时的 try/catch 形状抄 `ZeroArkitCameraGate.start`。
//   * 等内参再建会话:`ar_minimal_loop_page.dart` `_ensureSession`
//     「还没有交付过帧,下一帧再试」。`ZeroArkitCaptureRuntime.start()` 是同步的,
//     而 `pw_camera_slot_intrinsics` 要等**第一帧交付**才有值(Swift 返回 −1)
//     ⇒ 同步序里第 ② 步必失败。所以本页先起相机、轮询到内参非 null,再调
//     `provider.start()`;runtime 里那次 `startCamera` 打到
//     `PwCameraSlotImpl.start`,它对已在跑的会话返回 0(`PwCameraSlot.swift`
//     「已在跑」),**幂等**。
//   * 机型:[benchReadHwMachine] 是 `PwVioTimebase.swift` `case "deviceMachine"`
//     那十行(`sysctlbyname("hw.machine")` 先问长度再取值)从 dart:ffi 调一遍。
//     为什么不走 `PwDeviceMachine.prime()` 的通道:台架没有
//     `pocketworld_vio_timebase`(`PwVioTimebase.swift` 1519 行且 `import ARKit`,
//     不镜像)。`prime()` **仍照调**,回 null 如实进 manifest;机型经
//     `ZeroArkitCaptureRuntime(machineIdentifier:)` 显式传入,查表/provenance
//     仍是 `camera_time_offset.dart` 那一份,本页不另算 c。
//   * 拍一张:`ARFrameSaveSpec` 与 `capture_session.dart` 的 saveSpec 同形状;
//     JPEG 搬运与 sidecar 由 `VioArPoseProvider.saveCurrentFrame` 按密封契约
//     落地,本页**不碰内容**,只记 status/message。
//
// ══ 与生产 ON 臂的差别(有意,不是漏)══════════════════════════════════════
//   * 无租约闸(见上)。
//   * c 的机型来源是 sysctl 直读,不是 MethodChannel(见上)。
//   * 相机由本页先起、runtime 再幂等地起一次;生产由 runtime 一次起
//     (生产因此会踩到同一个「同步序等不到第一帧内参」——那是生产的事,
//     本页只如实记录 `intrinsics_wait_ms`,不改 runtime)。
//   * 3:4 框用 `AspectRatio(3/4)` 满宽(与上一刀同;视口像素与生产
//     `CapturePreviewRect` 一样,只是纵向位置不同)。
//
// ══ 🔴 关于 `startSession` 这个词 ═══════════════════════════════════════════
// 本文件里它只出现一次:`ZeroArkitPlatform` 接口要求的 override,转调的是
// `XrslamSession.start`(XRSLAM 会话),与 ARKit 的 `ARSession` 无关。台架
// 任何路径上没有 `ARSession` / `import ARKit`。
//
// ══ 判据(全在控制台)═══════════════════════════════════════════════════════
//   进页:机型 / c=…ms provenance=…(机型)/ 相机 rc / 内参等待 ms / 会话 rc ok
//   每 60 帧:帧=N state=… tracking=… tier=… 已存=…
//   每次快门:快门 #n status=… message=… 用时
//   完成:manifest 路径 + 各计数

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../official_dome/ar_pose.dart';
import '../capture/camera_time_offset.dart';
import '../capture/zero_arkit_capture_runtime.dart';
import '../ffi/pw_focus_ffi.dart';
import '../ffi/xrslam_config.dart' show CameraIntrinsics, FieldProvenanceLabel;
import '../ffi/xrslam_session.dart';
import '../pose/camera_projection.dart' show PinholeIntrinsics;
import '../pose/camera_slot_ffi.dart' show CameraExposure, PwCameraSlot;
import '../pose/vio_ar_pose_provider.dart';
import '../pose/zero_arkit_camera_gate.dart' show kZeroArkitCameraSymbolMissing;
import '../quality/pose_confidence.dart';
import 'zero_arkit_camera_preview.dart';

/// 日志前缀。grep 这个词就能把本页这条路的现场证据全拉出来。
const String kZeroArkitProbeLogTag = '[zero-arkit-probe]';

/// 每隔多少位姿帧打一行状态。抄台架页的 60。
const int kZeroArkitProbeLogEveryFrames = 60;

/// 等第一帧内参的上限与轮询间隔。相机起后第一帧通常 100–500 ms 到。
const Duration kZeroArkitProbeIntrinsicsTimeout = Duration(seconds: 5);
const Duration kZeroArkitProbeIntrinsicsPoll = Duration(milliseconds: 50);

/// manifest 的 schema 标签。
/// `/2` = 2026-09-23 加了对焦三臂那一块(`focus` 与 `focus_acceptance_tables`)。
const String kZeroArkitProbeManifestSchema = 'pw.bench.zero_arkit_capture_probe/2';

/// 快门前那一次对焦的轮询间隔与**兜底**上限。
/// 🔴 真正的上限在原生侧(B 臂 2 s、C 臂 3 s,见 `PwFocusArms.swift`),
///    这里这个 4 s 只防「原生一直不落终态」把按钮卡死,不是判据。
const Duration kZeroArkitProbeFocusPoll = Duration(milliseconds: 16);
const Duration kZeroArkitProbeFocusHardCap = Duration(seconds: 4);

/// 每隔多久把原生的对焦时间序列取空一次。原生环形上限 20000 条(≈11 分钟),
/// 1 秒一次 ⇒ 正常永远顶不到。
const Duration kZeroArkitProbeFocusDrain = Duration(seconds: 1);

/// manifest 里那条时间序列的点数上限(任务书)。
const int kZeroArkitProbeFocusSeriesMaxPoints = 2000;

/// 把对焦时间序列降采样到不超过 [maxPoints] 点。**纯函数,可单测。**
///
/// 做法:等间隔抽样(步长 = ceil(n / maxPoints)),并**无条件保留最后一条**。
/// 🔴 刻意不做窗口平均:平均会把「镜头在动的那一瞬」的尖峰抹平,而那正是
///    验收表 B 要看的东西(振荡 / 重触发)。抽样丢点是诚实的,平均是造数。
List<PwFocusSample> downsampleFocusSeries(
  List<PwFocusSample> src, {
  int maxPoints = kZeroArkitProbeFocusSeriesMaxPoints,
}) {
  if (maxPoints <= 0) return const <PwFocusSample>[];
  if (src.length <= maxPoints) return List<PwFocusSample>.of(src);
  final int stride = (src.length + maxPoints - 1) ~/ maxPoints;
  final List<PwFocusSample> out = <PwFocusSample>[];
  for (int i = 0; i < src.length; i += stride) {
    out.add(src[i]);
  }
  if (out.last != src.last) out.add(src.last);
  return out;
}

/// [downsampleFocusSeries] 实际用的步长(写进 manifest,便于回放时对账)。
int focusSeriesStride(int length, {int maxPoints = kZeroArkitProbeFocusSeriesMaxPoints}) {
  if (maxPoints <= 0 || length <= maxPoints) return 1;
  return (length + maxPoints - 1) ~/ maxPoints;
}

// ── 平台注入:台架版 ─────────────────────────────────────────────────────────

/// 台架实现:直接打到 `PwCameraSlot`,不经租约闸(台架没有 ARKit)。
///
/// 与 `NativeZeroArkitPlatform` 的对应关系逐方法写在文件头。
class BenchZeroArkitPlatform implements ZeroArkitPlatform {
  BenchZeroArkitPlatform();

  int? _lastCameraRc;
  bool _cameraStarted = false;
  Object? _symbolFailure;

  /// 最近一次 `PwCameraSlot.start` 的返回码(诊断用)。
  int? get lastCameraRc => _lastCameraRc;

  /// 符号查不到时的原因(模拟器 / 单测)。
  Object? get symbolFailure => _symbolFailure;

  @override
  int startCamera({
    required int width,
    required int height,
    required double fps,
    required double lensPosition,
  }) {
    try {
      final int rc = PwCameraSlot.start(
        width: width,
        height: height,
        fps: fps,
        lensPosition: lensPosition,
      );
      _lastCameraRc = rc;
      if (rc == 0) _cameraStarted = true;
      return rc;
    } catch (e) {
      // 符号不在(模拟器 / 单测)。与 `ZeroArkitCameraGate.start` 同一个码,
      // 与「被 ARKit 占着」的 −100 分开。
      _symbolFailure = e;
      _lastCameraRc = kZeroArkitCameraSymbolMissing;
      return kZeroArkitCameraSymbolMissing;
    }
  }

  @override
  void stopCamera() {
    if (!_cameraStarted) return;
    _cameraStarted = false;
    try {
      PwCameraSlot.stop();
    } catch (e) {
      _symbolFailure = e;
    }
  }

  /// 台架没有租约,「自研臂名下」= 本页起过且没停。拿不到证据就不宣称拥有。
  @override
  bool cameraOwnedBySelfVio() => _cameraStarted;

  @override
  PinholeIntrinsics? intrinsics({
    required int imageWidth,
    required int imageHeight,
  }) =>
      PwCameraSlot.intrinsics(imageWidth: imageWidth, imageHeight: imageHeight);

  @override
  CameraExposure? exposure() => PwCameraSlot.exposure();

  @override
  XrslamSessionStart startSession({
    required CameraIntrinsics intrinsics,
    required double cameraTimeOffsetSeconds,
  }) =>
      XrslamSession.start(
        intrinsics: intrinsics,
        cameraTimeOffsetSeconds: cameraTimeOffsetSeconds,
      );

  @override
  void destroySession() => XrslamSession.current?.destroy();
}

// ── 机型:sysctlbyname("hw.machine") ─────────────────────────────────────────

typedef _SysctlByNameNative = ffi.Int Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Size>,
  ffi.Pointer<ffi.Void>,
  ffi.Size,
);
typedef _SysctlByNameDart = int Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Size>,
  ffi.Pointer<ffi.Void>,
  int,
);

/// `hw.machine`(如 `iPhone15,2`)。逐行对应 `PwVioTimebase.swift`
/// `case "deviceMachine"`:先 `sysctlbyname(name, nil, &sz, nil, 0)` 问长度,
/// 再按长度取值。任何失败 ⇒ `null`(机型未知),不猜。
///
/// macOS 单测宿主上同样能调(返回 `arm64` / `x86_64`),所以有单测。
String? benchReadHwMachine() {
  try {
    final _SysctlByNameDart sysctlbyname = ffi.DynamicLibrary.process()
        .lookupFunction<_SysctlByNameNative, _SysctlByNameDart>('sysctlbyname');
    final ffi.Pointer<Utf8> name = 'hw.machine'.toNativeUtf8();
    final ffi.Pointer<ffi.Size> sz = calloc<ffi.Size>();
    try {
      if (sysctlbyname(name, ffi.nullptr, sz, ffi.nullptr, 0) != 0) return null;
      final int n = sz.value;
      if (n <= 0) return null;
      final ffi.Pointer<ffi.Char> buf = calloc<ffi.Char>(n);
      try {
        if (sysctlbyname(name, buf.cast(), sz, ffi.nullptr, 0) != 0) {
          return null;
        }
        final String s = buf.cast<Utf8>().toDartString();
        return s.isEmpty ? null : s;
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(sz);
      calloc.free(name);
    }
  } catch (_) {
    return null;
  }
}

// ── run 目录名与 manifest(纯函数,可单测)──────────────────────────────────

String _two(int v) => v.toString().padLeft(2, '0');

/// `zeroarkit_run_<yyyyMMdd_HHmmss>`,本地时间。
String zeroArkitRunDirName(DateTime t) =>
    'zeroarkit_run_${t.year}${_two(t.month)}${_two(t.day)}_'
    '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

/// 一次快门的记录。
class ZeroArkitProbeShot {
  const ZeroArkitProbeShot({
    required this.index,
    required this.jpegPath,
    required this.metadataPath,
    required this.targetTimestamp,
    required this.status,
    required this.message,
    required this.elapsedMs,
    required this.trackingStateAtTrigger,
    required this.isTrackingAtTrigger,
    this.focusPrepareState,
    this.focusPrepareMs,
    this.lensPositionAtShutter,
    this.focusMeasureAtShutter,
    this.armStateAtShutter,
    this.isAdjustingFocusAtShutter,
  });

  final int index;
  final String jpegPath;
  final String metadataPath;
  final double? targetTimestamp;
  final String status;
  final String? message;
  final int elapsedMs;
  final String? trackingStateAtTrigger;
  final bool isTrackingAtTrigger;

  // ── 验收表 A「按快门瞬间对到物体」的一行(判决书 §6.3)────────────────
  /// 快门前那一次对焦的终态。A 臂恒为 `unsupported_arm_a`(它本来就不动镜头,
  /// 那正是对照的定义)。
  final String? focusPrepareState;

  /// 那一次对焦用了多少毫秒。判决书 §6.3 的**次指标**(主指标是成片锐度)。
  final double? focusPrepareMs;

  /// 快门那一刻的镜头位置。🔴 0 = 最近、1 = 最远(Apple 头文件原文)。
  final double? lensPositionAtShutter;

  /// 快门那一刻 ROI 上的 Tenengrad。**不是成片锐度** —— 成片锐度要拉回 Mac
  /// 用 `quality_compute.dart` 的同一算子在照片上算(判决书 §6.3)。
  final double? focusMeasureAtShutter;

  final int? armStateAtShutter;
  final bool? isAdjustingFocusAtShutter;

  bool get saved => status == 'saved';

  Map<String, Object?> toJson() => <String, Object?>{
        'index': index,
        'jpeg': jpegPath,
        'metadata': metadataPath,
        'target_t': targetTimestamp,
        'status': status,
        'message': message,
        'elapsed_ms': elapsedMs,
        'tracking_state_at_trigger': trackingStateAtTrigger,
        'is_tracking_at_trigger': isTrackingAtTrigger,
        'focus_prepare_state': focusPrepareState,
        'focus_prepare_ms': focusPrepareMs,
        'lens_position_at_shutter': lensPositionAtShutter,
        'focus_measure_at_shutter': focusMeasureAtShutter,
        'arm_state_at_shutter': armStateAtShutter,
        'is_adjusting_focus_at_shutter': isAdjustingFocusAtShutter,
      };

  /// 验收表 A 的一行(判决书 §6.3)。只有对焦那几项,与表 B 分开记。
  Map<String, Object?> toFocusTableRow() => <String, Object?>{
        'index': index,
        'jpeg': jpegPath,
        'focus_prepare_state': focusPrepareState,
        'focus_prepare_ms': focusPrepareMs,
        'lens_position_at_shutter': lensPositionAtShutter,
        'focus_measure_at_shutter': focusMeasureAtShutter,
        'arm_state_at_shutter': armStateAtShutter,
        'is_adjusting_focus_at_shutter': isAdjustingFocusAtShutter,
        'photo_status': status,
      };
}

/// `run_manifest.json` 的内容。纯函数:所有输入都是已经发生的事实。
Map<String, Object?> buildZeroArkitProbeManifest({
  required String runDir,
  required String? hwMachine,
  required String? primedMachine,
  required ZeroArkitStartResult? runtimeStart,
  required int? cameraRc,
  required bool cameraOwnedBySelfVio,
  required Object? cameraSymbolFailure,
  required int? intrinsicsWaitMs,
  required PinholeIntrinsics? capturedIntrinsics,
  required List<ZeroArkitProbeShot> shots,
  required Map<String, int> trackingStateCounts,
  required int trackingFrames,
  required int notTrackingFrames,
  required Map<String, int> confidenceTierCounts,
  required int poseFrames,
  required Duration pageDuration,
  required DateTime startedAtUtc,
  required DateTime finishedAtUtc,
  required Object? engineUnavailableReason,
  required bool focusAvailable,
  required PwFocusState? focusStateAtFinish,
  required String? focusNativeReportJson,
  required List<PwFocusSample> focusSeries,
}) {
  final CameraTimeOffset? c = runtimeStart?.cameraTimeOffset;
  final CameraIntrinsics? feedK = runtimeStart?.intrinsics;
  return <String, Object?>{
    'schema': kZeroArkitProbeManifestSchema,
    'bundle': 'com.kyle.arloopbench',
    'run_dir': runDir,
    'started_at_utc': startedAtUtc.toIso8601String(),
    'finished_at_utc': finishedAtUtc.toIso8601String(),
    'page_duration_s': pageDuration.inMilliseconds / 1000.0,
    'machine': <String, Object?>{
      'hw_machine': hwMachine,
      'hw_machine_source':
          'sysctlbyname(hw.machine) via dart:ffi(抄 PwVioTimebase.swift deviceMachine)',
      'device_machine_prime': primedMachine,
      'device_machine_prime_note': primedMachine == null
          ? '台架没有 pocketworld_vio_timebase 通道 ⇒ prime() 如实 null'
          : 'prime() 有值',
    },
    'camera_time_offset': c == null
        ? null
        : <String, Object?>{
            'seconds': c.seconds,
            'milliseconds': c.milliseconds,
            'provenance': c.provenance.label,
            'machine': c.machine,
            'is_measured_for_this_device': c.isMeasuredForThisDevice,
            'note': c.note,
          },
    'camera': <String, Object?>{
      'start_rc': cameraRc,
      'owned_by_self_vio': cameraOwnedBySelfVio,
      'symbol_failure': cameraSymbolFailure?.toString(),
      'intrinsics_wait_ms': intrinsicsWaitMs,
      'captured_intrinsics': capturedIntrinsics == null
          ? null
          : <String, Object?>{
              'fx': capturedIntrinsics.fx,
              'fy': capturedIntrinsics.fy,
              'cx': capturedIntrinsics.cx,
              'cy': capturedIntrinsics.cy,
              'image_w': capturedIntrinsics.imageWidth,
              'image_h': capturedIntrinsics.imageHeight,
            },
    },
    'session': runtimeStart == null
        ? null
        : <String, Object?>{
            'started': runtimeStart.sessionStarted,
            'ok': runtimeStart.ok,
            'error': runtimeStart.error,
            'camera_rc': runtimeStart.cameraRc,
            'blocked_by_arkit': runtimeStart.blockedByArkit,
            'feed_intrinsics': feedK == null
                ? null
                : <String, Object?>{
                    'fx': feedK.fx,
                    'fy': feedK.fy,
                    'cx': feedK.cx,
                    'cy': feedK.cy,
                    'w': feedK.resolutionWidth,
                    'h': feedK.resolutionHeight,
                    'provenance': feedK.provenance.label,
                  },
          },
    'engine_unavailable_reason': engineUnavailableReason?.toString(),
    'pose_frames': poseFrames,
    'tracking_frames': trackingFrames,
    'not_tracking_frames': notTrackingFrames,
    'tracking_state_counts': Map<String, int>.of(trackingStateCounts),
    'confidence_tier_counts': Map<String, int>.of(confidenceTierCounts),
    'photos_requested': shots.length,
    'photos_saved': shots.where((ZeroArkitProbeShot s) => s.saved).length,
    'photos': shots.map((ZeroArkitProbeShot s) => s.toJson()).toList(),
    'focus': _focusBlock(
      focusAvailable: focusAvailable,
      stateAtFinish: focusStateAtFinish,
      nativeReportJson: focusNativeReportJson,
      series: focusSeries,
    ),
    // 🔴 判决书 §6.3 要求**两张验收表分开**:
    //    A「按快门瞬间对到物体」= 每张照片一行;
    //    B「视频流持续对焦」= 整场一条时间序列。
    //    不混着记,免得又出现「用一张表的数放行另一张表的问题」。
    'focus_acceptance_tables': <String, Object?>{
      'table_a_shutter_instant': <String, Object?>{
        'what': '按快门瞬间对到物体(判决书 §6.3 表 A,最关键 —— 近距景深只有毫米级)',
        'primary_metric_note':
            '🔴 主指标是**成片在物体 ROI 上的锐度**,要拉回 Mac 用 quality_compute.dart '
            '的同一 Laplacian 方差在照片上算;本 manifest 只给现场的次指标'
            '(对焦耗时 / 快门瞬间的镜头位置与视频流度量)。',
        'rows': shots
            .map((ZeroArkitProbeShot s) => s.toFocusTableRow())
            .toList(),
      },
      'table_b_video_stream': <String, Object?>{
        'what': '视频流持续对焦(判决书 §6.3 表 B)',
        'series_ref': 'focus.video_stream_series',
      },
    },
  };
}

/// manifest 里 `focus` 那一块。抽出来是为了让上面那个函数别再长。
Map<String, Object?> _focusBlock({
  required bool focusAvailable,
  required PwFocusState? stateAtFinish,
  required String? nativeReportJson,
  required List<PwFocusSample> series,
}) {
  Object? nativeReport;
  if (nativeReportJson != null) {
    try {
      nativeReport = jsonDecode(nativeReportJson);
    } catch (e) {
      // 解不开就把原文与原因都留着,不吞。
      nativeReport = <String, Object?>{
        'decode_error': '$e',
        'raw': nativeReportJson,
      };
    }
  }
  final List<PwFocusSample> kept = downsampleFocusSeries(series);
  return <String, Object?>{
    'available': focusAvailable,
    'unavailable_note': focusAvailable
        ? null
        : '🔴 pw_camera_slot_focus_* 五个符号没全查到 —— 这条路没编进这个二进制'
            '(模拟器 / 旧构建 / pbxproj 白名单漏了)⇒ 本场没有对焦数据。',
    'arm_launch_argument': '-PWFocusArm a|b|c(默认 a = 现状锁焦对照臂)',
    'state_at_finish': stateAtFinish?.toJson(),
    'minimum_focus_distance_mm': stateAtFinish?.minimumFocusDistanceMm,
    'minimum_focus_distance_note':
        '🔴 AVCaptureDevice.minimumFocusDistance,毫米,**-1 = 未知**(Apple 头文件原文)。'
        '判决书附录 A.4:主摄最近对焦距离若 > 10 cm,10 cm 档必须切超广角 —— '
        '那是换一颗镜头、换一套内参。',
    'native_report': nativeReport,
    'video_stream_series': <String, Object?>{
      'what': '验收表 B 的原始数据:逐帧 ROI 度量 + 镜头位置 + 对焦状态',
      'sample_fields': <String>['t', 'lens', 'fm', 'adj', 'st', 'luma'],
      'sample_fields_note':
          't = 帧 PTS 秒(与照片 sidecar 的 t 同域);lens = lensPosition **0=最近**;'
          'fm = Tenengrad ROI 均值;adj = isAdjustingFocus;'
          'st = A 恒 0 / B 是否调焦 / C = PwAfState(0 Idle 1 Scanning 2 Focused 3 Failed);'
          'luma = 同一 ROI 平均亮度。',
      'captured': series.length,
      'kept': kept.length,
      'max_points': kZeroArkitProbeFocusSeriesMaxPoints,
      'downsample_stride': focusSeriesStride(series.length),
      'downsample_note': '等间隔抽样 + 无条件保留最后一条;**不做平均**(平均会抹掉尖峰)。',
      'samples': kept.map((PwFocusSample x) => x.toJson()).toList(),
    },
  };
}

// ── 页面 ─────────────────────────────────────────────────────────────────────

class ZeroArkitCaptureProbePage extends StatefulWidget {
  const ZeroArkitCaptureProbePage({super.key});

  @override
  State<ZeroArkitCaptureProbePage> createState() =>
      _ZeroArkitCaptureProbePageState();
}

class _ZeroArkitCaptureProbePageState extends State<ZeroArkitCaptureProbePage> {
  final BenchZeroArkitPlatform _platform = BenchZeroArkitPlatform();
  ZeroArkitCaptureRuntime? _runtime;
  VioArPoseProvider? _provider;
  StreamSubscription<ARPose>? _poseSub;

  final Stopwatch _pageClock = Stopwatch()..start();
  final DateTime _startedAtUtc = DateTime.now().toUtc();

  String _phase = '进页:查机型';
  String? _fatal;
  String? _hwMachine;
  String? _primedMachine;
  int? _cameraRc;
  int? _intrinsicsWaitMs;
  PinholeIntrinsics? _capturedIntrinsics;
  Directory? _runDir;

  int _poseFrames = 0;
  int _trackingFrames = 0;
  int _notTrackingFrames = 0;
  final Map<String, int> _stateCounts = <String, int>{};
  final Map<String, int> _tierCounts = <String, int>{};
  ARPose? _lastPose;
  VioPoseConfidence _confidence = VioPoseConfidence.unknown;

  final List<ZeroArkitProbeShot> _shots = <ZeroArkitProbeShot>[];
  bool _running = false;
  bool _shutterBusy = false;
  bool _finished = false;
  bool _disposing = false;
  String? _manifestPath;

  // ── 对焦三臂 ────────────────────────────────────────────────────────────
  /// 整场的逐帧对焦流水(验收表 B)。每秒从原生取空一次,写 manifest 时再降采样。
  final List<PwFocusSample> _focusSeries = <PwFocusSample>[];
  Timer? _focusDrainTimer;
  PwFocusState? _focusState;
  PwFocusArm? _focusArm;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  void _log(String line) => debugPrint('$kZeroArkitProbeLogTag $line');

  Future<void> _boot() async {
    // ① Documents 下的 run 目录名先定下来;真正建目录在第一次快门/完成时。
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      _runDir = Directory('${docs.path}/${zeroArkitRunDirName(DateTime.now())}');
    } catch (e) {
      _fail('拿不到 Documents 目录:$e');
      return;
    }

    // ② 机型。prime() 照调(台架上如实 null),再 sysctl 直读。
    _primedMachine = await PwDeviceMachine.prime();
    _hwMachine = benchReadHwMachine();
    _log('机型 prime()=${_primedMachine ?? 'null'} '
        'sysctl(hw.machine)=${_hwMachine ?? 'null'} run=${_runDir!.path}');
    if (!mounted) return;

    // ②.5 🔴 读臂。**在起相机之前** —— `PwFocusArms.configureAtStart` 是在
    //     `PwCameraSlot.start` 的 lockForConfiguration 块里跑的,那之后再换臂
    //     就晚了(原生侧也会拒)。不传 `-PWFocusArm` 时默认 A = 现状对照臂。
    _focusArm = PwFocus.currentArm();
    _log('对焦臂 ${_focusArm?.describe ?? '🔴 pw_camera_slot_focus_* 符号不在'}'
        ' available=${PwFocus.available}');

    // ③ runtime + provider。机型显式传入,c 的查表/provenance 仍是
    //    camera_time_offset.dart 那一份。
    final ZeroArkitCaptureRuntime runtime = ZeroArkitCaptureRuntime(
      platform: _platform,
      machineIdentifier: _hwMachine ?? _primedMachine,
    );
    final VioArPoseProvider provider = VioArPoseProvider(runtime: runtime);
    _runtime = runtime;
    _provider = provider;
    _log('c 预解析:${runtime.cameraTimeOffset.describe} —— '
        '${runtime.cameraTimeOffset.note}');

    // ④ 🔴 相机先起(这一刻开摄像头),等第一帧内参。
    setState(() => _phase = '起相机');
    final int rc = _platform.startCamera(
      width: runtime.captureWidth,
      height: runtime.captureHeight,
      fps: runtime.fps,
      lensPosition: runtime.lensPosition,
    );
    _cameraRc = rc;
    _log('相机启动 rc=$rc (${runtime.captureWidth}x${runtime.captureHeight} '
        '@${runtime.fps} lens=${runtime.lensPosition})'
        '${rc == kZeroArkitCameraSymbolMissing ? ' 符号不在:${_platform.symbolFailure}' : ''}');
    if (rc != 0) {
      _fail('相机起不来 rc=$rc');
      return;
    }
    setState(() => _phase = '等第一帧内参');
    final Stopwatch sw = Stopwatch()..start();
    PinholeIntrinsics? k;
    while (mounted && sw.elapsed < kZeroArkitProbeIntrinsicsTimeout) {
      k = _platform.intrinsics(
        imageWidth: runtime.captureWidth,
        imageHeight: runtime.captureHeight,
      );
      if (k != null && k.isUsable) break;
      await Future<void>.delayed(kZeroArkitProbeIntrinsicsPoll);
    }
    _intrinsicsWaitMs = sw.elapsedMilliseconds;
    _capturedIntrinsics = k;
    if (!mounted) return;
    if (k == null || !k.isUsable) {
      _log('内参等待 ${sw.elapsedMilliseconds}ms 仍无值 —— runtime.start 会如实拒建会话');
    } else {
      _log('内参到位 ${sw.elapsedMilliseconds}ms fx=${k.fx.toStringAsFixed(2)} '
          'fy=${k.fy.toStringAsFixed(2)} cx=${k.cx.toStringAsFixed(2)} '
          'cy=${k.cy.toStringAsFixed(2)} ${k.imageWidth}x${k.imageHeight}');
    }

    // ⑤ provider.start():runtime.start()(startCamera 幂等 → 内参 → 会话)+ 轮询。
    _poseSub = provider.start().listen(_onPose);
    final ZeroArkitStartResult? r = provider.runtimeStart;
    _log('会话 rc=${r?.cameraRc} started=${r?.sessionStarted} ok=${r?.ok} '
        'err=${r?.error} owned=${_platform.cameraOwnedBySelfVio()} '
        '${r?.cameraTimeOffset.describe}');
    if (r != null && r.intrinsics != null) {
      final CameraIntrinsics fk = r.intrinsics!;
      _log('喂料内参 fx=${fk.fx.toStringAsFixed(2)} fy=${fk.fy.toStringAsFixed(2)} '
          'cx=${fk.cx.toStringAsFixed(2)} cy=${fk.cy.toStringAsFixed(2)} '
          '${fk.resolutionWidth}x${fk.resolutionHeight} ${fk.provenance.label}');
    }
    // ⑥ 对焦流水每秒取空一次(原生环形上限 20000 条,1 秒一次顶不到)。
    //    顺带刷新状态条要用的那一份快照。
    _drainFocus();
    _focusDrainTimer = Timer.periodic(kZeroArkitProbeFocusDrain, (Timer _) {
      _drainFocus();
      if (mounted) setState(() {});
    });
    final PwFocusState? fs = _focusState;
    if (fs != null) {
      _log('对焦 arm=${fs.arm?.label} 来源=${fs.armSource.label} '
          'ROI=${fs.roiX},${fs.roiY} ${fs.roiWidth}x${fs.roiHeight} '
          'minimumFocusDistance=${fs.minimumFocusDistanceMm}mm'
          '${fs.minimumFocusDistanceMm < 0 ? '(-1 = 未知)' : ''}');
    }

    setState(() {
      _running = true;
      _phase = (r?.ok ?? false) ? '在跑' : '会话未起(${r?.error ?? '未知'})';
    });
  }

  /// 把原生那边攒下的对焦流水取空,并刷一次状态快照。
  void _drainFocus() {
    final List<PwFocusSample> batch = PwFocus.drainSeries();
    if (batch.isNotEmpty) _focusSeries.addAll(batch);
    _focusState = PwFocus.state();
  }

  void _fail(String why) {
    _log('🔴 $why');
    if (!mounted) return;
    setState(() {
      _fatal = why;
      _phase = '失败';
    });
  }

  void _onPose(ARPose pose) {
    final VioArPoseProvider? provider = _provider;
    if (provider == null) return;
    _poseFrames++;
    _lastPose = pose;
    _confidence = provider.confidence;
    if (pose.isTracking) {
      _trackingFrames++;
    } else {
      _notTrackingFrames++;
    }
    final String state = pose.trackingStateName ?? 'null';
    _stateCounts[state] = (_stateCounts[state] ?? 0) + 1;
    final String tier = _confidence.tier.name;
    _tierCounts[tier] = (_tierCounts[tier] ?? 0) + 1;

    if (_poseFrames % kZeroArkitProbeLogEveryFrames == 0) {
      final CameraTimeOffset? c = provider.runtimeStart?.cameraTimeOffset;
      _log('帧=$_poseFrames state=$state tracking=${pose.isTracking} '
          'tier=$tier t=${pose.timestamp.toStringAsFixed(3)} '
          'owned=${_platform.cameraOwnedBySelfVio()} 已存=$_savedCount/${_shots.length} '
          '${c?.describe ?? 'c=?'}');
    }
    // UI 约 10 Hz 刷一次就够,别让 setState 跟着 60 Hz 跑。
    if (_poseFrames % 6 == 0 && mounted) setState(() {});
  }

  int get _savedCount => _shots.where((ZeroArkitProbeShot s) => s.saved).length;

  Future<void> _shutter() async {
    final VioArPoseProvider? provider = _provider;
    final Directory? runDir = _runDir;
    if (provider == null || runDir == null || _shutterBusy || _finished) return;
    setState(() => _shutterBusy = true);
    final int n = _shots.length + 1;

    // ── 🔴 表 A:**拍之前**按臂做一次对焦 ────────────────────────────────
    //   A 直接拍(它本来就不动镜头,这正是对照的定义);
    //   B 触发一次 `.autoFocus` 等 `isAdjustingFocus` 落定(原生上限 2 s);
    //   C 调 `TriggerScan()` 等 Focused/Failed(原生上限 3 s)。
    //   上限在原生侧;这里的 `kZeroArkitProbeFocusHardCap` 只防「一直不落终态」
    //   把按钮卡死,不是判据。
    final Stopwatch focusSw = Stopwatch()..start();
    PwFocusPrepareState? prepare = PwFocus.prepareBegin();
    if (prepare != null) {
      PwFocusPrepareState cur = prepare;
      while (mounted &&
          !cur.isTerminal &&
          focusSw.elapsed < kZeroArkitProbeFocusHardCap) {
        await Future<void>.delayed(kZeroArkitProbeFocusPoll);
        cur = PwFocus.preparePoll() ?? PwFocusPrepareState.error;
      }
      prepare = cur;
    }
    focusSw.stop();
    _drainFocus();
    final PwFocusState? focusAtShutter = _focusState;
    _log('快门 #$n 对焦 臂=${_focusArm?.flag ?? '?'} '
        '状态=${prepare?.label ?? 'symbol_missing'} '
        '用时=${focusSw.elapsedMilliseconds}ms '
        'lens=${focusAtShutter?.lensPosition.toStringAsFixed(4) ?? '?'} '
        'fm=${focusAtShutter?.focusMeasure.toStringAsFixed(1) ?? '?'}');

    final ARPose? pose = provider.lastPose;
    final ARFrameSaveSpec spec = ARFrameSaveSpec(
      frameID: '$n',
      cellIndex: 0,
      slotIndex: n,
      jpegPath: '${runDir.path}/photo_$n.jpg',
      metadataPath: '${runDir.path}/photo_$n.json',
      targetTimestamp: pose?.timestamp,
    );
    final Stopwatch sw = Stopwatch()..start();
    ARFrameSaveResult r;
    try {
      await runDir.create(recursive: true);
      r = await provider.saveCurrentFrame(spec);
    } catch (e) {
      r = ARFrameSaveResult(spec: spec, status: 'exception', message: '$e');
    }
    final ZeroArkitProbeShot shot = ZeroArkitProbeShot(
      index: n,
      jpegPath: spec.jpegPath,
      metadataPath: spec.metadataPath,
      targetTimestamp: spec.targetTimestamp,
      status: r.status,
      message: r.message,
      elapsedMs: sw.elapsedMilliseconds,
      trackingStateAtTrigger: pose?.trackingStateName,
      isTrackingAtTrigger: pose?.isTracking ?? false,
      focusPrepareState: prepare?.label,
      focusPrepareMs: focusSw.elapsedMilliseconds.toDouble(),
      lensPositionAtShutter: focusAtShutter?.lensPosition,
      focusMeasureAtShutter: focusAtShutter?.focusMeasure,
      armStateAtShutter: focusAtShutter?.armState,
      isAdjustingFocusAtShutter: focusAtShutter?.isAdjustingFocus,
    );
    _shots.add(shot);
    // 拍完把臂放回常时状态:B 回 `.continuousAutoFocus`、C 回连续档,
    // 否则「拍一张之后 B 臂就锁在那一次的结果上」,与它的定义不符。
    PwFocus.prepareEnd();
    _log('快门 #$n status=${r.status} message=${r.message ?? '-'} '
        '用时=${sw.elapsedMilliseconds}ms state=${pose?.trackingStateName} '
        'tracking=${pose?.isTracking} target_t=${spec.targetTimestamp} '
        'jpeg=${spec.jpegPath}');
    if (mounted) setState(() => _shutterBusy = false);
  }

  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
    if (mounted && !_disposing) {
      setState(() {
        _running = false; // 先拆预览(走拆卸序),再停相机
        _phase = '收尾';
      });
    }
    await _poseSub?.cancel();
    _poseSub = null;
    _focusDrainTimer?.cancel();
    _focusDrainTimer = null;
    // 会话销毁 + 相机关。provider 没建起来时直接停相机。
    if (_provider != null) {
      await _provider!.stop();
    } else {
      _platform.stopCamera();
    }
    // 相机已关,把原生那边最后那一批对焦流水取空(stop() 不清序列,就是为了这个)。
    _drainFocus();
    final String? focusReport = PwFocus.reportJson();
    _pageClock.stop();
    _log('对焦收尾:臂=${_focusState?.arm?.label ?? '?'} '
        '流水=${_focusSeries.length} 条 '
        '(降采样后 ${downsampleFocusSeries(_focusSeries).length} 条)'
        ' 丢=${_focusState?.seriesDropped ?? 0}');
    _log('已停:owned=${_platform.cameraOwnedBySelfVio()} '
        'session=${XrslamSession.current == null ? 'null' : 'alive'}');

    final Directory? runDir = _runDir;
    if (runDir != null) {
      final Map<String, Object?> manifest = buildZeroArkitProbeManifest(
        runDir: runDir.path,
        hwMachine: _hwMachine,
        primedMachine: _primedMachine,
        runtimeStart: _provider?.runtimeStart,
        cameraRc: _cameraRc,
        cameraOwnedBySelfVio: _platform.cameraOwnedBySelfVio(),
        cameraSymbolFailure: _platform.symbolFailure,
        intrinsicsWaitMs: _intrinsicsWaitMs,
        capturedIntrinsics: _capturedIntrinsics,
        shots: _shots,
        trackingStateCounts: _stateCounts,
        trackingFrames: _trackingFrames,
        notTrackingFrames: _notTrackingFrames,
        confidenceTierCounts: _tierCounts,
        poseFrames: _poseFrames,
        pageDuration: _pageClock.elapsed,
        startedAtUtc: _startedAtUtc,
        finishedAtUtc: DateTime.now().toUtc(),
        engineUnavailableReason: _provider?.engineUnavailableReason,
        focusAvailable: PwFocus.available,
        focusStateAtFinish: _focusState,
        focusNativeReportJson: focusReport,
        focusSeries: _focusSeries,
      );
      try {
        await runDir.create(recursive: true);
        final File f = File('${runDir.path}/run_manifest.json');
        await f.writeAsString(
          const JsonEncoder.withIndent('  ').convert(manifest),
          flush: true,
        );
        _manifestPath = f.path;
        _log('manifest=${f.path} 帧=$_poseFrames tracking=$_trackingFrames/'
            '$_poseFrames 状态=$_stateCounts 档=$_tierCounts '
            '照片=$_savedCount/${_shots.length} 时长=${_pageClock.elapsed.inSeconds}s');
      } catch (e) {
        _log('🔴 manifest 写不出:$e');
      }
    }
    if (mounted && !_disposing) setState(() => _phase = '完成');
  }

  @override
  void dispose() {
    // 离开本页 = 完成。stop 幂等;provider 的 dispose 要等 stop 之后。
    _disposing = true;
    unawaited(_teardown());
    super.dispose();
  }

  Future<void> _teardown() async {
    await _finish();
    await _provider?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VioArPoseProvider? provider = _provider;
    final ZeroArkitCaptureRuntime? runtime = _runtime;
    final ZeroArkitStartResult? r = provider?.runtimeStart;
    final CameraTimeOffset? c = r?.cameraTimeOffset ?? runtime?.cameraTimeOffset;
    final ARPose? pose = _lastPose;
    final ZeroArkitProbeShot? last = _shots.isEmpty ? null : _shots.last;
    final PwFocusState? f = _focusState;
    // C 臂的 armState 是 PwAfState;A/B 臂是「是否在调焦」。分开显示,不混。
    const List<String> afStateNames = <String>[
      'Idle', 'Scanning', 'Focused', 'Failed',
    ];
    String armStateText() {
      if (f == null) return '-';
      if (f.arm == PwFocusArm.c) {
        return f.armState >= 0 && f.armState < afStateNames.length
            ? afStateNames[f.armState]
            : '${f.armState}';
      }
      return f.armState != 0 ? '调焦中' : '稳定';
    }

    final List<String> lines = <String>[
      '阶段:$_phase${_fatal == null ? '' : ' 🔴 $_fatal'}',
      '机型 ${_hwMachine ?? '?'}(prime=${_primedMachine ?? 'null'})'
          ' · ${c?.describe ?? 'c=?'}',
      '相机 rc=${_cameraRc ?? '?'} · 内参等待 ${_intrinsicsWaitMs ?? '?'}ms'
          ' · 会话 rc=${r?.cameraRc ?? '?'} ok=${r?.ok ?? '?'}'
          '${r?.error == null ? '' : ' err=${r!.error}'}',
      '状态 ${pose?.trackingStateName ?? '-'} · tracking=${pose?.isTracking ?? '-'}'
          ' · tier=${_confidence.tier.name}',
      '位姿帧 $_poseFrames(跟踪 $_trackingFrames)· 已存 $_savedCount/${_shots.length} 张',
      // ── 对焦三臂 ────────────────────────────────────────────────────
      f == null
          ? '对焦 🔴 pw_camera_slot_focus_* 符号不在(这条路没编进这个二进制)'
          : '对焦臂 ${f.arm?.flag ?? '?'}(${f.arm?.label ?? '?'})'
              ' 来源=${f.armSource.label}'
              ' · minFocusDist=${f.minimumFocusDistanceMm}mm'
              '${f.minimumFocusDistanceMm < 0 ? '(未知)' : ''}',
      if (f != null)
        '镜位 ${f.lensPosition.toStringAsFixed(4)}(0=最近)'
            ' · 度量 ${f.focusMeasure.toStringAsFixed(1)}'
            ' · adjusting=${f.isAdjustingFocus}'
            ' · 状态 ${armStateText()}',
      if (f != null)
        '快门对焦 ${f.prepareState.label} ${f.prepareElapsedMs.toStringAsFixed(0)}ms'
            ' · 流水 ${_focusSeries.length}+${f.seriesPending}'
            '${f.seriesDropped > 0 ? ' 🔴丢${f.seriesDropped}' : ''}'
            ' · ROI ${f.roiWidth}x${f.roiHeight}@${f.roiX},${f.roiY}',
      last == null
          ? '最近快门:-'
          : '最近快门 #${last.index}:${last.status}'
              '${last.message == null ? '' : ' ${last.message}'}',
      if (_manifestPath != null) 'manifest:$_manifestPath',
    ];

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontFamily: 'Menlo',
                  height: 1.35,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lines.map((String s) => Text(s)).toList(),
                ),
              ),
            ),
            // 与生产 CapturePreviewRect 同比:满宽 3:4。
            AspectRatio(
              aspectRatio: 3 / 4,
              child: (_running && runtime != null && provider != null)
                  ? ZeroArkitCameraPreview(
                      imageWidth: runtime.captureWidth,
                      imageHeight: runtime.captureHeight,
                      poseReader: () => provider.lastRendererPose,
                    )
                  : ColoredBox(
                      color: const Color(0xFF202020),
                      child: Center(
                        child: Text(
                          _finished ? '已完成,相机已关' : '预览未挂',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton(
                      onPressed: (_running && !_shutterBusy && !_finished)
                          ? _shutter
                          : null,
                      child: Text(_shutterBusy ? '拍摄中…' : '拍一张'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _finished ? null : _finish,
                      child: const Text('完成(关相机 + 写 manifest)'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
