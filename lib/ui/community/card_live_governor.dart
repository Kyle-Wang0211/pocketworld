// card_live_governor.dart — 决定"社区 feed 现在允不允许有 live 卡片,允许的话
// 转多快"。方案 B 七道压热闸里,把**与具体是哪张卡无关**的四道收在这里:
//
//   闸 3  自转帧率封顶 24fps(不是 60)
//   闸 4  thermalState 自适应:nominal 24 → fair 15 → serious 停转回落静态图
//   闸 5  滚动中不转,静止 ~300ms 才启动
//   闸 7  内存告警即释放
//
// 另外三道(闸 1 单 live 卡 / 闸 2 八叉树降点 / 闸 6 离焦即回落)按"谁 mount 谁负责"
// 落在 VaultPage 与 LiveCardCloud —— 那三道要知道"是哪张卡",不属于这里。
//
// [2026-08-16 用户拍板] 社区 feed 焦点卡要**真实时**渲染自转,靠优化压住热,
// 不做预渲染转盘。热稳定是这个 App 的硬约束(拍摄链路已因热压挂死过 GPU、
// 冻结过相机),所以 live 能力从一开始就挂在一个可以随时把它关掉的闸门后面,
// 而不是"先转起来再说,热了再想办法"。
//
// 判决只有一个出口:[liveAllowed] + [fpsCap]。VaultPage 监听本类,liveAllowed
// 变 false 就把 live 卡卸载(不是隐藏)—— 闸 6/7 要求"不留后台渲染",隐藏的
// widget 仍在 build/paint,卸载才是真的停。
//
// 纯 Dart + 已在生产的 FFI 探针,没有新平台通道:thermalState 从
// PwTelemetry.sample() 读(pw_telemetry.mm 的 ProcessInfo 桶),内存告警走
// Flutter 自己的 didHaveMemoryPressure。

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../capture/pw_telemetry.dart';
import '../../util/device_log.dart';

/// 自转角速度(弧度/秒)—— 15 秒一圈。
///
/// 与帧率**解耦**:降到 15fps 时每帧转得多一点,视觉转速不变,只是步进变粗。
/// 这样闸 4 的降级用户感知为"略卡",而不是"忽然变慢了",后者会被当成卡死。
const double kCardRotateRadPerSec = 2 * 3.141592653589793 / 15;

/// 闸 3:自转帧率上限。60 → 24 直接砍掉约 60% 的每秒重绘。
const int kCardFpsNominal = 24;

/// 闸 4 中间档:thermalState == fair(苹果说"风扇转起来了"级别)。
const int kCardFpsFair = 15;

/// 闸 5:滚动停下后要静止这么久才允许起转。
///
/// 滚动中每帧都在换焦点卡,起转 = 反复 mount/卸载渲染器 + 反复跑八叉树降点,
/// 是纯浪费。300ms 也刚好过滤掉"划过去看一眼"的快速滑动。
const Duration kCardSettleDelay = Duration(milliseconds: 300);

/// thermalState 轮询周期。ProcessInfo 的桶是分钟级变化的量,2 秒足够跟上,
/// 而 sample() 每次是 3 次 malloc + 一次 mach 调用,不该按帧跑。
const Duration kThermalPollInterval = Duration(seconds: 2);

/// 每隔这么多次轮询往设备日志记一条热快照 —— 验收要的是**曲线**,不只是
/// "有没有降级过",所以平稳期也得留点。2s × 8 = 16s 一条,滚 10 分钟约 38 条。
const int kThermalLogEveryNPolls = 8;

/// 闸 4 的判据:现在该不该因为热而停转。
///
/// **带滞回** —— serious(2)以上才停,但要回到 nominal(0)才恢复。用同一个
/// 阈值开关会在 fair/serious 边界反复横跳,而每次横跳都是一轮卸载 + 重新
/// 下载解析降点,比一直转还费电。
///
/// [thermal] 为 -1 表示探针不可用(模拟器上 pw_telemetry 符号没链进来),
/// 按 nominal 走:那条路只在模拟器出现,而模拟器跑在 Mac 上,没有可压的热。
///
/// 抽成顶层纯函数是为了能单测 —— thermalState 本身来自 FFI,测不进去。
bool cardThermalStopFor({required int thermal, required bool stopped}) =>
    stopped ? thermal >= 1 : thermal >= 2;

