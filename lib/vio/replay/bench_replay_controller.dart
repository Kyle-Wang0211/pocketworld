// bench_replay_controller.dart —— 台架回放的编排:选录制 → 按**产品的** yaml 生成器
// 写两份配置 → 交给原生回放器 → 轮询 → 写回执。
//
// 只给台架(arloopbench)用;生产里没有 import 者。本文件不碰 widget,原生库可注入
// (BenchReplayNative),所以 Mac 上的 flutter test 能原样驱动它(tool/bench/replay_mac/)。
//
// ══ 配置怎么来 —— 全部复用产品已有的规则,本文件不另算 ═════════════════════
//   · 两份 yaml:`XrslamConfigBuilder`(lib/vio/ffi/xrslam_config.dart)原样生成。
//       intrinsics = 录制 manifest 的 intrinsics(= 录制第 0 帧的 ARFrame.camera.intrinsics,
//                    BasaltVIOBench DeviceRecordingWriter 写的;Mac 宿主回放 A 臂的
//                    「yaml 常量 K = 第 0 帧冻结」也是这组数)
//       resolution = 录制的 camera.width × height(**录多少喂多少**,不缩放)
//       extrinsic  = `CameraImuExtrinsic.forIosMachine(录制机型)` —— 与生产 ARKit 影子
//                    通路 `vio_diagnostics_recorder.dart:856-867` 同一个调用。
//                    🔴 零 ARKit ON 臂的 `XrslamSession.start` 用的是 `XrslamConfigBuilder
//                    (intrinsics: k)` 的默认外参 `iosPlaceholder`(单位四元数),而
//                    xrslam_config.dart:283-289 自己写着「真机实测那样喂 5731 帧一个位姿
//                    都出不来」;回放不照抄那一处,走查表(回执里 provenance 如实写)。
//   · c(相机时间戳常量):`resolveCameraTimeOffset(machine: 录制机型, overrideMillisRaw:
//     -PWBenchReplayCameraTimeOffsetMs)`(lib/vio/capture/camera_time_offset.dart)。
//     与 ON 臂一样,c 交给原生 create(传输层施加),yaml 里的 time_offset 保持生成器默认。
//   · 逐帧 K 开关:`-PWPerFrameIntrinsics on|off`,原生 PwXrslamLive 自己读(进程级,
//     启动参数定,页面改不了);回执里记原生报的解析结果。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../capture/camera_time_offset.dart';
import '../ffi/xrslam_config.dart';
import '../ffi/xrslam_official_feed.dart';
import '../ffi/xrslam_live_ffi.dart' show XrslamLiveIntrinsics;
import 'bench_replay_native.dart';

/// 回执 schema。
const String kBenchReplayReceiptSchema = 'pw.bench.replay-receipt/1';

/// ASCII 标记:进页面、进回执。构建后自检用它在 Dart AOT 里找「这一页在不在」
/// (中文串在 AOT 里是 UTF-16,grep 不到)。
const String kBenchReplayMarker = 'PW_BENCH_REPLAY_PAGE_V1';

/// 录制放在 App 容器 `Documents/<这个目录>/<run-…>/`(tool/bench/push_replay_recording.sh 推进来)。
const String kBenchReplayRecordingsDir = 'replay_recordings';

/// 每次回放的输出目录的父目录(tool/bench/pull_bench_replay_run.sh 从这里拉)。
const String kBenchReplayRunsDir = 'bench_replay_runs';

const List<String> kBenchReplayPaces = <String>['paced', 'max', 'paced-live-drop'];

/// 启动参数(原生读出来的原文)解析成的选择。纯数据,可单测。
class BenchReplayArgs {
  const BenchReplayArgs({
    this.recording,
    this.autoStart = false,
    this.pace = 'paced',
    this.tag,
    this.allowLossy = false,
    this.ignoreExposure = false,
    this.limitFrames = 0,
    this.cameraTimeOffsetMsRaw,
    this.verifyFramesDigest = false,
    this.perFrameIntrinsicsEnabled = true,
    this.perFrameIntrinsicsSource = 0,
    this.perFrameIntrinsicsRaw = '',
    this.exposureMidEnabled = true,
    this.exposureMidSource = 'default',
    this.exposureMidRaw = '',
    this.yamlOverrides = const <String>[],
    this.problems = const <String>[],
  });

