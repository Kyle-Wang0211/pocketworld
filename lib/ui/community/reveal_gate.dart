// 页面级"一起揭幕"闸。
//
// [2026-08-24 用户签决]「需要置顶栏和任务卡片一起加载成功」。
//
// 在此之前每一层各揭各的:主题卡硬编码、瞬时完成,作品卡要等 glb viewer 的
// 第一帧。真机日志(pw_device_log.txt)把这段时间量出来了 —— 23:51:20 挂载
// 两个 live viewer,23:51:29 才内存告警,中间好几秒。于是页面上长时间是
// "一张已完成的卡压着两张加载中的卡",这本身就是第三种状态。
//
// ⚠️ **为什么单独成类而不是留在 _VaultPageState 里**:因为最该验证的那一条
// (超时兜底)留在 State 里就只能写成源码文本断言,而变异测试当场证明那种断言
// 挡不住任何东西 —— 我删掉两处 cancel() 它照样全绿。抽出来之后可以用
// testWidgets 的假时钟真把时间推过去,看它到底放不放行。

import 'dart:async';

import 'package:flutter/foundation.dart';

class RevealGate extends ChangeNotifier {
  /// 首屏参与"一起揭幕"的卡片数。与 viewer 实例上限 / cacheExtent 一个口径 ——
  /// 再多的卡用户此刻也看不到,等它们只会白等。
  final int groupSize;

  /// 兜底时长。任何一张卡卡住(模型下载失败、viewer 起不来)都不能让整页
  /// 永远灰着;到点无条件放行,没就绪的那张自己继续盖它自己的幕布。
  final Duration deadline;

  RevealGate({
    this.groupSize = 3,
    this.deadline = const Duration(milliseconds: 2500),
  });

  final Set<String> _ready = {};
  List<String> _group = const [];
  bool _revealed = true;
  Timer? _timer;
  bool _disposed = false;

  bool get revealed => _revealed;

  /// 当前这一组(测试与日志用)。
  List<String> get group => List.unmodifiable(_group);

  /// 拿到(新的一批)feed 时定组。
  ///
  /// 同一组重复调用是 no-op —— 这条很重要:调用点在 build 里(works 只存在于
  /// FutureBuilder 的 snapshot 里,没进 state),每次 build 都重定组等于每次
  /// build 都把整页打回加载态。
  void setWorks(List<String> workIds) {
    if (_disposed) return;
    final next = workIds.take(groupSize).toList();
    final same =
        next.length == _group.length &&
        !next.indexed.any((e) => _group[e.$1] != e.$2);
    if (same) return;

    _group = next;
    _ready.clear();
    _timer?.cancel();
    _revealed = next.isEmpty;
    if (!_revealed) {
      _timer = Timer(deadline, () {
        if (_disposed || _revealed) return;
        _revealed = true;
        notifyListeners();
      });
    }
    // ⚠️ **这里不 notifyListeners()**。setWorks 的调用点在 VaultPage 的 build
    // 里(works 只存在于 FutureBuilder 的 snapshot 里,没进 state),build 期间
    // 通知监听者 = build 期间 setState,直接抛
    // "setState() or markNeedsBuild() called during build"。
    // 调用方此刻本来就在重建,读 [revealed] 拿到的已经是新值。
    // 真正需要通知的是**异步**发生的两件事:超时到点、以及最后一张卡报就绪。
  }

  /// 某张卡报告"我的内容能看了"。
  void markReady(String workId) {
    if (_disposed || _revealed) return;
    _ready.add(workId);
    if (!_group.every(_ready.contains)) return;
    _timer?.cancel();
    _revealed = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
