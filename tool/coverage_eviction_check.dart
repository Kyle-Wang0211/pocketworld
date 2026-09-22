// coverage_eviction_check.dart — 案②【覆盖云容量淘汰】纯 Dart 断言脚本。
//
// 目的:不依赖 flutter test(此 host 跑不了),用纯 Dart VM 固化 46 号采集
// 暴露的 P0 回归:旧淘汰序(photoCoverage DESC)在体素全 covered 后让新区
// 体素插入即被挤出 —— 67 张后 26 张零新覆盖点。铁律:**引导功能的使命是
// 显示未覆盖区,新区永远不能输给已饱和老区(新区插入必胜)**。
//
// 断言:
//   1. 新区插入必胜:老区全绿打满容量后,新区体素 ingest + markCapture
//      必须存活并点亮;被淘汰的是"已饱和且距当前相机最远"的绿体素;
//   2. 引导价值序:视差饥饿黄(观测饱和但视差不足,仍在引导"换角度")
//      即使比绿更远也后于绿被淘汰;
//   3. 65k 满载(用户签决:100m² 房间 @4cm ≈ 62,500 体素 → 上限 65,000)
//      性能与语义:65,536 绿墙上 markCapture / 堆式 prune / packed 计时
//      对账(宽松上界防病态回归)+ 新区必胜在 65k 满载下依然成立 +
//      packed() 二进制布局不变(xyz 3×f32 + rgb 3×u8,逐点同序)。
//
// 运行:cd <仓根> && dart run tool/coverage_eviction_check.dart
// 全部通过输出 "ALL PASS";任一断言失败即非零退出。

import 'dart:io';
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

import 'package:pocketworld_flutter/capture/capture_coverage_cloud.dart';
import 'package:pocketworld_flutter/dome/ar_pose.dart';

int _failures = 0;

void _check(bool cond, String label) {
  if (cond) {
    stdout.writeln('  PASS  $label');
  } else {
    _failures++;
    stdout.writeln('  FAIL  $label');
  }
}

/// 构造一个带若干 preview 点、相机在 [camPos] 的 ARPose(种体素用;
/// 淘汰序里"距当前相机"的锚就是这个 position)。
ARPose _poseWithPoints(Vector3 camPos, List<Vector3> points) => ARPose(
  position: camPos,
  orientation: Quaternion.identity(),
  azimuth: 0,
  elevation: 0,
  isTracking: true,
  timestamp: 0,
  hasOrigin: false,
  worldOrigin: Vector3.zero(),
  worldYaw: 0,
  extrinsic4x4: const <double>[],
  intrinsicFxFyCxCy: const <double>[],
  previewPoints: <ARPreviewPoint>[
    for (final p in points)
      ARPreviewPoint(position: p, r: 128, g: 128, b: 128, confidence: 1.0),
  ],
);

/// 相机在 [camPos]、旋转为单位阵(ARKit 相机系:-Z 前、+Y 上)的一拍。
/// extrinsic4x4 是列主序 camera-to-world(同 tool/coverage_parallax_check)。
SfmFrameFeed _feedAt(Vector3 camPos) => SfmFrameFeed(
  captureJobId: 'coverage-eviction-check',
  gray: Uint8List(0),
  grayW: 640,
  grayH: 480,
  imageW: 640,
  imageH: 480,
  intrinsicFxFyCxCy: const <double>[500, 500, 320, 240],
  extrinsic4x4: <double>[
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    camPos.x, camPos.y, camPos.z, 1, //
  ],
  timestamp: 0,
);

/// 把 [positions] 的体素拍到绿:两机位交替 5 拍(基线 1m @ 深度 5m,
/// 视差 ≥8° > parallaxMinDeg=5°,观测数 = coverageSaturation=5)。
void _saturateGreen(CaptureCoverageCloud cloud, Vector3 camA, Vector3 camB) {
  for (var i = 0; i < 5; i++) {
    cloud.markCapture(_feedAt(i.isEven ? camA : camB));
  }
}