/// feed live 卡片的总闸门。VaultPage 持有一个,监听它重算"谁能 live"。
class CardLiveGovernor extends ChangeNotifier with WidgetsBindingObserver {
  CardLiveGovernor({this.pollInterval = kThermalPollInterval}) {
    WidgetsBinding.instance.addObserver(this);
    _sampleThermal(); // 冷启动时设备可能已经是热的,别等第一个 tick
    _poll = Timer.periodic(pollInterval, (_) => _sampleThermal());
  }

  final Duration pollInterval;

  Timer? _poll;
  Timer? _settle;

  /// 0 nominal · 1 fair · 2 serious · 3 critical · -1 探针不可用(模拟器)。
  int _thermal = -1;
  bool _thermalStop = false;
  bool _memoryStop = false;
  bool _scrolling = false;
  bool _settled = true;
  bool _appActive = true;

  /// 最近一次读到的 thermalState —— 真机验收要记这条曲线。
  int get thermalState => _thermal;

  /// 现在允不允许存在 live 卡片。
  ///
  /// ⚠️ **内存压力不在这个判据里**。[2026-08-17 真机三连打脸] 它先是"永久
  /// 关死",改成 45s 退避后仍然是"从详情页退回来,点云僵着不动几十秒" ——
  /// 因为详情页拿全质量加载 mesh,内存必然冲高(实测 1685MB),一退回来就
  /// 撞在退避窗口里。
  ///
  /// 根子上是**响应搞错了**:停自转一个字节都不省(自转只是一个 ticker +
  /// 每帧 setMatrices),真正占内存的是 mount 着的 viewer 实例。所以内存压力
  /// 现在改由 [CardViewerRegistry.setMemoryPressure] 处理 —— 把实例上限
  /// 3 → 1、当场挤掉多余的,用户正在看的那张照常转。
  bool get liveAllowed =>
      !_thermalStop && !_scrolling && _settled && _appActive;

  /// 当前是否处于内存退避窗口(只影响实例上限,不影响自转)。
  bool get underMemoryPressure => _memoryStop;

  /// 允许时该按多少 fps 转。
  int get fpsCap => _thermal >= 1 ? kCardFpsFair : kCardFpsNominal;

  /// 本次会话是否曾因热而停转 —— 验收判据"`.serious` 不出现 = 过"直接看它。
  bool get everThermalStopped => _everThermalStopped;
  bool _everThermalStopped = false;

  /// 本次会话见过的最高 thermalState。
  int get peakThermal => _peakThermal;
  int _peakThermal = -1;

  int _polls = 0;

  void _sampleThermal() {
    final s = PwTelemetry.sample();
    // 验收判据是"滚 10 分钟,`.serious` 不出现",要的是一条**曲线**。
    // ⚠️ 这里必须走 DeviceLog 而不是 debugPrint:release 包里 debugPrint 是
    // no-op(见 util/device_log.dart 头注释),真机拔线跑完一行都拿不到。
    if (_polls++ % kThermalLogEveryNPolls == 0 && s != null) {
      DeviceLog.log(
        'FeedLive',
        'thermal=${s.thermalName}(${s.thermalState}) fps_cap=$fpsCap '
            'live_allowed=$liveAllowed mem=${s.physFootprintMb.toStringAsFixed(0)}MB '
            'peak_thermal=$_peakThermal',
      );
    }
    // 探针不可用(模拟器)= 拿不到热信号。按 nominal 走:这条路只在模拟器上
    // 出现,而模拟器跑在 Mac 上,没有可压的热。真机永远有值。
    final next = s?.thermalState ?? -1;
    if (next > _peakThermal) _peakThermal = next;
    final stop = cardThermalStopFor(thermal: next, stopped: _thermalStop);
    if (next == _thermal && stop == _thermalStop) return;
    final prevThermal = _thermal;
    _thermal = next;
    if (stop && !_thermalStop) {
      _everThermalStopped = true;
      DeviceLog.log('FeedLive',
          '🔴 闸 4 触发:thermal=${s?.thermalName ?? "n/a"} → 停转回落静态图');
    } else if (!stop && _thermalStop) {
      DeviceLog.log('FeedLive',
          '闸 4 解除:thermal=${s?.thermalName ?? "n/a"} → 恢复 live');
    } else if (next != prevThermal) {
      DeviceLog.log('FeedLive',
          'thermal 变化:${s?.thermalName ?? "n/a"}($next) fps_cap=$fpsCap');
    }
    _thermalStop = stop;
    notifyListeners();
  }

