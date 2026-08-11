// ruler_scrubber.dart — 弧形刻度盘(旋转点云)。
//
// [2026-08-07 用户签决,附手绘图] 从横轴改成**曲轴**,像汽车仪表盘:
//   · 弧心在面板下方(屏幕外),弧线上凸,刻度朝外;
//   · 中心指针固定指向正上方(圆头 + 尖端),弧顶正中一个发光白点;
//   · 原点刻度最粗最长,默认停在正上方中间;
//   · 每跨过一个刻度轻微震动;
//   · 弧线在屏幕两侧渐隐。
//
// 收起/展开是**同一个旋转**:整个组件(弧线 + 刻度 + 指针)绕弧心转 180°。
// 弧心在面板下方 ⇒ 转过去后弧线落到弧心另一侧,也就是屏幕外,于是"消失";
// 指针同一个变换从朝上变成朝下。用户描述的"从右侧消失 / 从左侧出现"就是这个
// 旋转扫过的方向 —— 一个变换同时交代了两件事,不需要额外的位移动画。
//
// 保留自横轴版的三条既有签决:
//   1)转动没有尽头,360° 循环,可停在两刻度之间(连续值,不吸附);
//   2)松手有惯性(FrictionSimulation,系数 0.135);抬手速度低也要滑行 ——
//      不能只信 DragEndDetails.velocity,实机上它常拿不到可用值;
//   3)绝对定位:读数回到 0 ⇒ 框精确回到基准(恒等式,不靠增量累加)。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart' show HapticFeedback;

// ── 几何(顶层常量,供守门测试直接断言)────────────────────────────────
/// 面板高度。弧只露出靠近弧顶的一小段,所以不需要很高。
const double kRulerHeight = 132;

/// 可见弧的张角。
///
/// [2026-08-07 用户签决] "漏出的滑轴部分有 45 度就行,曲面要平缓一些"。
/// 固定**张角**而不是固定半径:半径由屏幕宽反算,于是不同机型上露出的那段弧
/// 恒为 45°,弯度观感一致。此前固定 R=420,在 390 宽上实测张角 55°、偏弯。
const double kRulerVisibleSpanDeg = 45;

/// 弧顶到面板顶边的距离。弧心 y = kRulerArcTop + 半径(在面板下方、屏幕外)
/// —— 收起时整个组件绕它转 180°,弧线自然落到屏幕外。
const double kRulerArcTop = 34;

/// 弧半径:由可见宽度和张角反算 —— width/2 = R·sin(半张角)。
double rulerArcRadius(double width) =>
    (width / 2) / math.sin(kRulerVisibleSpanDeg * math.pi / 360);

/// 弧顶与弧两端的高差("平缓"程度的量化指标)。
double rulerArcDrop(double width) {
  final r = rulerArcRadius(width);
  return r - r * math.cos(kRulerVisibleSpanDeg * math.pi / 360);
}

/// 指针:圆圈半径 + 杆长。
///
/// [2026-08-07 用户签决] "不管什么时候,指针永远在编辑页面的底部,不能消失。
/// 指针是绕中间的圆圈原地转圈。指针和刻度不是一个圆心。"
/// ⇒ 指针有**自己的**枢轴(那个圆圈),位置固定在面板底部;收起时它原地自转
/// 180°,不跟着弧线转出屏幕。此前把两者绑在同一个旋转里,指针会跟着弧一起消失。
const double kRulerPinRadius = 9; // 圆盘外径
const double kRulerPinHoleRadius = 3.6; // 中间的孔(露出纯黑底 ⇒ 空心)
const double kRulerPinStemWidth = 7; // 杆宽,端头圆角 ⇒ "圆头的直线"
const double kRulerPinLength = 26;

/// 指针枢轴(圆圈中心)距面板底边的距离 —— 固定,不随收起/展开变化。
const double kRulerPinPivotFromBottom = 36;

/// 弧顶正中那个发光白点的半径(光晕另算)。
const double kRulerGlowRadius = 2.6;

