// auto_capture_mode.dart — 采集页「自动 / 手动」两态的**纯**表示层映射。
//
// 为什么单独一个文件而不是塞进 ar_capture_page.dart(计划书原本这么写):
// 那个文件已 4830 行,而且**它当前编译不过**(HEAD 上就有 8 个
// undefined_method/undefined_class,与本功能无关),所以放进去的任何一行
// 都只能靠 grep 源码来"测"。这里的四个映射全是纯函数,放出来就能真跑
// ——尤其是 [autoCaptureIndicatorFor],它守的正是本功能最容易静默错的一处
// (见该函数的注释)。页面那边仍然只做接线,判定逻辑一行都没进去。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md §7 / §8 / §8.1。

import 'auto_capture_governor.dart' show AutoCaptureDecision;

/// 采集页的两种模式。手动 = 一张一张按快门(原有行为,一个字节没改);
/// 自动 = AutoCaptureController 替用户按快门。
///
/// ⚠️ 命名刻意避开"录像":KIRI 与 Polycam 的 Video 模式是**真的录视频并从
/// 视频建模**,而我们不产生任何视频文件(spec D3)。沿用"录像"之名会让用过
/// 那两家的用户去找根本不存在的视频文件。
enum OfficialCaptureMode { manual, auto }

/// 自动态指示器的视觉状态。**只表达状态,不出文案** —— 既有产品铁律
/// 「不教用户」,spec §8 同款措辞。
enum AutoCaptureIndicator {
  /// 没在跑(手动模式,或自动模式还没点录制键)。指示器不表达任何东西。
  idle,

  /// 判定为 fire 的那一帧。
  ///
  /// ⚠️ **它不是脉冲动画的驱动源,不要把它接成驱动源。** 脉冲走的是采集页
  /// 的 `_autoFirePulseToken`,而那个令牌只在**真的入队成功**时才 +1
  /// (与 `fire_enqueued` 同一处记账)。理由见 spec §7/§8:开火 ≠ 拍成,
  /// 拿判定驱动脉冲会在入队失败时给用户一个假的正反馈 —— 红键脉冲一下、
  /// `N/300` 一动不动,而自动模式下那颗红键的脉冲是「到底拍上没有」的
  /// **唯一**反馈。〔2026-08-19 评审改正:此前就是这么接的。〕
  ///
  /// 保留这一档只为让 switch 穷尽、并把上面这条说明钉在类型上;
  /// 消费者(`_AutoRecordButton`)只区分 [waiting] 与其余。
  pulse,

  /// 位移不够,在等用户动 —— 转暗、静止。
  ///
  /// 这一态是**必需**的而不是锦上添花:位移闸意味着站着不动时一张都不拍,
  /// 屏幕显示"自动中"而张数不涨,不给反馈用户一定以为坏了(spec §8)。
  waiting,

  /// 在跑,但既没落帧也不是"没动够"(节奏被队列拉长、或丢跟踪)。
  /// **不额外表达** —— 节奏自然变慢即可(spec §8)。
  steady,
}

/// 把 controller 的运行态与最近一帧判定映射成指示器状态。
///
/// ⚠️ [running] **必须**来自 `AutoCaptureController.isRunning`,不能从
/// [decision] 反推:controller 没在跑时 `onPose` 返回的就是
/// [AutoCaptureDecision.skipNotMoved] —— 与"你还没动够"**逐字相同**。
/// 只看 decision 的话,一次已经结束的采集会永远停在"在等你动"上,
/// 而用户其实已经没有任何东西在跑了。这就是本函数存在的全部理由。
AutoCaptureIndicator autoCaptureIndicatorFor({
  required bool running,
  required AutoCaptureDecision decision,
}) {
  if (!running) return AutoCaptureIndicator.idle;
  switch (decision) {
    case AutoCaptureDecision.fire:
      return AutoCaptureIndicator.pulse;
    // skipNotMoved 归 waiting,不归 steady:用户此刻**还没动够**,
    // 指示灯该说"再走两步"而不是"一切正常"。
    case AutoCaptureDecision.skipNotMoved:
      return AutoCaptureIndicator.waiting;
    // 画质缓拍归 steady:节奏自然慢一拍即可,不额外表达(spec §8 同款
    // 取舍 —— skipPaced 也不表达)。
    case AutoCaptureDecision.skipTooDark:
    case AutoCaptureDecision.skipBlurry:
    case AutoCaptureDecision.skipPaced:
    case AutoCaptureDecision.skipNoVisualEvidence:
    case AutoCaptureDecision.skipRedundant:
    case AutoCaptureDecision.skipTracking:
    case AutoCaptureDecision.skipCapped:
    case AutoCaptureDecision.skipTimeLimit:
      return AutoCaptureIndicator.steady;
  }
}

/// 能不能起跑自动采集。
///
/// 前三条与手动快门的置灰判据**同源**(`ready && accepting && canShoot`):
/// 自动拍走的就是同一个入队路径,它不该在手动快门被判死的情况下还能开火。
/// 第四条是自动拍独有的 —— 起跑要一帧 pose 当基准种子。
bool autoCaptureCanStart({
  required bool captureReady,
  required bool queueAccepting,
  required bool withinFrameBudget,
  required bool posesFlowing,
}) => captureReady && queueAccepting && withinFrameBudget && posesFlowing;

/// 录制键可不可点。
///
/// 在跑时**恒可点** —— 哪怕张数刚好用尽、队列刚好停收,用户也必须能按停。
/// 把停止键和开始键用同一条判据置灰过一次就等于把用户关在自动模式里。
bool autoCaptureRecordButtonEnabled({
  required bool running,
  required bool canStart,
}) => running || canStart;

/// 顶部说明条文案(spec §8.1,按 RealityScan 实机截图复刻)。
String autoCaptureTopHintText(OfficialCaptureMode mode) {
  switch (mode) {
    case OfficialCaptureMode.manual:
      return '绕物成圈拍摄，覆盖所有角度，相邻照片挨紧';
    case OfficialCaptureMode.auto:
      return '对着物体从各个角度看过去，它会自动拍';
  }
}

/// 快门/录制键上方的提示行(spec §8.1)。
///
/// 自动模式**开拍后换成停止语义** —— RS 截图上这一行就是这么变的;
/// 不换的话,那颗红键在跑起来之后就没有任何地方告诉用户它现在是"停"。
String autoCaptureShutterHintText({
  required OfficialCaptureMode mode,
  required bool running,
  bool shouldPromptSlowDown = false,
}) {
  switch (mode) {
    case OfficialCaptureMode.manual:
      return '持续按快门拍摄';
    case OfficialCaptureMode.auto:
      if (!running) return '点一下录制键开始自动拍摄';
      if (shouldPromptSlowDown) return '重叠正在降低，请减速并保持物体在画面内';
      return '拍摄中，再点一下录制键停止';
  }
}

/// 切到自动模式时居中浮出的短提示(RS 的 "Auto Capture On")。
const String kAutoCaptureOnToastText = '自动拍摄已开启';
