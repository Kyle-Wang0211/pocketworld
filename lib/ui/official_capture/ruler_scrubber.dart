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

/// 刻度尺几何(顶层常量,供守门测试直接断言)。
///
/// 不变量:指针尖脚的底边必须落在最长(黄色初始)刻度的顶端**之上** ——
/// rulerPinBottom(h) <= rulerOriginTickTop(h)。
const double kRulerHeight = 68;
const double kRulerPinZone = 20; // 顶部留给指针的带宽
const double kRulerPinRadius = 4.5;

/// 刻度密度。
///
/// [2026-08-03] 曾一度改成 0.75(以为"阻力大"是指灵敏度),用户澄清指的是
/// **松手后的滑行**,与这里无关 ⇒ 回退到 1.1,避免无关变化,也免掉低密度带来
/// 的副作用(一圈 270px < 屏宽 ⇒ 屏上会同时出现两个黄色初始刻度)。
const double kRulerPxPerDeg = 1.1;

/// 松手后进入滑行的最低速度(度/s)。
///
/// [2026-08-03 用户实机"滑动之后齿轮应该慢慢减速停下,不是立刻停"] 原值 30
/// 度/s(≈33 px/s)对**真实手指**太高:人拨完通常是减速后再抬起,抬手瞬时
/// 速度常低于它 ⇒ 判成"轻推不甩"当场停住。合成 fling 的速度是给定的,所以
/// 测试一直看不出这个坑。降到 5 度/s,只挡真正的点按/轻触。
const double kRulerFlingMinDegPerSec = 5.0;

/// 最长(黄色)刻度的顶端 y。
double rulerOriginTickTop(double height) => kRulerPinZone;

/// 指针尖脚的底端 y。
double rulerPinBottom(double height) =>
    kRulerPinRadius + 1.5 + kRulerPinRadius * 2.2;

class RulerScrubber extends StatefulWidget {
  const RulerScrubber({
    super.key,
    required this.value,
    required this.onChanged,
    this.pixelsPerDegree = kRulerPxPerDeg,
    this.height = kRulerHeight,
    this.originDeg = 0,
  });

  /// 当前角度(度,任意实数;绘制按 mod 360 环向处理)。
  final double value;
  final ValueChanged<double> onChanged;

  /// 刻度密度(像素/度)。拖动灵敏度 = 1/pixelsPerDegree 度/像素。
  /// [2026-07-28 用户反馈"阻力太大"] 2.2 → 1.1:同样一拨转过两倍角度。
  final double pixelsPerDegree;
  final double height;

  /// 初始刻度(度)。画成**黄色且比大刻度更长**,一眼看出"没转过"的基准
  /// 位置在哪([2026-07-29 用户签决])。
  final double originDeg;

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

  /// 最近若干次 update 的 (事件时间戳, 当时读数) —— 抬手时**自己**算速度用。
  ///
  /// [2026-08-03 用户实机三次指认"没有触发任何惯性"] 不能只信
  /// DragEndDetails.velocity:实机上它常常拿不到可用值(合成手势里也复现不出
  /// 来,所以此前的测试一直是假绿/假红)。改成以自算速度兜底 —— 只要抬手前
  /// 100ms 内确实在移动,就一定有滑行。
  final List<(Duration, double)> _samples = [];
  static const Duration _kVelWindow = Duration(milliseconds: 100);

  void _onDragStart(DragStartDetails d) {
    _fling.stop();
    _gestureValue = widget.value;
    _samples.clear();
    final ts = d.sourceTimeStamp;
    if (ts != null) _samples.add((ts, _gestureValue));
  }

  void _onDragUpdate(DragUpdateDetails d) {
    // 刻度带跟手:手指右移 → 刻度右移 → 读数变小。无端点,不 clamp。
    _gestureValue -= d.delta.dx / widget.pixelsPerDegree;
    final ts = d.sourceTimeStamp;
    if (ts != null) {
      _samples.add((ts, _gestureValue));
      while (_samples.length > 2 && ts - _samples.first.$1 > _kVelWindow) {
        _samples.removeAt(0);
      }
    }
    widget.onChanged(_gestureValue);
  }

