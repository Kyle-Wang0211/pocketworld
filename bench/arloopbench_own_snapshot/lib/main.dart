// arloopbench —— 台架(一个包,所有台架功能)。
//
// 🔴 这是**台架**,不是生产。生产的 PocketWorld 一个字节都不碰。
// 等到 XRSLAM 在精度/稳定性上跟 ARKit 持平或更好,再谈上生产。
//
// [2026-09-24 合一] 手机上原来有三款台架(arloopbench / VIO Replacement Bench / PWSplatAB),
//   现在只装这一个:首页是菜单(lib/bench_unified/bench_home_page.dart),下面 _entries() 列出全部功能,
//   每一页都编进包里、运行期可达(装机前用 strings 核类名,见 ~/Developer/arloopbench_builds/unified_*/VERIFY.txt)。
//   启动参数:-PWBenchPage <id> 直开某一项;旧的 -PWBenchReplayRecording / -PWLodCapture -PWLodAuto /
//   -PWMode(PWSplatAB)/ -PWAutoRun(VIO Replacement Bench)照旧可用,见 bench_home_page.dart 文件头。
//   `lib/vio/**`、`lib/bench_*/**`、`lib/bench_unified/**` 是 pocketworld bench/unified 的**镜像**
//   (.sync_from_integration.sh 同步并自证逐字节一致);本文件是台架自己的,不在镜像范围。
//
// --dart-define 旧开关(都改成 const 了;没有 define 的包 = 菜单):
//   PW_FULL_CHAIN_BENCH=true  启动即跑生产 168 main()(与 -PWBenchPage fullchain 等价,旧包兼容)。
//   PW_LIDAR_RULER_BENCH / PW_LOD_BENCH / PW_BENCH_REPLAY / PW_ZERO_ARKIT_CAPTURE / PW_ZERO_ARKIT_PREVIEW /
//   PW_IMU_CALIB / PW_ZUPT / PW_POSE_CHAIN  启动即进该页(旧包兼容)。
//   🔴 bool.fromEnvironment 只有 const 调用在 AOT(profile/release)里生效。这些分支原先有 7 个没带 const,
//   profile 包里被静默忽略(2026-09-24 LOD 那次实测:带不带 define 编出的 app.dill 逐字节相同)。

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
// [2026-09-24 完整重建链 168] 生产入口本身(pocketworld_flutter 包 = 生产 lib/ 原样,见 pubspec)。
import 'package:pocketworld_flutter/main.dart' as pw168;

// [2026-09-24 LiDAR 米尺录制] 🔴 bench-only ruler:LiDAR 只在台架里当研发期米尺,永不进产品。
import 'bench_lidar/bench_lidar_record_page.dart';
import 'bench_splat/splat_ab_page.dart';
import 'bench_unified/bench_core_switches_page.dart';
import 'bench_unified/bench_full_chain_page.dart';
import 'bench_unified/bench_home_page.dart';
import 'bench_unified/bench_unified_native.dart';
import 'point_cloud_lod/lod_debug_page.dart';
import 'vio/calib/imu_calib_capture_page.dart';
import 'vio/render/ar_minimal_loop_page.dart';
import 'vio/render/bench_replay_page.dart';
import 'vio/render/pose_chain_probe_page.dart';
import 'vio/render/zupt_probe_page.dart';
import 'vio/render/zero_arkit_preview_probe_page.dart';
import 'vio/render/zero_arkit_capture_probe_page.dart';

// 🔴 [2026-09-22 用户原话「拍摄页面竟然可以反转成横向?锁死竖向屏幕」]
// 台架所有探针页都按竖屏算 3:4 框与 displayRotation=0,横过来预览与内参
// 口径就对不上。锁法照 Flutter 官方 SystemChrome.setPreferredOrientations
// 文档示例,并把 Info.plist 的 UISupportedInterfaceOrientations 只留 Portrait。
void main() {
  // [2026-09-24 完整重建链 168] 旧 define 包:启动即跑生产 168 的 main(),放在任何 ensureInitialized 之前
  //   (生产要求 ensureInitialized 与 runApp 在它自己的 zone 里)。
  if (const bool.fromEnvironment('PW_FULL_CHAIN_BENCH')) {
    unawaited(pw168.main());
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_start());
}

Future<void> _start() async {
  // -PWBenchPage fullchain:启动即进生产流程(自动化用)。菜单里的「进入」走同一个函数。
  //   这里 binding 已在台架 zone 里初始化;生产 main() 在它自己的 zone 里再 ensureInitialized + runApp,
  //   zone 不一致的检查只在 debug 断言里,profile/release 不查。
  final args = await BenchUnifiedNative.launchArgs();
  if (args['PWBenchPage'] == 'fullchain') {
    final err = await benchEnterFullChain();
    if (err == null) return;
    debugPrint('[bench] -PWBenchPage fullchain: $err');
  }
  SystemChrome.setPreferredOrientations(
      <DeviceOrientation>[DeviceOrientation.portraitUp]);
  runApp(const ArLoopBenchApp());
}

