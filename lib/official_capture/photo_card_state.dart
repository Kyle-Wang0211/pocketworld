// photo_card_state.dart — AR 空中照片卡片边框的纯 Dart 判定层。
//
// [2026-08-09 用户签决] **两态**:黑 = 没算(未处理/未注册),白 = 算完
// (已注册)。红(断联)与黄(低视差)废除 —— live 云已改全白显示,质量
// 分级信号整体退出边框层;覆盖云体素级引导(黄色区域横幅)是另一套系统,
// 保留。下方四态枚举与黄态滞回机件保留(枚举值是跨 MethodChannel 的稳定
// 编码,Swift 哑渲染器无需改;判定函数不再产出 2/3)。
//
// ── 以下为废除前的四态设计存档(阈值校准记录仍有史料价值)──
//   黑 = 处理中:后台 SfM 还没算到这帧(帧不在最新快照/连通性数据里),
//       **或已注册但真值视差还没算出来**(白/黄都是"真值已裁决"的状态,
//       真值未到达不冒充"拍好了");
//   白 = 计算完成且已注册(registered==1,真值视差充分);
//   黄 = 已注册但低视差(拍到了但角度不够 → 提示"横移一大步再拍");
//   红 = 断联(帧在最新数据里但 registered==0 → 提示"在该空间附近补拍")。
// 优先级(高覆盖低):红 > 黄 > 白 > 黑。
//
// 判黄**只用真值**(SfmLiveTrueParallax 的真实三角化角,见 true_parallax
// .dart)。视锥近似(route A)已彻底退出帧卡片判定 —— 两个实锤:
//   ① 过松两个数量级(5997 体素仅 1 starved / 98% 绿,而最终云 40.3%
//      的点三角化角 <8°);
//   ② 白→黄反序:近似先抢答"白",几秒后真值到达改判"黄",用户看到
//      "拍好了又变没拍好"。真值唯一 + 未到达保持黑,状态只会 黑→白 或
//      黑→黄,不再反序。
// (覆盖云**体素级**的"真值优先 + 近似兜底"保留不动,见
// capture_coverage_cloud._effectiveParallaxDeg —— 那是染色密度问题,
// 不是逐卡片的质量裁决。)
//
// 判黄阈值带滞回(消 白1↔黄3 抖动:worker 每批真值采样在阈值附近波动
// 时,单阈值会让卡片黄白来回闪)。2026-07-11 校准 8/7/9 → 5/4/6:真机
// 实测帧真值中位分布中心 p50=8.75°,旧阈值 8° 扎在分布正中心 → 68% 已
// 注册帧判黄(观感 80%+ 全场黄,数学必然,引导失效);金标 LAPa 最终云
// lt8=43.5% 且无重影(<8° ≠ 坏),重影厚区实测特征 5.2° —— 黄框只圈
// 真危险区,滞回带整体平移:
//   首判(从黑/红来,无白黄历史)真值 < 5°(kFrameYellowInitialDeg)→ 黄;
//   已白 → 转黄需真值 < 4°(kFrameYellowEnterDeg)**且连续
//     kFrameYellowEnterStreak(2)次真值采样都低于它**(白态粘性,防
//     点云长大时一批新低视差点瞬间拉低中位的单次抖动 —— 动态污染);
//   已黄 → 转白需真值 ≥ 6°(kFrameYellowExitDeg)。
//
// 判定逻辑全在 Dart(计算不进 Swift 的铁律)——iOS 侧
// AetherARKitPlugin 只收 [PhotoCardSfmState.channelValue] 做哑渲染。
// 本文件刻意零依赖(仅 dart:typed_data),tool/photo_card_state_check.dart
// 用纯 Dart VM 直接断言它。
//
// posesPacked 数据契约(与 SfmLiveSnapshot.posesPacked 一致):每帧 9 个
// double [frameId, registered(0/1), qw,qx,qy,qz, tx,ty,tz]。拍摄期的
// live 连通性 poses 是合成的(四元数/平移全 0,只有 frameId+registered
// 有效);finalize 快照的 poses 是 COLMAP 真值。两者本判定只读前两位。
//
// 红框语义按"断连区段"理解(见 SfmLiveSnapshot.disconnectedSegments):
// 每个 registered==0 的帧必属于某个连续断连区段,所以逐帧 registered
// 位与区段成员资格是同一个集合——卡片着色用逐帧位即可,区段结构留给
// "在 A 和 B 之间补拍"的文案引导。