/// 刻度密度(弧长像素 / 度)—— **由半径导出,不是独立常量**。
///
/// [2026-08-07 用户签决] "在滑轴 UI 屏幕上的间距可以大一些,但是对应点云的转动
/// 是一小格一度……可见范围可以转动 45 度就行(就是 45 个刻度就行)"。
///
/// 于是取 **弧上 1° 的几何角 = 1° 的读数** —— 刻度盘就是一个真正的角度盘,
/// 弧的可见张角 45° 自然等于 45 个刻度,两个"45°"是同一件事、不需要各设一遍。
/// 390 宽上:R≈510 ⇒ 一格 ≈ 8.9pt,清晰可辨。
///
/// ⚠️ 我此前把"45 度"误读成弧的**几何**张角,又另设密度 3.0pt/度 ⇒ 可见范围
/// 变成 133 格,太密。两者本来就该锁在一起。
double rulerPxPerDeg(double width) => rulerArcRadius(width) * math.pi / 180;

/// 松手后进入滑行的最低速度(度/s)。
///
/// [2026-08-03 用户实机"滑动之后齿轮应该慢慢减速停下,不是立刻停"] 原值 30
/// 度/s 对**真实手指**太高:人拨完通常是减速后再抬起,抬手瞬时速度常低于它。
const double kRulerFlingMinDegPerSec = 5.0;

/// 刻度分四级。[2026-08-07 用户签决] 最小一格 = **1 度**,每跨一格震一下。
/// 1° 太细,所以中间加一级 5°,否则只有 1° 和 30° 两级会显得没有层次。
const double kRulerMinorStepDeg = 1;
const double kRulerMediumEveryDeg = 5;
const double kRulerMajorEveryDeg = 30;

/// 震动最小间隔 —— 快速拨动时每 5° 一次会撞上系统 haptic engine 的节流,
/// 表现为整体卡顿。
const Duration kRulerHapticMinGap = Duration(milliseconds: 28);

/// 收起 / 展开的旋转:180°,恒定顺时针(累计角只增)。
const Duration kRulerDeployDuration = Duration(milliseconds: 420);

/// 收起态的整体亮度(升起为 1.0)。
const double kRulerCollapsedDim = 0.45;

/// 弧心在面板局部坐标里的 y。
double rulerArcCenterY(double width) => kRulerArcTop + rulerArcRadius(width);

/// 弧顶(未旋转时)在面板局部坐标里的 y。
double rulerArcApexY() => kRulerArcTop;

/// 指针枢轴的 y(面板局部坐标)。恒定 —— 收起只让它原地转。
double rulerPinPivotY(double height) => height - kRulerPinPivotFromBottom;

/// 升起态指针杆顶端的 y。
double rulerPinTipY(double height) => rulerPinPivotY(height) - kRulerPinLength;

/// 刻度与弧线之间的间隙 —— [2026-08-07 用户签决] "刻度可以画在圆轴上,需要隔
/// 一点距离";不贴着弧线画。
const double kRulerTickGap = 7;

/// 刻度长度(四级)。整体比第一版短一档(用户签决"刻度可以统一变短一点")。
const double kRulerOriginTickLen = 17;
const double kRulerMajorTickLen = 13;
const double kRulerMediumTickLen = 9;
const double kRulerMinorTickLen = 5;

/// 最长那根刻度的内端 y = 弧顶 + 间隙 + 长度。
double rulerTickInnerY() => kRulerArcTop + kRulerTickGap + kRulerOriginTickLen;

/// 弧顶发光点的灰色外圈半径。
const double kRulerGlowRingRadius = 8.5;

class RulerScrubber extends StatefulWidget {
  const RulerScrubber({
    super.key,
    required this.value,
    required this.onChanged,
    this.height = kRulerHeight,
    this.originDeg = 0,
    this.deployed = true,
    this.onDeployedChanged,
  });

  /// 当前角度(度,任意实数;绘制按 mod 360 环向处理)。
  final double value;
  final ValueChanged<double> onChanged;

  final double height;

  /// "原始角度"落在哪一格 —— 那一格最粗最长,默认停在正上方中间。
  final double originDeg;

  /// 升起 / 收起。[2026-08-07 用户签决] 打开编辑页时**默认升起**。
  final bool deployed;

  /// 点击指针、或在指针上下滑动 ⇒ 切换升起状态。
  final ValueChanged<bool>? onDeployedChanged;

  @override
  State<RulerScrubber> createState() => _RulerScrubberState();
}

