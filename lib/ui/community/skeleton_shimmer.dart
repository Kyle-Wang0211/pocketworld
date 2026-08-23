// 骨架屏 —— **手写,不引入任何包**。
//
// [D4 2026-08-22 用户签决] 三个候选逐个出局(2026-08-22 实测):
//
//   shimmer            ⛔ issue #64「Extremely high CPU usage causing phone to
//                         overheat」**开了三年未关**,40-60% CPU,多份报告特指
//                         iOS —— 正对本项目的热软肋。
//                         (它"要求 Flutter ≥3.44"那条理由已随 3.47.1 升级作废,
//                          但上面这条与版本无关,仍然成立。)
//   skeleton_loader /
//   skeletons          ⛔ 五年无人维护
//   flutter_animate    ⛔ 是动画库不是骨架屏库,骨头布局照样手写;停更 21 个月
//   skeletonizer       🟡 唯一值得考虑,但:① 需假数据 + 逐个加注解;
//                         ② 每帧 markNeedsPaint() + alwaysNeedsCompositing
//                            ⇒ **整个 feed 每帧全量重绘**;
//                         ③ **热闸插不进去** —— controller 在包内部
//
// 范式直接抄 lib/ui/splash_overlay.dart:39-56 的
// AnimationController(1800ms)..repeat(reverse: true) + AnimatedBuilder。
//
// ⚠️ **必须一并抄它踩过的坑**(splash_overlay.dart:60-70 原话):
//     "Don't spin/pulse behind an invisible overlay — that continuous
//      repaint is what made the sign-in page janky."
// 所以 animate=false 时**显式 stop() 并返回静态图**,不是让它转着但看不见。
//
// ⚠️ 热闸(本项目特有,不可省):一屏跑多个骨架卡是真实的发热面。
// animate 由调用方接 CardLiveGovernor.liveAllowed 传下来 —— 它说不行就一个都不转。

import 'package:flutter/material.dart';

/// 闪动一轮的时长。与 splash_overlay 的 pulse 同值,观感一致。
const Duration kSkeletonPulsePeriod = Duration(milliseconds: 1800);

/// 灰阶两端。差值刻意小 —— 方案要求"轻微闪动",不是扫光带。
const Color kSkeletonBase = Color(0xFF1B1B1F);
const Color kSkeletonHighlight = Color(0xFF26262B);

/// 一块会轻微呼吸的灰色骨头。
///
/// [animate] 为 false 时**停掉 controller**并画成静态底色 —— 见文件头注释,
/// 不可见时继续重绘正是本仓踩过的那个 jank 来源。
class SkeletonBox extends StatefulWidget {
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final bool animate;

  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.borderRadius,
    this.animate = true,
  });

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: kSkeletonPulsePeriod);
    if (widget.animate) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant SkeletonBox old) {
    super.didUpdateWidget(old);
    if (widget.animate == old.animate) return;
    // 热闸翻转时立刻生效,不等下一轮。
    if (widget.animate) {
      _c.repeat(reverse: true);
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(8);
    if (!widget.animate) {
      // 静态:不挂 AnimatedBuilder ⇒ 这棵子树不再每帧重建。
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(color: kSkeletonBase, borderRadius: radius),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(kSkeletonBase, kSkeletonHighlight, _c.value),
          borderRadius: radius,
        ),
      ),
    );
  }
}

/// 一张作品卡形状的骨架 —— 上方大方块(模型区)+ 下方玻璃板上的两行文字骨头。
///
/// 尺寸刻意贴着 WorkCard 的真实布局,避免真数据到位那一刻整页跳动。
class SkeletonWorkCard extends StatelessWidget {
  final bool animate;
  const SkeletonWorkCard({super.key, this.animate = true});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SkeletonBox(
              animate: animate,
              borderRadius: BorderRadius.circular(20),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SkeletonBox(animate: animate, width: 168, height: 16),
                  const SizedBox(height: 8),
                  SkeletonBox(animate: animate, width: 104, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