  /// 闸 5:滚动开始 —— 立刻停转,并作废任何等待中的 settle。
  void onScrollStart() {
    _settle?.cancel();
    _settle = null;
    if (_scrolling && !_settled) return;
    _scrolling = true;
    _settled = false;
    notifyListeners();
  }

  /// 闸 5:滚动结束 —— 等 [kCardSettleDelay] 静止期再放行。
  void onScrollEnd() {
    if (!_scrolling) return;
    _scrolling = false;
    _settle?.cancel();
    _settle = Timer(kCardSettleDelay, () {
      _settle = null;
      if (_scrolling) return; // 静止期内又划走了
      _settled = true;
      notifyListeners();
    });
    notifyListeners(); // _scrolling 已变,但 _settled 仍 false → 还是不放行
  }

  /// 闸 7:内存告警 —— **只记录,什么都不做**。
  ///
  /// [2026-08-17] 这条我改错了四次,每一版都被真机打回来:
  ///
  ///   v1 单向闸"本次浏览不再恢复" → 自转被永久关死,卡片渲出来却纹丝不动。
  ///   v2 45s 退避停自转          → 详情页全质量加载必然触发告警,一退回来
  ///                               就撞进退避窗口,点云僵几十秒(实测 78s)。
  ///   v3 收紧实例上限 3→1        → **比 v2 更糟**:屏幕上同时可见 2-3 张卡,
  ///                               cap 比可见数还小 ⇒ 焦点每切一次就得挤掉
  ///                               一个再挂一个,41 秒内 18 次挂载,每轮都付
  ///                               768² IOSurface + cgltf parse + GPU 上传 +
  ///                               全部销毁。内存反而从 1685MB 冲到 2132MB,
  ///                               交互全线卡顿。这正是五月注释里写死的那个
  ///                               循环("hits thermal=serious within ~10s")。
  ///   v4 就是现在:什么都不做。
  ///
  /// 教训:**cap 不能小于同时可见的卡片数**,否则收紧就等于制造 thrashing。
  /// 而五月压根没有这道闸 —— 固定 cap=3(= 当前卡 + 前一张 + 后一张)本身
  /// 就是内存上限,150ms debounce 挡住快滚,这两条是 2026-05-02 在 iPhone 14
  /// Pro 上调出来的。我三次想"再加一层保护",三次都让事情更糟。
  ///
  /// 留一个退避标志只为把告警记进日志(真机验收要看它跟内存曲线的关系)。
  static const Duration memoryBackoff = Duration(seconds: 45);
  Timer? _memoryTimer;

  @override
  void didHaveMemoryPressure() {
    // 只记录,不动任何东西 —— 见上面 v4 的说明。
    if (_memoryStop) return;
    _memoryStop = true;
    DeviceLog.log(
      'FeedLive',
      '内存告警(仅记录,不改实例上限 —— 收紧会制造 thrashing,实测更费)',
    );
    _memoryTimer?.cancel();
    _memoryTimer = Timer(memoryBackoff, () {
      _memoryTimer = null;
      _memoryStop = false;
    });
  }

  /// 后台不渲染 —— 省得息屏后还在转。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _appActive) return;
    _appActive = active;
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _settle?.cancel();
    _memoryTimer?.cancel();
    super.dispose();
  }
}


