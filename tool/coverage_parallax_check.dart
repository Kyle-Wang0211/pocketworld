// coverage_parallax_check.dart — 信号1【低视差维度】纯 Dart 断言脚本。
//
// 目的:不依赖 flutter test(此 host 跑不了),用纯 Dart VM 验证
// CaptureCoverageCloud 的视差累计与"低视差压黄"颜色策略:
//   1. 两个相机位置对同一体素,maxParallaxDeg = 两视线夹角(几何真值对拍);
//   2. 同机位连拍 → 视差≈0,次数达标也只给黄(不给绿);
//   3. 视差 ≥ parallaxMinDeg(8°)且次数达标 → 正常给绿;
//   4. packed() 二进制布局不变(xyz 3×f32 + rgb 3×u8,逐点同序)。
//
// 运行:cd <仓根> && dart run tool/coverage_parallax_check.dart
// 全部通过输出 "ALL PASS";任一断言失败即非零退出。

import 'dart:io';
import 'dart:math' as math;
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

void _checkClose(double got, double want, double tol, String label) {
  _check((got - want).abs() <= tol, '$label (got=$got want=$want ±$tol)');
}

/// 构造一个只带一个 preview 点的 ARPose(种下体素用)。
ARPose _poseWithPoint(Vector3 p) => ARPose(
      position: Vector3.zero(),
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
        ARPreviewPoint(position: p, r: 128, g: 128, b: 128, confidence: 1.0),
      ],
    );

/// 相机在 [camPos]、旋转为单位阵(ARKit 相机系:-Z 前、+Y 上)的一拍。
/// extrinsic4x4 是列主序 camera-to-world。
SfmFrameFeed _feedAt(Vector3 camPos) => SfmFrameFeed(
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

void main() {
  final voxelPos = Vector3(0, 0, -2); // 相机原点正前方 2 m
  final camA = Vector3.zero();
  final camB = Vector3(0.5, 0, 0); // 侧移 0.5 m
  // 几何真值:A 视线 (0,0,-1),B 视线 normalize(-0.5,0,-2),
  // 夹角 = acos(2 / sqrt(4.25)) ≈ 14.036°。
  final wantDeg =
      math.acos(2.0 / math.sqrt(4.25)).clamp(-1.0, 1.0) * 180.0 / math.pi;

  // ── 1. 两个相机位置对同一体素:验证夹角计算 ───────────────────────
  stdout.writeln('[1] 双机位视差夹角');
  final cloud = CaptureCoverageCloud();
  cloud.ingestPose(_poseWithPoint(voxelPos));
  _check(cloud.parallaxDegAt(voxelPos) == null, '未拍照前无视差读数(null)');
  cloud.markCapture(_feedAt(camA));
  _checkClose(cloud.parallaxDegAt(voxelPos) ?? -1, 0, 1e-9, '首拍后视差=0');
  cloud.markCapture(_feedAt(camB));
  _checkClose(
    cloud.parallaxDegAt(voxelPos) ?? -1,
    wantDeg,
    0.01,
    '第二机位后 maxParallaxDeg=两视线夹角',
  );
  cloud.markCapture(_feedAt(camA)); // 回到首机位:max 不回退
  _checkClose(
    cloud.parallaxDegAt(voxelPos) ?? -1,
    wantDeg,
    0.01,
    '回到首机位 max 不回退',
  );

  // ── 2. 同机位连拍:次数达标但视差≈0 → 压黄不给绿 ─────────────────
  stdout.writeln('[2] 低视差压黄');
  final flat = CaptureCoverageCloud(); // coverageSaturation 默认 5
  flat.ingestPose(_poseWithPoint(voxelPos));
  for (var i = 0; i < 5; i++) {
    flat.markCapture(_feedAt(camA));
  }
  _check(flat.parallaxStarvedVoxelCount == 1, '视差饥饿体素计数=1');
  final flatPacked = flat.packed();
  _check(flatPacked.count == 1, 'packed 点数=1');
  _check(flatPacked.xyz.length == 3 && flatPacked.rgb.length == 3,
      'packed 布局:3×f32 + 3×u8');
  _checkClose(flatPacked.xyz[2], -2.0, 1e-6, 'packed xyz 同序同值');
  _check(
    flatPacked.rgb[0] == 255 && flatPacked.rgb[1] == 255,
    '5 拍零视差 → 停在黄 (255,255,·) 而非绿',
  );

  // ── 3. 视差充足(14° > 8°)且次数达标 → 正常给绿 ──────────────────
  stdout.writeln('[3] 视差达标给绿');
  final rich = CaptureCoverageCloud();
  rich.ingestPose(_poseWithPoint(voxelPos));
  rich.markCapture(_feedAt(camA));
  rich.markCapture(_feedAt(camB));
  for (var i = 0; i < 3; i++) {
    rich.markCapture(_feedAt(camA));
  }
  _check(rich.parallaxStarvedVoxelCount == 0, '视差饥饿体素计数=0');
  final richPacked = rich.packed();
  _check(
    richPacked.rgb[0] == 0 && richPacked.rgb[1] == 255,
    '5 拍 + 14° 视差 → 绿 (0,255,·)',
  );

  // ── 4. 阈值边界:略低于 8° 压黄,略高于 8° 给绿 ───────────────────
  stdout.writeln('[4] 8° 阈值边界');
  // 侧移 x 使夹角 = atan(x/2):7.5° → x≈0.2634;8.5° → x≈0.2989。
  for (final (deg, wantGreen) in <(double, bool)>[(7.5, false), (8.5, true)]) {
    final x = 2.0 * math.tan(deg * math.pi / 180.0);
    final c = CaptureCoverageCloud();
    c.ingestPose(_poseWithPoint(voxelPos));
    c.markCapture(_feedAt(camA));
    c.markCapture(_feedAt(Vector3(x, 0, 0)));
    for (var i = 0; i < 3; i++) {
      c.markCapture(_feedAt(camA));
    }
    final p = c.packed();
    final isGreen = p.rgb[0] == 0 && p.rgb[1] == 255;
    _check(isGreen == wantGreen,
        '$deg° → ${wantGreen ? "绿" : "黄"} (r=${p.rgb[0]} g=${p.rgb[1]})');
  }

  if (_failures > 0) {
    stdout.writeln('FAILED: $_failures assertion(s)');
    exit(1);
  }
  stdout.writeln('ALL PASS');
}
