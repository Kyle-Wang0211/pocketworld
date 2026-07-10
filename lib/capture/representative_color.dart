// 代表色选择 — 修"白床单变粉"的观测混色 bug(handoff §16.6)。
//
// 旧归约把一个点在其 track 全部观测里采到的 RGB 做算术平均:白床单上的点
// 大多数观测是白(255,255,255),个别观测扫到相邻红物(255,0,0),平均后变成
// 粉(255,191,191)——合成出一个从未被任何照片拍到过的颜色。
//
// 本文件改为"真实观测代表色":收集每点全部有效双线性采样样本,归约时选
// 亮度(0.299R+0.587G+0.114B)最接近样本亮度下中位数的那个**真实样本**,
// 输出它的完整 RGB——不合成、不平均,输出永远是某次真实观测到的颜色。
// 样本数=1 时就是它自己;=2 时下中位数落在更暗的样本上。
//
// 两个调用方——live 的 _colorizeSnapshot(ar_capture_page.dart)与冷恢复的
// _persistColored(sfm_resume.dart)——共享此实现,保证现场取色与恢复取色
// 逐点一致(handoff §7.3)。

import 'dart:typed_data';

/// 纯函数:在扁平 `[r,g,b, r,g,b, ...]` 样本池中,对从第 `start` 个样本起、
/// 共 `count` 个样本选代表样本,返回被选样本的样本下标(RGB 起点 = 下标*3)。
///
/// 规则:取样本亮度的下中位数(count 为偶数时取中间偏暗的那个),选亮度与其
/// 距离最小的样本;距离并列取更暗者,再并列取靠前者。因为下中位数本身就是
/// 某个样本的亮度,结果等价于"第一个亮度等于下中位数的样本"——确定性、
/// 不依赖浮点容差。
int selectRepresentativeSample(Float32List samples, int start, int count) {
  assert(count > 0);
  if (count == 1) return start;
  final lumas = Float64List(count);
  for (var k = 0; k < count; k++) {
    final o = (start + k) * 3;
    lumas[k] =
        0.299 * samples[o] + 0.587 * samples[o + 1] + 0.114 * samples[o + 2];
  }
  final sorted = Float64List.fromList(lumas)..sort();
  final median = sorted[(count - 1) >> 1]; // 下中位数:count=2 时即更暗者
  var best = 0;
  var bestDist = double.infinity;
  for (var k = 0; k < count; k++) {
    final d = (lumas[k] - median).abs();
    if (d < bestDist || (d == bestDist && lumas[k] < lumas[best])) {
      best = k;
      bestDist = d;
    }
  }
  return start + best;
}

/// 每点观测样本收集器(CSR 紧凑扁平存储,替代旧 sumR/sumG/sumB 累加器)。
///
/// 容量按每点有效观测数预分配(~10 万点 × 5-10 观测 × 3×4B ≈ 几 MB,可接受);
/// 解码失败/采样越界的观测不会入池,实际样本数可小于容量。
class RepresentativeColorSamples {
  final Int32List _base; // 每点样本区起点(以样本个数计)
  final Int32List _cap; // 每点容量
  final Int32List _count; // 每点已收样本数
  final Float32List _rgb; // 扁平样本池 [r,g,b]*

  RepresentativeColorSamples._(this._base, this._cap, this._count, this._rgb);

  factory RepresentativeColorSamples(Int32List capacityPerPoint) {
    final n = capacityPerPoint.length;
    final base = Int32List(n);
    var total = 0;
    for (var i = 0; i < n; i++) {
      base[i] = total;
      total += capacityPerPoint[i];
    }
    return RepresentativeColorSamples._(
      base,
      capacityPerPoint,
      Int32List(n),
      Float32List(total * 3),
    );
  }

  /// 收一条点 i 的双线性采样样本(0-255 浮点)。超容量静默丢弃(理论不触发)。
  void add(int i, double r, double g, double b) {
    final c = _count[i];
    if (c >= _cap[i]) return;
    final o = (_base[i] + c) * 3;
    _rgb[o] = r;
    _rgb[o + 1] = g;
    _rgb[o + 2] = b;
    _count[i] = c + 1;
  }

  /// 点 i 的已收样本数(替代旧 hits[i])。
  int hitCount(int i) => _count[i];

  /// 为点 i 选代表色写入 out[i*3 .. i*3+2]。无样本返回 false(调用方涂灰)。
  bool selectInto(int i, Uint8List out) {
    final c = _count[i];
    if (c == 0) return false;
    final s = selectRepresentativeSample(_rgb, _base[i], c);
    final o = s * 3;
    out[i * 3] = _rgb[o].round().clamp(0, 255);
    out[i * 3 + 1] = _rgb[o + 1].round().clamp(0, 255);
    out[i * 3 + 2] = _rgb[o + 2].round().clamp(0, 255);
    return true;
  }
}
