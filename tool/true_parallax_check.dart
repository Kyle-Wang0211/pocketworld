// true_parallax_check.dart — route B(拍摄期真实三角化角)纯 Dart 断言。
//
// 运行(纯 Dart VM,repo 根目录下执行;true_parallax.dart /
// photo_card_state.dart 零 Flutter 依赖,capture_coverage_cloud.dart 仅依赖
// vector_math 纯包):
//   dart tool/true_parallax_check.dart
//
// 验收几何(任务书原文,2026-07-11 阈值校准 8°→5° 后判黄几何改用 4°):
// 构造已知几何 —— 两相机 4° 观测的点→帧判黄(<5° 首判锚);15°→白;
// 混合场景聚合正确。另断言:相机中心恢复(CamFromWorld→C=-Rᵀt)、
// 体素中位聚合、观测封顶、退化护栏、跨步采样,以及覆盖云端到端:真值
// 注入后压黄/放绿翻转、体素级视锥近似只兜底、coverageStats 的
// starved_true。(白→黄反序修复后帧卡片判黄只用真值 ——
// frameLowParallaxTrue,真值缺席返回 null 卡片保持黑;覆盖云的帧级近似
// 信号仅诊断,见 capture_coverage_cloud.isFrameLowParallax。)

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/capture_coverage_cloud.dart';
import 'package:pocketworld_flutter/capture/photo_card_state.dart';
import 'package:pocketworld_flutter/capture/true_parallax.dart';
import 'package:pocketworld_flutter/dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

int _failures = 0;

void check(String name, Object? actual, Object? expected) {
  final ok = actual == expected;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'}  $name'
    '${ok ? '' : '  (expected $expected, got $actual)'}',
  );
  if (!ok) _failures++;
}

void checkNear(
  String name,
  double? actual,
  double expected, {
  double tol = 0.01,
}) {
  final ok = actual != null && (actual - expected).abs() <= tol;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'}  $name'
    '${ok ? '' : '  (expected $expected ± $tol, got $actual)'}',
  );
  if (!ok) _failures++;
}

/// 距点 [p] 2 米、绕世界 Y 轴偏 [deg] 度的相机中心(deg=0 → p+(0,0,2))。
/// 两个这样的中心对 p 的张角恰好等于二者 deg 之差 —— 已知几何的地基。
List<double> camAt(List<double> p, double deg) {
  final rad = deg * math.pi / 180.0;
  return [p[0] + 2 * math.sin(rad), p[1], p[2] + 2 * math.cos(rad)];
}

/// 单点云的观测数组构造:1 个点 @ [p],观测帧 = [fids]。
({Float32List xyz, Int32List offs, Int32List fids}) onePoint(
  List<double> p,
  List<int> fids,
) => (
  xyz: Float32List.fromList([p[0], p[1], p[2]]),
  offs: Int32List.fromList([0, fids.length]),
  fids: Int32List.fromList(fids),
);

/// framesPacked([frameId, medianDeg] ×2/帧)→ map 查询。
Map<int, double> frameMap(Float64List packed) => {
  for (var i = 0; i + 1 < packed.length; i += 2)
    packed[i].toInt(): packed[i + 1],
};

