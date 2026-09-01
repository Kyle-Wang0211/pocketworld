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

import 'dart:math' as math;
import 'dart:typed_data';

/// 遥测【colorize】的每点观测数直方图桶(任务 E:buckets[1,2,3-4,5-8,9+]):
/// 返回 0..4 = [1, 2, 3-4, 5-8, 9+] 的桶下标。count<=0 不应入直方图,
/// 调用方先用 hitCount 过滤;防御性归入桶 0。
/// tool/telemetry_check.dart 有边界断言。
/// [RS-CORRECT-COLORS v3 2026-08-14] sRGB 编码值(0-255)⇄ 线性光(缩放到 0-255)。
///
/// **为什么必须转**:曝光只有在**线性光**里才是纯乘法。AliceVision 官方实现
/// (PR #656)原文:"exposure correction must be applied in Linear colorspace
/// while texturing must be done in sRGB colorspace"。v2 直接在 sRGB 值上拟合
/// ⇒ 增益跨度 0.572~1.279(过校正),线性光判据 0.400 比**不校正的 0.178 还差**;
/// 诊断图显示它把每帧的估计误差整片画到点云上,肉眼读作"光影"(用户当场发现
/// "B 的光影感更强"——那不是优点,是误差有空间结构)。
///
/// 缩放回 0-255 量级是必需的:Brown&Lowe 的 α/β 按灰阶标定(σ_N=10 灰阶),
/// 不缩放会让数据项小 4 个数量级、先验把增益全钉在 1.0。
double srgbToLinear255(double v) {
  final c = v / 255.0;
  final lin = c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return lin * 255.0;
}

double linear255ToSrgb(double v) {
  final c = (v < 0 ? 0.0 : v) / 255.0;
  final e = c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;
  return e * 255.0;
}

int obsHistBucket(int count) {
  if (count <= 1) return 0;
  if (count == 2) return 1;
  if (count <= 4) return 2;
  if (count <= 8) return 3;
  return 4;
}

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
/// [RS-CORRECT-COLORS 2026-08-14] 每帧三通道增益,复刻 RealityScan 的
/// `Correct colors`(官方原文:"Automatically compensate the **color, brightness
/// and contrast** differences across all images in the selected component")。
///
/// 为什么需要它(实测,s4 场 85 帧 / 1058 个 TVG 内点配对):
/// 帧间同点亮度比 中位 1.072 / p90 1.304;拟合每帧三通道增益后残差降到
/// 中位 1.013 / p90 1.057 —— **81% 的跨视角颜色分歧是每帧曝光/白平衡漂移**,
/// 不是材质的视角相关性。相机是 `.continuousAutoExposure`(未锁),增益实测
/// 跨度 R 0.765~1.148 / G 0.693~1.174 / B 0.678~1.215;三通道范围互不相同 ⇒
/// 白平衡也在漂,只做亮度一维会漏掉。
///
/// 不校正的后果不是"某个点颜色不准",而是**整片云不协调**:相邻两点各自
/// 挑了不同帧的真实观测,颜色都真,但差 25% 亮度 ⇒ 斑块。
class FrameColorGains {
  FrameColorGains(this.frames)
      : logGain = Float64List(frames * 3),
        banned = Uint8List(frames);

  final int frames;

  /// `[frame*3+c]` 的 **log** 增益;校正值 = 原值 / exp(logGain)。
  final Float64List logGain;

  /// 1 = 该帧残差离群被剔除(对应 RS 的"禁用图片":不参与变换,自身不变)。
  final Uint8List banned;

  /// **线性光**里的乘性增益(Brown&Lowe 约定:校正值 = g × I_linear)。
  double gainOf(int frame, int c) =>
      frame < 0 || frame >= frames ? 1.0 : math.exp(logGain[frame * 3 + c]);

  /// 把一个 sRGB 编码采样值按该帧增益校正,仍返回 sRGB 编码值。
  /// 三步 = AliceVision 口径:解码到线性光 → 乘增益 → 编码回 sRGB。
  double correct(double srgbValue, int frame, int c) =>
      linear255ToSrgb(srgbToLinear255(srgbValue) * gainOf(frame, c));