class _RulerScrubberState extends State<RulerScrubber>
    with TickerProviderStateMixin {
  // 显式在 initState 建(不用 late final 惰性初始化):否则从未甩动过的实例
  // 首次访问发生在 dispose() 里,vsync(this) 在已 deactivate 的树上找
  // TickerMode 祖先会炸(selection_page._presetAnim 同一个坑,已记档)。
  late final AnimationController _fling;

  /// 收起/展开的过渡进度 0→1(每次切换都从 0 跑到 1)。
  late final AnimationController _deploy;

  /// 指针与弧线的**累计**旋转角(弧度)。
  ///
  /// [2026-08-07 用户签决] "指针和滑轴一样,都是要从右侧降落,从左侧升起"。
  /// 此前写成 rotate(π·(1−deploy)) 是**双向插值** —— 收起顺时针经右侧下去,
  /// 升起就逆时针从右侧原路回来,与签决相反。改成每次切换角度**只增** π:
  /// 0 → π(经右下去)→ 2π(经左上来),视觉上 2π ≡ 0,而旋转方向恒为顺时针。
  double _rotFrom = 0;
  double _rotTo = 0;
  double _dimFrom = 1;
  double _dimTo = 1;

  @override
  void initState() {
    super.initState();
    _fling = AnimationController.unbounded(vsync: this)
      ..addListener(() => widget.onChanged(_fling.value));
    _deploy = AnimationController(vsync: this, duration: kRulerDeployDuration)
      ..addListener(() => setState(() {}))
      ..value = 1;
    _rotFrom = _rotTo = 0;
    _dimFrom = _dimTo = widget.deployed ? 1.0 : kRulerCollapsedDim;
  }

  @override
  void didUpdateWidget(RulerScrubber old) {
    super.didUpdateWidget(old);
    if (widget.deployed != old.deployed) {
      // 每按一次就再多转半圈:**目标累加 π**,起点取当前显示角。
      //
      // [2026-08-07 用户实机指认"快速多次按动不应该快速转吗,为什么现在只变色
      // 不转了"] 上一版写成 floor(当前角/π)·π + π —— 当前角在 (0,π) 之间时算出来
      // **还是 π**,也就是"已经在去的那个目标",于是第二、第三次点击都没有新增
      // 旋转,角度卡在 π 而 dim 每次翻转 ⇒ 只变色不转。
      //
      // 累加目标同时满足三件事:落点恒为 π 的整数倍(只停正上/正下)、方向恒
      // 顺时针(目标只增)、连点越快单次动画要走的角度越大 ⇒ 转得越快。
      _rotFrom = _rotNow;
      _rotTo += math.pi;
      _dimFrom = _dimNow;
      _dimTo = widget.deployed ? 1.0 : kRulerCollapsedDim;
      _deploy.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fling.dispose();
    _deploy.dispose();
    super.dispose();
  }

  double get _t => Curves.easeOutCubic.transform(_deploy.value.clamp(0, 1));
  double get _rotNow => _rotFrom + (_rotTo - _rotFrom) * _t;

  /// 当前累计旋转角(弧度)—— 供守门断言"只能停在 π 的整数倍"。
  @visibleForTesting
  double get debugRotation => _rotNow;

  /// 落定目标角 —— 守门用它验证吸附。
  @visibleForTesting
  double get debugRotationTarget => _rotTo;

  /// 当前亮度 —— 守门断言"朝上亮、朝下暗"。
  @visibleForTesting
  double get debugDim => _dimNow;
  double get _dimNow => _dimFrom + (_dimTo - _dimFrom) * _t;

  /// 当前可见宽度 —— 密度由它导出(见 rulerPxPerDeg),手势换算要用。
  double _width = 390;
  double get _ppd => rulerPxPerDeg(_width);

  /// 手势期间的角度累积基准。⚠️不能在 update 里用 widget.value 做基准:触摸
  /// 事件一帧可到多个,而 widget.value 要等父级 setState 重建后才刷新,同帧内
  /// 后一个事件会用同一个旧基准**覆盖**前一个的增量 —— 大半拖动量被吞。
  double _gestureValue = 0;

  /// 最近若干次 update 的 (事件时间戳, 当时读数) —— 抬手时**自己**算速度用。
  /// 不能只信 DragEndDetails.velocity:实机上它常拿不到可用值(合成手势里也
  /// 复现不出来,所以此前的测试一直是假绿/假红)。
  final List<(Duration, double)> _samples = [];
  static const Duration _kVelWindow = Duration(milliseconds: 100);

  /// 震动节流用:上次震动时刻 + 上次落在哪一格。
  Duration _lastHapticAt = Duration.zero;
  int? _lastTickIndex;

  int _tickIndexOf(double deg) => (deg / kRulerMinorStepDeg).floor();

  /// 跨过刻度就震一下(节流)。
  void _hapticOnTickCross(double deg, Duration? ts) {
    final idx = _tickIndexOf(deg);
    if (_lastTickIndex == null) {
      _lastTickIndex = idx;
      return;
    }
    if (idx == _lastTickIndex) return;
    _lastTickIndex = idx;
    final now = ts ?? _lastHapticAt + kRulerHapticMinGap;
    if (now - _lastHapticAt < kRulerHapticMinGap) return;
    _lastHapticAt = now;
    HapticFeedback.selectionClick();
  }

  void _onDragStart(DragStartDetails d) {
    _fling.stop();
    _gestureValue = widget.value;
    _samples.clear();
    _lastTickIndex = _tickIndexOf(_gestureValue);
    final ts = d.sourceTimeStamp;
    if (ts != null) _samples.add((ts, _gestureValue));
  }

  void _onDragUpdate(DragUpdateDetails d) {
    // 沿弧跟手:手指右移 → 刻度带右移 → 读数变小。无端点,不 clamp。
    _gestureValue -= d.delta.dx / _ppd;
    final ts = d.sourceTimeStamp;
    if (ts != null) {
      _samples.add((ts, _gestureValue));
      while (_samples.length > 2 && ts - _samples.first.$1 > _kVelWindow) {
        _samples.removeAt(0);
      }
    }
    _hapticOnTickCross(_gestureValue, ts);
    widget.onChanged(_gestureValue);
  }

  /// 抬手速度(度/s):框架值优先,拿不到就用自己的样本窗口算。
  double _releaseVelocity(DragEndDetails d) {
    final framework = -d.velocity.pixelsPerSecond.dx / _ppd;
    if (framework.abs() >= kRulerFlingMinDegPerSec) return framework;
    if (_samples.length < 2) return framework;
    final dt =
        (_samples.last.$1 - _samples.first.$1).inMicroseconds / 1000000.0;
    if (dt < 0.008) return framework;
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

  void _toggleDeployed() {
    HapticFeedback.selectionClick();
    widget.onDeployedChanged?.call(!widget.deployed);
  }

  /// 指针区域的竖直滑动:向下 ⇒ 收起,向上 ⇒ 升起。
  void _onPinVerticalDragEnd(DragEndDetails d) {
    final vy = d.velocity.pixelsPerSecond.dy;
    if (vy > 60 && widget.deployed) {
      widget.onDeployedChanged?.call(false);
    } else if (vy < -60 && !widget.deployed) {
      widget.onDeployedChanged?.call(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (ctx, c) {
          if (c.maxWidth.isFinite && c.maxWidth > 0) _width = c.maxWidth;
          return Stack(
            children: [
              // 弧线 + 刻度 + 指针,整体绕弧心旋转(t=1 升起,t=0 收起)。
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // ⚠️ 必须 down 而不是默认的 start:指针那层有竖直手势,两者进同一
                  // 个竞技场,水平识别器 claim 前那 18px slop 的位移会被**丢弃** ——
                  // 实测一圈只转到 287° 而不是 360°,真机上手感就是"碰一下不动、要
                  // 多划一点才开始转"。down 让 slop 内的位移也全额到账。
                  dragStartBehavior: DragStartBehavior.down,
                  onHorizontalDragStart: _onDragStart,
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  child: CustomPaint(
                    painter: _ArcRulerPainter(
                      value: widget.value,
                      originDeg: widget.originDeg,
                      rot: _rotNow,
                      dim: _dimNow,
                    ),
                  ),
                ),
              ),
              // 指针的命中区:点击切换、竖直滑动切换。横向拖动仍归刻度带,所以
              // 这一层只认 tap 和 vertical drag。
              // 指针的命中区:跟着指针在**底部**,而不是顶部。点击切换、竖直滑动
              // 切换;横向拖动仍归刻度带,所以这一层只认 tap 和 vertical drag。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: kRulerPinPivotFromBottom + kRulerPinLength + 12,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: GestureDetector(
                    key: const ValueKey('ruler-pin'),
                    behavior: HitTestBehavior.translucent,
                    onTap: _toggleDeployed,
                    onVerticalDragEnd: _onPinVerticalDragEnd,
                    child: SizedBox(
                      width: 72,
                      height: kRulerPinPivotFromBottom + kRulerPinLength + 12,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ArcRulerPainter extends CustomPainter {
  _ArcRulerPainter({
    required this.value,
    required this.originDeg,
    required this.rot,
    required this.dim,
  });

  final double value;
  final double originDeg;

  /// **累计**旋转角(弧度)。偶数倍 π = 升起,奇数倍 = 收起;只增不减,所以
  /// 旋转方向恒为顺时针(用户签决:右侧降落、左侧升起)。
  final double rot;

  /// 整体亮度 —— 收起变暗、升起变亮。
  final double dim;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final r = rulerArcRadius(size.width);
    final cy = rulerArcCenterY(size.width);

    // ① 弧线 + 刻度 + 发光点:绕**弧心**(屏幕外)转 ⇒ 整条弧扫出/扫入屏幕。
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rot);
    canvas.translate(-cx, -cy);
    _drawArc(canvas, size, cx, cy, r, dim);
    _drawTicks(canvas, size, cx, cy, r, dim);
    _drawGlow(canvas, cx, dim);
    canvas.restore();

    // ② 指针:绕**自己的圆圈**原地转 180°,位置恒定、永不消失。
    //    两个旋转中心是分开的 —— 这正是用户签决的那一条。
    _drawPin(canvas, size, cx, dim);
  }

  /// 弧线本体:两侧渐隐。
  void _drawArc(
    Canvas canvas,
    Size size,
    double cx,
    double cy,
    double r,
    double dim,
  ) {
    // 可见张角固定 45°(半张角 22.5°)—— 半径已按它反算,弧刚好横跨面板宽。
    const halfSpan = kRulerVisibleSpanDeg * math.pi / 360;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    // 沿弧的 alpha 渐变 —— 用 SweepGradient 会把接缝落在弧中间,所以改成
    // 分段画:每段一个 alpha,段够密就看不出台阶。
    const seg = 48;
    for (var i = 0; i < seg; i++) {
      final t0 = i / seg, t1 = (i + 1) / seg;
      // t=0.5 是弧顶(正上方),两端渐隐。
      final mid = (t0 + t1) / 2;
      final fade = 1.0 - math.pow((mid - 0.5).abs() * 2, 1.6).toDouble();
      final a = (fade.clamp(0.0, 1.0) * 0.9 * dim * 255).round();
      if (a <= 1) continue;
      final start = -math.pi / 2 - halfSpan + 2 * halfSpan * t0;
      final sweep = 2 * halfSpan * (t1 - t0) * 1.04; // 略重叠,消除段缝
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = Color.fromARGB(a, 255, 255, 255)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..isAntiAlias = true,
      );
    }
  }

  /// 刻度:沿弧分布,朝外(远离弧心)伸出。
  void _drawTicks(
    Canvas canvas,
    Size size,
    double cx,
    double cy,
    double r,
    double dim,
  ) {
    const halfSpan = kRulerVisibleSpanDeg * math.pi / 360;
    final pxPerDeg = rulerPxPerDeg(size.width);
    // 一格小刻度对应的弧角(弧长 = 半径 × 弧角 ⇒ 弧角 = 弧长 / 半径)。
    final radPerDeg = pxPerDeg / r;
    final spanDeg = halfSpan / radPerDeg + kRulerMinorStepDeg;
    final first =
        ((value - spanDeg) / kRulerMinorStepDeg).ceilToDouble() *
        kRulerMinorStepDeg;

    for (var a = first; a <= value + spanDeg; a += kRulerMinorStepDeg) {
      // 该刻度相对弧顶的角偏移(读数增大 ⇒ 刻度带左移)。
      final off = (a - value) * radPerDeg;
      if (off.abs() > halfSpan) continue;
      final ang = -math.pi / 2 + off;

      final m = ((a % 360.0) + 360.0) % 360.0;
      bool onEvery(double step) =>
          (m % step).abs() < kRulerMinorStepDeg / 2 ||
          (step - (m % step)).abs() < kRulerMinorStepDeg / 2;
      final isMajor = onEvery(kRulerMajorEveryDeg);
      final isMedium = !isMajor && onEvery(kRulerMediumEveryDeg);
      var da = ((m - originDeg) % 360.0 + 360.0) % 360.0;
      if (da > 180.0) da -= 360.0;
      final isOrigin = da.abs() < kRulerMinorStepDeg / 2;

      // 原点最粗最长(用户签决:"最粗最长",不再靠颜色区分 —— 全白)。
      final len = isOrigin
          ? kRulerOriginTickLen
          : isMajor
          ? kRulerMajorTickLen
          : isMedium
          ? kRulerMediumTickLen
          : kRulerMinorTickLen;
      final w = isOrigin
          ? 2.8
          : isMajor
          ? 1.8
          : isMedium
          ? 1.4
          : 1.0;
      final baseAlpha = isOrigin
          ? 1.0
          : isMajor
          ? 0.95
          : isMedium
          ? 0.7
          : 0.42;

      final fade = 1.0 - math.pow((off / halfSpan).abs(), 1.6).toDouble();
      final f01 = fade.clamp(0.0, 1.0);
      final alpha = (baseAlpha * f01 * dim * 255).round();
      if (alpha <= 1) continue;

      // [2026-08-07 用户签决] 刻度朝**内**(朝弧心,也就是朝下、朝着指针),
      // 而且与弧线隔开 kRulerTickGap —— 不贴着画。
      final dir = Offset(math.cos(ang), math.sin(ang));
      final base = Offset(cx, cy) + dir * (r - kRulerTickGap);
      final tip = Offset(cx, cy) + dir * (r - kRulerTickGap - len);
      canvas.drawLine(
        base,
        tip,
        Paint()
          ..color = Color.fromARGB(alpha, 255, 255, 255)
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }
  }

  /// 指针:位置固定在面板底部,绕自己的圆圈原地自转。
  ///
  /// [2026-08-07 用户签决] "不管什么时候,指针永远在编辑页面的底部,不能消失。
  /// 指针是绕中间的圆圈原地转圈。指针和刻度不是一个圆心。"
  void _drawPin(Canvas canvas, Size size, double cx, double dim) {
    final pivot = Offset(cx, rulerPinPivotY(size.height));
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    // 与弧线**同一个**累计角 ⇒ 两者同步、同向(右侧降落、左侧升起)。
    canvas.rotate(rot);

    Color white(double a) =>
        Color.fromARGB((dim * a * 255).round(), 255, 255, 255);

    // [2026-08-07 用户签决,附参考图] "不需要有指针,一个空心圆配一个圆头的
    // 直线就可以" —— 实心白:圆盘 + 圆头杆,圆心一个孔露出纯黑底 ⇒ 空心。
    //
    // ⚠️ 必须合成**一个** Path 再一次填充。分两次 draw 时,暗色模式下两个
    // 半透明白在圆盘与杆的重叠区叠加 ⇒ 那一块明显更亮(用户实机指认)。
    // Path 默认 nonZero 填充,重叠区只上色一次。
    final stem = RRect.fromRectAndRadius(
      Rect.fromLTRB(
        -kRulerPinStemWidth / 2,
        -kRulerPinLength,
        kRulerPinStemWidth / 2,
        0,
      ),
      const Radius.circular(kRulerPinStemWidth / 2),
    );
    canvas.drawPath(
      Path()
        ..addOval(Rect.fromCircle(center: Offset.zero, radius: kRulerPinRadius))
        ..addRRect(stem),
      Paint()
        ..color = white(1.0)
        ..isAntiAlias = true,
    );
    // 孔:纯黑 = 页面底色 ⇒ 空心效果。整屏统一纯黑,所以直接用不透明黑,
    // 这样它也不会被上面那层的半透明"透出来"。
    canvas.drawCircle(
      Offset.zero,
      kRulerPinHoleRadius,
      Paint()
        ..color = Colors.black
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  /// 弧顶正中的发光白点(第二张灵感图里那个高光)。
  void _drawGlow(Canvas canvas, double cx, double dim) {
    final y = rulerArcApexY();
    // 光晕:两层径向渐变,不用 blur —— BackdropFilter/blur 在这里是纯浪费,
    // 热预算要留给点云渲染。
    for (final (rr, aa) in [(11.0, 0.10), (6.5, 0.20)]) {
      canvas.drawCircle(
        Offset(cx, y),
        rr,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Color.fromARGB((aa * dim * 255).round(), 255, 255, 255),
              const Color(0x00FFFFFF),
            ],
          ).createShader(Rect.fromCircle(center: Offset(cx, y), radius: rr)),
      );
    }
    // [2026-08-07 用户签决] "中间的白点可以微微发光,然后有一个灰色的外圈"。
    canvas.drawCircle(
      Offset(cx, y),
      kRulerGlowRingRadius,
      Paint()
        ..color = Color.fromARGB((dim * 0.42 * 255).round(), 155, 155, 155)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      Offset(cx, y),
      kRulerGlowRadius,
      Paint()
        ..color = Color.fromARGB((dim * 255).round(), 255, 255, 255)
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_ArcRulerPainter old) =>
      old.value != value ||
      old.originDeg != originDeg ||
      old.rot != rot ||
      old.dim != dim;
}
