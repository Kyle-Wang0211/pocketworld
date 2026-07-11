// gravity_align_check.dart — 重力对齐纯函数的纯 Dart VM 断言(resume 对齐战役)。
//
// 运行(纯 Dart VM,repo 根目录下):
//   dart tool/gravity_align_check.dart
//
// 背景:断点续跑(sfm_resume.dart)恢复出的点云歪着 —— resume 会话没喂过
// 帧,facade 的 _fedMeta 为空,_gravityAlign 整段跳过。修法 = 从
// sfm_fed_frames.jsonl 回填 ARKit 四元数(seedFedMeta),live 与 resume 走
// gravity_align.dart 同一纯函数。本脚本按定义构造已知 ARKit+COLMAP pose 对:
//
//   约定:x_ark = R_ark·p_ark(ARKit CamFromWorld),x_col = R_col·p_col,
//   相机系翻转 x_col = C·x_ark(C = diag(1,-1,-1) = 绕 X 转 180°),
//   规约(gauge)旋转 p_col = W·p_ark(COLMAP 世界任意歪)。
//   ⇒ R_col = C·R_ark·W^T,而 R_w = R_ark^T·C·R_col = W^T,
//   即对齐输出应精确等于 ARKit 重力世界坐标 p_ark(+Y = 天)。
//
// 断言:①变换后点云回到 ARKit 重力世界(竖直杆重新对齐 +Y);②四元数
// 半球符号翻转(q 与 -q 同旋转)不影响均值;③证据不足(<3 帧)返回 null;
// ④合成连通性 poses(四元数全 0)被 norm 门跳过 → null;⑤未注册帧被
// 忽略;⑥缺 ARKit 四元数的帧被跳过。附:floater_filter.dart 共享提出后的
// 冒烟断言(孤点删、密集面保、小云不过滤)。

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/floater_filter.dart';
import 'package:pocketworld_flutter/capture/gravity_align.dart';

int _failures = 0;

void check(String name, bool ok, [String detail = '']) {
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name${ok ? '' : '  ($detail)'}');
  if (!ok) _failures++;
}

// ── 四元数工具(wxyz,Hamilton)──────────────────────────────────────
List<double> qmul(List<double> a, List<double> b) => [
  a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
  a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
  a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
];

List<double> qconj(List<double> q) => [q[0], -q[1], -q[2], -q[3]];

List<double> qAxisAngle(double x, double y, double z, double angle) {
  final n = math.sqrt(x * x + y * y + z * z);
  final s = math.sin(angle / 2) / n;
  return [math.cos(angle / 2), x * s, y * s, z * s];
}

List<double> qrot(List<double> q, List<double> v) {
  final p = qmul(qmul(q, [0.0, v[0], v[1], v[2]]), qconj(q));
  return [p[1], p[2], p[3]];
}

/// C = diag(1,-1,-1) = 绕 X 轴 180°(与 gravity_align.dart 的 qC 同一常量)。
const List<double> qC = [0.0, 1.0, 0.0, 0.0];

// ── 测试场景 ──────────────────────────────────────────────────────
/// ARKit 重力世界点集:竖直杆(沿 +Y)+ 地面方块。
List<List<double>> arkitScene() {
  final pts = <List<double>>[];
  for (var i = 0; i <= 10; i++) {
    pts.add([0.0, i / 10.0, 0.0]); // 杆:y = 0..1
  }
  for (final x in [-0.5, 0.0, 0.5]) {
    for (final z in [-0.5, 0.0, 0.5]) {
      pts.add([x, 0.0, z]); // 地面
    }
  }
  return pts;
}

Float64List posesFor(List<List<double>> qCols, {List<int>? registered}) {
  final out = Float64List(qCols.length * 9);
  for (var i = 0; i < qCols.length; i++) {
    final o = i * 9;
    out[o] = i.toDouble(); // frameId
    out[o + 1] = (registered == null || registered.contains(i)) ? 1 : 0;
    out[o + 2] = qCols[i][0];
    out[o + 3] = qCols[i][1];
    out[o + 4] = qCols[i][2];
    out[o + 5] = qCols[i][3];
    out[o + 6] = 0.31 * i; // 平移任意 —— 对齐只用旋转
    out[o + 7] = -0.7;
    out[o + 8] = 1.9 + i;
  }
  return out;
}