  /// 遥测:各通道增益的 [min,max]。
  List<double> get span {
    var lo = double.infinity, hi = -double.infinity;
    for (var f = 0; f < frames; f++) {
      for (var c = 0; c < 3; c++) {
        final g = math.exp(logGain[f * 3 + c]);
        if (g < lo) lo = g;
        if (g > hi) hi = g;
      }
    }
    return frames == 0 ? <double>[1, 1] : <double>[lo, hi];
  }

  int get bannedCount {
    var n = 0;
    for (final b in banned) {
      if (b != 0) n++;
    }
    return n;
  }
}

class RepresentativeColorSamples {
  final Int32List _base; // 每点样本区起点(以样本个数计)
  final Int32List _cap; // 每点容量
  final Int32List _count; // 每点已收样本数
  final Float32List _rgb; // 扁平样本池 [r,g,b]*
  final Int32List _frame; // [RS-CORRECT-COLORS] 每样本来自第几帧(-1=未知)

  RepresentativeColorSamples._(
      this._base, this._cap, this._count, this._rgb, this._frame);

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
      Int32List(total)..fillRange(0, total, -1),
    );
  }

  /// 收一条点 i 的双线性采样样本(0-255 浮点)。超容量静默丢弃(理论不触发)。
  /// [frame] = 该样本来自哪一帧(jobs 下标);不传 = -1,增益估计会忽略它。
  void add(int i, double r, double g, double b, [int frame = -1]) {
    final c = _count[i];
    if (c >= _cap[i]) return;
    final o = (_base[i] + c) * 3;
    _rgb[o] = r;
    _rgb[o + 1] = g;
    _rgb[o + 2] = b;
    _frame[_base[i] + c] = frame;
    _count[i] = c + 1;
  }

  /// 点 i 的已收样本数(替代旧 hits[i])。
  int hitCount(int i) => _count[i];

  /// 遥测【colorize】混色嫌疑信号(任务 E):点 i 全部样本 RGB 对代表色
  /// (r,g,b) 的均方差(RMS,0-255 灰阶单位)——每样本三通道平方差取均值、
  /// 再对样本取均值、开方。样本数 <2 时返回 0(单样本无离散度)。
  /// 白床单混入红观测的点该值显著升高(阈值 40 见 ar_capture_page 的
  /// colorize 遥测),纯色表面接近 JPEG 噪声地板(<10)。
  double rmsDeviation(int i, int r, int g, int b) {
    final c = _count[i];
    if (c < 2) return 0;
    var sum = 0.0;
    for (var k = 0; k < c; k++) {
      final o = (_base[i] + k) * 3;
      final dr = _rgb[o] - r;
      final dg = _rgb[o + 1] - g;
      final db = _rgb[o + 2] - b;
      sum += (dr * dr + dg * dg + db * db) / 3.0;
    }
    return math.sqrt(sum / c);
  }

  /// 为点 i 选代表色写入 out[i*3 .. i*3+2]。无样本返回 false(调用方涂灰)。
  ///
  /// [gains] 为 null 时**逐位等同于校正前的旧实现**(默认路径不受影响)。
  /// 给了 [gains]:
  ///   - 选择永远在**校正后的亮度**上比较(修的是"挑到曝光更低的帧"这个偏差);
  ///   - [applyToOutput]=false → 输出被选样本的**原始 RGB**(仍是真实观测);
  ///   - [applyToOutput]=true  → 输出校正后的 RGB(RS `Correct colors` 的忠实
  ///     形态:颜色仍来自这个点自己的那次观测,只是按整帧倍数缩放,不与任何
  ///     其它表面混合 —— 与"白床单变粉"那个**平均**bug 不是一类)。
  bool selectInto(int i, Uint8List out,
      {FrameColorGains? gains, bool applyToOutput = false}) {
    final c = _count[i];
    if (c == 0) return false;
    if (gains == null) {
      final s = selectRepresentativeSample(_rgb, _base[i], c);
      final o = s * 3;
      out[i * 3] = _rgb[o].round().clamp(0, 255);
      out[i * 3 + 1] = _rgb[o + 1].round().clamp(0, 255);
      out[i * 3 + 2] = _rgb[o + 2].round().clamp(0, 255);
      return true;
    }
    // 校正后亮度的下中位数选择(规则与 selectRepresentativeSample 一致:
    // 下中位数 → 距离最小 → 并列取更暗 → 再并列取靠前)。
    final base = _base[i];
    final lum = Float64List(c);
    for (var k = 0; k < c; k++) {
      final o = (base + k) * 3;
      final f = _frame[base + k];
      final r = gains.correct(_rgb[o], f, 0);
      final g = gains.correct(_rgb[o + 1], f, 1);
      final b = gains.correct(_rgb[o + 2], f, 2);
      lum[k] = 0.299 * r + 0.587 * g + 0.114 * b;
    }
    final sorted = Float64List.fromList(lum)..sort();
    final median = sorted[(c - 1) >> 1];
    var best = 0;
    var bestDist = double.infinity;
    for (var k = 0; k < c; k++) {
      final d = (lum[k] - median).abs();
      if (d < bestDist || (d == bestDist && lum[k] < lum[best])) {
        best = k;
        bestDist = d;
      }
    }
    final o = (base + best) * 3;
    final f = _frame[base + best];
    final sr = applyToOutput ? gains.correct(_rgb[o], f, 0) : _rgb[o];
    final sg = applyToOutput ? gains.correct(_rgb[o + 1], f, 1) : _rgb[o + 1];
    final sb = applyToOutput ? gains.correct(_rgb[o + 2], f, 2) : _rgb[o + 2];
    out[i * 3] = sr.round().clamp(0, 255);
    out[i * 3 + 1] = sg.round().clamp(0, 255);
    out[i * 3 + 2] = sb.round().clamp(0, 255);
    return true;
  }

  /// [RS-MULTIBAND 2026-08-14] 代表色的**浮点**版(写 out[i*3..]),语义与
  /// [selectInto] 完全一致,只是不取整 —— multi-band 要在浮点域做频段加减,
  /// 先取整会把量化误差带进低频。
  bool selectIntoFloat(int i, Float32List out,
      {FrameColorGains? gains, bool applyToOutput = false}) {
    final c = _count[i];
    if (c == 0) return false;
    final base = _base[i];
    int best;
    if (gains == null) {
      best = selectRepresentativeSample(_rgb, base, c) - base;
    } else {
      final lum = Float64List(c);
      for (var k = 0; k < c; k++) {
        final o = (base + k) * 3;
        final f = _frame[base + k];
        lum[k] = 0.299 * gains.correct(_rgb[o], f, 0) +
            0.587 * gains.correct(_rgb[o + 1], f, 1) +
            0.114 * gains.correct(_rgb[o + 2], f, 2);
      }
      final sorted = Float64List.fromList(lum)..sort();
      final median = sorted[(c - 1) >> 1];
      best = 0;
      var bestDist = double.infinity;
      for (var k = 0; k < c; k++) {
        final d = (lum[k] - median).abs();
        if (d < bestDist || (d == bestDist && lum[k] < lum[best])) {
          best = k;
          bestDist = d;
        }
      }
    }
    final o = (base + best) * 3;
    final f = _frame[base + best];
    final useGain = gains != null && applyToOutput;
    out[i * 3] = useGain ? gains.correct(_rgb[o], f, 0) : _rgb[o];
    out[i * 3 + 1] = useGain ? gains.correct(_rgb[o + 1], f, 1) : _rgb[o + 1];
    out[i * 3 + 2] = useGain ? gains.correct(_rgb[o + 2], f, 2) : _rgb[o + 2];
    return true;
  }

  /// [RS-MULTIBAND 2026-08-14] 该点全部观测的**线性均值**(RS 原文
  /// "joined linearly"),作为 multi-band 的**低频**来源。给了 [gains] 则先
  /// 按帧增益校正再平均 —— 否则均值本身就被曝光漂移污染。
  ///
  /// ⚠️ 它**只用于低频**。直接把均值当交付色就是 RS 的 Linear 档,会重演
  /// 07-12 "白床单混入邻近红观测 → 变粉"的合成色 bug;multi-band 的高频仍
  /// 来自单一真实观测,所以不会跨表面合成。
  bool meanIntoFloat(int i, Float32List out, {FrameColorGains? gains}) {
    final c = _count[i];
    if (c == 0) return false;
    final base = _base[i];
    var sr = 0.0, sg = 0.0, sb = 0.0;
    for (var k = 0; k < c; k++) {
      final o = (base + k) * 3;
      final f = _frame[base + k];
      if (gains == null) {
        sr += _rgb[o];
        sg += _rgb[o + 1];
        sb += _rgb[o + 2];
      } else {
        sr += gains.correct(_rgb[o], f, 0);
        sg += gains.correct(_rgb[o + 1], f, 1);
        sb += gains.correct(_rgb[o + 2], f, 2);
      }
    }
    out[i * 3] = sr / c;
    out[i * 3 + 1] = sg / c;
    out[i * 3 + 2] = sb / c;
    return true;
  }

  /// [RS-CORRECT-COLORS v3 2026-08-14] 每帧三通道增益 = **Brown & Lowe 增益补偿,
  /// 在线性光里解**。这是全景拼接/多视纹理的行业标准,权威实现见 OpenCV
  /// `modules/stitching/src/exposure_compensate.cpp`(GainCompensator /
  /// ChannelsCompensator)。
  ///
  /// 目标(每通道独立,= ChannelsCompensator):
  ///   min Σ_{i<j} N_ij · [ α·(g_i·Ī_ij − g_j·Ī_ji)² + β·(1−g_i)² ]
  ///   · Ī_ij / Ī_ji = 帧 i / j 在**共视点**上的线性光均值,N_ij = 共视点数;
  ///   · α=0.01, β=100 —— 论文的 σ_N=10 灰阶、σ_g=0.1(OpenCV 同值);
  ///   · 先验项把增益拉向 1(= 保住整体亮度,并杜绝 g→0 的退化解)。
  ///
  /// 🔴 两版失败史(都被实测/肉眼当场否掉,勿回退):
  /// v1「每点样本下中位数当参考」——61% 的点只有 2 个观测,下中位数就是其中
  ///    一个样本 ⇒ 该帧残差恒 0,**结构性没信号**;跨度只有 0.97~1.19,交付
  ///    颜色只动 1 灰阶,用户看三档"没有任何区别"。
  /// v2「sRGB 空间 log 图拟合」——域用错(曝光只有在线性光里才是纯乘法),
  ///    跨度 0.572~1.279 = 过校正;线性光判据 0.400 **比不校正的 0.178 还差**;
  ///    诊断图显示它把每帧误差整片画到点云上,肉眼读作"光影感更强"——那是
  ///    误差有空间结构(每帧覆盖一片连续区域),不是恢复了真实光照。
  ///
  /// 末轮按增益幅度 3σ(MAD)剔坏帧 = RS 的"禁用图片"(不参与变换、自身不变)。
  FrameColorGains estimateFrameGains(int frameCount,
      {int iterations = 200,
      double minLevel = 12.0,
      int minPairPoints = 30,
      double alpha = 0.01,
      double beta = 100.0}) {
    final out = FrameColorGains(frameCount);
    if (frameCount <= 0) return out;

    // ── 帧对统计:共视点上的**线性光均值**与共视点数 ──
    final sumA = <int, Float64List>{}; // key = f1*frameCount+f2 (f1<f2)
    final sumB = <int, Float64List>{};
    final cnt = <int, int>{};
    final n = _count.length;
    for (var i = 0; i < n; i++) {
      final c = _count[i];
      if (c < 2) continue;
      final base = _base[i];
      for (var a = 0; a < c; a++) {
        final fa = _frame[base + a];
        if (fa < 0 || fa >= frameCount) continue;
        for (var b = a + 1; b < c; b++) {
          final fb = _frame[base + b];
          if (fb < 0 || fb >= frameCount || fb == fa) continue;
          final aIsLo = fa < fb;
          final key = (aIsLo ? fa : fb) * frameCount + (aIsLo ? fb : fa);
          final oa = (base + (aIsLo ? a : b)) * 3;
          final ob = (base + (aIsLo ? b : a)) * 3;
          final sa = sumA.putIfAbsent(key, () => Float64List(3));
          final sb = sumB.putIfAbsent(key, () => Float64List(3));
          for (var ch = 0; ch < 3; ch++) {
            sa[ch] += srgbToLinear255(_rgb[oa + ch]);
            sb[ch] += srgbToLinear255(_rgb[ob + ch]);
          }
          cnt[key] = (cnt[key] ?? 0) + 1;
        }
      }
    }
    final e1 = <int>[], e2 = <int>[], ew = <int>[];
    final ia = <Float64List>[], ib = <Float64List>[];
    cnt.forEach((key, N) {
      if (N < minPairPoints) return;
      final sa = sumA[key]!, sb = sumB[key]!;
      final ma = Float64List(3), mb = Float64List(3);
      for (var ch = 0; ch < 3; ch++) {
        ma[ch] = sa[ch] / N;
        mb[ch] = sb[ch] / N;
      }
      // 太暗的对不参与:线性光下暗部比值噪声极大。
      if (ma[1] < srgbToLinear255(minLevel) || mb[1] < srgbToLinear255(minLevel)) {
        return;
      }
      e1.add(key ~/ frameCount);
      e2.add(key % frameCount);
      ew.add(N);
      ia.add(ma);
      ib.add(mb);
    });
    if (ia.isEmpty) return out; // 共视不足 ⇒ 增益全 1 = 不校正

    // ── Gauss-Seidel 解上面的正规方程(逐通道) ──
    final num = Float64List(frameCount), den = Float64List(frameCount);
    for (var ch = 0; ch < 3; ch++) {
      final g = Float64List(frameCount)..fillRange(0, frameCount, 1.0);
      for (var it = 0; it < iterations; it++) {
        num.fillRange(0, frameCount, 0);
        den.fillRange(0, frameCount, 0);
        for (var k = 0; k < ia.length; k++) {
          final a = e1[k], b = e2[k];
          final N = ew[k].toDouble();
          final meanA = ia[k][ch], meanB = ib[k][ch];
          num[a] += alpha * N * meanA * meanB * g[b] + beta * N;
          den[a] += alpha * N * meanA * meanA + beta * N;
          num[b] += alpha * N * meanB * meanA * g[a] + beta * N;
          den[b] += alpha * N * meanB * meanB + beta * N;
        }
        for (var f = 0; f < frameCount; f++) {
          if (den[f] > 0) g[f] = num[f] / den[f];
        }
      }
      for (var f = 0; f < frameCount; f++) {
        out.logGain[f * 3 + ch] = math.log(g[f] <= 0 ? 1.0 : g[f]);
      }
    }

    // 坏帧剔除(= RS "禁用图片"):增益幅度离群 >3σ(MAD)⇒ 锁 1.0。
    final mags = <double>[];
    for (var f = 0; f < frameCount; f++) {
      var m = 0.0;
      for (var ch = 0; ch < 3; ch++) {
        m += out.logGain[f * 3 + ch].abs();
      }
      mags.add(m / 3.0);
    }
    final sortedMag = List<double>.from(mags)..sort();
    final med = sortedMag[(sortedMag.length - 1) >> 1];
    final dev = (mags.map((x) => (x - med).abs()).toList()..sort());
    final mad = dev[(dev.length - 1) >> 1];
    final thr = med + 3 * 1.4826 * (mad <= 0 ? 1e-6 : mad);
    for (var f = 0; f < frameCount; f++) {
      if (mags[f] > thr) {
        out.banned[f] = 1;
        for (var ch = 0; ch < 3; ch++) {
          out.logGain[f * 3 + ch] = 0.0;
        }
      }
    }
    return out;
  }
}
