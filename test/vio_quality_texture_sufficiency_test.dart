// 条目 10 单测:纹理充分性。
// 合成数据 = 已知点数 N + 已知等效面积占比 φ_true → 确认 φ̂ 能还原 φ_true,
// 且与 N 解耦。负向对照直接把**上一版的公式**在测试里重算一遍,证明它会被骗过。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/quality/texture_sufficiency.dart';

const int kW = 640;
const int kH = 480;

/// N 个点均匀撒在画面左上角 [areaFraction] 比例的**正方形子区域**内。
Float32List _points(int n, double areaFraction, {int seed = 3}) {
  final r = math.Random(seed);
  final side = math.sqrt(areaFraction);
  final w = kW * side, h = kH * side;
  final out = Float32List(n * 2);
  for (var i = 0; i < n; i++) {
    out[i * 2] = r.nextDouble() * w;
    out[i * 2 + 1] = r.nextDouble() * h;
  }
  return out;
}

/// 🔴 上一版(2026-08-22)的分布指标,原样重算,用作负向对照。
///     spreadRatio = exp(H) / min(N, K),K = 16×16 固定
double _legacySpreadRatio(Float32List xy) {
  const side = 16;
  const k = side * side;
  final hist = List<int>.filled(k, 0);
  var n = 0;
  final m = xy.length ~/ 2;
  for (var i = 0; i < m; i++) {
    final x = xy[i * 2], y = xy[i * 2 + 1];
    if (x < 0 || y < 0 || x >= kW || y >= kH) continue;
    var cx = (x * side / kW).floor();
    var cy = (y * side / kH).floor();
    if (cx >= side) cx = side - 1;
    if (cy >= side) cy = side - 1;
    hist[cy * side + cx]++;
    n++;
  }
  if (n == 0) return 0.0;
  var h = 0.0;
  for (final c in hist) {
    if (c == 0) continue;
    final p = c / n;
    h -= p * math.log(p);
  }
  return math.exp(h) / math.min(n, k);
}

