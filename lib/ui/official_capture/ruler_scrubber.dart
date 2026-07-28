// ruler_scrubber.dart — RS 同款无限刻度尺(Rotate Point Cloud)。
//
// [2026-07-28 用户签决] 复刻 RS:1)转动没有尽头,可一直拨动 360° 循环;
// 2)看似有刻度,实际可停在两刻度中间(连续值,不吸附);3)有惯性 ——
// 大力甩动后靠摩擦模拟慢慢停下(FrictionSimulation,Flutter 滚动同款
// 系数 0.135),新一次触摸立即接管。
// 实现:中心固定指针,刻度带随手指滚动;角度按最短环向距离取模绘制,
// 环缝(±180°)处视觉无缝;值域不裁剪,由调用方决定是否归一化。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

class RulerScrubber extends StatefulWidget {
  const RulerScrubber({
    super.key,
    required this.value,
    required this.onChanged,
    this.pixelsPerDegree = 1.1,
    this.height = 56,
  });

  /// 当前角度(度,任意实数;绘制按 mod 360 环向处理)。
  final double value;
  final ValueChanged<double> onChanged;

  /// 刻度密度(像素/度)。拖动灵敏度 = 1/pixelsPerDegree 度/像素。
  /// [2026-07-28 用户反馈"阻力太大"] 2.2 → 1.1:同样一拨转过两倍角度。
  final double pixelsPerDegree;
  final double height;

  @override
  State<RulerScrubber> createState() => _RulerScrubberState();
}

class _RulerScrubberState extends State<RulerScrubber>
    with SingleTickerProviderStateMixin {
  // 显式在 initState 建(不用 late final 惰性初始化):否则从未甩动过的
  // 实例首次访问发生在 dispose() 里,vsync(this) 在已 deactivate 的树上
  // 找 TickerMode 祖先会炸(selection_page._presetAnim 同一个坑,已记档)。
  late final AnimationController _fling;

  @override
  void initState() {
    super.initState();
    _fling = AnimationController.unbounded(vsync: this)
      ..addListener(() => widget.onChanged(_fling.value));
  }

  @override
  void dispose() {
    _fling.dispose();
    super.dispose();
  }

  /// 手势期间的角度累积基准。⚠️不能在 update 里用 widget.value 做基准:
  /// 触摸事件一帧可到多个,而 widget.value 要等父级 setState 重建后才刷新,
  /// 同帧内后一个事件会用同一个旧基准**覆盖**前一个的增量 —— 大半拖动量
  /// 被吞,实机观感就是"阻力太大"(用户实机指认的根因)。
  double _gestureValue = 0;

  void _onDragStart(DragStartDetails d) {
    _fling.stop();
    _gestureValue = widget.value;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    // 刻度带跟手:手指右移 → 刻度右移 → 读数变小。无端点,不 clamp。
    _gestureValue -= d.delta.dx / widget.pixelsPerDegree;
    widget.onChanged(_gestureValue);
  }

  void _onDragEnd(DragEndDetails d) {
    final v = -d.velocity.pixelsPerSecond.dx / widget.pixelsPerDegree; // 度/s
    if (v.abs() < 30) return; // 轻推不甩,直接停在手指位置
    _fling.value = _gestureValue;
    unawaited(_fling.animateWith(FrictionSimulation(0.135, _gestureValue, v)));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _RulerPainter(
            value: widget.value,
            pxPerDeg: widget.pixelsPerDegree,
          ),
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