void main() {
  // ── 相机中心恢复:CamFromWorld(q wxyz, t)→ C = -Rᵀt ─────────────
  {
    final c = cameraCenterFromCamFromWorld([1, 0, 0, 0], [1, 2, 3]);
    check('中心恢复:单位四元数 → C = -t', c != null, true);
    checkNear('  C.x = -1', c![0], -1.0, tol: 1e-9);
    checkNear('  C.y = -2', c[1], -2.0, tol: 1e-9);
    checkNear('  C.z = -3', c[2], -3.0, tol: 1e-9);
    // 绕 Y 轴 90°(w=cos45°, y=sin45°),t=(1,0,0) → C = (0,0,-1)。
    final h = math.sqrt(2) / 2;
    final c90 = cameraCenterFromCamFromWorld([h, 0, h, 0], [1, 0, 0]);
    checkNear('中心恢复:绕Y 90° C.x', c90![0], 0.0, tol: 1e-9);
    checkNear('  C.z = -1', c90[2], -1.0, tol: 1e-9);
    check(
      '中心恢复:零四元数(合成/降级 pose)→ null',
      cameraCenterFromCamFromWorld([0, 0, 0, 0], [1, 2, 3]),
      null,
    );
  }

  // ── 验收几何①:两相机 4° 观测一个点 → 帧中位 4° → 判黄 ───────────
  // (2026-07-11 首判锚 8°→5°:5° 恰在边界之上不再判黄,判黄几何用 4°。)
  const p0 = [0.0, 0.0, 0.0];
  {
    final pt = onePoint(p0, [1, 2]);
    final agg = trueParallaxAggregate(
      xyz: pt.xyz,
      obsOffsets: pt.offs,
      obsFrameIds: pt.fids,
      centersByFrame: {1: camAt(p0, 0), 2: camAt(p0, 4)},
    )!;
    final fm = frameMap(agg.framesPacked);
    checkNear('4° 几何:帧 1 中位 = 4°', fm[1], 4.0);
    checkNear('4° 几何:帧 2 中位 = 4°', fm[2], 4.0);
    check('4° 几何:体素数 = 1', agg.voxelKeys.length, 1);
    check(
      '4° 几何:voxel key 与 coverageVoxelKeyFor 一致',
      agg.voxelKeys[0],
      coverageVoxelKeyFor(0, 0, 0, kCoverageVoxelSizeM),
    );
    checkNear('4° 几何:体素真值 = 4°', agg.voxelDeg[0], 4.0);
    // 帧判定:真值 4° < 5°(首判锚)→ 黄(photoCardSfmState 端到端)。
    final poses = Float64List(9)
      ..[0] = 1
      ..[1] = 1; // 帧1已注册
    check(
      '4° → 卡片黄(lowParallax)',
      photoCardSfmState(
        frameId: 1,
        posesPacked: poses,
        lowParallax: frameLowParallaxTrue(
          trueMedianDeg: fm[1],
          wasLowParallax: null,
        ),
      ),
      PhotoCardSfmState.lowParallax,
    );
    // 边界对照:5° 恰等于首判锚(5.0 < 5.0 为假)→ 白,不再全场黄。
    check(
      '5°(= 首判锚)→ 白(阈值校准后 5° 不判黄)',
      frameLowParallaxTrue(trueMedianDeg: 5.0, wasLowParallax: null),
      false,
    );
  }

  // ── 验收几何②:两相机 15° → 白 ───────────────────────────────────
  {
    final pt = onePoint(p0, [1, 2]);
    final agg = trueParallaxAggregate(
      xyz: pt.xyz,
      obsOffsets: pt.offs,
      obsFrameIds: pt.fids,
      centersByFrame: {1: camAt(p0, 0), 2: camAt(p0, 15)},
    )!;
    final fm = frameMap(agg.framesPacked);
    checkNear('15° 几何:帧 1 中位 = 15°', fm[1], 15.0);
    final poses = Float64List(9)
      ..[0] = 1
      ..[1] = 1;
    check(
      '15° → 卡片白(registered)',
      photoCardSfmState(
        frameId: 1,
        posesPacked: poses,
        lowParallax: frameLowParallaxTrue(
          trueMedianDeg: fm[1],
          wasLowParallax: null,
        ),
      ),
      PhotoCardSfmState.registered,
    );
    // 真值唯一铁律(白→黄反序修复):真值 15° → 白,视锥近似无发言权。
    check(
      '真值 15° → 不判黄(视锥近似已彻底退出帧判定)',
      frameLowParallaxTrue(trueMedianDeg: fm[1], wasLowParallax: null),
      false,
    );
    // 真值缺席 → null → 已注册也保持黑(处理中),不再回退视锥近似。
    check(
      '真值缺席 → null(不许近似顶替)',
      frameLowParallaxTrue(trueMedianDeg: null, wasLowParallax: null),
      null,
    );
    check(
      '真值缺席 → 卡片黑(已注册也不抢答白)',
      photoCardSfmState(frameId: 1, posesPacked: poses, lowParallax: null),
      PhotoCardSfmState.pending,
    );
  }

  // ── 验收几何③:混合场景聚合 ─────────────────────────────────────
  // 点 A@原点 被帧 {10,11} 以 4° 观测;点 B@(0,0,4) 被帧 {10,12} 以 15°
  // 观测。帧 10 观测两点 → 中位 = (4+15)/2 = 9.5° → 白;帧 11 → 4° 黄;
  // 帧 12 → 15° 白。体素:A、B 各自成体素,真值分别 4°/15°。
  {
    final xyz = Float32List.fromList([0, 0, 0, 0, 0, 4]);
    final offs = Int32List.fromList([0, 2, 4]);
    final fids = Int32List.fromList([10, 11, 10, 12]);
    // 帧 10 中心 (0,0,2):对 A(原点)是 0° 基准;从 B=(0,0,4) 看去方向
    // (0,0,-1)、距离 2m。帧 12 放在 B 的同侧(-z 半球)偏 15°:
    // c12 = B + 2·(sin15°, 0, -cos15°) → 对 B 的张角恰 15°。
    final r15 = 15 * math.pi / 180.0;
    final c12 = [2 * math.sin(r15), 0.0, 4 - 2 * math.cos(r15)];
    final agg = trueParallaxAggregate(
      xyz: xyz,
      obsOffsets: offs,
      obsFrameIds: fids,
      centersByFrame: {10: camAt(p0, 0), 11: camAt(p0, 4), 12: c12},
    )!;
    final fm = frameMap(agg.framesPacked);
    checkNear('混合:帧 10(见 4° 与 15° 两点)中位 = 9.5°', fm[10], 9.5);
    checkNear('混合:帧 11 中位 = 4°', fm[11], 4.0);
    checkNear('混合:帧 12 中位 = 15°', fm[12], 15.0);
    check(
      '混合:帧 10 → 白(中位 9.5° ≥ 5° 首判锚)',
      frameLowParallaxTrue(trueMedianDeg: fm[10], wasLowParallax: null),
      false,
    );
    check(
      '混合:帧 11 → 黄',
      frameLowParallaxTrue(trueMedianDeg: fm[11], wasLowParallax: null),
      true,
    );
    check(
      '混合:framesPacked 按 frameId 升序',
      agg.framesPacked[0] < agg.framesPacked[2] &&
          agg.framesPacked[2] < agg.framesPacked[4],
      true,
    );
    check('混合:体素数 = 2', agg.voxelKeys.length, 2);
    final kA = coverageVoxelKeyFor(0, 0, 0, kCoverageVoxelSizeM);
    final kB = coverageVoxelKeyFor(0, 0, 4, kCoverageVoxelSizeM);
    final vox = {
      for (var i = 0; i < agg.voxelKeys.length; i++)
        agg.voxelKeys[i]: agg.voxelDeg[i].toDouble(),
    };
    checkNear('混合:体素 A 真值 = 4°', vox[kA], 4.0);
    checkNear('混合:体素 B 真值 = 15°', vox[kB], 15.0);
  }

  // ── 同体素多点 → 中位数 ─────────────────────────────────────────
  {
    const p1 = [0.010, 0.010, 0.010];
    const p2 = [0.020, 0.020, 0.020]; // 同一 4cm 体素
    final xyz = Float32List.fromList([...p1, ...p2]);
    final offs = Int32List.fromList([0, 2, 4]);
    final fids = Int32List.fromList([20, 21, 22, 23]);
    final agg = trueParallaxAggregate(
      xyz: xyz,
      obsOffsets: offs,
      obsFrameIds: fids,
      centersByFrame: {
        20: camAt(p1, 0),
        21: camAt(p1, 5),
        22: camAt(p2, 0),
        23: camAt(p2, 15),
      },
    )!;
    check('同体素两点:体素数 = 1', agg.voxelKeys.length, 1);
    checkNear(
      '同体素两点(5°/15°):中位 = 10°',
      agg.voxelDeg[0].toDouble(),
      10.0,
      tol: 0.05,
    );
  }

  // ── 观测封顶(maxObsPerPoint=6):第 7 个 90° 观测不参与 ──────────
  {
    final pt = onePoint(p0, [0, 1, 2, 3, 4, 5, 6]);
    final agg = trueParallaxAggregate(
      xyz: pt.xyz,
      obsOffsets: pt.offs,
      obsFrameIds: pt.fids,
      centersByFrame: {
        for (var k = 0; k < 6; k++) k: camAt(p0, k.toDouble()), // 前6个:0..5°
        6: camAt(p0, 90), // 第7个:若未封顶会把角度顶到 90°
      },
    )!;
    checkNear('观测封顶:7 观测只取前 6 → 角度 5° 而非 90°', agg.voxelDeg[0].toDouble(), 5.0);
  }

  // ── 退化护栏 ────────────────────────────────────────────────────
  {
    final pt = onePoint(p0, [1, 2]);
    check(
      '相机中心缺失只剩 1 个 → 无证据 → null',
      trueParallaxAggregate(
        xyz: pt.xyz,
        obsOffsets: pt.offs,
        obsFrameIds: pt.fids,
        centersByFrame: {1: camAt(p0, 0), 3: camAt(p0, 15)}, // 帧2无中心
      ),
      null,
    );
    check(
      '相机中心与点重合(射线退化)→ 不伪造 0° → null',
      trueParallaxAggregate(
        xyz: pt.xyz,
        obsOffsets: pt.offs,
        obsFrameIds: pt.fids,
        centersByFrame: {1: p0, 2: camAt(p0, 15)},
      ),
      null,
    );
    check(
      '可用相机 < 2 → null',
      trueParallaxAggregate(
        xyz: pt.xyz,
        obsOffsets: pt.offs,
        obsFrameIds: pt.fids,
        centersByFrame: {1: camAt(p0, 0)},
      ),
      null,
    );
    check(
      '空点云 → null',
      trueParallaxAggregate(
        xyz: Float32List(0),
        obsOffsets: Int32List(1),
        obsFrameIds: Int32List(0),
        centersByFrame: {1: camAt(p0, 0), 2: camAt(p0, 5)},
      ),
      null,
    );
  }

  // ── 跨步采样护栏 ────────────────────────────────────────────────
  {
    // 5 个相同几何的点(帧 1/2 以 5° 观测),maxSample=2 → stride=3 →
    // 采样下标 0、3 → sampled=2。
    final xyz = Float32List(15);
    final offs = Int32List.fromList([0, 2, 4, 6, 8, 10]);
    final fids = Int32List.fromList([1, 2, 1, 2, 1, 2, 1, 2, 1, 2]);
    final agg = trueParallaxAggregate(
      xyz: xyz,
      obsOffsets: offs,
      obsFrameIds: fids,
      centersByFrame: {1: camAt(p0, 0), 2: camAt(p0, 5)},
      maxSample: 2,
    )!;
    check('跨步采样:n=5 maxSample=2 → stride=3', agg.stride, 3);
    check('跨步采样:sampled=2', agg.sampledPoints, 2);
  }

  // ── 覆盖云端到端:真值注入 → 压黄/放绿翻转,视锥近似只兜底 ────────
  {
    final cloud = CaptureCoverageCloud(); // 默认:0.04 / 饱和5 / 5°
    const p = [0.5, 0.5, -1.0];
    final vp = Vector3(p[0], p[1], p[2]);
    // VIO 点建体素。
    cloud.ingestPose(_poseWithPreviewPoint(vp));
    // 同机位连拍 5 张(视锥近似视差 ≈ 0°,photoCoverage=5)。
    for (var i = 0; i < 5; i++) {
      cloud.markCapture(_feedLookingAt(cam: [0.5, 0.5, 1.0], jpeg: 'f$i.jpg'));
    }
    var stats = cloud.coverageStats();
    check('端到端:同机位×5 → 绿 0(视锥压黄)', stats.green, 0);
    check('端到端:parallaxCapped = 1', stats.parallaxCapped, 1);
    check('端到端:真值未到达 → trueVoxels = 0', stats.trueVoxels, 0);
    check('端到端:starvedTrue = 0(真值缺席不计)', stats.starvedTrue, 0);
    check('端到端:starved(有效口径)= 1', cloud.parallaxStarvedVoxelCount, 1);
    check(
      '端到端:帧级近似信号判黄(仅诊断,已退出卡片判定)',
      cloud.isFrameLowParallax('f0.jpg'),
      true,
    );

    // 真值注入 12° ≥ 5° → 放绿(worker 侧同函数算 key,逐位一致)。
    final key = coverageVoxelKeyFor(p[0], p[1], p[2], kCoverageVoxelSizeM);
    cloud.applyTrueParallax(
      Int64List.fromList([key]),
      Float32List.fromList([12.0]),
    );
    stats = cloud.coverageStats();
    check('端到端:真值 12° 注入 → 绿 1', stats.green, 1);
    check('端到端:trueVoxels = 1', stats.trueVoxels, 1);
    check('端到端:trueLt8 = 0', stats.trueLt8, 0);
    check('端到端:starvedTrue = 0', stats.starvedTrue, 0);
    check('端到端:starved 清零', cloud.parallaxStarvedVoxelCount, 0);
    check(
      '端到端:帧级近似信号转白(真值经体素回流,仅诊断)',
      cloud.isFrameLowParallax('f0.jpg'),
      false,
    );
    checkNear('端到端:parallaxDegAt = 真值 12°', cloud.parallaxDegAt(vp), 12.0);

    // 真值降为 4° < 5° → 重新压黄 + starved_true 计数(D 域对数字段)。
    cloud.applyTrueParallax(
      Int64List.fromList([key]),
      Float32List.fromList([4.0]),
    );
    stats = cloud.coverageStats();
    check('端到端:真值 4° → 绿 0', stats.green, 0);
    check('端到端:trueLt8 = 1', stats.trueLt8, 1);
    check('端到端:starvedTrue = 1', stats.starvedTrue, 1);
    check('端到端:starved(有效口径)回到 1', cloud.parallaxStarvedVoxelCount, 1);

    // 真值压过视锥近似:两机位 15° 视锥视差的体素,真值 4° 仍压黄。
    final cloud2 = CaptureCoverageCloud();
    cloud2.ingestPose(_poseWithPreviewPoint(vp));
    for (var i = 0; i < 5; i++) {
      // 交替两个相隔 ~15° 的机位 → 视锥近似 maxParallaxDeg ≈ 15°。
      cloud2.markCapture(
        _feedLookingAt(
          cam: i.isEven
              ? [0.5, 0.5, 1.0]
              : [
                  0.5 + 2 * math.sin(15 * math.pi / 180),
                  0.5,
                  -1.0 + 2 * math.cos(15 * math.pi / 180),
                ],
          jpeg: 'g$i.jpg',
        ),
      );
    }
    check('对照:视锥 15° 无真值 → 绿', cloud2.coverageStats().green, 1);
    cloud2.applyTrueParallax(
      Int64List.fromList([key]),
      Float32List.fromList([4.0]),
    );
    check('对照:真值 4° 压过视锥 15° → 压黄(真值优先)', cloud2.coverageStats().green, 0);
    // 长度不匹配的注入被整批拒绝(防御)。
    cloud2.applyTrueParallax(Int64List.fromList([key]), Float32List(0));
    check(
      '防御:keys/degs 长度不匹配 → 忽略,真值不变',
      cloud2.coverageStats().starvedTrue,
      1,
    );
  }

  // ── voxel key 负坐标语义(floor,不是 truncate)──────────────────
  check(
    'voxel key:±0.01 分属不同体素(floor 语义)',
    coverageVoxelKeyFor(-0.01, -0.01, -0.01, kCoverageVoxelSizeM) ==
        coverageVoxelKeyFor(0.01, 0.01, 0.01, kCoverageVoxelSizeM),
    false,
  );

  if (_failures > 0) {
    stdout.writeln('\n$_failures assertion(s) FAILED');
    exit(1);
  }
  stdout.writeln('\nALL PASS');
}