/// 全 App 同时存活的 live viewer 实例硬上限(LRU 挤出)。
///
/// 逐字取自五月 PostCard 的 _LiveInstanceRegistry,只做了一处扩展:上限可以
/// 被内存压力临时收紧。五月的原注释:
///
///   每个实例握着一块 768×768 IOSurface、一份 Dawn SharedTextureMemory
///   导入、逐 primitive 的顶点/索引/因子缓冲,以及一条逐 primitive 的
///   BindGroup 链(光国际象棋那个场景就有 49 条)。
///   上限原本是 5(compose-reels 公式 preloadCount*2+1),2026-05-02 在
///   iPhone 14 Pro 上实测"快滚 ~10s 内 thermal=serious、掉到 12-15fps"
///   之后降到 3 —— 即"当前卡 + 前一张 + 后一张"。
///
/// 参考:https://github.com/manjees/compose-reels
class CardViewerRegistry {
  /// 常态上限 —— 够整个 feed 常驻,让 3D 内容**持久存在**。
  ///
  /// [2026-08-17 用户签决] "ply 不能持久存在吗?还需要反复加载吗?" —— 对,
  /// 之前是我把因果搞反了。
  ///
  /// 真机数据(build 19,cap=2):60 秒内 13 次挂载,全是 `存活 2/2`,内存
  /// 424MB → 1752MB。feed 里 5 张卡在 2 个槽位里轮换,同一张卡被反复加载,
  /// 而 evict 之后 GPU 资源并没有真正回收 ⇒ **卸载-重载循环本身就是内存
  /// 增长的来源**,不是省内存的手段。
  ///
  /// 所以上限要大到装得下用户滚动范围内的全部卡片(当前 feed 5 个),
  /// 让每张卡加载一次就一直在:
  ///   • 没有重复的 cgltf parse / GPU 上传
  ///   • 缩略图垫底只在**首次**露一下,之后再不出现(重挂才会把
  ///     _viewerFirstFrameReady 打回 false)
  ///   • 内存是稳态的固定开销,不是反复分配的锯齿
  ///
  /// 仍然保留 LRU:feed 翻到很远处时老卡片该让位,只是不再是"每切一次焦点
  /// 就换一次"。
  static const int normalCap = 6;

  static const int pressureCap = 1;

  static int _cap = normalCap;
  static final List<void Function()> _alive = <void Function()>[];

  static int get aliveCount => _alive.length;
  static int get cap => _cap;

  static void register(void Function() forceUnmount) {
    _alive.add(forceUnmount);
    _evictDown();
  }

  /// 全部释放 —— 进详情页时用。
  ///
  /// [2026-08-17] 详情页会再开一个 ViewerQuality.full 的 viewer,而 feed 这边
  /// 的 sticky(5 分钟)让 2 个卡片 viewer 原地不动 ⇒ 三份 GPU 资源叠在一起,
  /// 正是峰值的来源。feed 此刻已经被详情页整个盖住,留着纯属浪费。
  /// 代价是 pop 回来要重挂(约 500ms + 淡入),换内存达标,值。
  static void releaseAll(String why) {
    if (_alive.isEmpty) return;
    final n = _alive.length;
    final victims = List<void Function()>.from(_alive);
    _alive.clear();
    for (final v in victims) {
      v();
    }
    DeviceLog.log('FeedLive', '释放全部 live viewer($n 个)—— $why');
  }

  static void unregister(void Function() forceUnmount) {
    _alive.remove(forceUnmount);
  }

  /// 内存压力升降 —— 收紧/放开上限,收紧时立刻挤掉超出的那些。
  ///
  /// [2026-08-17] 这是闸 7 的**正确**响应。原先的做法是把自转停掉 45 秒,
  /// 那既不省内存(自转只是一个 ticker + 每帧 setMatrices),又把用户唯一
  /// 看得见的东西关了 —— 从详情页退回来时点云僵在那里不动,就是它干的。
  /// 真正占内存的是 mount 着的 viewer 实例,所以压力来了该吐实例。
  static void setMemoryPressure(bool under) {
    final next = under ? pressureCap : normalCap;
    if (next == _cap) return;
    _cap = next;
    final before = _alive.length;
    _evictDown();
    DeviceLog.log(
      'FeedLive',
      '实例上限 ${under ? "收紧" : "放开"} → $_cap(存活 $before → ${_alive.length})',
    );
  }

  static void _evictDown() {
    while (_alive.length > _cap) {
      // 挤掉队头(最早挂载的那张)—— 列表按插入序,removeAt(0) 就是 LRU。
      final victim = _alive.removeAt(0);
      victim();
    }
  }
}