void main() {
  stdout.writeln('== 1. 新区插入必胜(46 号回归):老区全绿打满后新区必存活 ==');
  {
    final cloud = CaptureCoverageCloud(maxVoxels: 32); // slack = max(8, 0) = 8
    // 老区:40 个体素在 x∈[10, 11.95]、z=-5 的远墙(4cm 体素,5cm 步距
    // 保证 key 互异)。ingest 后恰好 40 = 32+8,不触发整理。
    final farPts = <Vector3>[
      for (var i = 0; i < 40; i++) Vector3(10.0 + 0.05 * i, 0, -5),
    ];
    final camA = Vector3(10, 0, 0);
    cloud.ingestPose(_poseWithPoints(camA, farPts));
    // 两机位交替 5 拍 → 全部 40 个体素绿(饱和且视差达标)。
    _saturateGreen(cloud, camA, Vector3(11, 0, 0));
    _check(
      cloud.coverageStats().green == 40,
      '前置:老区 40 体素全绿 (green=${cloud.coverageStats().green})',
    );

    // 新区:用户转身,相机回到原点,10 个新体素出现在眼前(z=-1)。
    // 50 > 32+8 → 触发整理。旧序在这里把 10 个新体素全部挤出(46 号 bug);
    // 新序必须留下它们,淘汰的是距相机最远的 18 个绿。
    final nearPts = <Vector3>[
      for (var j = 0; j < 10; j++) Vector3(-0.25 + 0.05 * j, 0, -1),
    ];
    cloud.ingestPose(_poseWithPoints(Vector3.zero(), nearPts));
    _check(cloud.evictedTotal == 18, '整理淘汰 18 个 (got=${cloud.evictedTotal})');
    _check(
      cloud.coverageStats().green == 22,
      '留下的绿 = 22(最近的)(got=${cloud.coverageStats().green})',
    );
    _check(
      cloud.parallaxDegAt(Vector3(10.0, 0, -5)) != null,
      '距相机最近的绿存活 (x=10.0)',
    );
    _check(
      cloud.parallaxDegAt(Vector3(11.95, 0, -5)) == null,
      '距相机最远的绿被淘汰 (x=11.95)',
    );

    // 快门落在新区 → 10 个新体素必须全部点亮(46 号是 0 个)。
    cloud.markCapture(_feedAt(Vector3.zero()));
    var litNew = 0;
    for (final p in nearPts) {
      if (cloud.parallaxDegAt(p) != null) litNew++;
    }
    _check(litNew == 10, '新区 10/10 体素点亮 (got=$litNew)');
    final packed = cloud.packed();
    _check(packed.count == 32, 'packed 含 22 绿 + 10 新红 (count=${packed.count})');
    _check(
      packed.xyz.length == packed.count * 3 &&
          packed.rgb.length == packed.count * 3,
      'packed 布局不变(xyz 3×f32 + rgb 3×u8)',
    );
  }

  stdout.writeln('== 2. 引导价值序:视差饥饿黄比绿后淘汰(哪怕黄更远) ==');
  {
    final cloud = CaptureCoverageCloud(maxVoxels: 16); // slack=8 → 24 触发
    // 绿区:16 体素 @ x∈[10,10.75], z=-5(距新区相机 ~11m)。
    final greenPts = <Vector3>[
      for (var i = 0; i < 16; i++) Vector3(10.0 + 0.05 * i, 0, -5),
    ];
    cloud.ingestPose(_poseWithPoints(Vector3(10, 0, 0), greenPts));
    _saturateGreen(cloud, Vector3(10, 0, 0), Vector3(11, 0, 0));
    // 黄区(视差饥饿):5 体素 @ x∈[-20,-19.8], z=-6(距新区相机 ~21m,
    // 比绿更远)。同机位连拍 5 次 → 观测饱和但视差 0 → 压黄。
    final yellowPts = <Vector3>[
      for (var i = 0; i < 5; i++) Vector3(-20.0 + 0.05 * i, 0, -6),
    ];
    cloud.ingestPose(_poseWithPoints(Vector3(-20, 0, 0), yellowPts));
    for (var i = 0; i < 5; i++) {
      cloud.markCapture(_feedAt(Vector3(-20, 0, 0)));
    }
    var st = cloud.coverageStats();
    _check(st.green == 16 && st.yellow == 5, '前置:16 绿 + 5 饥饿黄');

    // 新区 4 体素 → 25 > 24 触发整理,留 16:5 黄 + 4 新 + 最近的 7 绿。
    final nearPts = <Vector3>[
      for (var j = 0; j < 4; j++) Vector3(0.05 * j, 0, -1),
    ];
    cloud.ingestPose(_poseWithPoints(Vector3.zero(), nearPts));
    st = cloud.coverageStats();
    _check(st.yellow == 5, '5 个饥饿黄全部存活(引导价值仍在)(got=${st.yellow})');
    _check(st.green == 7, '绿被淘汰到 7(最远的先走)(got=${st.green})');
    var yellowAlive = 0;
    for (final p in yellowPts) {
      if (cloud.parallaxDegAt(p) != null) yellowAlive++;
    }
    _check(yellowAlive == 5, '黄体素坐标级复核 5/5 (got=$yellowAlive)');
    cloud.markCapture(_feedAt(Vector3.zero()));
    var litNew = 0;
    for (final p in nearPts) {
      if (cloud.parallaxDegAt(p) != null) litNew++;
    }
    _check(litNew == 4, '新区 4/4 点亮 (got=$litNew)');
  }

  stdout.writeln('== 3. 65k 满载性能 + 新区必胜(用户签决提额 65,000) ==');
  {
    final cloud = CaptureCoverageCloud(); // maxVoxels=65000, slack=1015
    // 老区绿墙:256×256 = 65,536 体素 @ z=-30(x,y ∈ [-6.4, 6.35],5cm
    // 步距,12.8m 见方 —— "书柜吃 9.6m²"量级的房间墙面)。逐行 ingest
    // (256 pose × 256 点);65,536 < 66,016 触发线 → 种植期不整理。
    final swSeed = Stopwatch()..start();
    for (var row = 0; row < 256; row++) {
      final y = -6.4 + 0.05 * row;
      final pts = <Vector3>[
        for (var col = 0; col < 256; col++) Vector3(-6.4 + 0.05 * col, y, -30),
      ];
      cloud.ingestPose(_poseWithPoints(Vector3.zero(), pts));
    }
    swSeed.stop();
    _check(cloud.evictedTotal == 0, '种植期未触发整理 (evicted=0)');

    // 两机位交替 5 拍打绿(基线 4m @ 深度 30m,全网格视差 ≥6.9° > 5°)。
    // 逐拍计时 = markCapture @65k 满载的单次成本。
    final markMsList = <int>[];
    final swMark = Stopwatch();
    for (var i = 0; i < 5; i++) {
      swMark
        ..reset()
        ..start();
      cloud.markCapture(_feedAt(i.isEven ? Vector3.zero() : Vector3(4, 0, 0)));
      swMark.stop();
      markMsList.add(swMark.elapsedMilliseconds);
    }
    final markMaxMs = markMsList.reduce((a, b) => a > b ? a : b);
    _check(
      cloud.coverageStats().green == 65536,
      '前置:65,536 体素全绿 (green=${cloud.coverageStats().green})',
    );

    // packed @65k 满载:计时 + payload 对账(65,536×15B = 983,040B)。
    final swPack = Stopwatch()..start();
    final packedFull = cloud.packed();
    swPack.stop();
    final payloadBytes =
        packedFull.xyz.lengthInBytes + packedFull.rgb.lengthInBytes;
    _check(
      packedFull.count == 65536 && payloadBytes == 65536 * 15,
      'packed @65k 满载:count=65,536,payload=983,040B (got=$payloadBytes)',
    );

    // 溢出:一次 ingest 塞 500 个远区新体素(两行 y=6.40/6.45)→ 66,036
    // > 66,016 触发堆式整理,k = 1,036。计时含整理。
    final overflowPts = <Vector3>[
      for (var col = 0; col < 250; col++) Vector3(-6.4 + 0.05 * col, 6.40, -30),
      for (var col = 0; col < 250; col++) Vector3(-6.4 + 0.05 * col, 6.45, -30),
    ];
    final swPrune = Stopwatch()..start();
    cloud.ingestPose(_poseWithPoints(Vector3.zero(), overflowPts));
    swPrune.stop();
    _check(
      cloud.evictedTotal == 1036,
      '整理淘汰 1,036 个(66,036−65,000)(got=${cloud.evictedTotal})',
    );
    _check(
      cloud.coverageStats().green == 65536 - 1036,
      '被淘汰的全是绿(最远优先)(green=${cloud.coverageStats().green})',
    );
    _check(cloud.parallaxDegAt(Vector3(-6.4, -6.4, -30)) == null, '最远角落绿被淘汰');
    _check(cloud.parallaxDegAt(Vector3(0, 0, -30)) != null, '中心绿存活');

    // 新区必胜 @65k 满载:20 个近区体素(z=-1)ingest + 快门 → 全部点亮。
    final nearPts = <Vector3>[
      for (var j = 0; j < 20; j++) Vector3(-0.5 + 0.05 * j, 0, -1),
    ];
    cloud.ingestPose(_poseWithPoints(Vector3.zero(), nearPts));
    cloud.markCapture(_feedAt(Vector3.zero()));
    var litNew = 0;
    for (final p in nearPts) {
      if (cloud.parallaxDegAt(p) != null) litNew++;
    }
    _check(litNew == 20, '新区 20/20 体素在 65k 满载下点亮 (got=$litNew)');
    final packedAfter = cloud.packed();
    _check(
      packedAfter.xyz.length == packedAfter.count * 3 &&
          packedAfter.rgb.length == packedAfter.count * 3,
      'packed 布局不变 @65k (count=${packedAfter.count})',
    );

    stdout.writeln(
      '  成本表(host VM):seed(256 pose × 256 pts)=${swSeed.elapsedMilliseconds}ms | '
      'markCapture @65k per-shutter=${markMsList.join('/')}ms (max=${markMaxMs}ms) | '
      'prune(ingest 500 + 堆式整理 k=1036)=${swPrune.elapsedMilliseconds}ms | '
      'packed @65k=${swPack.elapsedMilliseconds}ms, payload=${(payloadBytes / 1024).toStringAsFixed(0)}KB/push',
    );
    // 宽松上界(host VM 防病态回归;主 isolate 单次预算 8ms 的余量对账
    // 见报告):三项单次操作都必须停留在个位数~十几 ms 量级。
    _check(markMaxMs < 40, 'markCapture @65k 单次 < 40ms (got=${markMaxMs}ms)');
    _check(
      swPrune.elapsedMilliseconds < 40,
      'prune @66k 单次 < 40ms (got=${swPrune.elapsedMilliseconds}ms)',
    );
    _check(
      swPack.elapsedMilliseconds < 40,
      'packed @65k 单次 < 40ms (got=${swPack.elapsedMilliseconds}ms)',
    );
  }

  if (_failures > 0) {
    stdout.writeln('FAILED: $_failures assertion(s)');
    exit(1);
  }
  stdout.writeln('ALL PASS');
}