  /// 抬手速度(度/s):框架值优先,拿不到就用自己的样本窗口算。
  double _releaseVelocity(DragEndDetails d) {
    final framework = -d.velocity.pixelsPerSecond.dx / widget.pixelsPerDegree;
    if (framework.abs() >= kRulerFlingMinDegPerSec) return framework;
    if (_samples.length < 2) return framework;
    final dt =
        (_samples.last.$1 - _samples.first.$1).inMicroseconds / 1000000.0;
    if (dt < 0.008) return framework; // 样本跨度太短,数值不可信
    // 读数增长方向与 FrictionSimulation 需要的方向一致,无需再翻符号。
    return (_samples.last.$2 - _samples.first.$2) / dt;
  }

  void _onDragEnd(DragEndDetails d) {
    final v = _releaseVelocity(d);
    _samples.clear();
    if (v.abs() < kRulerFlingMinDegPerSec) return; // 纯点按才不甩
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
            originDeg: widget.originDeg,
          ),
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  const _RulerPainter({
    required this.value,
    required this.pxPerDeg,
    required this.originDeg,
  });

  final double value;
  final double pxPerDeg;
  final double originDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final halfW = size.width / 2;
    const minorStep = 5.0; // 小刻度 5°
    const majorEvery = 30.0; // 大刻度 30°
    final baseline = size.height;
    // [2026-08-03 用户实机指认"指针太低,挡住了最高的黄色刻度"] 顶部固定留出
    // kRulerPinZone 给指针,刻度一律从它下面起画 —— 此前指针 y 和刻度高度各算
    // 各的(pin 底 18.7 vs 黄标顶 7.2),必然重叠。
    final originH = baseline - kRulerPinZone; // 黄标(最长)
    final majorH = originH / 1.34;
    final minorH = majorH * 0.62;

    // [2026-08-03] 刻度带**重复**绘制而不是只画一圈:灵敏度调低后一圈的像素
    // 宽度(360×pxPerDeg)会小于屏幕宽,只画 ±180° 会让两侧露白。角度按 360
    // 取模判断大/小/黄标,所以"相邻黄标间距 = 360°"依然成立。
    final spanDeg = halfW / pxPerDeg + minorStep;
    final first = ((value - spanDeg) / minorStep).ceilToDouble() * minorStep;
    for (var a = first; a <= value + spanDeg; a += minorStep) {
      final x = cx + (a - value) * pxPerDeg;
      if (x < -2 || x > size.width + 2) continue;
      final m = ((a % 360.0) + 360.0) % 360.0;
      final isMajor =
          (m % majorEvery).abs() < minorStep / 2 ||
          (majorEvery - (m % majorEvery)).abs() < minorStep / 2;
      var da = ((m - originDeg) % 360.0 + 360.0) % 360.0;
      if (da > 180.0) da -= 360.0;
      final isOrigin = da.abs() < minorStep / 2;
      // 边缘淡出(RS 观感)。
      final fade = 1.0 - math.pow((x - cx).abs() / halfW, 2.0).toDouble();
      final f01 = fade.clamp(0.0, 1.0);
      final alpha = ((isMajor ? 0.95 : 0.45) * f01 * 255).round();
      final h = isOrigin ? originH : (isMajor ? majorH : minorH);
      canvas.drawLine(
        Offset(x, baseline - h),
        Offset(x, baseline),
        Paint()
          ..color = isOrigin
              ? Color.fromARGB((f01 * 255).round(), 0xFF, 0xC1, 0x07)
              : Color.fromARGB(alpha, 255, 255, 255)
          ..strokeWidth = isOrigin ? 2.6 : (isMajor ? 2.0 : 1.4)
          ..strokeCap = StrokeCap.round,
      );
    }

    // 中心固定指针:小水滴(圆头+尖脚),RS 同款。
    final pinY = kRulerPinRadius + 1.5;
    const r = kRulerPinRadius;
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
      old.value != value ||
      old.pxPerDeg != pxPerDeg ||
      old.originDeg != originDeg;
}