import 'dart:typed_data';

/// 卡片边框四态。[channelValue] 是跨 MethodChannel 传给 iOS 哑渲染器的
/// 稳定编码(Swift 只 switch 这个 int 选颜色,别改已有值)。
enum PhotoCardSfmState {
  /// 黑:帧还没被 SfM worker 处理到,或已注册但真值视差未到达(处理中)。
  pending(0),

  /// 白:已注册进重建,且真值视差充分。
  registered(1),

  /// 红:断联——帧在最新数据里但没连进重建。
  disconnected(2),

  /// 黄:已注册但低视差(观测角度不够,深度不可靠——"双墙"高危)。
  lowParallax(3);

  const PhotoCardSfmState(this.channelValue);
  final int channelValue;
}

/// 四态判定(纯函数)。[posesPacked] 是最新一份 9-double/帧的 pose 数组
/// (拍摄期 live 连通性或 finalize 快照,契约见文件头);[lowParallax]
/// 是该帧的真值判黄结论([frameLowParallaxTrue] 的输出,三态):
///   true → 黄;false → 白;null → 真值未到达,**已注册也保持黑**
///   (处理中 —— 白/黄都必须由真值裁决,近似不得抢答)。
///
/// 帧不在 [posesPacked] 里 → 黑(未处理);registered==0 → 红(断联是
/// 连通性事实,不需要视差证据,优先于一切);registered==1 → 看
/// [lowParallax] 三态。
PhotoCardSfmState photoCardSfmState({
  required int frameId,
  required Float64List posesPacked,
  required bool? lowParallax,
}) {
  // [2026-08-09 用户签决] 四态 → 两态:"没算就是黑边框,算完就是白边框,
  // 不需要再有红色状态"。红(断联)与黄(低视差)一并废除 —— live 云已
  // 改全白显示,质量分级信号整体退出边框层;覆盖云体素级引导(黄色区域
  // 横幅)是另一套系统,保留不动。registered==0 归"没算"(黑);已注册
  // 即白,不再等真值视差裁决。lowParallax 参数保留签名兼容,判定忽略。
  for (var i = 0; i + 8 < posesPacked.length; i += 9) {
    if (posesPacked[i].toInt() != frameId) continue;
    if (posesPacked[i + 1] == 0) return PhotoCardSfmState.pending;
    return PhotoCardSfmState.registered;
  }
  return PhotoCardSfmState.pending;
}