void main() {
  // 规约旋转 W(COLMAP 世界的任意歪斜):p_col = W · p_ark。
  final qW = qAxisAngle(0.3, 0.8, 0.52, 1.1);
  // 5 帧互不相同的 ARKit CamFromWorld。
  final qArks = <List<double>>[
    qAxisAngle(1, 2, 3, 0.7),
    qAxisAngle(-1, 0.5, 2, 1.9),
    qAxisAngle(0, 1, 0, 3.0),
    qAxisAngle(2, -1, 0.3, 0.2),
    qAxisAngle(0.1, 0.9, -0.4, 2.4),
  ];
  // R_col = C·R_ark·W^T。
  final qCols = [
    for (final qa in qArks) qmul(qC, qmul(qa, qconj(qW))),
  ];

  final scene = arkitScene();
  final xyzCol = Float32List(scene.length * 3);
  for (var i = 0; i < scene.length; i++) {
    final pCol = qrot(qW, scene[i]);
    xyzCol[i * 3] = pCol[0];
    xyzCol[i * 3 + 1] = pCol[1];
    xyzCol[i * 3 + 2] = pCol[2];
  }
  final poses = posesFor(qCols);

  // ── ① 基本对齐:输出 == ARKit 重力世界(+Y = 天)──────────────
  {
    final out = gravityAlignedPoints(
      xyz: xyzCol,
      posesPacked: poses,
      arkitQuatWxyzOf: (id) => id >= 0 && id < qArks.length ? qArks[id] : null,
    );
    check('已知 pose 对 → 非空输出', out != null);
    if (out != null) {
      var maxErr = 0.0;
      for (var i = 0; i < scene.length; i++) {
        for (var k = 0; k < 3; k++) {
          final e = (out[i * 3 + k] - scene[i][k]).abs();
          if (e > maxErr) maxErr = e;
        }
      }
      check('全部点回到 ARKit 重力世界 (maxErr<1e-4)', maxErr < 1e-4,
          'maxErr=$maxErr');
      // 竖直杆方向 = 对齐后的重力轴:杆顶-杆底 ≈ (0,1,0)。
      final dx = out[10 * 3] - out[0];
      final dy = out[10 * 3 + 1] - out[1];
      final dz = out[10 * 3 + 2] - out[2];
      check(
        '竖直杆对齐 +Y(重力轴)',
        (dx.abs() < 1e-4) && ((dy - 1.0).abs() < 1e-4) && (dz.abs() < 1e-4),
        'delta=($dx,$dy,$dz)',
      );
    }
  }

  // ── ② 四元数半球:部分 q_ark 取 -q(同旋转)结果不变 ─────────────
  {
    final flipped = [
      for (var i = 0; i < qArks.length; i++)
        i.isEven ? [for (final v in qArks[i]) -v] : qArks[i],
    ];
    final out = gravityAlignedPoints(
      xyz: xyzCol,
      posesPacked: poses,
      arkitQuatWxyzOf: (id) => flipped[id],
    );
    var maxErr = double.infinity;
    if (out != null) {
      maxErr = 0.0;
      for (var i = 0; i < scene.length; i++) {
        for (var k = 0; k < 3; k++) {
          final e = (out[i * 3 + k] - scene[i][k]).abs();
          if (e > maxErr) maxErr = e;
        }
      }
    }
    check('半球符号翻转不影响均值 (maxErr<1e-4)', out != null && maxErr < 1e-4,
        'maxErr=$maxErr');
  }

  // ── ③ 证据不足(<3 帧带 ARKit 四元数)→ null(保持原点云)────────
  {
    final out = gravityAlignedPoints(
      xyz: xyzCol,
      posesPacked: poses,
      arkitQuatWxyzOf: (id) => id < 2 ? qArks[id] : null,
    );
    check('仅 2 帧证据 → null(不冒错误倾角的险)', out == null);
  }

  // ── ④ 合成连通性 poses(四元数全 0)→ norm 门跳过 → null ─────────
  {
    final zeroPoses = Float64List(5 * 9);
    for (var i = 0; i < 5; i++) {
      zeroPoses[i * 9] = i.toDouble();
      zeroPoses[i * 9 + 1] = 1;
      // COLMAP 四元数全 0(拍摄期合成 poses 的契约,见 SfmLiveConnectivity)
    }
    final out = gravityAlignedPoints(
      xyz: xyzCol,
      posesPacked: zeroPoses,
      arkitQuatWxyzOf: (id) => qArks[id],
    );
    check('合成 poses(全 0 四元数)→ null(绝不旋转流式云)', out == null);
  }

  // ── ⑤ 未注册帧被忽略:3 好帧注册 + 2 垃圾帧未注册 → 仍正确 ────────
  {
    final garbage = [
      qCols[0],
      qCols[1],
      qCols[2],
      qAxisAngle(1, 1, 1, 2.9), // 垃圾:与场景无关的旋转
      qAxisAngle(-2, 1, 0, 1.3),
    ];
    final poses5 = posesFor(garbage, registered: [0, 1, 2]);
    final out = gravityAlignedPoints(
      xyz: xyzCol,
      posesPacked: poses5,
      arkitQuatWxyzOf: (id) => qArks[id],
    );
    var maxErr = double.infinity;
    if (out != null) {
      maxErr = 0.0;
      for (var i = 0; i < scene.length; i++) {
        for (var k = 0; k < 3; k++) {
          final e = (out[i * 3 + k] - scene[i][k]).abs();
          if (e > maxErr) maxErr = e;
        }
      }
    }
    check('未注册帧被忽略 (maxErr<1e-4)', out != null && maxErr < 1e-4,
        'maxErr=$maxErr');
  }

  // ── ⑥ 空输入护栏 ────────────────────────────────────────────────
  {
    final out = gravityAlignedPoints(
      xyz: Float32List(0),
      posesPacked: poses,
      arkitQuatWxyzOf: (id) => qArks[id],
    );
    check('空点云 → null', out == null);
  }

  // ── floater_filter 共享提出后的冒烟断言 ─────────────────────────
  {
    // 20×20×8 密集网格(3200 点,>2000 过滤门)+ 1 个 100 倍距离外的孤点。
    final pts = <double>[];
    for (var x = 0; x < 20; x++) {
      for (var y = 0; y < 20; y++) {
        for (var z = 0; z < 8; z++) {
          pts.addAll([x * 0.01, y * 0.01, z * 0.01]);
        }
      }
    }
    final denseN = pts.length ~/ 3;
    pts.addAll([10.0, 10.0, 10.0]); // 孤点:云直径的 ~50 倍开外
    final xyz = Float32List.fromList(pts);
    final r = floaterKeepIndices(xyz);
    final removedOrphan = !r.keep.contains(denseN);
    check('floater: 零近邻孤点被删', removedOrphan,
        'kept=${r.keep.length}/${denseN + 1}');
    check('floater: 密集面全保', r.keep.length >= denseN,
        'kept=${r.keep.length} dense=$denseN');
    // 小云(<2000)不过滤。
    final small = Float32List.fromList([
      for (var i = 0; i < 30; i++) ...[i * 1.0, 0.0, 0.0],
      1e6, 1e6, 1e6, // 哪怕有明显孤点
    ]);
    final rs = floaterKeepIndices(small);
    check('floater: 小云(<2000)不过滤', rs.keep.length == 31);
    // 紧凑拷贝助手。
    final keep = Int32List.fromList([0, 2]);
    final cx = compactXyzRgbByIndices(
      Float32List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]),
      Uint8List.fromList([10, 11, 12, 13, 14, 15, 16, 17, 18]),
      keep,
    );
    check(
      'compactXyzRgbByIndices 按索引压实',
      cx.xyz.length == 6 &&
          cx.xyz[3] == 7 &&
          cx.rgb.length == 6 &&
          cx.rgb[5] == 18,
    );
  }

  stdout.writeln(_failures == 0 ? '\nALL PASS' : '\n$_failures FAILURE(S)');
  if (_failures > 0) exitCode = 1;
}