  final String? recording;
  final bool autoStart;
  final String pace;
  final String? tag;
  final bool allowLossy;
  final bool ignoreExposure;
  final int limitFrames;
  final String? cameraTimeOffsetMsRaw;
  final bool verifyFramesDigest;

  /// 原生 `PwPerFrameIntrinsicsSwitch.resolved`(0 默认 / 1 启动参数 / 2 解析不了)。
  final bool perFrameIntrinsicsEnabled;
  final int perFrameIntrinsicsSource;
  final String perFrameIntrinsicsRaw;

  /// [bench 2026-09-25] 原生 `PwXrslamOfficialFeed.resolved` 的曝光中点开关(台架默认 on;
  /// `-PWXrslamExposureMid off` 退回原始 PTS)。只在原生解析一处,这里原样取。
  /// on ⇒ c 默认按录制机型查表;off ⇒ c 默认官方 0。`-PWBenchReplayCameraTimeOffsetMs` 两种情况下都能覆盖。
  /// 缺这个键(旧原生)⇒ 按台架默认 on。
  final bool exposureMidEnabled;
  final String exposureMidSource;
  final String exposureMidRaw;

  /// `-PWYamlOverride <section>.<key>=<value>`(可重复,按 argv 顺序)。见 [applyYamlOverrides]。
  final List<String> yamlOverrides;

  /// 解析不了的参数(不静默吞,进页面与回执)。
  final List<String> problems;

  /// 布尔读法与 `PwPerFrameIntrinsicsSwitch`(PwXrslamLive.swift:155-162)同一张表。
  static bool? parseBool(String? raw) {
    if (raw == null) return null;
    final String v = raw.trim().toLowerCase();
    if (const <String>['on', '1', 'true', 'yes'].contains(v)) return true;
    if (const <String>['off', '0', 'false', 'no'].contains(v)) return false;
    return null;
  }