/// 中位数(空列表 → null)。偶数个取中间两值均值。
double? medianOf(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = List<double>.from(values)..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// 判黄首判阈值(度):与覆盖云压黄同源的锚(CaptureCoverageCloud
/// .parallaxMinDeg = 5°)。首判用锚本身,保证卡片与覆盖云体素在
/// "第一眼"口径一致。
///
/// 2026-07-11 校准 8°→5°(真机遥测):帧真值中位分布中心 p50=8.75°,
/// 旧阈值 8° 扎在分布正中心 → 68% 已注册帧判黄(观感 80%+ 全场黄);
/// 金标 LAPa 最终云 lt8=43.5% 且无重影(<8° 不等于坏),重影厚区实测
/// 特征 5.2° —— 5° 把黄框圈回真危险区。
const double kFrameYellowInitialDeg = 5.0;

/// 白→黄阈值(度):已判白的帧,真值跌破 4° 才改判黄(滞回下界,
/// 且需连续 [kFrameYellowEnterStreak] 次采样,见 [frameBelowEnterStreak])。
const double kFrameYellowEnterDeg = 4.0;

/// 黄→白阈值(度):已判黄的帧,真值升到 ≥6° 才改判白(滞回上界)。
const double kFrameYellowExitDeg = 6.0;

/// 白→黄粘性(次):已白的帧除滞回外,还需**连续**该次数的真值采样
/// 低于 [kFrameYellowEnterDeg] 才转黄。防动态污染:流式点云长大时,
/// 一批新低视差点可能把该帧真值中位数瞬间拉低一次,单次跌破不改判;
/// 连续两批都低才是真的低视差。
const int kFrameYellowEnterStreak = 2;

/// 白→黄连续计数器更新(纯函数)。**真值采样到达时**per-帧调用一次
/// (不是每次状态机刷新调用 —— 刷新会重复评估同一份陈旧采样,重复
/// 计数会把"连续 2 次采样"退化成"同 1 次采样被看 2 眼"):
///   采样 < [enterDeg] → 计数 +1;否则清零。
/// 调用方按帧存计数(与真值表同生命周期,新一轮拍摄一起归零),再把
/// 最新计数传给 [frameLowParallaxTrue] 的 belowEnterStreak。
int frameBelowEnterStreak({
  required double sampleDeg,
  required int prevStreak,
  double enterDeg = kFrameYellowEnterDeg,
}) => sampleDeg < enterDeg ? prevStreak + 1 : 0;

/// 帧级判黄 v4(真值唯一 + 滞回 + 白态粘性)。
///
/// [trueMedianDeg] = worker 对流式 preview 云算出的"该帧观测点真实三角
/// 化角中位数"(度,见 true_parallax.trueParallaxAggregate);null =
/// 真值未到达 → 返回 null(卡片保持黑)。调用方**不得**用视锥近似顶替
/// —— v2 的 frustumFallback 参数已废除,它正是"白→黄反序"的根因。
///
/// [wasLowParallax] = 该帧上一次的白/黄裁决(true=黄,false=白,null=
/// 首判 —— 从黑/红来,没有可滞回的历史)。滞回消 1↔3 抖动:
///   首判:trueMedianDeg <  [kFrameYellowInitialDeg](5°)→ 黄;
///   已白:trueMedianDeg <  [kFrameYellowEnterDeg](4°) **且**
///         [belowEnterStreak] ≥ [kFrameYellowEnterStreak](2)才转黄
///         (白态粘性 —— 连续 2 次真值采样都跌破 enter 阈才认,消
///         "新低视差点瞬间拉低中位"的单次抖动);
///   已黄:trueMedianDeg >= [kFrameYellowExitDeg](6°) 才转白;
/// 4°..6° 带内已有裁决保持不动。
///
/// [belowEnterStreak] = 该帧当前"连续低于 enter 阈的真值采样次数"
/// (含本次采样;用 [frameBelowEnterStreak] 在采样到达时维护)。只在
/// 已白(wasLowParallax == false)时参与判定;不接线的调用方(如纯
/// 首判断言)可用默认值,语义 = 粘性条件恒满足,退回纯滞回。
bool? frameLowParallaxTrue({
  required double? trueMedianDeg,
  required bool? wasLowParallax,
  int belowEnterStreak = kFrameYellowEnterStreak,
  double initialDeg = kFrameYellowInitialDeg,
  double enterDeg = kFrameYellowEnterDeg,
  double exitDeg = kFrameYellowExitDeg,
  int enterStreak = kFrameYellowEnterStreak,
}) {
  if (trueMedianDeg == null) return null;
  if (wasLowParallax == null) return trueMedianDeg < initialDeg;
  if (wasLowParallax) return trueMedianDeg < exitDeg;
  // 已白:滞回下界 + 粘性(连续 enterStreak 次采样低于 enter 阈)。
  return trueMedianDeg < enterDeg && belowEnterStreak >= enterStreak;
}
