// multiband_color.dart — [RS-MULTIBAND 2026-08-14] 复刻 RealityScan 的
// **Multi-band 顶点上色**(官方 `Adjusting Coloring and Texturing Settings`
// 原文):
//
//   "Multi-band ... uses several channels, it divides images into more
//    frequencies, which are joined together afterwards. **Lower frequencies,
//    which can be joined linearly even in bigger surroundings, carry color and
//    brightness. Higher frequencies carry detail, for example texture grain
//    size, and are joined in a different optimized way.**"
//
// 映射到稀疏点云(我们交付的是顶点色,正对应 RS 的 Coloring 而非 Texturing):
//   · **低频 = 空间上缓变的颜色/亮度** → 在较大邻域内**线性融合**(= 该点全部
//     观测的均值场,再做邻域平滑)。这一段决定"整片云协不协调"。
//   · **高频 = 逐点细节**(纹理颗粒)→ 只来自**单一真实观测**(代表色),
//     混合会糊。
//
// 输出 = 低频(线性融合场) + 高频(代表色 − 代表色场的低频)
//      = T(p) + (C(p) − S(p))
// 其中 C=代表色(单源,保细节),S=C 的邻域低通,T=均值色的邻域低通。
// 直觉:把"每点各挑各帧"造成的**低频斑块**换成一个平滑一致的低频,而把
// 每个点自己的高频细节原样保留。
//
// **为什么不是"平均"**:纯平均(RS 的 Linear 档)会把高频一起抹平,也会重演
// 07-12 "白床单混入邻近红物 → 变粉"的合成色 bug —— 那个 bug 的成因是**跨表面
// 的观测被平均**。这里低频虽然融合,但融合的是**空间邻域**(同一片表面)的
// 颜色,且高频仍来自单一观测,不跨表面合成。
//
// 关闭时(默认)不调用本文件任何函数 ⇒ 行为逐位不变。
// 断言见 tool/multiband_color_check.dart。

import 'dart:math' as math;
import 'dart:typed_data';

/// 均匀体素网格近邻查询(点云 5 万量级足够快,O(n·k),无第三方依赖)。
class _VoxelGrid {
  _VoxelGrid(this.xyz, this.cell) {
    final n = xyz.length ~/ 3;
    for (var i = 0; i < n; i++) {
      final k = _key(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2]);
      (_buckets[k] ??= <int>[]).add(i);
    }
  }

  final Float32List xyz;
  final double cell;
  final Map<int, List<int>> _buckets = <int, List<int>>{};

  int _key(double x, double y, double z) {
    final ix = (x / cell).floor(), iy = (y / cell).floor(), iz = (z / cell).floor();
    // 三维格点 → 64 位哈希(质数混合,避免负数取模问题)。
    return ((ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791)) & 0x3FFFFFFF;
  }

  /// 收集 p 所在格及 26 邻格里的点(含自身);上限 [cap] 防止稠密区爆炸。
  List<int> neighbors(int i, int cap) {
    final x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2];
    final ix = (x / cell).floor(), iy = (y / cell).floor(), iz = (z / cell).floor();
    final out = <int>[];
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dz = -1; dz <= 1; dz++) {
          final k = (((ix + dx) * 73856093) ^
                  ((iy + dy) * 19349663) ^
                  ((iz + dz) * 83492791)) &
              0x3FFFFFFF;
          final b = _buckets[k];
          if (b == null) continue;
          for (final j in b) {
            out.add(j);
            if (out.length >= cap) return out;
          }
        }
      }
    }
    return out;
  }
}

/// 邻域低通:对 [src](扁平 RGB,0-255)按空间邻域求均值。
/// [radius] 内的点参与(欧氏距离),自身恒参与;无邻居时返回自身。
Float32List _lowPass(
    Float32List xyz, Float32List src, _VoxelGrid grid, double radius, int cap) {
  final n = xyz.length ~/ 3;
  final out = Float32List(n * 3);
  final r2 = radius * radius;
  for (var i = 0; i < n; i++) {
    final cand = grid.neighbors(i, cap);
    var sr = 0.0, sg = 0.0, sb = 0.0;
    var w = 0;
    final x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2];
    for (final j in cand) {
      final dx = xyz[j * 3] - x, dy = xyz[j * 3 + 1] - y, dz = xyz[j * 3 + 2] - z;
      if (dx * dx + dy * dy + dz * dz > r2) continue;
      sr += src[j * 3];
      sg += src[j * 3 + 1];
      sb += src[j * 3 + 2];
      w++;
    }
    if (w == 0) {
      out[i * 3] = src[i * 3];
      out[i * 3 + 1] = src[i * 3 + 1];
      out[i * 3 + 2] = src[i * 3 + 2];
    } else {
      out[i * 3] = sr / w;
      out[i * 3 + 1] = sg / w;
      out[i * 3 + 2] = sb / w;
    }
  }
  return out;
}

/// 点云尺度自适应的邻域半径:取全部点两两包围盒对角线的一个小比例,
/// 保证"bigger surroundings"在米制场景与厘米制场景下含义一致(跨端一致,
/// 不依赖任何设备/单位假设)。
double autoRadius(Float32List xyz) {
  final n = xyz.length ~/ 3;
  if (n < 2) return 0.0;
  var lo = List<double>.filled(3, double.infinity);
  var hi = List<double>.filled(3, -double.infinity);
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < 3; c++) {
      final v = xyz[i * 3 + c];
      if (v < lo[c]) lo[c] = v;
      if (v > hi[c]) hi[c] = v;
    }
  }
  final dx = hi[0] - lo[0], dy = hi[1] - lo[1], dz = hi[2] - lo[2];
  final diag = math.sqrt(dx * dx + dy * dy + dz * dz);
  return diag * 0.02; // 包围盒对角线的 2%
}

/// Multi-band 顶点上色。
///
/// [selected] = 代表色(单一真实观测,保高频);[linear] = 该点全部观测的
/// 线性均值(最稳的低频估计,对应 RS 的 "joined linearly");两者都是扁平
/// RGB(0-255,float)。返回混合后的 0-255 整数 RGB。
///
/// 公式:`out = T + (C − S)`,T/S 分别是 linear/selected 的邻域低通。
/// - 常色云:C≡S、T≡linear ⇒ out ≡ linear,无副作用;
/// - 阶跃边:C−S 保住跃变(高频不被抹),低频跟随邻域 ⇒ 边不糊。
Uint8List multiBandBlend({
  required Float32List xyz,
  required Float32List selected,
  required Float32List linear,
  double? radius,
  int neighborCap = 96,
}) {
  final n = xyz.length ~/ 3;
  final out = Uint8List(n * 3);
  final r = radius ?? autoRadius(xyz);
  if (n == 0 || r <= 0) {
    for (var k = 0; k < n * 3; k++) {
      out[k] = selected[k].round().clamp(0, 255);
    }
    return out;
  }
  final grid = _VoxelGrid(xyz, r);
  final s = _lowPass(xyz, selected, grid, r, neighborCap);
  final t = _lowPass(xyz, linear, grid, r, neighborCap);
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < 3; c++) {
      final v = t[i * 3 + c] + (selected[i * 3 + c] - s[i * 3 + c]);
      out[i * 3 + c] = v.round().clamp(0, 255);
    }
  }
  return out;
}