  static BenchReplayArgs fromLaunchJson(Map<String, Object?> j) {
    final List<String> problems = <String>[];
    String? str(String k) {
      final Object? v = j[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    bool boolArg(String k, bool dflt) {
      final String? raw = str(k);
      if (raw == null) return dflt;
      final bool? b = parseBool(raw);
      if (b == null) problems.add('-$k "$raw" 解析不了 ⇒ 按 $dflt');
      return b ?? dflt;
    }

    final String? recording = str('PWBenchReplayRecording');
    String pace = str('PWBenchReplayPace') ?? 'paced';
    if (!kBenchReplayPaces.contains(pace)) {
      problems.add('-PWBenchReplayPace "$pace" 不认识 ⇒ 按 paced');
      pace = 'paced';
    }
    int limit = 0;
    final String? limitRaw = str('PWBenchReplayLimitFrames');
    if (limitRaw != null) {
      final int? n = int.tryParse(limitRaw);
      if (n == null || n < 0) {
        problems.add('-PWBenchReplayLimitFrames "$limitRaw" 解析不了 ⇒ 全部帧');
      } else {
        limit = n;
      }
    }
    final Object? ovr = j['PWYamlOverride'];
    final List<String> overrides = ovr is List
        ? ovr.whereType<String>().where((String v) => v.trim().isNotEmpty).toList()
        : const <String>[];
    final Object? sw = j['PWPerFrameIntrinsics'];
    final Map<String, Object?> swm =
        sw is Map<String, Object?> ? sw : const <String, Object?>{};
    final Object? em = j['PWXrslamExposureMid'];
    final Map<String, Object?> emm =
        em is Map<String, Object?> ? em : const <String, Object?>{};
    return BenchReplayArgs(
      recording: recording,
      autoStart: boolArg('PWBenchReplayAutoStart', recording != null),
      pace: pace,
      tag: str('PWBenchReplayTag'),
      allowLossy: boolArg('PWBenchReplayAllowLossy', false),
      ignoreExposure: boolArg('PWBenchReplayIgnoreExposure', false),
      limitFrames: limit,
      cameraTimeOffsetMsRaw: str('PWBenchReplayCameraTimeOffsetMs'),
      verifyFramesDigest: boolArg('PWBenchReplayVerifyDigest', false),
      perFrameIntrinsicsEnabled: swm['enabled'] != false,
      perFrameIntrinsicsSource: (swm['source'] as num?)?.toInt() ?? 0,
      perFrameIntrinsicsRaw: (swm['raw'] as String?) ?? '',
      exposureMidEnabled: emm['enabled'] != false,
      exposureMidSource: (emm['source'] as String?) ?? 'default',
      exposureMidRaw: (emm['raw'] as String?) ?? '',
      yamlOverrides: List<String>.unmodifiable(overrides),
      problems: List<String>.unmodifiable(problems),
    );
  }

  BenchReplayArgs copyWith({
    String? pace,
    bool? allowLossy,
    bool? ignoreExposure,
    int? limitFrames,
  }) =>
      BenchReplayArgs(
        recording: recording,
        autoStart: autoStart,
        pace: pace ?? this.pace,
        tag: tag,
        allowLossy: allowLossy ?? this.allowLossy,
        ignoreExposure: ignoreExposure ?? this.ignoreExposure,
        limitFrames: limitFrames ?? this.limitFrames,
        cameraTimeOffsetMsRaw: cameraTimeOffsetMsRaw,
        verifyFramesDigest: verifyFramesDigest,
        perFrameIntrinsicsEnabled: perFrameIntrinsicsEnabled,
        perFrameIntrinsicsSource: perFrameIntrinsicsSource,
        perFrameIntrinsicsRaw: perFrameIntrinsicsRaw,
        exposureMidEnabled: exposureMidEnabled,
        exposureMidSource: exposureMidSource,
        exposureMidRaw: exposureMidRaw,
        yamlOverrides: yamlOverrides,
        problems: problems,
      );

  String get perFrameArmLabel =>
      perFrameIntrinsicsEnabled ? 'pfk-on' : 'pfk-off';
}

/// 一份录制的只读摘要(原生 inspect 的结果)。
class BenchReplayRecording {
  const BenchReplayRecording({
    required this.dirName,
    required this.path,
    required this.inspect,
  });

  final String dirName;
  final String path;
  final Map<String, Object?> inspect;

  bool get ok => inspect['ok'] == true;
  String? get error => inspect['error'] as String?;
  String get recordingId => (inspect['recording_id'] as String?) ?? dirName;
  String get shortId =>
      recordingId.length >= 8 ? recordingId.substring(0, 8) : recordingId;
  Map<String, Object?> get _camera =>
      (inspect['camera'] as Map<String, Object?>?) ?? const <String, Object?>{};
  int get width => (_camera['width'] as num?)?.toInt() ?? 0;
  int get height => (_camera['height'] as num?)?.toInt() ?? 0;
  int get frameCount => (inspect['frame_count'] as num?)?.toInt() ?? 0;
  int get lossCount => (inspect['loss_count'] as num?)?.toInt() ?? 0;
  String? get deviceModel => inspect['device_model'] as String?;
  bool get verdictResolution => width == 1920 && height == 1440;

  /// manifest 的 intrinsics(= 第 0 帧 K)。
  List<double>? get manifestK {
    final Object? m = inspect['manifest_intrinsics'];
    if (m is! Map<String, Object?>) return null;
    final List<double> k = <double>[];
    for (final String key in const <String>['fx', 'fy', 'cx', 'cy']) {
      final Object? v = m[key];
      if (v is! num) return null;
      k.add(v.toDouble());
    }
    return k;
  }

  String describe() => ok
      ? '$dirName  ${width}x$height  帧=$frameCount  loss=$lossCount  '
          '机型=${deviceModel ?? "?"}'
      : '$dirName  🔴 $error';
}

/// 开跑前决定好的一切。回执里原样写出。
class BenchReplayPlan {
  BenchReplayPlan({
    required this.recording,
    required this.args,
    required this.runDir,
    required this.slamConfigPath,
    required this.deviceConfigPath,
    required this.builder,
    required this.cameraTimeOffset,
    this.yamlOverridesApplied = const <Map<String, Object?>>[],
  });

  final BenchReplayRecording recording;
  final BenchReplayArgs args;
  final Directory runDir;
  final String slamConfigPath;
  final String deviceConfigPath;
  final XrslamConfigBuilder builder;
  final CameraTimeOffset cameraTimeOffset;

  /// [applyYamlOverrides] 的逐条结果(replaced / inserted)。
  final List<Map<String, Object?>> yamlOverridesApplied;

  Map<String, Object?> nativeConfig() => <String, Object?>{
        'recording_dir': recording.path,
        'out_dir': runDir.path,
        'slam_config_path': slamConfigPath,
        'device_config_path': deviceConfigPath,
        'camera_time_offset_s': cameraTimeOffset.seconds,
        'pace': args.pace,
        'allow_lossy': args.allowLossy,
        'ignore_exposure': args.ignoreExposure,
        'limit_frames': args.limitFrames,
        'verify_frames_digest': args.verifyFramesDigest,
      };
}

/// 一次回放的结果。
class BenchReplayResult {
  const BenchReplayResult({
    required this.ok,
    required this.runDir,
    required this.receiptPath,
    required this.receipt,
    this.error,
  });

  final bool ok;
  final Directory runDir;
  final String? receiptPath;
  final Map<String, Object?> receipt;
  final String? error;
}

class BenchReplayController {
  BenchReplayController({
    required this.native,
    required this.documents,
    DateTime Function()? now,
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _now = now ?? DateTime.now;

  final BenchReplayNative native;
  final Directory documents;
  final DateTime Function() _now;
  final Duration pollInterval;

  Directory get recordingsRoot =>
      Directory('${documents.path}/$kBenchReplayRecordingsDir');
  Directory get runsRoot => Directory('${documents.path}/$kBenchReplayRunsDir');

  BenchReplayArgs launchArgs() =>
      BenchReplayArgs.fromLaunchJson(native.launchArgs());

  /// `Documents/replay_recordings/` 下每个含 recording_manifest.json 的目录。
  List<BenchReplayRecording> listRecordings() {
    final Directory root = recordingsRoot;
    if (!root.existsSync()) return const <BenchReplayRecording>[];
    final List<Directory> dirs = root
        .listSync(followLinks: true)
        .whereType<Directory>()
        .where((Directory d) =>
            File('${d.path}/recording_manifest.json').existsSync())
        .toList()
      ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
    return dirs
        .map((Directory d) => BenchReplayRecording(
              dirName: d.uri.pathSegments.where((String s) => s.isNotEmpty).last,
              path: d.path,
              inspect: native.inspect(d.path),
            ))
        .toList(growable: false);
  }

  /// 按启动参数选录制:目录名全等优先,否则「目录名或录制 id 以它开头」且唯一。
  static BenchReplayRecording? resolve(
      List<BenchReplayRecording> all, String token,
      {List<String>? why}) {
    for (final BenchReplayRecording r in all) {
      if (r.dirName == token) return r;
    }
    final String t = token.startsWith('run-') ? token.substring(4) : token;
    final List<BenchReplayRecording> hits = all
        .where((BenchReplayRecording r) =>
            r.dirName.startsWith(token) ||
            r.dirName.startsWith('run-$t') ||
            r.recordingId.startsWith(t))
        .toList();
    if (hits.length == 1) return hits.single;
    why?.add(hits.isEmpty
        ? '没有录制匹配「$token」'
        : '「$token」匹配到 ${hits.length} 份录制,不猜:'
            '${hits.map((BenchReplayRecording r) => r.dirName).join(", ")}');
    return null;
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// 输出目录名:`replay_<录制前 8 位>_<pfk-on|pfk-off>_<节拍>_<时间>[_<标签>]`。
  static String runDirName(BenchReplayRecording r, BenchReplayArgs a, DateTime t) {
    final String tag = a.tag == null
        ? ''
        : '_${a.tag!.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-')}';
    return 'replay_${r.shortId}_${a.perFrameArmLabel}_${a.pace}_${_stamp(t)}$tag';
  }

  /// 建输出目录、按产品生成器写两份 yaml。不碰原生会话。
  BenchReplayPlan plan(BenchReplayRecording r, BenchReplayArgs a) =>
      planReplay(runsRoot: runsRoot, recording: r, args: a, now: _now());

  /// [plan] 的纯文件系统部分(不需要原生库,可单测)。
  static BenchReplayPlan planReplay({
    required Directory runsRoot,
    required BenchReplayRecording recording,
    required BenchReplayArgs args,
    required DateTime now,
  }) {
    final BenchReplayRecording r = recording;
    final BenchReplayArgs a = args;
    if (!r.ok) {
      throw StateError('录制不可用:${r.error}');
    }
    final List<double>? k = r.manifestK;
    if (k == null || r.width <= 0 || r.height <= 0) {
      throw StateError('录制 manifest 缺 intrinsics 或尺寸');
    }
    final CameraIntrinsics intrinsics = CameraIntrinsics(
      fx: k[0],
      fy: k[1],
      cx: k[2],
      cy: k[3],
      resolutionWidth: r.width,
      resolutionHeight: r.height,
      provenance: FieldProvenance.deviceApi,
    );
    // [bench 2026-09-24] 官方配置口径:device yaml 写 640×480 + box/3 换算的内参(原生照 yaml 做
    //   同一个 box,见 xrslam_official_feed.dart)。
    // [bench 2026-09-25] c 跟着曝光中点开关走(台架默认 on,规则 t_feed = PTS + exposure/2 + c,
    //   c ≈ readout/2,Huai arXiv 2001.00470 §IV.B,09-22 定案):
    //   on  ⇒ 按录制机型查表(camera_time_offset.dart,iPhone15,2 = 3.00 ms 实测);
    //   off ⇒ 官方 0(每机 yaml `time_offset: 0.0`,原始 PTS)。
    //   -PWBenchReplayCameraTimeOffsetMs 两种情况下都能覆盖。
    //   证据(真机回放 run-13f53d2f,on + 2.65 ms):XRSLAM/ARKit 0.963 → 1.0022,ATE 5.4 → 1.79 cm。
    final XrslamConfigBuilder builder = XrslamConfigBuilder(
      intrinsics: xrslamOfficialFeedIntrinsics(intrinsics),
      extrinsic: CameraImuExtrinsic.forIosMachine(r.deviceModel),
    );
    final CameraTimeOffset c = a.cameraTimeOffsetMsRaw != null
        ? resolveCameraTimeOffset(
            machine: r.deviceModel,
            overrideMillisRaw: a.cameraTimeOffsetMsRaw,
          )
        : a.exposureMidEnabled
            ? resolveCameraTimeOffset(machine: r.deviceModel)
            : CameraTimeOffset(
                seconds: 0.0,
                provenance: FieldProvenance.sharedDefault,
                machine: r.deviceModel,
                note: '-PWXrslamExposureMid off ⇒ 官方 iOS 配置 time_offset: 0.0'
                    '(slam_params + 每机 yaml),原始 PTS',
              );
    final Directory runDir =
        Directory('${runsRoot.path}/${runDirName(r, a, now)}')
          ..createSync(recursive: true);
    final YamlOverrideResult ovr =
        applyYamlOverrides(builder.buildSlamConfigYaml(), a.yamlOverrides);
    if (ovr.errors.isNotEmpty) {
      runDir.deleteSync(recursive: true);
      throw StateError('-PWYamlOverride 拒收:${ovr.errors.join(';')}');
    }
    final File slam = File('${runDir.path}/slam_config.yaml')
      ..writeAsStringSync(ovr.text, flush: true);
    final File dev = File('${runDir.path}/device_config.yaml')
      ..writeAsStringSync(builder.buildDeviceConfigYaml(), flush: true);
    // 引擎读不到 yaml 是 abort 不是错误码(xrslam_session.dart 文件头 ①)⇒ 先核一次。
    if (!slam.existsSync() || !dev.existsSync()) {
      throw StateError('yaml 写了但读不到:${slam.path} / ${dev.path}');
    }
    return BenchReplayPlan(
      recording: r,
      args: a,
      runDir: runDir,
      slamConfigPath: slam.path,
      deviceConfigPath: dev.path,
      builder: builder,
      cameraTimeOffset: c,
      yamlOverridesApplied: ovr.applied,
    );
  }

  /// 开跑、轮询到终态、写回执。[onStatus] 每次轮询回调一次(给页面画进度)。
  Future<BenchReplayResult> run(
    BenchReplayPlan p, {
    void Function(Map<String, Object?> status)? onStatus,
  }) async {
    final DateTime startedAt = _now().toUtc();
    final int rc = native.start(p.nativeConfig());
    if (rc != 0) {
      final String err = rc == -1 ? '原生回放器正在跑另一场' : '原生拒收配置 rc=$rc';
      final Map<String, Object?> receipt =
          buildReceipt(p, <String, Object?>{'phase': 'failed', 'error': err},
              startedAt: startedAt, endedAt: _now().toUtc());
      final String path = _writeReceipt(p, receipt);
      return BenchReplayResult(
          ok: false, runDir: p.runDir, receiptPath: path, receipt: receipt, error: err);
    }
    Map<String, Object?> st;
    while (true) {
      await Future<void>.delayed(pollInterval);
      st = native.status();
      onStatus?.call(st);
      final Object? phase = st['phase'];
      if (phase == 'done' || phase == 'failed') break;
    }
    final Map<String, Object?> receipt =
        buildReceipt(p, st, startedAt: startedAt, endedAt: _now().toUtc());
    final String path = _writeReceipt(p, receipt);
    final bool ok = st['phase'] == 'done' &&
        ((receipt['invariants'] as Map<String, Object?>?)?['passed'] == true);
    return BenchReplayResult(
      ok: ok,
      runDir: p.runDir,
      receiptPath: path,
      receipt: receipt,
      error: st['error'] as String?,
    );
  }

  String _writeReceipt(BenchReplayPlan p, Map<String, Object?> receipt) {
    final File f = File('${p.runDir.path}/receipt.json');
    f.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(receipt), flush: true);
    return f.path;
  }

  /// 回执。**纯函数**(给定 plan 与原生终态),可单测。
  static Map<String, Object?> buildReceipt(
    BenchReplayPlan p,
    Map<String, Object?> status, {
    required DateTime startedAt,
    required DateTime endedAt,
  }) {
    final Map<String, Object?> s =
        (status['summary'] as Map<String, Object?>?) ?? const <String, Object?>{};
    final Map<String, Object?> cfg =
        (s['config'] as Map<String, Object?>?) ?? const <String, Object?>{};
    final Object? ikWire = s['intrinsics_report'];
    XrslamLiveIntrinsics? ik;
    if (ikWire is List && s['intrinsics_report_rc'] == 0) {
      ik = XrslamLiveIntrinsics.fromWire(
          ikWire.map((Object? v) => (v as num?)?.toDouble() ?? double.nan).toList());
    }
    final Map<String, Object?> sw =
        (s['per_frame_intrinsics_switch'] as Map<String, Object?>?) ??
            <String, Object?>{
              'enabled': p.args.perFrameIntrinsicsEnabled,
              'source': p.args.perFrameIntrinsicsSource,
              'raw': p.args.perFrameIntrinsicsRaw,
            };
    final CameraImuExtrinsic ext = p.builder.extrinsic;
    final BenchReplayRecording r = p.recording;
    return <String, Object?>{
      'schema': kBenchReplayReceiptSchema,
      'marker': kBenchReplayMarker,
      'bundle': 'com.kyle.arloopbench',
      'run_dir_name': p.runDir.uri.pathSegments
          .where((String x) => x.isNotEmpty)
          .last,
      'started_at_utc': startedAt.toIso8601String(),
      'ended_at_utc': endedAt.toIso8601String(),
      'phase': status['phase'],
      if (status['error'] != null) 'error': status['error'],
      'recording': <String, Object?>{
        'recording_id': r.recordingId,
        'dir_name': r.dirName,
        'device_model': r.deviceModel,
        'device_model_source': r.inspect['device_model_source'],
        'manifest_sha256': r.inspect['manifest_sha256'],
        'frames_digest_sha256': r.inspect['frames_digest_sha256'],
        'camera': r.inspect['camera'],
        'frame_count': r.frameCount,
        'loss_count': r.lossCount,
        'load_report': s['load_report'] ?? r.inspect['load_report'],
      },
      'feed_resolution': <String, Object?>{
        'width': r.width,
        'height': r.height,
        'downscaled': false,
        'at_or_above_1920x1440': r.width >= 1920 && r.height >= 1440,
        'note': r.verdictResolution
            ? '录制即 1920×1440,原样喂'
            : '🔴 录制是 ${r.width}×${r.height},原样喂(不放大不缩小);'
                '低于 1920×1440 的场次不能代表出货分辨率',
      },
      'switches': <String, Object?>{
        'per_frame_intrinsics': sw,
        'arm_label': (sw['enabled'] == false) ? 'pfk-off' : 'pfk-on',
        'pace': p.args.pace,
        'allow_lossy': p.args.allowLossy,
        'ignore_exposure': p.args.ignoreExposure,
        'limit_frames': p.args.limitFrames,
        'verify_frames_digest': p.args.verifyFramesDigest,
        'tag': p.args.tag,
        'launch_arg_problems': p.args.problems,
      },
      'config': <String, Object?>{
        'slam_config': 'slam_config.yaml',
        'device_config': 'device_config.yaml',
        'slam_config_sha256': cfg['slam_config_sha256'],
        'device_config_sha256': cfg['device_config_sha256'],
        'effective_config_sha256': cfg['effective_config_sha256'],
        'generator': 'lib/vio/ffi/xrslam_config.dart XrslamConfigBuilder',
        'provenance': p.builder.provenanceReport(),
        'yaml_overrides': p.yamlOverridesApplied,
        'solver_time_budget': solverBudgetSummary(
            File(p.slamConfigPath).existsSync()
                ? File(p.slamConfigPath).readAsStringSync()
                : ''),
        'has_placeholders': p.builder.hasPlaceholders,
        'extrinsic': <String, Object?>{
          'q_bc': ext.qbc,
          'p_bc': ext.pbc,
          'provenance': ext.provenance.label,
          'rule': 'CameraImuExtrinsic.forIosMachine(录制机型)',
        },
        'camera_time_offset': <String, Object?>{
          'seconds': p.cameraTimeOffset.seconds,
          'milliseconds': p.cameraTimeOffset.milliseconds,
          'provenance': p.cameraTimeOffset.provenance.label,
          'machine': p.cameraTimeOffset.machine,
          'note': p.cameraTimeOffset.note,
          'applied_by': 'PWXrslamTransportCreateWithCameraTimeOffset(与 ON 臂同)',
        },
        // [bench 2026-09-25] 曝光中点开关(台架默认 on)。原生回执 xrslam_feed 里有同一份解析结果
        //   与本场实际加上的 exposure/2 均值。
        'exposure_mid': <String, Object?>{
          'enabled': p.args.exposureMidEnabled,
          'source': p.args.exposureMidSource,
          'raw': p.args.exposureMidRaw,
          'bench_default': true,
          'rule': p.args.exposureMidEnabled
              ? 't_feed = pts + exposure/2 + c(Huai arXiv 2001.00470 §IV.B,09-22 定案)'
              : 't_feed = pts + c(原始 PTS,-PWXrslamExposureMid off)',
        },
      },
      'engine': <String, Object?>{
        'info_plist': s['engine_identity_info_plist'],
        'identity_source': 'Info.plist(由 stamp_bench_engine_identity.sh 在 Release 构建时'
            '按 ios/scripts/stamp_runtime_identity.sh 的臂表与二进制指纹核对后盖章)',
        'gpu_frontend_trail': s['gpu_frontend_trail'],
        'telemetry_symbols_found': s['telemetry_symbols_found'],
      },
      'per_frame_intrinsics': ik?.toJson(),
      'transport_stats': s['transport_stats'],
      'timebase': s['timebase'],
      'feeding': s['feeding'],
      'thermal_state': s['thermal_state'],
      'device': s['device'],
      'launch_arguments': s['launch_arguments'],
      'outputs': s['outputs'],
      'native_summary_file': 'replay_native_summary.json',
      'invariants': s['invariants'] ??
          <String, Object?>{
            'passed': false,
            'failed': <String>['no_native_summary'],
          },
    };
  }
}

/// [applyYamlOverrides] 的结果。
class YamlOverrideResult {
  const YamlOverrideResult(this.text, this.applied, this.errors);
  final String text;
  final List<Map<String, Object?>> applied;
  final List<String> errors;
}

/// `-PWYamlOverride <section>.<key>=<value>` 的白名单节(逐字抄 BasaltVIOBench
/// `BenchmarkRunPreparation.swift:190-191`;`solver` 是 2026-09-16 加进去的那一节)。
const List<String> kYamlOverrideSections = <String>[
  'feature_tracker', 'sliding_window', 'solver', 'initializer', 'rotation', 'parsac',
];

/// 允许**插入**的键(源只许替换已有键,:202 找不到就 preconditionFailure)。
/// 产品生成器的 slam yaml 里没有这两个键,而时间预算引擎(xrslam fork
/// feat/solver-time-budget @b0937ef,yaml_config.cpp:347-355)对它们是「缺键 = 关」
/// ⇒ 只有这两个可以补进去,其余键仍然只许替换。
const List<String> kYamlOverrideInsertableKeys = <String>[
  'solver.frame_time_budget', 'solver.min_iterations',
];

/// 按源的算法改 slam yaml 的一个标量键(源 `BenchmarkRunPreparation.swift:157-211`):
/// 顶格且以 `:` 结尾的行是节头;在目标节里第一条 `key:` 开头的行整行换成
/// 「原缩进 + key: value」。与源的差别只有两处:
///   ① 找不到时,若在 [kYamlOverrideInsertableKeys] 里就插在节头下一行(两格缩进,
///      与生成器同一缩进),否则记错误 —— 源是 preconditionFailure(整个 App 崩),
///      台架改成拒绝开跑并把原因写出来;
///   ② 节不在白名单同样记错误而不是崩。
/// 回执里 config sha 随之改变,所以每一场都自带「跑的是什么」(源 :154-156 的理由)。
YamlOverrideResult applyYamlOverrides(String text, List<String> overrides) {
  final List<Map<String, Object?>> applied = <Map<String, Object?>>[];
  final List<String> errors = <String>[];
  List<String> lines = text.split('\n');
  for (final String arg in overrides) {
    final int eq = arg.indexOf('=');
    final int dot = arg.indexOf('.');
    if (eq < 0 || dot < 0 || dot > eq) {
      errors.add('「$arg」不是 <section>.<key>=<value>');
      continue;
    }
    final String section = arg.substring(0, dot);
    final String key = arg.substring(dot + 1, eq);
    final String value = arg.substring(eq + 1);
    if (!kYamlOverrideSections.contains(section)) {
      errors.add('节 $section 不在白名单 $kYamlOverrideSections');
      continue;
    }
    bool inSection = false;
    int? header;
    bool replaced = false;
    for (int n = 0; n < lines.length; n++) {
      final String line = lines[n];
      final String trimmed = line.trim();
      if (!line.startsWith(' ') && trimmed.endsWith(':')) {
        inSection = trimmed == '$section:';
        if (inSection) header = n;
        continue;
      }
      if (inSection && trimmed.startsWith('$key:')) {
        final String indent = line.substring(0, line.length - line.trimLeft().length);
        lines[n] = '$indent$key: $value';
        replaced = true;
        break;
      }
    }
    if (replaced) {
      applied.add(<String, Object?>{
        'arg': arg, 'section': section, 'key': key, 'value': value, 'action': 'replaced',
      });
    } else if (header != null && kYamlOverrideInsertableKeys.contains('$section.$key')) {
      lines = <String>[
        ...lines.sublist(0, header + 1),
        '  $key: $value',
        ...lines.sublist(header + 1),
      ];
      applied.add(<String, Object?>{
        'arg': arg, 'section': section, 'key': key, 'value': value, 'action': 'inserted',
      });
    } else {
      errors.add('$section.$key 在生成的 slam yaml 里找不到'
          '${header == null ? '(连节 $section 都没有)' : ''},且不在可插入名单 '
          '$kYamlOverrideInsertableKeys');
    }
  }
  return YamlOverrideResult(lines.join('\n'), applied, errors);
}

/// 回执用:这一场 slam yaml 里时间预算两键的**生效值**。缺键 ⇒ 引擎默认
/// (fork b0937ef config.cpp:65-70:frame_time_budget −1 = 关,min_iterations 3)。
Map<String, Object?> solverBudgetSummary(String slamYaml) {
  String? find(String key) {
    bool inSolver = false;
    for (final String line in slamYaml.split('\n')) {
      final String t = line.trim();
      if (!line.startsWith(' ') && t.endsWith(':')) {
        inSolver = t == 'solver:';
        continue;
      }
      if (inSolver && t.startsWith('$key:')) {
        return t.substring(key.length + 1).trim();
      }
    }
    return null;
  }

  final String? budget = find('frame_time_budget');
  final String? minIt = find('min_iterations');
  final double? b = budget == null ? null : double.tryParse(budget);
  return <String, Object?>{
    'frame_time_budget': budget,
    'min_iterations': minIt,
    'frame_time_budget_effective_s': b ?? -1.0,
    'budget_on': b != null && b >= 0,
    'note': budget == null
        ? '键不在 ⇒ 引擎默认 −1(关);只有时间预算引擎(b0937ef 起)认这两个键,'
            '别的臂 yaml-cpp 读不到也不报错'
        : '显式设置;只有时间预算引擎认,别的臂忽略',
  };
}
