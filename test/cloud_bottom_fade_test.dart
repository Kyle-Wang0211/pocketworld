// 编辑态点云的滑轨渐隐:点只在滑轨上方出现。
//
// [2026-08-09 用户签决] "点云要是靠近滑轴就自动慢慢变淡,在滑轴处和下方都直接
// 变透明(所以就是,点云只在滑轴的上方出现)。" —— painter 的 bottomFade:
// 屏幕 y 落在 `height - bottomFade` 以下的点不画,其上 kCloudBottomFadeBand px
// 内 alpha 线性渐隐。只动显示,点一个不删(交付无损)。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';
import 'package:pocketworld_flutter/ui/sparse_thumbnail.dart';

/// 均匀球壳点云(白色)—— 投影后铺满画面,便于逐行采样。
(Float32List, Uint8List) sphere(int n) {
  final xyz = Float32List(n * 3);
  final rgb = Uint8List(n * 3);
  final rnd = math.Random(11);
  for (var i = 0; i < n; i++) {
    final u = rnd.nextDouble() * 2 - 1;
    final t = rnd.nextDouble() * 2 * math.pi;
    final s = math.sqrt(1 - u * u);
    xyz[i * 3] = 2 * s * math.cos(t);
    xyz[i * 3 + 1] = 2 * u;
    xyz[i * 3 + 2] = 2 * s * math.sin(t);
    rgb[i * 3] = 255;
    rgb[i * 3 + 1] = 255;
    rgb[i * 3 + 2] = 255;
  }
  return (xyz, rgb);
}

/// 画一张并返回每行最亮字节(0 = 该行全黑)。可选 [colFrom]/[colTo] 只统计
/// 某一列带(用于分别看屏幕中央与边缘 —— 弧线边界两处的高度不同)。
Future<List<int>> rowMax({
  required double bottomFade,
  double arcRadius = 0,
  int size = 400,
  int colFrom = 0,
  int colTo = -1,
}) async {
  final (xyz, rgb) = sphere(4000);
  final fit = SparseCloudPainter.fitOf(xyz);
  final sprite = await buildPointSprite();
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = Colors.black,
  );
  SparseCloudPainter(
    xyz: xyz,
    rgb: rgb,
    sprite: sprite,
    yaw: 0,
    pitch: 0,
    zoom: 1,
    panX: 0,
    panY: 0,
    pivotX: fit.cx,
    pivotY: fit.cy,
    pivotZ: fit.cz,
    pointSize: 3,
    exposure: 1,
    tone: 2,
    orthographic: kCloudOrthographic,
    drawSelectionWireframe: false,
    bottomFade: bottomFade,
    bottomFadeArcRadius: arcRadius,
  ).paint(canvas, Size(size.toDouble(), size.toDouble()));
  final img = await rec.endRecording().toImage(size, size);
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  sprite.dispose();
  img.dispose();
  final px = data!.buffer.asUint8List();
  final x1 = colTo < 0 ? size : colTo;
  return List<int>.generate(size, (y) {
    var mx = 0;
    for (var x = colFrom; x < x1; x++) {
      final o = (y * size + x) * 4;
      final v = math.max(px[o], math.max(px[o + 1], px[o + 2]));
      if (v > mx) mx = v;
    }
    return mx;
  });
}

void main() {
  test('bottomFade:滑轨处及以下全黑,渐隐带内变暗,其上原亮', () async {
    // 画布 700:渐隐带 240(用户"范围x2")之上还要留出满亮区做对照。
    const size = 700;
    const fadePx = 100.0;
    final rows = await rowMax(bottomFade: fadePx, size: size);
    // [2026-08-09 用户实机指认"离滑轴更远一点消失"] 边界抬高 kCloudBottomFadeGap。
    const cut = size - fadePx - kCloudBottomFadeGap;

    // ① 滑轨处及以下:一个亮像素都不许有(点圆盘半径余量 8px)。
    for (var y = cut.toInt() + 8; y < size; y++) {
      expect(rows[y], 0, reason: '第 $y 行(滑轨下方)仍有亮度 ${rows[y]} ⇒ 点云穿到滑轨后面了');
    }
    // ② 渐隐带内(紧贴边界上方)显著变暗:比画面上部的满亮度低。
    final brightTop = rows.sublist(120, 300).reduce(math.max); // 远离边界的满亮区(渐隐带外)
    final nearCut = rows.sublist(cut.toInt() - 24, cut.toInt() - 4);
    final nearMax = nearCut.reduce(math.max);
    expect(nearMax, greaterThan(0), reason: '渐隐带内不该直接全黑(应该是变淡)');
    expect(
      nearMax,
      lessThan(brightTop * 0.6),
      reason:
          '紧贴滑轨的点没有变淡(近界=$nearMax vs 上部=$brightTop)'
          ' ⇒ 是硬切不是渐隐',
    );
  });

  test('弧线边界:偏离中央的消失线更低(贴合滑轨曲线,不是横线)', () async {
    // [2026-08-09 用户实机指认] "点云和滑轴的边界需要是贴合滑轴的曲线而不是
    // 现在的横线。" 弧顶在中央 ⇒ 中央的边界最高;弧向两侧下垂 ⇒ 偏离中央的
    // 点可以画到更低的位置。
    //
    // ⚠️ 采样列带必须在球体投影覆盖区内(球投影是半径 ~162px 的圆盘,屏幕
    // 最边缘两列没有点)—— 第一版取 x∈[0,60] 量到的是球自己的轮廓,假红。
    const size = 700;
    const fadePx = 100.0;
    const arcR = 250.0; // 弧弯得足够明显:dx=115 处比中央低 ~28px
    int lowest(List<int> rows) {
      for (var y = rows.length - 1; y >= 0; y--) {
        if (rows[y] > 0) return y;
      }
      return -1;
    }

    final mid = await rowMax(
      bottomFade: fadePx,
      arcRadius: arcR,
      size: size,
      colFrom: 335,
      colTo: 365,
    );
    final side = await rowMax(
      bottomFade: fadePx,
      arcRadius: arcR,
      size: size,
      colFrom: 235,
      colTo: 265,
    );
    final midLow = lowest(mid), sideLow = lowest(side);
    expect(midLow, greaterThan(0));
    expect(sideLow, greaterThan(0));
    // 理论差:R - sqrt(R² - dx²),dx=85..115 → 15..28px。留裕量断 >10。
    expect(
      sideLow - midLow,
      greaterThan(10),
      reason:
          '侧带最低点 y=$sideLow 与中央 y=$midLow 齐平 ⇒ 边界还是横线,'
          '没有贴合滑轨弧线',
    );
    // 侧带的点也绝不越过它那一列的弧线(局部边界),取带内最远端 dx=115。
    const crest = size - fadePx - kCloudBottomFadeGap;
    final arcAtSide = crest + arcR - math.sqrt(arcR * arcR - 115.0 * 115.0);
    expect(
      sideLow,
      lessThan(arcAtSide + 9),
      reason: '侧带的点画到弧线下面去了(y=$sideLow > 弧=$arcAtSide)',
    );
  });

  test('bottomFade=0(缩略图/浏览态)⇒ 底部照常有点,行为不变', () async {
    final rows = await rowMax(bottomFade: 0);
    final bottomMax = rows.sublist(320, 392).reduce(math.max);
    expect(
      bottomMax,
      greaterThan(0),
      reason: '关掉 bottomFade 底部也没点了 ⇒ 默认行为被改坏,缩略图会缺一块',
    );
  });
}