/// 造一个只带 1 个 preview 点的 ARPose(其余字段全为占位)。
ARPose _poseWithPreviewPoint(Vector3 p) => ARPose(
  position: Vector3.zero(),
  orientation: Quaternion.identity(),
  azimuth: 0,
  elevation: 0,
  isTracking: true,
  timestamp: 0,
  hasOrigin: true,
  worldOrigin: Vector3.zero(),
  worldYaw: 0,
  extrinsic4x4: const [],
  intrinsicFxFyCxCy: const [],
  previewPoints: [ARPreviewPoint(position: p, r: 0, g: 0, b: 0, confidence: 1)],
);

/// 造一个从 [cam] 望向 -z(单位旋转)的 SfmFrameFeed:cam 放在被测点
/// 正后方/侧后方时点必落在视锥内(fx=100, c=(200,200), 400×400)。
SfmFrameFeed _feedLookingAt({
  required List<double> cam,
  required String jpeg,
}) => SfmFrameFeed(
  captureJobId: 'true-parallax-check-${jpeg.split('/').last}',
  gray: Uint8List(0),
  grayW: 1,
  grayH: 1,
  imageW: 400,
  imageH: 400,
  intrinsicFxFyCxCy: const [100, 100, 200, 200],
  extrinsic4x4: [
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    cam[0], cam[1], cam[2], 1,
  ],
  timestamp: 0,
  jpegPath: jpeg,
);