/// 菜单全部条目。id 是 -PWBenchPage 的取值,改了要同步改自动化脚本。
List<BenchEntry> _entries() => <BenchEntry>[
      BenchEntry(
        id: 'lidar',
        group: '采集 / 回放',
        title: 'LiDAR 米尺录制',
        subtitle: '会开摄像头:ARKit 1920×1440@60,按 XRSLAM 30 Hz 准入闸落盘整幅 1920×1440 + CoreMotion + '
            'sceneDepth,落 replay_recordings/run-…(🔴 bench-only ruler,LiDAR 永不进产品)',
        icon: Icons.straighten,
        page: () => const BenchLidarRecordPage(),
      ),
      BenchEntry(
        id: 'replay',
        group: '采集 / 回放',
        title: '录制回放(XRSLAM)',
        subtitle: '不开摄像头:录制 → 产品 ON 臂喂料通路 → XRSLAM,出位姿与计时,落 bench_replay_runs/',
        icon: Icons.replay,
        page: () => const BenchReplayPage(),
      ),
      BenchEntry(
        id: 'fullchain',
        group: '重建',
        title: '完整重建链(生产原样)',
        subtitle: '生产 168 流程 + 修复核;进去后由生产接管,回台架要杀掉 App 重开',
        icon: Icons.view_in_ar,
        page: () => const BenchFullChainPage(),
      ),
      BenchEntry(
        id: 'core-switches',
        group: '重建',
        title: '完整链核开关',
        subtitle: 'DEVICE-ALIGN-V1 / REG-EVIDENCE / FINALIZE-VIA-RESUME / GSS-FUSED(official_env.json)',
        icon: Icons.tune,
        page: () => const BenchCoreSwitchesPage(),
      ),
      BenchEntry(
        id: 'vio-live',
        group: 'VIO',
        title: 'VIO 实时(AR 最小回路)',
        subtitle: '会开摄像头:相机 → XRSLAM → Filament AR 背景与位姿',
        icon: Icons.videocam,
        page: () => const ArMinimalLoopPage(),
      ),
      BenchEntry(
        id: 'zero-arkit-capture',
        group: 'VIO',
        title: '零 ARKit 拍摄探针',
        subtitle: '会开摄像头 + XRSLAM 会话 + 快门写 JPEG/sidecar 到 Documents/',
        icon: Icons.camera,
        page: () => const ZeroArkitCaptureProbePage(),
      ),
      BenchEntry(
        id: 'zero-arkit-preview',
        group: 'VIO',
        title: '零 ARKit 预览探针',
        subtitle: '会开摄像头:3:4 框预览',
        icon: Icons.crop_portrait,
        page: () => const ZeroArkitPreviewProbePage(),
      ),
      BenchEntry(
        id: 'imu-calib',
        group: 'VIO',
        title: 'IMU 六位置标定采集',
        subtitle: '不开摄像头,纯 IMU',
        icon: Icons.screen_rotation,
        page: () => const ImuCalibCapturePage(),
      ),
      BenchEntry(
        id: 'zupt',
        group: 'VIO',
        title: '零速检测探针',
        subtitle: '不开摄像头,纯 IMU;静置 / 移动在页面上选',
        icon: Icons.pause_circle_outline,
        page: () => const ZuptProbePage(),
      ),
      BenchEntry(
        id: 'pose-chain',
        group: 'VIO',
        title: '位姿链探针',
        subtitle: '不开摄像头,纯几何',
        icon: Icons.linear_scale,
        page: () => const PoseChainProbePage(),
      ),
      BenchEntry(
        id: 'viobench',
        group: 'VIO',
        title: '旧 VIO 替换台架(Basalt / XRSLAM / ARKit 参考 / EuRoC)',
        subtitle: '原 VIO Replacement Bench 整套原生界面;录制落 VIOBenchRuns/,格式不变',
        icon: Icons.science,
        action: (context) async {
          try {
            await BenchUnifiedNative.openVioKit();
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('打不开旧 VIO 台架:$e')));
            }
          }
        },
      ),
      BenchEntry(
        id: 'lod',
        group: '渲染',
        title: 'LOD 调试',
        subtitle: '不开摄像头:建树 + 自检 / 查看 / M1(-PWLod* 启动参数)',
        icon: Icons.grain,
        page: () => LodDebugPage(),
      ),
      BenchEntry(
        id: 'splat-ab',
        group: '渲染',
        title: '泼溅 A/B',
        subtitle: '原 PWSplatAB:实例化 vs 顶点展开 / 裸点 / 真实点云 / LOD 台架,落 SplatAB/',
        icon: Icons.blur_on,
        page: () => const SplatAbPage(),
      ),
    ];

/// 旧 const define 包:直接进某一页(没有 define = 菜单)。
Widget? _legacyDefinePage() {
  if (const bool.fromEnvironment('PW_LIDAR_RULER_BENCH')) {
    return benchReplayRequestedByLaunchArgs()
        ? const BenchReplayPage()
        : const BenchLidarRecordPage();
  }
  if (const bool.fromEnvironment('PW_LOD_BENCH')) return LodDebugPage();
  if (const bool.fromEnvironment('PW_BENCH_REPLAY')) return const BenchReplayPage();
  if (const bool.fromEnvironment('PW_ZERO_ARKIT_CAPTURE')) {
    return const ZeroArkitCaptureProbePage();
  }
  if (const bool.fromEnvironment('PW_ZERO_ARKIT_PREVIEW')) {
    return const ZeroArkitPreviewProbePage();
  }
  if (const bool.fromEnvironment('PW_IMU_CALIB')) return const ImuCalibCapturePage();
  if (const String.fromEnvironment('PW_ZUPT') != '') return const ZuptProbePage();
  if (const bool.fromEnvironment('PW_POSE_CHAIN')) return const PoseChainProbePage();
  return null;
}

class ArLoopBenchApp extends StatelessWidget {
  const ArLoopBenchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Loop Bench',
      debugShowCheckedModeBanner: false,
      home: _legacyDefinePage() ??
          BenchHomePage(
            entries: _entries(),
            footer: '台架包,不是生产。真源:pocketworld bench/unified(本地分支,未推送)。'
                '菜单 id 可用 -PWBenchPage <id> 直开。',
          ),
    );
  }
}