void main() {
  group('E[H] 解析式必须是对的(独立蒙特卡洛校验)', () {
    // 这是整个指标的地基:φ̂ 是拿 E[H] 反解出来的。地基错了上面全错。
    for (final nk in const <List<int>>[
      [60, 25],
      [400, 196],
      [40, 16],
    ]) {
      final n = nk[0], k = nk[1];
      test('N=$n, K=$k:解析 E[H] 与蒙特卡洛一致', () {
        final r = math.Random(99);
        const trials = 4000;
        var acc = 0.0;
        for (var t = 0; t < trials; t++) {
          final hist = List<int>.filled(k, 0);
          for (var i = 0; i < n; i++) {
            hist[r.nextInt(k)]++;
          }
          var h = 0.0;
          for (final c in hist) {
            if (c == 0) continue;
            final p = c / n;
            h -= p * math.log(p);
          }
          acc += h;
        }
        final mc = acc / trials;
        final analytic = expectedUniformEntropy(n, k.toDouble());
        expect(analytic, closeTo(mc, 0.01), reason: 'MC=$mc analytic=$analytic');
      });
    }
  });

  group('φ̂ 还原已知面积占比,且与点数解耦', () {
    for (final n in const [60, 200, 800]) {
      test('N=$n 均匀铺满整帧 ⇒ φ̂ ≈ 1', () {
        final s = evaluateTextureSufficiency(
          xy: _points(n, 1.0),
          imageWidth: kW,
          imageHeight: kH,
        );
        expect(
          s.effectiveAreaFraction,
          greaterThan(0.80),
          reason: 'N=$n 得到 ${s.effectiveAreaFraction}',
        );
      });

      test('N=$n 挤在 1/4 画面 ⇒ φ̂ ≈ 0.25(不随 N 漂)', () {
        final s = evaluateTextureSufficiency(
          xy: _points(n, 0.25),
          imageWidth: kW,
          imageHeight: kH,
        );
        expect(
          s.effectiveAreaFraction,
          closeTo(0.25, 0.09),
          reason: 'N=$n 得到 ${s.effectiveAreaFraction}',
        );
      });

      test('N=$n 挤在 1/16 画面 ⇒ φ̂ ≈ 0.0625', () {
        final s = evaluateTextureSufficiency(
          xy: _points(n, 0.0625),
          imageWidth: kW,
          imageHeight: kH,
        );
        expect(
          s.effectiveAreaFraction,
          closeTo(0.0625, 0.045),
          reason: 'N=$n 得到 ${s.effectiveAreaFraction}',
        );
      });
    }
  });

  group('🔴 推翻上一版:固定 K 的 spreadRatio 在 N ≤ K 时对聚簇失明', () {
    test('N=60 挤在 1/4 画面:旧公式判达标,新公式压在门上', () {
      final xy = _points(60, 0.25);
      final legacy = _legacySpreadRatio(xy);
      final s = evaluateTextureSufficiency(
        xy: xy,
        imageWidth: kW,
        imageHeight: kH,
        // 数量门放低,把变量隔离成"只看分布"。
        config: const TextureConfig(minKeypointCount: 10),
      );

      // 负向对照:旧公式远远高于 0.25 的门 ⇒ 会判 sufficient。
      expect(
        legacy,
        greaterThan(0.55),
        reason: '旧 spreadRatio=$legacy(分母 min(N,K)=N 把聚簇洗掉了)',
      );
      // 新公式给出接近真值 0.25 的读数。
      expect(s.effectiveAreaFraction, lessThan(0.40));
      expect(s.gridSide, lessThan(kTextureGridSideMax), reason: '网格随 N 变粗');
    });

    test('N=60 挤在 1/16 画面:两版都能抓到,但只有新版读数对得上真值', () {
      final xy = _points(60, 0.0625);
      final legacy = _legacySpreadRatio(xy);
      final s = evaluateTextureSufficiency(
        xy: xy,
        imageWidth: kW,
        imageHeight: kH,
        config: const TextureConfig(minKeypointCount: 10),
      );
      expect(s.verdict, TextureVerdict.clustered);
      expect(s.effectiveAreaFraction, closeTo(0.0625, 0.045));
      // 旧公式虽然也低于门,但读数与真值 0.0625 差很多 —— 它压根不是"面积
      // 占比",不能拿来做引导进度。
      expect(
        (legacy - 0.0625).abs(),
        greaterThan(0.10),
        reason: '旧 spreadRatio=$legacy',
      );
    });
  });

  group('四档结论', () {
    test('白墙:点少且挤 ⇒ starved', () {
      final s = evaluateTextureSufficiency(
        xy: _points(8, 0.02),
        imageWidth: kW,
        imageHeight: kH,
      );
      expect(s.verdict, TextureVerdict.starved);
    });

    test('弱纹理但铺开:点少、分布好 ⇒ sparse', () {
      final s = evaluateTextureSufficiency(
        xy: _points(20, 1.0),
        imageWidth: kW,
        imageHeight: kH,
      );
      expect(s.keypointCount, 20);
      expect(s.effectiveAreaFraction, greaterThan(0.6));
      expect(s.verdict, TextureVerdict.sparse);
    });

    test('海报:点多但挤 ⇒ clustered', () {
      final s = evaluateTextureSufficiency(
        xy: _points(400, 0.05),
        imageWidth: kW,
        imageHeight: kH,
      );
      expect(s.verdict, TextureVerdict.clustered);
    });

    test('正常场景 ⇒ sufficient', () {
      final s = evaluateTextureSufficiency(
        xy: _points(400, 1.0),
        imageWidth: kW,
        imageHeight: kH,
      );
      expect(s.verdict, TextureVerdict.sufficient);
      expect(s.isSufficient, isTrue);
    });
  });

  group('输入卫生与既有尺子的复用', () {
    test('越界点与非有限点被丢弃,不计入 keypointCount', () {
      final xy = Float32List.fromList(<double>[
        10, 10, // 有效
        -5, 10, // 越界
        10, 999, // 越界
        double.nan, 10, // 非有限
        double.infinity, 3, // 非有限
        20, 20, // 有效
      ]);
      final s = evaluateTextureSufficiency(
        xy: xy,
        imageWidth: kW,
        imageHeight: kH,
      );
      expect(s.keypointCount, 2);
    });

    test('零点 ⇒ starved,不崩', () {
      final s = evaluateTextureSufficiency(
        xy: Float32List(0),
        imageWidth: kW,
        imageHeight: kH,
      );
      expect(s.verdict, TextureVerdict.starved);
      expect(s.keypointCount, 0);
    });

    test('网格上限复用既有 16×16 novelty 签名网格', () {
      expect(kTextureGridSideMax, 16);
      // 大 N 时被上限夹住,不会无限细分。
      expect(adaptiveGridSide(100000), 16);
      // 小 N 时不会细过 2×2。
      expect(adaptiveGridSide(1), 2);
      expect(adaptiveGridSide(0), 2);
      // 目标每格 2 点:N=50 ⇒ side = round(sqrt(25)) = 5。
      expect(adaptiveGridSide(50), 5);
    });

    test('大 N 走渐近分支时 E[H] 仍单调、有界', () {
      final a = expectedUniformEntropy(100000, 256.0);
      expect(a, lessThan(math.log(256)));
      expect(a, greaterThan(math.log(256) - 0.01));
      expect(a, greaterThan(expectedUniformEntropy(100000, 128.0)));
    });
  });
}
