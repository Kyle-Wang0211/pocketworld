// ruler_scrubber.dart — RS 同款无限刻度尺(Rotate Point Cloud)。
//
// [2026-07-28 用户签决] 复刻 RS:1)转动没有尽头,可一直拨动 360° 循环;
// 2)看似有刻度,实际可停在两刻度中间(连续值,不吸附)。
// 实现:中心固定指针,刻度带随手指滚动;角度按最短环向距离取模绘制,
// 环缝(±180°)处视觉无缝;值域不裁剪,由调用方决定是否归一化。
import 'dart:math' as math;

import 'package:flutter/material.dart';

class RulerScrubber extends StatelessWidget {
  const RulerScrubber({
    super.key,
    required this.value,
    required this.onChanged,
    this.pixelsPerDegree = 2.2,
    this.height = 56,
  });

  /// 当前角度(度,任意实数;绘制按 mod 360 环向处理)。
  final double value;
  final ValueChanged<double> onChanged;

  /// 刻度密度(像素/度)。拖动灵敏度 = 1/pixelsPerDegree 度/像素。
  final double pixelsPerDegree;
  final double height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 刻度带跟手:手指右移 → 刻度右移 → 读数变小。无端点,不 clamp。
      onHorizontalDragUpdate: (d) =>
          onChanged(value - d.delta.dx / pixelsPerDegree),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _RulerPainter(value: value, pxPerDeg: pixelsPerDegree),
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  const _RulerPainter({required this.value, required this.pxPerDeg});

  final double value;
  final double pxPerDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final halfW = size.width / 2;
    const minorStep = 5.0; // 小刻度 5°
    const majorEvery = 30.0; // 大刻度 30°
    final tickTop = size.height * 0.35;
    final baseline = size.height;

    for (var a = 0.0; a < 360.0; a += minorStep) {
      // 最短环向距离 → 环缝处无缝循环。
      var delta = (a - value) % 360.0;
      if (delta > 180.0) delta -= 360.0;
      final x = cx + delta * pxPerDeg;
      if (x < -2 || x > size.width + 2) continue;
      final isMajor = a % majorEvery == 0;
      // 边缘淡出(RS 观感)。
      final fade = 1.0 - math.pow((x - cx).abs() / halfW, 2.0).toDouble();
      final alpha = ((isMajor ? 0.95 : 0.45) * fade.clamp(0.0, 1.0) * 255)
          .round();
      final h = isMajor ? baseline - tickTop : (baseline - tickTop) * 0.62;
      canvas.drawLine(
        Offset(x, baseline - h),
        Offset(x, baseline),
        Paint()
          ..color = Color.fromARGB(alpha, 255, 255, 255)
          ..strokeWidth = isMajor ? 2.0 : 1.4
          ..strokeCap = StrokeCap.round,
      );
    }

    // 中心固定指针:小水滴(圆头+尖脚),RS 同款。
    final pinY = tickTop * 0.45;
    const r = 4.5;
    final pin = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, pinY), radius: r))
      ..moveTo(cx - r * 0.7, pinY + r * 0.6)
      ..lineTo(cx, pinY + r * 2.2)
      ..lineTo(cx + r * 0.7, pinY + r * 0.6)
      ..close();
    canvas.drawPath(pin, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.value != value || old.pxPerDeg != pxPerDeg;
}
